import Foundation
import Testing
import UIKit
import SwiftUI
@testable import textual

@MainActor struct ReaderShelfDragTests {
    @Test func crossingShelfRowsKeepsTheSameCoverViews() async throws {
        let state = ReaderShelfDrag()
        let favorites = (0..<4).map { ReaderFavorite(book: Book(title: "Cover \($0)", author: "", isbn: "", coverURL: "")) }
        func shelf(_ items: [ReaderFavorite]) -> some View {
            ReaderBookshelf(readerName: "Reader", favorites: items, isOwner: true, open: { _ in })
                .environment(\.readerShelfDrag, state)
                .transaction { $0.disablesAnimations = true }
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let host = UIHostingController(rootView: shelf(favorites))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        func coverViews(_ view: UIView) -> [UIView] {
            let own = (view.gestureRecognizers ?? []).contains { $0 is UIPanGestureRecognizer } ? [view] : []
            return own + view.subviews.flatMap(coverViews)
        }
        let before = coverViews(host.view)
        #expect(before.count == 4)
        let oldFrames = favorites.compactMap { state.frame(for: $0.id, in: window) }
        // The drag coordinator commits after its UIKit spring finishes, with
        // SwiftUI animation disabled so there is no second reorder animation.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            host.rootView = shelf([favorites[1], favorites[2], favorites[3], favorites[0]])
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
        }
        // UIHostingController applies a replacement root on its next update.
        for _ in 0..<25 {
            await Task.yield()
            host.view.layoutIfNeeded()
            if let frame = state.frame(for: favorites[0].id, in: window), oldFrames.count == 4,
               abs(frame.maxY - oldFrames[3].maxY) < 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let after = coverViews(host.view)
        #expect(Set(before.map(ObjectIdentifier.init)) == Set(after.map(ObjectIdentifier.init)))
        let moved = try #require(state.frame(for: favorites[0].id, in: window))
        #expect(oldFrames.count == 4)
        #expect(abs(moved.maxY - oldFrames[3].maxY) < 1)
    }

    @Test func cancelledDragRestoresNavigationWithoutEditingShelf() {
        let state = ReaderShelfDrag(), id = UUID(), token = UUID()
        var edits = 0
        state.begin(id: id, token: token, move: { _, _ in edits += 1 }, remove: { _ in edits += 1 })
        state.isOverTrash = true
        state.finish(token: token)
        #expect(!state.isActive)
        #expect(!state.isOverTrash)
        #expect(edits == 0)
    }
    @Test func foreignOrStaleDragsCannotRemoveBooks() {
        let state = ReaderShelfDrag(), id = UUID(), token = UUID()
        var removed: [UUID] = []
        state.begin(id: id, token: token, move: { _, _ in }, remove: { removed.append($0) })
        #expect(!state.discard(id: id, token: UUID()))
        #expect(!state.discard(id: UUID(), token: token))
        state.finish(token: UUID())
        #expect(state.isActive)
        #expect(state.discard(id: id, token: token))
        #expect(!state.discard(id: id, token: token))
        #expect(removed == [id])
        #expect(!state.isActive)
    }
    @Test func placementReordersOnceAndRestoresMenu() {
        let state = ReaderShelfDrag(), id = UUID(), target = UUID(), token = UUID()
        var order = [id, target]
        state.begin(id: id, token: token, move: { from, to in
            if let a = order.firstIndex(of: from), let b = order.firstIndex(of: to) {
                order.insert(order.remove(at: a), at: b)
            }
        }, remove: { _ in Issue.record("Placement must not remove a book") })
        #expect(state.place(id: id, token: token, on: target))
        #expect(order == [target, id])
        #expect(!state.isActive)
        #expect(!state.place(id: id, token: token, on: target))
    }
    @Test func dragHitTestingUsesWindowCoordinatesAndClearsOutsideTargets() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let shelf = UIView(frame: CGRect(x: 20, y: 300, width: 360, height: 200))
        let first = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 150))
        let second = UIView(frame: CGRect(x: 120, y: 0, width: 100, height: 150))
        let trash = UIView(frame: CGRect(x: 172, y: 720, width: 56, height: 56))
        window.addSubview(shelf); shelf.addSubview(first); shelf.addSubview(second); window.addSubview(trash)
        let state = ReaderShelfDrag(), firstID = UUID(), secondID = UUID()
        state.register(first, id: firstID); state.register(second, id: secondID); state.trashView = trash
        state.begin(id: firstID, token: UUID(), move: { _, _ in }, remove: { _ in })
        state.track(CGPoint(x: 175, y: 350), in: window)
        #expect(state.targetID == secondID)
        #expect(!state.isOverTrash)
        state.track(CGPoint(x: 200, y: 748), in: window)
        #expect(state.isOverTrash)
        #expect(state.targetID == nil)
        state.track(CGPoint(x: 380, y: 200), in: window)
        #expect(!state.isOverTrash)
        #expect(state.targetID == nil)
        // Recalculate targets after scrolling/layout changes; don't use stale saved frames.
        shelf.frame.origin.y = 100
        state.track(CGPoint(x: 175, y: 150), in: window)
        #expect(state.targetID == secondID)
        state.cancel()
        #expect(!state.isActive)
    }

    @Test func coverShrinksContinuouslyAndLeavesTrashVisible() {
        let trash = CGRect(x: 172, y: 720, width: 56, height: 56)
        let far = ReaderShelfDragAppearance.proximity(CGPoint(x: 200, y: 500), trash: trash)
        let near = ReaderShelfDragAppearance.proximity(CGPoint(x: 200, y: 640), trash: trash)
        let over = ReaderShelfDragAppearance.proximity(CGPoint(x: 200, y: 748), trash: trash)
        #expect(far == 0)
        #expect(near > far && near < over)
        #expect(over == 1)
        #expect(ReaderShelfDragAppearance.scale(proximity: near) > ReaderShelfDragAppearance.scale(proximity: over))
        let size = CGSize(width: 110, height: 170)
        let center = ReaderShelfDragAppearance.center(point: CGPoint(x: 200, y: 748), offset: .zero,
                                                      size: size, trash: trash, proximity: over)
        let bottom = center.y + size.height * ReaderShelfDragAppearance.scale(proximity: over) / 2
        #expect(bottom <= trash.minY - 11.9)
        #expect(ReaderShelfDragAppearance.proximity(.zero, trash: nil) == 0)
    }

    @Test func fingerUpReturnsMenuBeforeBookSettlesOrSaveRuns() {
        let state = ReaderShelfDrag(), id = UUID(), target = UUID(), token = UUID()
        var saves = 0
        state.begin(id: id, token: token, move: { _, _ in saves += 1 }, remove: { _ in saves += 1 })
        #expect(state.isDragging)
        state.release()
        #expect(!state.isDragging)
        #expect(state.isActive)
        #expect(saves == 0)
        #expect(state.place(id: id, token: token, on: target))
        #expect(saves == 1)
        #expect(!state.isActive)
    }

    @Test func liveInsertionKeepsHitSlotsStableAndDoesNotSaveUntilDrop() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let first = UIView(frame: CGRect(x: 20, y: 300, width: 100, height: 150))
        let second = UIView(frame: CGRect(x: 140, y: 330, width: 100, height: 120))
        let third = UIView(frame: CGRect(x: 260, y: 300, width: 100, height: 150))
        [first, second, third].forEach(window.addSubview)
        let ids = [UUID(), UUID(), UUID()], token = UUID(), state = ReaderShelfDrag()
        for (id, view) in zip(ids, [first, second, third]) { state.register(view, id: id) }
        var saved: [UUID] = ids
        state.begin(id: ids[0], token: token, order: ids,
                    move: { saved = ReaderShelfReorder.preview(saved, moving: $0, to: $1) }, remove: { _ in })
        let slot = try #require(state.frame(for: ids[2], in: window))
        state.track(CGPoint(x: 310, y: 350), in: window)
        #expect(state.targetID == ids[2])
        #expect(saved == ids)
        // Moving covers must not move their hit-test slots or retrigger neighboring slots.
        #expect(state.frame(for: ids[2], in: window) == slot)
        state.track(CGPoint(x: 310, y: 350), in: window)
        #expect(state.targetID == ids[2])
        let landing = try #require(state.landingFrame(for: ids[0], at: ids[1], in: window))
        #expect(landing.height == first.bounds.height)
        #expect(landing.maxY == second.frame.maxY)
        state.release()
        #expect(state.place(id: ids[0], token: token, on: ids[2]))
        #expect(saved == [ids[1], ids[2], ids[0]])
        #expect([first, second, third].allSatisfy { $0.transform == .identity })
    }

    @Test func canceledLiveInsertionKeepsOriginalOrder() {
        let ids = [UUID(), UUID(), UUID(), UUID()]
        #expect(ReaderShelfReorder.preview(ids, moving: ids[0], to: ids[3]) == [ids[1], ids[2], ids[3], ids[0]])
        #expect(ReaderShelfReorder.preview(ids, moving: ids[3], to: ids[0]) == [ids[3], ids[0], ids[1], ids[2]])
        let state = ReaderShelfDrag(), token = UUID()
        var saved = ids
        state.begin(id: ids[0], token: token, order: ids,
                    move: { saved = ReaderShelfReorder.preview(saved, moving: $0, to: $1) }, remove: { _ in })
        state.release()
        state.finish(token: token)
        #expect(saved == ids)
        #expect(!state.isDragging && !state.isActive)
    }

}
