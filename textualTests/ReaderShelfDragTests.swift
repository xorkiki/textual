import Foundation
import Testing
import UIKit
import SwiftUI
@testable import textual

@MainActor struct ReaderShelfDragTests {
    @Test(arguments: [ReaderBookshelf.Kind.favorites, .upNext])
    func crossingShelfRowsKeepsTheSameCoverViews(kind: ReaderBookshelf.Kind) async throws {
        let state = ReaderShelfDrag()
        let favorites = (0..<4).map { ReaderFavorite(book: Book(title: "Cover \($0)", author: "", isbn: "", coverURL: "")) }
        func shelf(_ items: [ReaderFavorite]) -> some View {
            ReaderBookshelf(readerName: "Reader", kind: kind, favorites: items, isOwner: true, open: { _ in })
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
        // Owner shelves start locked without removing their stable cover views.
        #expect(before.flatMap { $0.gestureRecognizers ?? [] }
            .filter { $0 is UIPanGestureRecognizer }.allSatisfy { !$0.isEnabled })
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

    @Test func draggingRequiresEditModeButTappingStillOpensBooks() {
        let state = ReaderShelfDrag(), id = UUID()
        var opened = 0
        func source(editing: Bool) -> ReaderShelfDragSource<Text> {
            ReaderShelfDragSource(id: id, order: [id], state: state, isEnabled: editing,
                                 move: { _, _ in }, remove: { _ in }, open: { opened += 1 }) {
                Text("Book")
            }
        }
        let coordinator = source(editing: false).makeCoordinator()
        let pan = UIPanGestureRecognizer()
        #expect(!coordinator.gestureRecognizerShouldBegin(pan))
        coordinator.openBook()
        #expect(opened == 1)
        coordinator.parent = source(editing: true)
        #expect(coordinator.gestureRecognizerShouldBegin(pan))
        state.begin(id: id, token: UUID(), move: { _, _ in }, remove: { _ in })
        #expect(!coordinator.gestureRecognizerShouldBegin(pan))
        state.cancel()
        coordinator.parent = source(editing: false)
        #expect(!coordinator.gestureRecognizerShouldBegin(pan))
        coordinator.openBook()
        #expect(opened == 2)
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

    @Test func insertionTargetsIncludeGapsShortCoversAndPartialRows() {
        let ids = (0..<4).map { _ in UUID() }
        let slots = [
            (id: ids[0], frame: CGRect(x: 20, y: 300, width: 100, height: 150)),
            (id: ids[1], frame: CGRect(x: 140, y: 330, width: 100, height: 120)),
            (id: ids[2], frame: CGRect(x: 260, y: 300, width: 100, height: 150)),
            (id: ids[3], frame: CGRect(x: 20, y: 510, width: 100, height: 150))
        ]
        #expect(ReaderShelfReorder.destination(at: CGPoint(x: 190, y: 305), slots: slots) == ids[1])
        #expect(ReaderShelfReorder.destination(at: CGPoint(x: 135, y: 375), slots: slots) == ids[1])
        #expect(ReaderShelfReorder.destination(at: CGPoint(x: 310, y: 500), slots: slots) == ids[3])
        #expect(ReaderShelfReorder.destination(at: CGPoint(x: 310, y: 580), slots: slots) == ids[3])
        #expect(ReaderShelfReorder.destination(at: CGPoint(x: 390, y: 750), slots: slots) == nil)
    }

    @Test func hostedCoversMakeRoomAcrossRowsAndSurviveLayoutUpdates() async throws {
        let ids = (0..<4).map { _ in UUID() }, state = ReaderShelfDrag(), token = UUID()
        var saves = 0
        func shelf() -> some View {
            ZStack(alignment: .topLeading) {
                ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                    ReaderShelfDragSource(id: id, order: ids, state: state, isEnabled: true,
                                          move: { _, _ in saves += 1 }, remove: { _ in saves += 1 }, open: {}) {
                        Text("Book \(index)").frame(width: 100, height: 150)
                    }
                    .frame(width: 100, height: 150)
                    .opacity(state.bookID == id ? 0 : 1)
                    .position(x: CGFloat(index % 3) * 120 + 70, y: CGFloat(index / 3) * 210 + 175)
                }
            }.frame(width: 380, height: 500)
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let host = UIHostingController(rootView: shelf())
        window.rootViewController = host
        window.isHidden = false
        defer { state.cancel(); window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        func surfaces(_ view: UIView) -> [UIView] {
            let own = (view.gestureRecognizers ?? []).contains { $0 is UIPanGestureRecognizer } ? [view] : []
            return own + view.subviews.flatMap(surfaces)
        }
        let views = surfaces(host.view)
        let slots = ids.compactMap { state.frame(for: $0, in: window) }
        #expect(views.count == 4)
        #expect(slots.count == 4)
        guard views.count == 4, slots.count == 4 else { return }
        let lastSurface = try #require(views.first { abs($0.convert($0.bounds, to: window).midY - slots[3].midY) < 1 })
        let lastCover = try #require(lastSurface.subviews.first)
        state.begin(id: ids[0], token: token, order: ids,
                    move: { _, _ in saves += 1 }, remove: { _ in saves += 1 })
        state.track(CGPoint(x: slots[3].midX, y: slots[3].midY), in: window)
        // Force the parent update that used to overwrite outer-view transforms.
        host.rootView = shelf()
        try await Task.sleep(for: .milliseconds(450))
        host.view.layoutIfNeeded()
        let shifted = lastCover.convert(lastCover.bounds, to: window)
        #expect(abs(shifted.midX - slots[2].midX) < 1)
        #expect(abs(shifted.maxY - slots[2].maxY) < 1)
        #expect(lastSurface.transform == .identity)
        #expect(state.frame(for: ids[3], in: window) == slots[3])
        #expect(saves == 0)
        state.track(CGPoint(x: slots[0].midX, y: slots[0].midY), in: window)
        try await Task.sleep(for: .milliseconds(450))
        #expect(lastCover.transform == .identity)
        #expect(state.targetID == nil)
        state.track(CGPoint(x: slots[3].midX, y: slots[3].midY), in: window)
        state.track(CGPoint(x: -200, y: -200), in: window)
        try await Task.sleep(for: .milliseconds(450))
        #expect(lastCover.transform == .identity)
        #expect(state.targetID == nil)
        #expect(saves == 0)
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
