import SwiftUI
import UIKit

/// Experimental entrance bridge, deliberately not attached to live sheets.
/// A layer-only entrance cannot synchronize the native dimmer or interactive
/// dismissal. Model/Plus keep UIKit's coordinated presentation instead.
struct SheetEntranceMotion: UIViewControllerRepresentable {
    let enabled: Bool

    func makeUIViewController(context: Context) -> EntranceController {
        EntranceController(enabled: enabled)
    }

    func updateUIViewController(_ controller: EntranceController, context: Context) {
        controller.enabled = enabled
        if !enabled { controller.cancelEntrance() }
    }

    static func dismantleUIViewController(_ controller: EntranceController, coordinator: ()) {
        controller.cancelEntrance()
    }

    final class EntranceController: UIViewController, CAAnimationDelegate {
        var enabled: Bool
        private var attempted = false
        private weak var animatedView: UIView?
        private weak var sheetOwner: UIViewController?
        private var previousInteraction: Bool?
        private var previousDismissalLock: Bool?
        private static let animationKey = "mychat.sheet.entrance"

        init(enabled: Bool) { self.enabled = enabled; super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            view.accessibilityElementsHidden = true
        }

        override func viewIsAppearing(_ animated: Bool) {
            super.viewIsAppearing(animated)
            // This callback runs after layout and before the first display.
            // A nonanimated native presentation therefore has no final-frame
            // flash before the custom layer entrance is installed.
            beginEntranceIfReady(finalAttempt: false)
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            beginEntranceIfReady(finalAttempt: true)
        }

        override func viewWillDisappear(_ animated: Bool) {
            cancelEntrance()
            super.viewWillDisappear(animated)
        }

        private func beginEntranceIfReady(finalAttempt: Bool) {
            guard !attempted else { return }
            guard enabled, !UIAccessibility.isReduceMotionEnabled else {
                attempted = true
                MyChatDebugLog.event("sheet entrance: reduced-motion native path")
                return
            }
            var candidate = parent
            var owner: UIViewController?
            while let controller = candidate {
                if controller.presentingViewController != nil,
                   controller.sheetPresentationController != nil {
                    owner = controller
                }
                candidate = controller.parent
            }
            guard let owner, let presentation = owner.presentationController,
                  let presented = presentation.presentedView,
                  let container = presentation.containerView,
                  presented.window != nil else {
                if finalAttempt { failOpen("public presentedView unavailable") }
                return
            }
            // Never stack an app animation on a native animated transition.
            // The presentation binding must use a no-animation transaction.
            guard owner.transitionCoordinator?.isAnimated != true else {
                failOpen("native animated transition remained active")
                return
            }
            let frame = presented.convert(presented.bounds, to: container)
            let distance = container.bounds.maxY - frame.minY
            guard distance.isFinite, distance > 1, presented.bounds.height > 1 else {
                if finalAttempt { failOpen("native sheet geometry unavailable") }
                return
            }
            attempted = true
            animatedView = presented
            sheetOwner = owner
            previousInteraction = presented.isUserInteractionEnabled
            previousDismissalLock = owner.isModalInPresentation
            presented.isUserInteractionEnabled = false
            owner.isModalInPresentation = true

            let entrance = CABasicAnimation(keyPath: "transform.translation.y")
            entrance.fromValue = distance
            entrance.toValue = 0
            entrance.duration = 0.48
            entrance.timingFunction = CAMediaTimingFunction(controlPoints: 0.42, 0, 0.22, 1)
            entrance.isRemovedOnCompletion = true
            entrance.delegate = self
            presented.layer.add(entrance, forKey: Self.animationKey)
            MyChatDebugLog.event("sheet entrance: custom curve active, travel=\(Int(distance)), duration=480ms")
        }

        private func failOpen(_ reason: String) {
            attempted = true
            MyChatDebugLog.event("sheet entrance: native-fallback (\(reason))")
        }

        nonisolated func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
            Task { @MainActor [weak self] in
                self?.restoreInteraction()
                MyChatDebugLog.event("sheet entrance: \(flag ? "settled" : "cancelled")")
            }
        }

        func cancelEntrance() {
            animatedView?.layer.removeAnimation(forKey: Self.animationKey)
            restoreInteraction()
        }

        private func restoreInteraction() {
            if let previousInteraction { animatedView?.isUserInteractionEnabled = previousInteraction }
            if let previousDismissalLock { sheetOwner?.isModalInPresentation = previousDismissalLock }
            previousInteraction = nil
            previousDismissalLock = nil
            animatedView = nil
            sheetOwner = nil
        }
    }
}

/// One opaque page surface for the principal native sheets. The system owns
/// the rounded rim and contact shadow; no extra dark shadow is layered on it.
struct MyChatSheetSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.presentationCornerRadius(42).presentationBackground(MyChatTheme.canvas)
    }
}

// The principal sheets share one native transition, including the dimmer and
// the live finger position. The earlier layer-only experiment stays unattached.
enum SheetRestingPosition { case compact, expanded, dismissed }

struct SheetMotionGeometry {
    let bounds: CGRect
    let topInset: CGFloat
    let fraction: CGFloat

    var expanded: CGRect {
        let top = bounds.minY + max(12, topInset) + 8
        return CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bounds.maxY - top))
    }
    var compact: CGRect {
        let height = expanded.height * min(1, max(0.2, fraction))
        return CGRect(x: bounds.minX, y: bounds.maxY - height, width: bounds.width, height: height)
    }
    func dragged(top: CGFloat, reduceMotion: Bool) -> CGRect {
        if top > compact.minY { return compact.offsetBy(dx: 0, dy: top - compact.minY) }
        if top < expanded.minY {
            let excess = expanded.minY - top
            let resistance = reduceMotion ? 0 : 14 * excess / (excess + 44)
            return expanded.offsetBy(dx: 0, dy: -resistance)
        }
        return CGRect(x: bounds.minX, y: top, width: bounds.width, height: bounds.maxY - top)
    }
    func dimming(top: CGFloat) -> CGFloat {
        1 - min(1, max(0, (top - compact.minY) / max(1, compact.height)))
    }
    func target(top: CGFloat, velocity: CGFloat, cancelled: Bool,
                origin: SheetRestingPosition) -> SheetRestingPosition {
        if cancelled { return origin }
        let projected = top + min(2_500, max(-2_500, velocity)) * 0.16
        if projected > compact.minY + compact.height * 0.32 { return .dismissed }
        return projected < (expanded.minY + compact.minY) / 2 ? .expanded : .compact
    }
}

extension View {
    func myChatSheet<Sheet: View>(isPresented: Binding<Bool>, fraction: CGFloat,
        showsGrabber: Bool = true, edgeInset: CGFloat = 0, onDismiss: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Sheet) -> some View {
        modifier(MyChatNativeSheetModifier(isPresented: isPresented, fraction: fraction,
            showsGrabber: showsGrabber, edgeInset: edgeInset, onDismiss: onDismiss, sheet: content))
    }
}

private struct MyChatNativeSheetModifier<Sheet: View>: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let fraction: CGFloat
    let showsGrabber: Bool
    let edgeInset: CGFloat
    let onDismiss: () -> Void
    let sheet: () -> Sheet

    func body(content: Content) -> some View {
        content.background {
            MyChatNativeSheetPresenter(isPresented: $isPresented, fraction: fraction,
                edgeInset: edgeInset, reduceMotion: reduceMotion, onDismiss: onDismiss) {
                VStack(spacing: 0) {
                    if showsGrabber {
                        Capsule().fill(MyChatTheme.secondaryText.opacity(0.32))
                            .frame(width: 36, height: 5).padding(.top, 10).padding(.bottom, 6)
                            .accessibilityHidden(true)
                    }
                    sheet().frame(maxWidth: .infinity, maxHeight: .infinity)
                }.background(MyChatTheme.canvas.ignoresSafeArea())
            }.frame(width: 0, height: 0).accessibilityHidden(true)
        }
    }
}

private struct MyChatNativeSheetPresenter<Sheet: View>: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let fraction: CGFloat
    let edgeInset: CGFloat
    let reduceMotion: Bool
    let onDismiss: () -> Void
    let content: () -> Sheet

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> SheetPresentationAnchor {
        let anchor = SheetPresentationAnchor()
        anchor.ready = { [weak coordinator = context.coordinator] in coordinator?.reconcile() }
        return anchor
    }
    func updateUIViewController(_ anchor: SheetPresentationAnchor, context: Context) {
        let coordinator = context.coordinator
        coordinator.anchor = anchor
        coordinator.binding = $isPresented
        coordinator.fraction = fraction
        coordinator.edgeInset = edgeInset
        coordinator.reduceMotion = reduceMotion
        coordinator.onDismiss = onDismiss
        coordinator.makeContent = { AnyView(content()) }
        coordinator.scheduleReconcile()
    }
    static func dismantleUIViewController(_ anchor: SheetPresentationAnchor, coordinator: Coordinator) {
        coordinator.host?.dismiss(animated: false)
    }

    final class Coordinator: NSObject, UIViewControllerTransitioningDelegate {
        weak var anchor: SheetPresentationAnchor?
        var binding: Binding<Bool> = .constant(false)
        var fraction: CGFloat = 1
        var edgeInset: CGFloat = 0
        var reduceMotion = false
        var onDismiss: () -> Void = {}
        var makeContent: () -> AnyView = { AnyView(EmptyView()) }
        var host: UIHostingController<AnyView>?
        private var queued = false

        func scheduleReconcile() {
            guard !queued else { return }
            queued = true
            DispatchQueue.main.async { [weak self] in
                self?.queued = false
                self?.reconcile()
            }
        }
        func reconcile() {
            guard let anchor, anchor.view.window != nil else { return }
            if let host {
                guard !binding.wrappedValue, !host.isBeingPresented, !host.isBeingDismissed else { return }
                host.dismiss(animated: true)
                return
            }
            guard binding.wrappedValue else { return }
            var owner: UIViewController = anchor
            while let parent = owner.parent { owner = parent }
            guard owner.presentedViewController == nil else { return }
            let next = UIHostingController(rootView: makeContent())
            next.modalPresentationStyle = .custom
            next.transitioningDelegate = self
            next.view.backgroundColor = UIColor(MyChatTheme.canvas)
            next.view.accessibilityViewIsModal = true
            host = next
            owner.present(next, animated: true) { [weak self] in self?.reconcile() }
        }
        func presentationController(forPresented presented: UIViewController,
            presenting: UIViewController?, source: UIViewController) -> UIPresentationController? {
            let controller = CoordinatedSheetPresentation(presentedViewController: presented,
                presenting: presenting, fraction: fraction, edgeInset: edgeInset, reduceMotion: reduceMotion)
            controller.finished = { [weak self, weak presented] in
                guard let self, self.host === presented else { return }
                self.host = nil
                self.binding.wrappedValue = false
                self.onDismiss()
            }
            return controller
        }
        func animationController(forPresented presented: UIViewController,
            presenting: UIViewController, source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
            CoordinatedSheetAnimator(presenting: true, reduceMotion: reduceMotion)
        }
        func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
            CoordinatedSheetAnimator(presenting: false, reduceMotion: reduceMotion)
        }
    }
}

private final class SheetPresentationAnchor: UIViewController {
    var ready: () -> Void = {}
    override func loadView() {
        view = UIView(); view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
    }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); ready() }
}

private final class CoordinatedSheetPresentation: UIPresentationController, UIGestureRecognizerDelegate {
    let dimmer = UIButton(type: .custom)
    let fraction: CGFloat
    let edgeInset: CGFloat
    let reduceMotion: Bool
    var finished: () -> Void = {}
    private var expanded = false
    private var transitioning = false
    private var dragging = false
    private var originTop: CGFloat = 0
    private var originPosition: SheetRestingPosition = .compact
    private var settling: UIViewPropertyAnimator?
    private lazy var pan: UIPanGestureRecognizer = {
        let value = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        value.maximumNumberOfTouches = 1
        value.delegate = self
        value.delaysTouchesBegan = false
        return value
    }()
    init(presentedViewController: UIViewController, presenting: UIViewController?,
        fraction: CGFloat, edgeInset: CGFloat, reduceMotion: Bool) {
        self.fraction = fraction; self.edgeInset = edgeInset; self.reduceMotion = reduceMotion
        expanded = fraction >= 0.99
        super.init(presentedViewController: presentedViewController, presenting: presenting)
    }
    private var geometry: SheetMotionGeometry {
        let bounds = containerView?.bounds ?? .zero
        return SheetMotionGeometry(bounds: CGRect(x: bounds.minX + edgeInset, y: bounds.minY,
            width: max(0, bounds.width - edgeInset * 2), height: max(0, bounds.height - edgeInset)),
            topInset: containerView?.safeAreaInsets.top ?? 0, fraction: fraction)
    }
    override var frameOfPresentedViewInContainerView: CGRect { expanded ? geometry.expanded : geometry.compact }
    override func presentationTransitionWillBegin() {
        guard let containerView, let presentedView else { return }
        transitioning = true
        dimmer.backgroundColor = UIColor.black.withAlphaComponent(0.18)
        dimmer.alpha = 0
        dimmer.accessibilityLabel = "关闭弹层"
        dimmer.addTarget(self, action: #selector(close), for: .touchUpInside)
        containerView.insertSubview(dimmer, at: 0)
        dimmer.frame = containerView.bounds
        presentedView.layer.cornerRadius = 42
        presentedView.layer.cornerCurve = .continuous
        presentedView.layer.maskedCorners = edgeInset > 0
            ? [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        presentedView.clipsToBounds = true
        presentedView.addGestureRecognizer(pan)
    }
    override func presentationTransitionDidEnd(_ completed: Bool) {
        transitioning = false
        if !completed { dimmer.removeFromSuperview(); finished() }
    }
    override func dismissalTransitionWillBegin() {
        transitioning = true
        let liveFrame = presentedView?.layer.presentation()?.frame
        let liveDim = dimmer.layer.presentation()?.opacity
        settling?.stopAnimation(true); settling = nil
        if let liveFrame { presentedView?.frame = liveFrame }
        if let liveDim { dimmer.alpha = CGFloat(liveDim) }
        dragging = false
        pan.isEnabled = false
    }
    override func dismissalTransitionDidEnd(_ completed: Bool) {
        transitioning = false
        if completed { dimmer.removeFromSuperview(); finished() }
        else { pan.isEnabled = true; settle(to: expanded ? .expanded : .compact, velocity: 0) }
    }
    override func containerViewWillLayoutSubviews() {
        super.containerViewWillLayoutSubviews()
        dimmer.frame = containerView?.bounds ?? .zero
        if !transitioning, !dragging, settling == nil { presentedView?.frame = frameOfPresentedViewInContainerView }
    }
    @objc private func close() { presentedViewController.dismiss(animated: true) }
    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        let velocity = pan.velocity(in: presentedView)
        return !transitioning && abs(velocity.y) > abs(velocity.x) * 1.3
    }
    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Lists keep their native scrolling; the grabber/header owns resizing.
        touch.location(in: presentedView).y <= 90
    }
    @objc private func dragged(_ recognizer: UIPanGestureRecognizer) {
        guard !transitioning, let presentedView else { return }
        switch recognizer.state {
        case .began:
            let liveFrame = presentedView.layer.presentation()?.frame ?? presentedView.frame
            let liveDim = dimmer.layer.presentation()?.opacity ?? Float(dimmer.alpha)
            settling?.stopAnimation(true); settling = nil
            presentedView.frame = liveFrame; dimmer.alpha = CGFloat(liveDim)
            originTop = liveFrame.minY
            originPosition = expanded ? .expanded : .compact
            dragging = true
        case .changed:
            let frame = geometry.dragged(top: originTop + recognizer.translation(in: containerView).y,
                reduceMotion: reduceMotion)
            presentedView.frame = frame
            dimmer.alpha = geometry.dimming(top: frame.minY)
        case .ended, .cancelled, .failed:
            guard dragging else { return }
            dragging = false
            let velocity = recognizer.velocity(in: containerView).y
            let target = geometry.target(top: presentedView.frame.minY, velocity: velocity,
                cancelled: recognizer.state != .ended, origin: originPosition)
            if target == .dismissed { close() }
            else { settle(to: target, velocity: recognizer.state == .ended ? velocity : 0) }
        default: break
        }
    }
    private func settle(to position: SheetRestingPosition, velocity: CGFloat) {
        guard let presentedView else { return }
        expanded = position == .expanded
        let target = frameOfPresentedViewInContainerView
        let distance = target.minY - presentedView.frame.minY
        let timing: UITimingCurveProvider = reduceMotion
            ? UICubicTimingParameters(animationCurve: .easeOut)
            : UISpringTimingParameters(dampingRatio: 1,
                initialVelocity: CGVector(dx: 0, dy: abs(distance) > 1 ? min(12, max(-12, velocity / distance)) : 0))
        let next = UIViewPropertyAnimator(duration: reduceMotion ? 0.12 : 0.32, timingParameters: timing)
        settling = next
        next.addAnimations { [weak self] in
            presentedView.frame = target
            self?.dimmer.alpha = 1
        }
        next.addCompletion { [weak self, weak next] _ in
            guard let self, self.settling === next else { return }
            self.settling = nil
            presentedView.frame = target
            self.dimmer.alpha = 1
        }
        next.startAnimation()
    }
}

private final class CoordinatedSheetAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    let presenting: Bool
    let reduceMotion: Bool
    private var running: UIViewPropertyAnimator?
    init(presenting: Bool, reduceMotion: Bool) { self.presenting = presenting; self.reduceMotion = reduceMotion }
    func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval {
        reduceMotion ? 0.12 : presenting ? 0.44 : 0.28
    }
    func animateTransition(using context: UIViewControllerContextTransitioning) {
        interruptibleAnimator(using: context).startAnimation()
    }
    func interruptibleAnimator(using context: UIViewControllerContextTransitioning) -> UIViewImplicitlyAnimating {
        if let running { return running }
        let key: UITransitionContextViewControllerKey = presenting ? .to : .from
        let controller = context.viewController(forKey: key)!
        let pane = context.view(forKey: presenting ? .to : .from) ?? controller.view!
        let presentation = controller.presentationController as? CoordinatedSheetPresentation
        if presenting {
            pane.frame = presentation?.frameOfPresentedViewInContainerView ?? context.finalFrame(for: controller)
            context.containerView.addSubview(pane)
            if reduceMotion { pane.alpha = 0 }
            else { pane.transform = CGAffineTransform(translationX: 0, y: context.containerView.bounds.maxY - pane.frame.minY) }
        }
        let next = UIViewPropertyAnimator(duration: transitionDuration(using: context),
            controlPoint1: CGPoint(x: 0.32, y: 0), controlPoint2: CGPoint(x: 0.12, y: 1))
        running = next
        next.addAnimations { [self] in
            if presenting { pane.transform = .identity; pane.alpha = 1; presentation?.dimmer.alpha = 1 }
            else {
                if reduceMotion { pane.alpha = 0 }
                else { pane.transform = CGAffineTransform(translationX: 0, y: context.containerView.bounds.maxY - pane.frame.minY) }
                presentation?.dimmer.alpha = 0
            }
        }
        next.addCompletion { [weak self] _ in
            let completed = !context.transitionWasCancelled
            if !completed { pane.transform = .identity; pane.alpha = 1; presentation?.dimmer.alpha = 1 }
            if completed && self?.presenting == false { pane.removeFromSuperview() }
            context.completeTransition(completed)
            self?.running = nil
        }
        return next
    }
}
