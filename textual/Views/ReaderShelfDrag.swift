import SwiftUI
import Observation
import UIKit

/// One local shelf drag, scoped to the signed-in account's tab host.
@MainActor @Observable
final class ReaderShelfDrag {
    private(set) var bookID: UUID?
    private(set) var token: UUID?
    var targetID: UUID?
    var isOverTrash = false
    private(set) var isSettling = false
    var isDragging: Bool { isActive && !isSettling }
    func release() { isSettling = true; isOverTrash = false }
    @ObservationIgnored private var targets: [UUID: WeakShelfTarget] = [:]
    @ObservationIgnored private var orderedIDs: [UUID] = []
    @ObservationIgnored private var previewTarget: UUID?
    @ObservationIgnored private var previewAnimator: UIViewPropertyAnimator?
    @ObservationIgnored weak var trashView: UIView?
    func register(_ view: UIView, id: UUID) { targets[id] = WeakShelfTarget(view) }
    func frame(for id: UUID, in window: UIWindow) -> CGRect? {
        guard let view = targets[id]?.view, view.window === window else { return nil }
        // Hit-test the stable shelf slots, not books moving under a spring animation.
        guard let superview = view.superview else { return nil }
        let center = superview.convert(view.center, to: window)
        return CGRect(x: center.x - view.bounds.width / 2, y: center.y - view.bounds.height / 2,
                      width: view.bounds.width, height: view.bounds.height)
    }
    func trashFrame(in window: UIWindow) -> CGRect? {
        guard let view = trashView, view.window === window else { return nil }
        return view.convert(view.bounds, to: window)
    }
    func track(_ point: CGPoint, in window: UIWindow) {
        let overTrash = trashView.map { $0.window === window && $0.convert($0.bounds, to: window).insetBy(dx: -12, dy: -12).contains(point) } ?? false
        if overTrash && !isOverTrash { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
        isOverTrash = overTrash
        let ids = orderedIDs.isEmpty ? Array(targets.keys) : orderedIDs
        let hit = overTrash ? nil : ids.first { frame(for: $0, in: window)?.insetBy(dx: -6, dy: -6).contains(point) == true }
        targetID = hit == bookID ? nil : hit
        if let hit { previewInsertion(at: hit, in: window) }
    }
    private func stopPreviewAtPresentation() {
        guard let animator = previewAnimator else { return }
        let current = targets.compactMapValues { $0.view?.layer.presentation()?.affineTransform() }
        animator.stopAnimation(true)
        for (id, transform) in current { targets[id]?.view?.transform = transform }
        previewAnimator = nil
    }
    private func previewInsertion(at target: UUID, in window: UIWindow) {
        guard let bookID, !orderedIDs.isEmpty, previewTarget != target else { return }
        previewTarget = target
        let order = ReaderShelfReorder.preview(orderedIDs, moving: bookID, to: target)
        animatePreview(order, in: window)
        if target != bookID { UISelectionFeedbackGenerator().selectionChanged() }
    }
    func previewRemoval(in window: UIWindow) {
        guard let bookID else { return }
        animatePreview(orderedIDs.filter { $0 != bookID }, in: window)
    }
    private func animatePreview(_ order: [UUID], in window: UIWindow) {
        guard let bookID else { return }
        let slots = orderedIDs.compactMap { frame(for: $0, in: window) }
        guard slots.count == orderedIDs.count else { return }
        stopPreviewAtPresentation()
        let animations = {
            for (index, id) in order.enumerated() where id != bookID {
                guard let view = self.targets[id]?.view, let base = self.frame(for: id, in: window) else { continue }
                let slot = slots[index]
                view.transform = CGAffineTransform(translationX: slot.midX - base.midX, y: slot.maxY - base.maxY)
            }
        }
        if UIAccessibility.isReduceMotionEnabled { animations(); return }
        let animator = UIViewPropertyAnimator(duration: 0.32, dampingRatio: 0.88, animations: animations)
        previewAnimator = animator
        animator.startAnimation()
    }
    func restorePreview(animated: Bool) {
        stopPreviewAtPresentation()
        let animations = { for target in self.targets.values { target.view?.transform = .identity } }
        if animated && !UIAccessibility.isReduceMotionEnabled {
            let animator = UIViewPropertyAnimator(duration: 0.3, dampingRatio: 0.9, animations: animations)
            previewAnimator = animator
            animator.startAnimation()
        } else { animations() }
        previewTarget = nil
    }
    func landingFrame(for id: UUID, at target: UUID?, in window: UIWindow) -> CGRect? {
        guard let source = frame(for: id, in: window) else { return nil }
        guard let target, let slot = frame(for: target, in: window) else { return source }
        return CGRect(x: slot.midX - source.width / 2, y: slot.maxY - source.height,
                      width: source.width, height: source.height)
    }
    @ObservationIgnored private var moveBook: ((UUID, UUID) -> Void)?
    @ObservationIgnored private var removeBook: ((UUID) -> Void)?
    var isActive: Bool { bookID != nil }

    func begin(id: UUID, token: UUID, order: [UUID] = [], move: @escaping (UUID, UUID) -> Void, remove: @escaping (UUID) -> Void) {
        cancel()
        orderedIDs = order
        bookID = id; self.token = token; moveBook = move; removeBook = remove
    }

    func accepts(id: UUID, token: UUID) -> Bool { bookID == id && self.token == token }

    @discardableResult func place(id: UUID, token: UUID, on target: UUID) -> Bool {
        guard accepts(id: id, token: token) else { return false }
        let action = moveBook
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) {
            cancel()
            if id != target { action?(id, target) }
        }
        return true
    }

    @discardableResult func discard(id: UUID, token: UUID) -> Bool {
        guard accepts(id: id, token: token) else { return false }
        let action = removeBook
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) {
            cancel()
            action?(id)
        }
        return true
    }

    func finish(token: UUID) { if self.token == token { cancel() } }
    func cancel() {
        restorePreview(animated: false)
        orderedIDs = []; isSettling = false
        bookID = nil; token = nil; targetID = nil; isOverTrash = false
        moveBook = nil; removeBook = nil
    }
}

enum ReaderShelfReorder {
    static func preview(_ ids: [UUID], moving id: UUID, to target: UUID) -> [UUID] {
        guard let source = ids.firstIndex(of: id), let destination = ids.firstIndex(of: target) else { return ids }
        var result = ids
        result.insert(result.remove(at: source), at: destination)
        return result
    }
}

/// Continuous proximity response, independent of the animated navigation capsule.
enum ReaderShelfDragAppearance {
    static func proximity(_ point: CGPoint, trash: CGRect?) -> CGFloat {
        guard let trash else { return 0 }
        let distance = hypot(point.x - trash.midX, point.y - trash.midY)
        let t = min(1, max(0, (180 - distance) / 136))
        return t * t * (3 - 2 * t)
    }
    static func scale(proximity: CGFloat) -> CGFloat { 1.03 - 0.79 * proximity }
    static func center(point: CGPoint, offset: CGPoint, size: CGSize, trash: CGRect?, proximity: CGFloat) -> CGPoint {
        let normal = CGPoint(x: point.x + offset.x, y: point.y + offset.y)
        guard let trash else { return normal }
        let above = CGPoint(x: trash.midX, y: trash.minY - 12 - size.height * scale(proximity: proximity) / 2)
        return CGPoint(x: normal.x + (above.x - normal.x) * proximity,
                       y: normal.y + (above.y - normal.y) * proximity)
    }
}

private struct ReaderShelfDragKey: EnvironmentKey {
    static let defaultValue: ReaderShelfDrag? = nil
}
extension EnvironmentValues {
    var readerShelfDrag: ReaderShelfDrag? {
        get { self[ReaderShelfDragKey.self] }
        set { self[ReaderShelfDragKey.self] = newValue }
    }
}

private final class WeakShelfTarget {
    weak var view: UIView?
    init(_ view: UIView) { self.view = view }
}

/// A dedicated touch surface separates tap-to-open from direct dragging.
struct ReaderShelfDragSource<Content: View>: UIViewRepresentable {
    let id: UUID
    let order: [UUID]
    let state: ReaderShelfDrag
    let move: (UUID, UUID) -> Void
    let remove: (UUID) -> Void
    let open: () -> Void
    let content: Content

    init(id: UUID, order: [UUID], state: ReaderShelfDrag, move: @escaping (UUID, UUID) -> Void,
         remove: @escaping (UUID) -> Void, open: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.id = id; self.order = order; self.state = state; self.move = move; self.remove = remove; self.open = open; self.content = content()
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> ShelfTouchView {
        let host = UIHostingController(rootView: content)
        context.coordinator.host = host
        let view = ShelfTouchView()
        view.backgroundColor = .clear
        let hosted = host.view!
        hosted.backgroundColor = .clear
        hosted.isUserInteractionEnabled = false
        hosted.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosted)
        NSLayoutConstraint.activate([
            hosted.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosted.topAnchor.constraint(equalTo: view.topAnchor),
            hosted.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        view.shelfPan = pan
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.openBook))
        tap.require(toFail: pan)
        view.addGestureRecognizer(tap)
        state.register(view, id: id)
        return view
    }
    func updateUIView(_ uiView: ShelfTouchView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.host?.rootView = content
        state.register(uiView, id: id)
    }
    static func dismantleUIView(_ uiView: ShelfTouchView, coordinator: Coordinator) { coordinator.cancel() }

    final class ShelfTouchView: UIView {
        weak var shelfPan: UIPanGestureRecognizer?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let pan = shelfPan, let scroll = enclosingScrollView {
                scroll.panGestureRecognizer.require(toFail: pan)
            }
        }
        var enclosingScrollView: UIScrollView? {
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView { return scroll }
                ancestor = view.superview
            }
            return nil
        }
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: ReaderShelfDragSource
        var host: UIHostingController<Content>?
        private var token: UUID?
        private var lifted: UIView?
        private var origin = CGRect.zero
        private var touchOffset = CGPoint.zero
        private weak var activePan: UIPanGestureRecognizer?
        private var displayLink: CADisplayLink?
        private var visualProximity: CGFloat = 0
        private var lastFrameTime: CFTimeInterval = 0
        init(_ parent: ReaderShelfDragSource) { self.parent = parent }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { !parent.state.isActive }
        @objc func openBook() { if !parent.state.isActive { parent.open() } }

        @objc func pan(_ pan: UIPanGestureRecognizer) {
            guard let view = pan.view, let window = view.window else { cancel(); return }
            let point = pan.location(in: window)
            switch pan.state {
            case .began:
                let token = UUID()
                self.token = token
                visualProximity = 0; lastFrameTime = CACurrentMediaTime()
                origin = view.convert(view.bounds, to: window)
                let translation = pan.translation(in: window)
                touchOffset = CGPoint(x: origin.midX - point.x + translation.x, y: origin.midY - point.y + translation.y)
                let snapshot = view.snapshotView(afterScreenUpdates: false) ?? UIView(frame: origin)
                snapshot.frame = origin
                snapshot.isUserInteractionEnabled = false
                snapshot.layer.shadowColor = UIColor.black.cgColor
                snapshot.layer.shadowOpacity = 0.4
                snapshot.layer.shadowRadius = 12
                window.addSubview(snapshot)
                lifted = snapshot
                parent.state.begin(id: parent.id, token: token, order: parent.order, move: parent.move, remove: parent.remove)
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                activePan = pan
                let link = CADisplayLink(target: self, selector: #selector(displayFrame))
                let refresh = Float(window.screen.maximumFramesPerSecond)
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: refresh, preferred: refresh)
                link.add(to: .main, forMode: .common)
                displayLink = link
                update(point, window: window)
            case .changed:
                break // The display link owns movement updates; don't also animate on touch delivery.
            case .ended:
                parent.state.track(point, in: window)
                finish(window: window, commit: true)
            case .cancelled, .failed:
                finish(window: window, commit: false)
            default: break
            }
        }
        private func update(_ point: CGPoint, window: UIWindow) {
            guard let token, parent.state.accepts(id: parent.id, token: token) else { cancel(); return }
            let trash = parent.state.trashFrame(in: window)
            let now = CACurrentMediaTime()
            let dt = min(0.05, max(1.0 / 240, now - lastFrameTime))
            lastFrameTime = now
            let desired = ReaderShelfDragAppearance.proximity(point, trash: trash)
            visualProximity += (desired - visualProximity) * CGFloat(1 - exp(-dt / 0.055))
            let proximity = visualProximity
            let scale = ReaderShelfDragAppearance.scale(proximity: proximity)
            // Direct finger tracking avoids competing animation blocks on every movement.
            lifted?.transform = CGAffineTransform(scaleX: scale, y: scale)
            lifted?.center = ReaderShelfDragAppearance.center(point: point, offset: touchOffset,
                size: origin.size, trash: trash, proximity: proximity)
            parent.state.track(point, in: window)
        }
        @objc private func displayFrame() {
            guard let pan = activePan, let view = pan.view as? ShelfTouchView, let window = view.window else { return }
            let point = pan.location(in: window)
            defer { update(point, window: window) }
            guard let scroll = view.enclosingScrollView,
                  ReaderShelfDragAppearance.proximity(point, trash: parent.state.trashFrame(in: window)) < 0.1 else { return }
            let rect = scroll.convert(scroll.bounds, to: window)
            let top = rect.minY + scroll.adjustedContentInset.top + 55
            let bottom = min(rect.maxY, window.bounds.maxY - 100)
            let dt = min(0.05, max(1.0 / 240, (displayLink?.targetTimestamp ?? 0) - (displayLink?.timestamp ?? 0)))
            let edge = point.y < top ? max(-1, (point.y - top) / 60) : (point.y > bottom ? min(1, (point.y - bottom) / 60) : 0)
            let speed = edge * 360 * dt
            let minimum = -scroll.adjustedContentInset.top
            let maximum = max(minimum, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            let next = min(maximum, max(minimum, scroll.contentOffset.y + speed))
            if abs(next - scroll.contentOffset.y) > 0.01 { scroll.contentOffset.y = next }
        }
        private func finish(window: UIWindow, commit: Bool) {
            guard let token else { return }
            displayLink?.invalidate(); displayLink = nil; activePan = nil
            let state = parent.state
            let trash = commit && state.isOverTrash
            let target = commit ? state.targetID : nil
            let id = parent.id
            let destination = state.landingFrame(for: id, at: target, in: window) ?? origin
            let snapshot = lifted
            lifted = nil; self.token = nil
            let trashFrame = state.trashFrame(in: window)
            // Navigation returns on finger-up, independently of the shelf's settling animation.
            state.release()
            if trash { state.previewRemoval(in: window) }
            if !trash && target == nil { state.restorePreview(animated: true) }
            UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0.12 : 0.3,
                           delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
                           options: [.beginFromCurrentState, .allowUserInteraction], animations: {
                if trash {
                    snapshot?.transform = CGAffineTransform(scaleX: 0.02, y: 0.02)
                    if let trashFrame { snapshot?.center = CGPoint(x: trashFrame.midX, y: trashFrame.midY) }
                    snapshot?.alpha = 0
                } else {
                    snapshot?.transform = .identity
                    snapshot?.bounds.size = destination.size
                    snapshot?.center = CGPoint(x: destination.midX, y: destination.midY)
                }
            }, completion: { _ in
                if trash { state.discard(id: id, token: token) }
                else if let target { state.place(id: id, token: token, on: target) }
                else { state.finish(token: token) }
                snapshot?.removeFromSuperview()
            })
            if trash { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            else if target != nil { UISelectionFeedbackGenerator().selectionChanged() }
        }
        func cancel() {
            displayLink?.invalidate(); displayLink = nil; activePan = nil
            lifted?.removeFromSuperview(); lifted = nil
            if let token { parent.state.finish(token: token) }
            token = nil
        }
    }
}

struct ReaderShelfTrashTarget: UIViewRepresentable {
    let state: ReaderShelfDrag
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        state.trashView = view
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) { state.trashView = uiView }
}
