import SwiftUI
import UIKit

struct HoldSlideAction: Identifiable {
    let id: String
    let title: String
    let icon: DesignSystemIcon
}

/// Fixed targets for the lifetime of a gesture. Hit testing never follows animation.
struct HoldSlideLayout {
    let origin: CGPoint
    let centers: [CGPoint]
    static let hitRadius: CGFloat = 30

    init(origin: CGPoint, bounds: CGRect, count: Int) {
        self.origin = origin
        let safe = bounds.insetBy(dx: 36, dy: 36)
        var best: [CGPoint] = []
        var bestScore = CGFloat.infinity
        for (radius, spread) in [(CGFloat(100), CGFloat.pi * 0.74), (CGFloat(132), CGFloat.pi * 0.55), (CGFloat(156), CGFloat.pi * 0.433)] {
        for step in 0..<72 {
            let direction = -CGFloat.pi / 2 + CGFloat(step) * .pi / 36
            let points = (0..<count).map { index in
                let angle = direction + (count > 1 ? CGFloat(index) / CGFloat(count - 1) - 0.5 : 0) * spread
                return CGPoint(x: origin.x + cos(angle) * radius, y: origin.y + sin(angle) * radius)
            }
            let overflow = points.reduce(CGFloat.zero) { result, point in
                result + pow(max(safe.minX - point.x, 0, point.x - safe.maxX), 2)
                    + pow(max(safe.minY - point.y, 0, point.y - safe.maxY), 2)
            }
            // Prefer an upward arc, rotating inward near the screen edges.
            let score = overflow * 1000 + CGFloat(min(step, 72 - step)) + (radius - 100) * 2
            if score < bestScore { best = points; bestScore = score }
        }
        }
        centers = best
    }

    func target(at point: CGPoint) -> Int? {
        guard hypot(point.x - origin.x, point.y - origin.y) > 36 else { return nil }
        return centers.indices.first { hypot(point.x - centers[$0].x, point.y - centers[$0].y) <= Self.hitRadius }
    }
}

/// Reusable SwiftUI touch surface. A single continuous UIKit long press owns the
/// entire hold/slide/release; there is no second drag recognizer to steal the touch.
/// Ordinary scrolling wins before the hold begins. Once it begins, it owns movement.
struct HoldSlideSource<Content: View>: UIViewRepresentable {
    let actions: [HoldSlideAction]
    let isEnabled: Bool
    let open: () -> Void
    let select: (String) -> Void
    var onHoldBegan: () -> Void = {}
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        let host = UIHostingController(rootView: content())
        context.coordinator.host = host
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.32
        hold.allowableMovement = 8
        hold.delegate = context.coordinator
        view.addGestureRecognizer(hold)
        view.hold = hold
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap))
        tap.require(toFail: hold)
        view.addGestureRecognizer(tap)
        view.onDetach = { [weak coordinator = context.coordinator] in coordinator?.cancel() }
        return view
    }
    func updateUIView(_ view: TouchView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.host?.rootView = content()
        view.hold?.isEnabled = isEnabled
        if !isEnabled { context.coordinator.cancel() }
    }
    static func dismantleUIView(_ view: TouchView, coordinator: Coordinator) { coordinator.cancel() }

    final class TouchView: UIView {
        weak var hold: UILongPressGestureRecognizer?
        var onDetach: (() -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { onDetach?() }
        }
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: HoldSlideSource
        var host: UIHostingController<Content>?
        private var overlay: UIHostingController<HoldSlideOverlay>?
        private var layout: HoldSlideLayout?
        private var highlighted: Int?
        private var activeActions: [HoldSlideAction] = []
        private let feedback = UISelectionFeedbackGenerator()
        init(_ parent: HoldSlideSource) {
            self.parent = parent
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(cancel),
                name: UIApplication.willResignActiveNotification, object: nil)
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard parent.isEnabled, !parent.actions.isEmpty else { return false }
            var ancestor = gestureRecognizer.view?.superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView, scroll.isDragging || scroll.isDecelerating { return false }
                ancestor = view.superview
            }
            return true
        }
        @objc func tap() { if parent.isEnabled { parent.open() } }
        @objc func hold(_ gesture: UILongPressGestureRecognizer) {
            guard parent.isEnabled, let window = gesture.view?.window else { cancel(); return }
            let point = gesture.location(in: window)
            switch gesture.state {
            case .began:
                cancel()
                parent.onHoldBegan()
                activeActions = parent.actions
                let layout = HoldSlideLayout(origin: point,
                    bounds: window.bounds.inset(by: window.safeAreaInsets), count: activeActions.count)
                self.layout = layout
                let overlay = UIHostingController(rootView: HoldSlideOverlay(actions: activeActions,
                    layout: layout, highlighted: nil))
                overlay.view.backgroundColor = .clear
                overlay.view.isUserInteractionEnabled = false
                overlay.view.frame = window.bounds
                window.addSubview(overlay.view)
                self.overlay = overlay
                overlay.view.alpha = 0
                UIView.animate(withDuration: 0.14) { overlay.view.alpha = 1 }
                UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.7)
                feedback.prepare()
            case .changed:
                guard let layout else { return }
                // A rotation or window resize invalidates the old touch geometry.
                guard overlay?.view.frame == window.bounds else { cancel(); return }
                let next = layout.target(at: point)
                if next != highlighted {
                    highlighted = next
                    if next != nil { feedback.selectionChanged(); feedback.prepare() }
                    overlay?.rootView = HoldSlideOverlay(actions: activeActions, layout: layout, highlighted: next)
                }
            case .ended:
                let action = layout?.target(at: point).map { activeActions[$0].id }
                cancel()
                if let action { parent.select(action) }
            case .failed, .cancelled: cancel()
            default: break
            }
        }
        @objc func cancel() {
            overlay?.view.removeFromSuperview()
            overlay = nil; layout = nil; highlighted = nil; activeActions = []
        }
    }
}

struct HoldSlideOverlay: View {
    let actions: [HoldSlideAction]
    let layout: HoldSlideLayout
    let highlighted: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.inkwell.opacity(0.22)
                ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                    DesignSystemIconView(action.icon, size: 23)
                        .foregroundStyle(highlighted == index ? Color.inkwell : Color.paper)
                        .frame(width: 52, height: 52)
                        .background(highlighted == index ? Color.paper : Color.velvet, in: Circle())
                        .overlay(Circle().strokeBorder(Color.paper.opacity(0.12), lineWidth: 1))
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                        .scaleEffect(highlighted == index && !reduceMotion ? 1.18 : 1)
                        .position(layout.centers[index])
                        .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.75), value: highlighted)
                }
                Text(highlighted.map { actions[$0].title } ?? "Slide to an action")
                    .font(.designSystem(.bodySmall))
                    .foregroundStyle(Color.paper)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.velvet, in: Capsule())
                    .position(x: min(max(layout.origin.x, 100), geometry.size.width - 100),
                              y: labelY(height: geometry.size.height))
            }
        }
        .ignoresSafeArea().accessibilityHidden(true)
    }
    private func labelY(height: CGFloat) -> CGFloat {
        let top = layout.centers.map(\.y).min() ?? layout.origin.y
        let bottom = layout.centers.map(\.y).max() ?? layout.origin.y
        return top > 100 ? top - 58 : min(height - 60, bottom + 58)
    }
}
