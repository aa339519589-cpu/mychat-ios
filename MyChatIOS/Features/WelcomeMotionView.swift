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
    let timing: KeyboardTransitionTiming
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIViewController(context: Context) -> WelcomeMotionController {
        let controller = WelcomeMotionController()
        updateUIViewController(controller, context: context)
        return controller
    }
    func updateUIViewController(_ controller: WelcomeMotionController, context: Context) {
        controller.configure(greeting: greeting, isPrivate: isPrivate,
            bottomOcclusion: bottomOcclusion, systemBottomInset: systemBottomInset,
            timing: timing, reduceMotion: reduceMotion)
    }
}

final class WelcomeMotionSurface: UIView {
    let logo = UIImageView()
    let greeting = UILabel()
    let hint = UILabel()
    weak var privateLogo: UIView?
}

final class WelcomeMotionController: UIViewController {
    private let surface = WelcomeMotionSurface()
    private let privateHost = UIHostingController(rootView: AnyView(
        PrivacyChatGlyph(foreground: MyChatTheme.text, eyeColor: MyChatTheme.canvas, size: 48).frame(width: 52, height: 52)))
    private var greetingText = ""
    private var privateMode = false
    private var bottomOcclusion: CGFloat = 140
    private var systemBottomInset: CGFloat = 34
    private var configured = false
    private var reducedMotion = false

    override func loadView() { view = surface }
    override func viewDidLoad() {
        super.viewDidLoad()
        surface.backgroundColor = .clear
        surface.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard)))
        if let url = Bundle.main.url(forResource: "home-logo", withExtension: "png", subdirectory: "DotMotion") {
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
                   systemBottomInset: CGFloat, timing: KeyboardTransitionTiming, reduceMotion: Bool) {
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
        let changes = { self.placeContent(); self.applyAppearance() }
        if animate && (changesGeometry || changesMode) {
            let duration = changesMode ? 0.34 : timing.duration
            let options: UIView.AnimationOptions = changesMode
                ? [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction] : timing.options
            UIView.animate(withDuration: duration, delay: 0, options: options, animations: changes)
        } else { UIView.performWithoutAnimation(changes) }
    }

    private func refreshTypography() {
        surface.greeting.font = MyChatSystemFont.appSerifUIFont(size: 24, relativeTo: .title2, weight: .medium)
        surface.greeting.textColor = UIColor(MyChatTheme.text)
        surface.greeting.text = greetingText
        surface.hint.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: UIFont.systemFont(ofSize: 13))
        surface.hint.textColor = UIColor(MyChatTheme.secondaryText)
        let text = "Incognito chats stay out of history and memory."
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineSpacing = 2
        let attributed = NSMutableAttributedString(string: text, attributes: [.paragraphStyle: paragraph])
        surface.hint.attributedText = attributed
    }

    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); placeContent() }
    private func placeContent() {
        let width = surface.bounds.width
        guard width > 0 else { return }
        let available = max(0, surface.bounds.height - max(0, bottomOcclusion - systemBottomInset))
        let anchor = CGPoint(x: width / 2, y: available * 0.43)
        for logo in [surface.logo, privateHost.view!] {
            logo.bounds = CGRect(x: 0, y: 0, width: 52, height: 52); logo.center = anchor
        }
        let greetingHeight = ceil(surface.greeting.font.lineHeight + 4)
        surface.greeting.bounds = CGRect(x: 0, y: 0, width: max(1, width - 36), height: greetingHeight)
        surface.greeting.center = CGPoint(x: anchor.x, y: anchor.y + 52)
        let hintWidth = min(max(1, width - 68), 600)
        let hintHeight = min(surface.hint.font.lineHeight * 2 + 2,
            surface.hint.sizeThatFits(CGSize(width: hintWidth, height: .greatestFiniteMagnitude)).height)
        surface.hint.bounds = CGRect(x: 0, y: 0, width: hintWidth, height: hintHeight)
        surface.hint.center = CGPoint(x: anchor.x, y: anchor.y + 52 + hintHeight / 2)
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
