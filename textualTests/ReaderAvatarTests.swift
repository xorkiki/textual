import Foundation
import ImageIO
import SwiftData
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import textual

@MainActor
struct ReaderAvatarTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: ReaderProfileDraft.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func oldCardsDecodeWithoutPhotoAndPathsAreAccountScoped() throws {
        let content = try JSONDecoder().decode(ReaderPublicContent.self, from: Data(
            #"{"stats":{"reads":2,"genres":1,"rereads":0},"sentence":"hello","favorites":[]}"#.utf8))
        #expect(content.avatarPath == nil)
        let owner = UUID(), path = ReaderAvatar.path(userID: owner)
        #expect(ReaderAvatar.isValid(path: path, userID: owner))
        #expect(!ReaderAvatar.isValid(path: path, userID: UUID()))
        #expect(!ReaderAvatar.isValid(path: "../" + path))
        #expect(!ReaderAvatar.isValid(path: "https://example.com/photo.jpg"))
    }

    @Test func photoIsResizedAndLocationMetadataIsRemoved() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 1200), format: format).image { renderer in
            UIColor.green.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
        }
        let original = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(original, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(image.cgImage), [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 10.0, kCGImagePropertyGPSLongitude: 20.0]
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let prepared = try await ReaderAvatarProcessor.shared.prepare(original as Data)
        let source = try #require(CGImageSourceCreateWithData(prepared as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 768)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 576)
        #expect(prepared.count <= ReaderAvatar.maximumBytes)
        await #expect(throws: ReaderAvatar.PhotoError.self) {
            try await ReaderAvatarProcessor.shared.prepare(Data("not a photo".utf8))
        }
    }

    @Test func selectedPhotoSurvivesReopeningAndDoesNotLeakToAnotherAccount() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("profile.store"), owner = UUID(), data = Data([1, 2, 3])
        func write() throws {
            let container = try ModelContainer(for: ReaderProfileDraft.self, configurations: ModelConfiguration(url: url))
            let store = ReaderProfileStore(userID: owner, context: container.mainContext, transport: AvatarFixtureTransport())
            try store.update(ReaderPersonality.summarize([], favorites: []))
            try store.setAvatar(data)
        }
        try write()
        let reopened = try ModelContainer(for: ReaderProfileDraft.self, configurations: ModelConfiguration(url: url))
        let store = ReaderProfileStore(userID: owner, context: reopened.mainContext, transport: AvatarFixtureTransport())
        #expect(try store.draft()?.matchingAvatarData == data)
        #expect(try store.draft()?.avatarNeedsUpload == true)
        let other = ReaderProfileStore(userID: UUID(), context: reopened.mainContext, transport: AvatarFixtureTransport())
        #expect(try other.draft() == nil)
    }

    @Test func failedPhotoUploadRemainsQueuedAndPublishesOnlyAfterRetry() async throws {
        let container = try container(), transport = AvatarFixtureTransport()
        let store = ReaderProfileStore(userID: UUID(), context: container.mainContext, transport: transport)
        try store.update(ReaderPersonality.summarize([], favorites: []))
        try store.setAvatar(Data([1, 2, 3]))
        await transport.failUpload(true)
        await store.synchronize(username: "reader")
        #expect(try store.draft()?.avatarNeedsUpload == true)
        #expect(try store.draft()?.matchingAvatarData == Data([1, 2, 3]))
        #expect(await transport.profile == nil)
        await transport.failUpload(false)
        await store.synchronize(username: "reader")
        #expect(try store.draft()?.needsUpload == false)
        #expect(try store.draft()?.avatarNeedsUpload == false)
        #expect(await transport.profile?.content.avatarPath == (try store.draft()?.content?.avatarPath))
    }

    @Test func publishRetryReusesUploadedPhotoAndNewDeviceRestoresIt() async throws {
        let container = try container(), transport = AvatarFixtureTransport(), owner = UUID()
        let store = ReaderProfileStore(userID: owner, context: container.mainContext, transport: transport)
        try store.update(ReaderPersonality.summarize([], favorites: []))
        try store.setAvatar(Data([1, 2, 3]))
        await transport.failPublish(true)
        await store.synchronize(username: "reader")
        #expect(try store.draft()?.avatarNeedsUpload == false)
        #expect(try store.draft()?.needsUpload == true)
        await transport.failPublish(false)
        await store.synchronize(username: "reader")
        #expect(await transport.uploadCount == 1)
        let fresh = try self.container()
        let restored = ReaderProfileStore(userID: owner, context: fresh.mainContext, transport: transport)
        try restored.update(ReaderPersonality.summarize([], favorites: []))
        await restored.synchronize(username: "reader")
        let path = try #require(try restored.draft()?.content?.avatarPath)
        #expect(try await transport.downloadAvatar(path: path) == Data([1, 2, 3]))
        #expect(try restored.draft()?.needsUpload == false)
    }

    @Test func choosingRemoteProfileDiscardsPendingLocalPhoto() async throws {
        let container = try container(), transport = AvatarFixtureTransport(), owner = UUID()
        let store = ReaderProfileStore(userID: owner, context: container.mainContext, transport: transport)
        try store.update(ReaderPersonality.summarize([], favorites: []))
        await store.synchronize(username: "reader")
        try store.setAvatar(Data([1]))
        var remote = ReaderPersonality.summarize([], favorites: [])
        remote.avatarPath = ReaderAvatar.path(userID: owner)
        try await transport.uploadAvatar(userID: owner, path: remote.avatarPath!, data: Data([2]))
        _ = try await transport.publish(userID: owner, revision: 1, content: remote)
        await store.synchronize(username: "reader")
        #expect(store.conflictingProfile != nil)
        try store.resolveConflict(keepLocal: false)
        #expect(try store.draft()?.content?.avatarPath == remote.avatarPath)
        #expect(try store.draft()?.avatarNeedsUpload == false)
        #expect(try store.draft()?.matchingAvatarData == nil)
    }
}

private actor AvatarFixtureTransport: ReaderProfileTransport {
    var profile: PublicReaderProfile?
    var uploaded: [String: Data] = [:]
    var uploadCount = 0
    private var uploadFails = false
    private var publishFails = false
    func failUpload(_ value: Bool) { uploadFails = value }
    func failPublish(_ value: Bool) { publishFails = value }
    func fetch(username: String) async throws -> PublicReaderProfile? { profile }
    func uploadAvatar(userID: UUID, path: String, data: Data) async throws {
        if uploadFails { throw URLError(.notConnectedToInternet) }
        uploadCount += 1; uploaded[path] = data
    }
    func downloadAvatar(path: String) async throws -> Data {
        guard let data = uploaded[path] else { throw URLError(.fileDoesNotExist) }
        return data
    }
    func publish(userID: UUID, revision: Int, content: ReaderPublicContent) async throws -> PublicReaderProfile {
        if publishFails { throw URLError(.notConnectedToInternet) }
        if let path = content.avatarPath, uploaded[path] == nil { throw URLError(.fileDoesNotExist) }
        let saved = PublicReaderProfile(username: "reader", firstName: "Reader", memberSince: "2026-10-09", revision: revision + 1, content: content)
        profile = saved
        return saved
    }
}
