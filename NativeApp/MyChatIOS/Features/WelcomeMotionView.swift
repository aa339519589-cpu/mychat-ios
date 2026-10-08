import SwiftUI
import UIKit

struct KeyboardTransitionTiming: Equatable {
    var duration: Double = 0.3
    var curve: UInt = 7
    init() {}
    init(_ notification: Notification) {
        duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.3
        curve = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
    }
    var options: UIView.AnimationOptions {
        [.init(rawValue: curve << 16), .beginFromCurrentState, .allowUserInteraction]
    }
    var animation: Animation? {
        guard !UIAccessibility.isReduceMotionEnabled, duration > 0 else { return nil }
        switch curve {
        case 0: return .timingCurve(0.42, 0, 0.58, 1, duration: duration)
        case 1: return .easeIn(duration: duration)
        case 2: return .easeOut(duration: duration)
        case 3: return .linear(duration: duration)
        default: return .timingCurve(0.2, 0.85, 0.25, 1, duration: duration)
        }
    }
}

struct WelcomeMotionView: UIViewControllerRepresentable {
    let greeting: String
    let isPrivate: Bool
    let bottomOcclusion: CGFloat
    let systemBottomInset: CGFloat
    let canvasLayout: ChatCanvasLayout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIViewController(context: Context) -> WelcomeMotionController {
        let controller = WelcomeMotionController()
        updateUIViewController(controller, context: context)
        return controller
    }
    func updateUIViewController(_ controller: WelcomeMotionController, context: Context) {
        controller.configure(greeting: greeting, isPrivate: isPrivate,
            bottomOcclusion: bottomOcclusion, systemBottomInset: systemBottomInset,
            canvasLayout: canvasLayout, reduceMotion: reduceMotion)
    }
}

final class WelcomeMotionSurface: UIView {
    let logo = UIImageView()
    let greeting = UILabel()
    let hint = UILabel()
    weak var privateLogo: UIView?
    var didAttach: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        didAttach?()
    }
}

private struct WelcomePrivacyGhost: Shape {
    func path(in rect: CGRect) -> Path {
        // A round crown and three soft bottom scallops, matching the reference.
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 40))
        path.addCurve(to: CGPoint(x: 40, y: 0),
            control1: CGPoint(x: 0, y: 17.91), control2: CGPoint(x: 17.91, y: 0))
        path.addCurve(to: CGPoint(x: 80, y: 40),
            control1: CGPoint(x: 62.09, y: 0), control2: CGPoint(x: 80, y: 17.91))
        path.addLine(to: CGPoint(x: 80, y: 75.5))
        path.addCurve(to: CGPoint(x: 73, y: 76),
            control1: CGPoint(x: 80, y: 81), control2: CGPoint(x: 76, y: 81))
        path.addCurve(to: CGPoint(x: 66.67, y: 70),
            control1: CGPoint(x: 71, y: 72), control2: CGPoint(x: 69, y: 70))
        path.addCurve(to: CGPoint(x: 53.33, y: 80),
            control1: CGPoint(x: 60, y: 70), control2: CGPoint(x: 60, y: 80))
        path.addCurve(to: CGPoint(x: 40, y: 70),
            control1: CGPoint(x: 47, y: 80), control2: CGPoint(x: 47, y: 70))
        path.addCurve(to: CGPoint(x: 26.67, y: 80),
            control1: CGPoint(x: 33, y: 70), control2: CGPoint(x: 33, y: 80))
        path.addCurve(to: CGPoint(x: 13.33, y: 70),
            control1: CGPoint(x: 20, y: 80), control2: CGPoint(x: 20, y: 70))
        path.addCurve(to: CGPoint(x: 7, y: 76),
            control1: CGPoint(x: 11, y: 70), control2: CGPoint(x: 9, y: 72))
        path.addCurve(to: CGPoint(x: 0, y: 75.5),
            control1: CGPoint(x: 4, y: 81), control2: CGPoint(x: 0, y: 81))
        path.closeSubpath()
        for x: CGFloat in [23.2, 56.8] {
            path.addEllipse(in: CGRect(x: x - 5.4, y: 34.6, width: 10.8, height: 10.8))
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 80, y: rect.height / 80)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

final class WelcomeMotionController: UIViewController {
    private let surface = WelcomeMotionSurface()
    private let privateHost = UIHostingController(rootView: AnyView(
        WelcomePrivacyGhost().fill(MyChatTheme.text, style: FillStyle(eoFill: true))
            .frame(width: 34, height: 34)
            .frame(width: 52, height: 52)))
    private var greetingText = ""
    private var privateMode = false
    private var bottomOcclusion: CGFloat = 140
    private var systemBottomInset: CGFloat = 34
    private var configured = false
    private var reducedMotion = false
    private weak var canvasLayout: ChatCanvasLayout?
    private weak var boundComposer: UIView?
    private let availableSpace = UILayoutGuide()
    private let welcomeAnchor = UILayoutGuide()
    private var restingBottom: NSLayoutConstraint!
    private var composerBottom: NSLayoutConstraint?
    private var greetingHeight: NSLayoutConstraint!
    private var hintHeight: NSLayoutConstraint!

    override func loadView() { view = surface }
    override func viewDidLoad() {
        super.viewDidLoad()
        surface.backgroundColor = .clear
        surface.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard)))
        if let url = Bundle.main.url(forResource: "coherent-idle", withExtension: "png", subdirectory: "DotMotion") {
            surface.logo.image = UIImage(contentsOfFile: url.path)
        }
        surface.logo.contentMode = .scaleAspectFit
        surface.logo.accessibilityIdentifier = "home.logo"
        surface.logo.accessibilityLabel = "MyChat"
        surface.greeting.accessibilityIdentifier = "home.greeting"
        surface.greeting.textAlignment = .center
        surface.greeting.adjustsFontSizeToFitWidth = true
        surface.greeting.minimumScaleFactor = 0.82
        surface.hint.numberOfLines = 2
        surface.hint.textAlignment = .center
        surface.hint.accessibilityIdentifier = "home.private-hint"
        for child in [surface.logo, surface.greeting, surface.hint] { surface.addSubview(child) }
        privateHost.safeAreaRegions = []
        addChild(privateHost); surface.addSubview(privateHost.view); privateHost.didMove(toParent: self)
        privateHost.view.backgroundColor = .clear
        privateHost.view.isUserInteractionEnabled = false
        privateHost.view.accessibilityIdentifier = "home.private-logo"
        privateHost.view.accessibilityLabel = "隐私聊天"
        privateHost.view.accessibilityTraits = .image
        surface.privateLogo = privateHost.view
        installGeometry()
        surface.didAttach = { [weak self] in self?.connectComposerGeometry() }
        refreshTypography()
        applyAppearance()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (controller: WelcomeMotionController, _) in
            controller.refreshTypography(); controller.view.setNeedsLayout()
        }
    }

    @objc private func dismissKeyboard() {
        NotificationCenter.default.post(name: .myChatDismissComposer, object: nil)
        view.window?.endEditing(true)
    }

    func configure(greeting: String, isPrivate: Bool, bottomOcclusion: CGFloat,
                   systemBottomInset: CGFloat, canvasLayout: ChatCanvasLayout, reduceMotion: Bool) {
        self.canvasLayout = canvasLayout
        let changesMode = privateMode != isPrivate
        let changesGeometry = abs(self.bottomOcclusion - bottomOcclusion) > 0.5
        guard !configured || changesMode || changesGeometry || greetingText != greeting
                || self.systemBottomInset != systemBottomInset || reducedMotion != reduceMotion else { return }
        let animate = configured && isViewLoaded && view.window != nil && !reduceMotion
        reducedMotion = reduceMotion
        greetingText = greeting; privateMode = isPrivate
        self.bottomOcclusion = bottomOcclusion; self.systemBottomInset = systemBottomInset
        configured = true
        guard isViewLoaded else { return }
        refreshTypography()
        updateAccessibility()
        restingBottom.constant = -max(0, bottomOcclusion - systemBottomInset)
        connectComposerGeometry()
        // Only the privacy appearance has its own animation. Position is an
        // affine function of the native input's top anchor in the same layout
        // tree, so keyboard show/hide/reversal cannot start a second chase.
        if animate && changesMode {
            UIView.animate(withDuration: 0.34, delay: 0,
                options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]) {
                self.applyAppearance()
            }
        } else { UIView.performWithoutAnimation { self.applyAppearance() } }
    }

    private func refreshTypography() {
        surface.greeting.font = MyChatSystemFont.appSerifUIFont(size: 24, relativeTo: .title2, weight: .medium)
        surface.greeting.textColor = UIColor(MyChatTheme.text)
        surface.greeting.text = greetingText
        surface.hint.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: MyChatSystemFont.appUIFont(size: 13))
        surface.hint.textColor = UIColor(MyChatTheme.secondaryText)
        let text = "隐私对话不会保存在历史记录或记忆中。"
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineSpacing = 2
        let attributed = NSMutableAttributedString(string: text, attributes: [.paragraphStyle: paragraph])
        surface.hint.attributedText = attributed
    }

    private func installGeometry() {
        surface.addLayoutGuide(availableSpace)
        surface.addLayoutGuide(welcomeAnchor)
        let children = [surface.logo, surface.greeting, surface.hint, privateHost.view!]
        children.forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        restingBottom = availableSpace.bottomAnchor.constraint(equalTo: surface.bottomAnchor,
            constant: -max(0, bottomOcclusion - systemBottomInset))
        greetingHeight = surface.greeting.heightAnchor.constraint(equalToConstant: 32)
        hintHeight = surface.hint.heightAnchor.constraint(equalToConstant: 36)
        let preferredHintWidth = surface.hint.widthAnchor.constraint(equalTo: surface.widthAnchor, constant: -68)
        preferredHintWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            availableSpace.topAnchor.constraint(equalTo: surface.topAnchor),
            availableSpace.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            availableSpace.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            restingBottom,
            welcomeAnchor.topAnchor.constraint(equalTo: availableSpace.topAnchor),
            welcomeAnchor.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            welcomeAnchor.widthAnchor.constraint(equalToConstant: 0),
            welcomeAnchor.heightAnchor.constraint(equalTo: availableSpace.heightAnchor, multiplier: 0.43),
            surface.logo.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            surface.logo.centerYAnchor.constraint(equalTo: welcomeAnchor.bottomAnchor),
            surface.logo.widthAnchor.constraint(equalToConstant: 52),
            surface.logo.heightAnchor.constraint(equalToConstant: 52),
            privateHost.view.centerXAnchor.constraint(equalTo: surface.logo.centerXAnchor),
            privateHost.view.centerYAnchor.constraint(equalTo: surface.logo.centerYAnchor),
            privateHost.view.widthAnchor.constraint(equalToConstant: 52),
            privateHost.view.heightAnchor.constraint(equalToConstant: 52),
            surface.greeting.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            surface.greeting.centerYAnchor.constraint(equalTo: surface.logo.centerYAnchor, constant: 52),
            surface.greeting.widthAnchor.constraint(equalTo: surface.widthAnchor, constant: -36),
            greetingHeight,
            surface.hint.centerXAnchor.constraint(equalTo: surface.centerXAnchor),
            surface.hint.topAnchor.constraint(equalTo: surface.logo.centerYAnchor, constant: 52),
            surface.hint.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
            preferredHintWidth, hintHeight
        ])
    }

    private func connectComposerGeometry() {
        guard let composer = canvasLayout?.composerView, surface.window != nil,
              composer.window === surface.window else { return }
        if boundComposer === composer, composerBottom?.isActive == true { return }
        // Constraints may only cross the two hosts once they share an ancestor.
        var ancestor = surface.superview
        while let candidate = ancestor, !composer.isDescendant(of: candidate) {
            ancestor = candidate.superview
        }
        guard ancestor != nil else { return }
        composerBottom?.isActive = false
        restingBottom.isActive = false
        let constraint = availableSpace.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -8)
        composerBottom = constraint
        boundComposer = composer
        constraint.isActive = true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        connectComposerGeometry()
        let width = surface.bounds.width
        guard width > 0 else { return }
        greetingHeight.constant = ceil(surface.greeting.font.lineHeight + 4)
        let hintWidth = min(max(1, width - 68), 600)
        hintHeight.constant = min(surface.hint.font.lineHeight * 2 + 2,
            surface.hint.sizeThatFits(CGSize(width: hintWidth, height: .greatestFiniteMagnitude)).height)
    }

    private func applyAppearance() {
        surface.logo.alpha = privateMode ? 0 : 1
        surface.logo.transform = privateMode ? CGAffineTransform(scaleX: 0.88, y: 0.88) : .identity
        surface.greeting.alpha = privateMode ? 0 : 1
        surface.greeting.transform = privateMode ? CGAffineTransform(translationX: 0, y: -5) : .identity
        privateHost.view.alpha = privateMode ? 1 : 0
        privateHost.view.transform = privateMode ? .identity : CGAffineTransform(scaleX: 0.88, y: 0.88)
        surface.hint.alpha = privateMode ? 1 : 0
        surface.hint.transform = privateMode ? .identity : CGAffineTransform(translationX: 0, y: 5)
        updateAccessibility()
    }
    private func updateAccessibility() {
        surface.logo.isAccessibilityElement = !privateMode
        surface.greeting.isAccessibilityElement = !privateMode
        privateHost.view.isAccessibilityElement = privateMode
        privateHost.view.accessibilityElementsHidden = !privateMode
        surface.hint.isAccessibilityElement = privateMode
    }
}
