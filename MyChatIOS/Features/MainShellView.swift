import AuthenticationServices
import AVFoundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// The live app and visual reference render through this same surface. Keep the
// drawer host alive while restoring authentication instead of replacing it.
struct MyChatApplicationSurface: View {
    @ObservedObject var appModel: AppModel

    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("--preview-voice-ui") {
            MainShellView()
                .environmentObject(appModel)
        } else {
            authenticatedSurface
        }
    }

    private var authenticatedSurface: some View {
        ZStack {
            MainShellView()
                .environmentObject(appModel)
                .opacity(appModel.authSession == nil ? 0 : 1)
                .allowsHitTesting(appModel.authSession != nil)
                .accessibilityHidden(appModel.authSession == nil)

            if appModel.authSession == nil {
                if appModel.isRestoringAuthentication {
                    ZStack {
                        MyChatTheme.canvas.ignoresSafeArea()
                        ProgressView()
                    }
                } else {
                    AuthenticationView(client: appModel.authenticationClient,
                                       onAuthenticated: appModel.acceptAuthentication)
                }
            }
        }
    }
}

struct MainShellView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sidebarVisible = ProcessInfo.processInfo.arguments.contains("--sidebar")
    @State private var modelPickerVisible = false
    @State private var toolsVisible = false
    @State private var settingsVisible = false
    @State private var automaticDocument: ChatDocument?
    @State private var documentModalID = UUID()
    @StateObject private var canvasLayout = ChatCanvasLayout()

    var body: some View {
        GeometryReader { proxy in
            let drawerWidth = min(
                min(max(proxy.size.width * MyChatTheme.drawerWidthRatio, 280), 320),
                max(0, proxy.size.width - 48)
            )
            NativeDrawerHost(
                width: drawerWidth,
                isOpen: $sidebarVisible,
                blocked: settingsVisible || modelPickerVisible || toolsVisible,
                reduceMotion: reduceMotion,
                canvasLayout: canvasLayout,
                navigationKey: CanvasNavigationKey(appModel: appModel),
                sidebar: SidebarView(appModel: appModel, width: drawerWidth, interactionLocked: false,
                    openSettings: openSettings, close: closeSidebar)
                    .equatable().environmentObject(appModel),
                canvas: MainCanvasView(appModel: appModel,
                    openSidebar: openSidebar, openTools: { toolsVisible = true },
                    openModels: { modelPickerVisible = true },
                    openArtifact: presentArtifact)
                    .environmentObject(appModel).environmentObject(canvasLayout),
                composer: AnyView(FloatingComposerView(appModel: appModel,
                    openTools: { toolsVisible = true }, openModels: { modelPickerVisible = true },
                    drawerIsOpen: { sidebarVisible }))
            )
        }
        .ignoresSafeArea()
        .sheet(isPresented: $settingsVisible, onDismiss: { setChatRenderSuspended(false) }) {
            MyChatSettingsView(appModel: appModel, close: closeSettings).environmentObject(appModel)
                .presentationDetents([.large]).presentationDragIndicator(.hidden)
                .presentationCornerRadius(40).presentationBackground(MyChatTheme.canvas)
        }
        .onChange(of: appModel.pendingDocumentPreview) { _, _ in presentPendingDocument() }
        .onChange(of: settingsVisible) { _, visible in if !visible { presentPendingDocument() } }
        .onChange(of: sidebarVisible) { _, visible in if !visible { presentPendingDocument() } }
        .onChange(of: appModel.activeConversationID) { _, _ in appModel.pendingDocumentPreview = nil }
        .sheet(item: $automaticDocument, onDismiss: {
            NativeDocumentModalActivity.set(documentModalID, active: false)
            Task { try? await Task.sleep(for: .milliseconds(250)); presentPendingDocument() }
        }) { document in
            ChatDocumentPreview(document: document).presentationDetents([.large])
                .presentationCornerRadius(42).presentationBackground(MyChatTheme.canvas)
        }
        .onChange(of: modelPickerVisible) { _, presented in
            if presented { dismissKeyboard(); setChatRenderSuspended(true) }
        }
        .onChange(of: toolsVisible) { _, presented in
            if presented { dismissKeyboard(); setChatRenderSuspended(true) }
        }
        .sheet(isPresented: $modelPickerVisible, onDismiss: {
            setChatRenderSuspended(false)
        }) {
            ModelPickerSheet()
                .environmentObject(appModel)
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(42)
                .presentationBackground(MyChatTheme.canvas)
        }
        .sheet(isPresented: $toolsVisible, onDismiss: {
            setChatRenderSuspended(false)
        }) {
            ToolsSheet(close: { toolsVisible = false })
                .environmentObject(appModel)
                .presentationDetents([.fraction(0.56), .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(34)
                .presentationBackground(MyChatTheme.canvas)
        }
        .fullScreenCover(item: $appModel.artifactPreview, onDismiss: {
            setChatRenderSuspended(false)
        }) { artifact in
            ArtifactLibraryDetail(artifact: artifact)
                .environmentObject(appModel)
        }
    }

    private func presentPendingDocument() {
        guard !settingsVisible, !sidebarVisible, !toolsVisible, !modelPickerVisible,
              automaticDocument == nil, appModel.selectedDestination == .chats,
              let document = appModel.pendingDocumentPreview else { return }
        NativeDocumentModalActivity.set(documentModalID, active: true)
        automaticDocument = document
        appModel.pendingDocumentPreview = nil
    }

    private func openSidebar() {
        dismissKeyboard()
        HapticFeedback.impact()
        sidebarVisible = true
    }

    private func closeSidebar() { sidebarVisible = false }

    private func openSettings() {
        dismissKeyboard()
        settingsVisible = true
    }

    private func presentArtifact(_ artifact: ArtifactRecord) {
        dismissKeyboard()
        setChatRenderSuspended(true)
        appModel.artifactPreview = artifact
    }

    private func closeSettings() {
        settingsVisible = false
    }

    private func setChatRenderSuspended(_ suspended: Bool) {
        NotificationCenter.default.post(
            name: .myChatModalVisibilityChanged,
            object: suspended
        )
    }

    private func dismissKeyboard() {
        NotificationCenter.default.post(name: .myChatDismissComposer, object: nil)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

// UIKit keeps the hosting controller alive during drawer gestures. Its root
// must still receive a new value when navigation changes. This key excludes
// streaming text and composer edits, so those do not relayout the whole canvas.
private struct CanvasNavigationKey: Equatable {
    let destination: AppDestination
    let projectID: UUID?
    let projectName: String?
    let conversationID: UUID?
    let newChatRevision: Int
    let privateChat: Bool
    let transcriptIsEmpty: Bool

    @MainActor init(appModel: AppModel) {
        destination = appModel.selectedDestination
        projectID = appModel.activeProjectID
        projectName = appModel.projects.first {
            UUID(uuidString: $0.id) == appModel.activeProjectID
        }?.name
        conversationID = appModel.activeConversationID
        newChatRevision = appModel.newChatRevision
        privateChat = appModel.isPrivateChat
        transcriptIsEmpty = appModel.messages.isEmpty
    }
}

private struct MainCanvasView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var canvasLayout: ChatCanvasLayout
    private let appModel: AppModel
    let openSidebar: () -> Void
    let openTools: () -> Void
    let openModels: () -> Void
    let openArtifact: (ArtifactRecord) -> Void

    init(appModel: AppModel, openSidebar: @escaping () -> Void,
         openTools: @escaping () -> Void, openModels: @escaping () -> Void,
         openArtifact: @escaping (ArtifactRecord) -> Void) {
        self.appModel = appModel
        self.openSidebar = openSidebar
        self.openTools = openTools
        self.openModels = openModels
        self.openArtifact = openArtifact
    }

    var body: some View {
        navigationContent
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(MyChatTheme.text)
    }

    @ViewBuilder
    private var navigationContent: some View {
        if appModel.selectedDestination == .chats {
            ZStack(alignment: .top) {
                destinationContent
                if appModel.messages.isEmpty, activeProject == nil {
                    EmptyChatHeader(appModel: appModel, openSidebar: openSidebar)
                } else if appModel.isPrivateChat {
                    PrivateChatHeader(openSidebar: openSidebar, closePrivateChat: { appModel.beginNewChat() })
                } else if let activeProject {
                    ProjectChatHeader(
                        projectName: activeProject.name,
                        appModel: appModel,
                        conversation: activeConversation,
                        backToProject: { appModel.selectedDestination = .projects },
                        newProjectChat: { beginNewChat(in: activeProject) }
                    )
                } else {
                    HeaderView(
                        openSidebar: openSidebar,
                        beginNewChat: { beginNewChat() },
                        conversation: activeConversation
                    )
                }
            }
        } else {
            VStack(spacing: 0) {
                if appModel.selectedDestination != .artifacts {
                    NavigationOnlyHeader(title: navigationTitle, openSidebar: openSidebar)
                }
                destinationContent
            }
        }
    }

    @ViewBuilder
    private var destinationContent: some View {
        switch appModel.selectedDestination {
        case .chats:
            ZStack {
            if appModel.messages.isEmpty {
                GeometryReader { proxy in
                    EmptyChatCanvas(isPrivate: appModel.isPrivateChat, bottomOcclusion: canvasLayout.bottomOcclusion,
                        systemBottomInset: proxy.safeAreaInsets.bottom, timing: canvasLayout.keyboardTiming)
                }.transition(.opacity.combined(with: .scale(scale: 0.97)).combined(with: .offset(y: -8)))
            } else {
                ChatConversationView(appModel: appModel)
                    .equatable()
                    .environmentObject(appModel)
                    .transition(.opacity.combined(with: .offset(y: 10)))
            }
            }.animation(.smooth(duration: 0.3, extraBounce: 0), value: appModel.messages.isEmpty)
        case .projects:
            ProjectsLanding()
        case .artifacts:
            ArtifactsLanding(openSidebar: openSidebar, openArtifact: openArtifact)
        case .code:
            CodeLanding()
        }
    }

    private func beginNewChat(in project: ProjectRecord? = nil) {
        MyChatDebugLog.event("beginNewChat() entered, project=\(project?.name ?? "nil")")
        HapticFeedback.impact()

        // End the text field's editing transaction before clearing the model.
        // Resigning it afterwards can write its previous text back into the
        // fresh chat, making this button appear to do nothing with the keyboard up.
        NotificationCenter.default.post(name: .myChatDismissComposer, object: nil)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
        var resetTransaction = Transaction()
        resetTransaction.disablesAnimations = true
        withTransaction(resetTransaction) {
            if let project {
                appModel.beginNewChat(in: project)
            } else {
                appModel.beginNewChat()
            }
        }
    }

    private var navigationTitle: String? {
        switch appModel.selectedDestination {
        case .projects: return "Projects"
        case .artifacts: return "Artifacts"
        case .chats, .code: return nil
        }
    }

    private var activeProject: ProjectRecord? {
        guard let activeProjectID = appModel.activeProjectID else { return nil }
        return appModel.projects.first {
            UUID(uuidString: $0.id) == activeProjectID
        }
    }

    private var activeConversation: ConversationRecord? {
        guard let activeConversationID = appModel.activeConversationID else { return nil }
        return appModel.conversations.first {
            UUID(uuidString: $0.id) == activeConversationID
        }
    }

}

@MainActor final class ChatCanvasLayout: ObservableObject {
    @Published private(set) var bottomOcclusion: CGFloat = 140
    var keyboardTiming = KeyboardTransitionTiming()
    private var pendingOcclusion: CGFloat = 140
    private var scheduled = false

    func setBottomOcclusion(_ height: CGFloat) {
        pendingOcclusion = height
        guard !scheduled, abs(bottomOcclusion - height) > 0.5 else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            if abs(self.bottomOcclusion - self.pendingOcclusion) > 0.5 {
                self.bottomOcclusion = self.pendingOcclusion
            }
        }
    }
}

private struct FloatingComposerView: View {
    let appModel: AppModel
    let openTools: () -> Void
    let openModels: () -> Void
    let drawerIsOpen: () -> Bool

    var body: some View {
        ComposerView(openTools: openTools, openModels: openModels, drawerIsOpen: drawerIsOpen)
            .environmentObject(appModel)
            .font(MyChatTypography.appDefault)
    }
}

private struct NativeDrawerHost<Sidebar: View, Canvas: View>: UIViewControllerRepresentable {
    let width: CGFloat
    @Binding var isOpen: Bool
    let blocked: Bool
    let reduceMotion: Bool
    let canvasLayout: ChatCanvasLayout
    let navigationKey: CanvasNavigationKey
    let sidebar: Sidebar
    let canvas: Canvas
    let composer: AnyView

    func makeUIViewController(context: Context) -> DrawerController<Sidebar, Canvas> {
        let controller = DrawerController(sidebar: sidebar, canvas: canvas, composer: composer)
        controller.lastNavigationKey = navigationKey
        configure(controller)
        return controller
    }

    func updateUIViewController(_ controller: DrawerController<Sidebar, Canvas>, context: Context) {
        configure(controller)
        // Preserve both hosting trees across finger tracking and release.
        // Replacing a root here relays out the entire transcript mid-animation.
        if controller.lastWidth != width {
            controller.lastWidth = width
            controller.sidebarHost.rootView = sidebar
        }
        if controller.lastNavigationKey != navigationKey {
            controller.lastNavigationKey = navigationKey
            controller.canvasHost.rootView = canvas
        }
        controller.setOpen(isOpen)
    }

    private func configure(_ controller: DrawerController<Sidebar, Canvas>) {
        controller.drawerWidth = width
        controller.blocked = blocked
        controller.reduceMotion = reduceMotion
        controller.canvasLayout = canvasLayout
        controller.composerVisible = navigationKey.destination == .chats
        controller.onOpenChanged = { isOpen = $0 }
    }
}

private final class DrawerEdgeDepth: UIView {
    private var renderedBounds: CGRect = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.10
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: -1, height: 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds != renderedBounds else { return }
        renderedBounds = bounds
        // Fixed shadow geometry is reused while the whole panel translates.
        // No text rasterization, shadow-path rebuild, or layout on gesture frames.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.shadowPath = UIBezierPath(
            roundedRect: bounds, byRoundingCorners: [.topLeft, .bottomLeft],
            cornerRadii: CGSize(width: 42, height: 42)
        ).cgPath
        CATransaction.commit()
    }
}

private final class DrawerController<Sidebar: View, Canvas: View>: UIViewController, UIGestureRecognizerDelegate {
    let sidebarHost: UIHostingController<Sidebar>
    let canvasHost: UIHostingController<Canvas>
    let composerHost: UIHostingController<AnyView>
    var composerVisible = true {
        didSet {
            guard oldValue != composerVisible, isViewLoaded else { return }
            composerHost.view.isHidden = !composerVisible
            view.setNeedsLayout()
        }
    }
    var drawerWidth: CGFloat = 0 {
        didSet { if oldValue != drawerWidth { sidebarWidthConstraint?.constant = drawerWidth } }
    }
    var blocked = false
    var reduceMotion = false
    var lastWidth: CGFloat = 0
    var lastNavigationKey: CanvasNavigationKey?
    var onOpenChanged: (Bool) -> Void = { _ in }
    private let surface = UIView()
    private let edgeDepth = DrawerEdgeDepth()
    private let tapShield = UIButton(type: .custom)
    private var lastDrawerVisible: Bool?
    private var lastInteractionActive: Bool?
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var composerHeightConstraint: NSLayoutConstraint?
    private var composerBottomConstraint: NSLayoutConstraint?
    private var keyboardEndFrame: CGRect?
    var canvasLayout: ChatCanvasLayout?
    private var keyboardMotionAudit: KeyboardMotionAudit?
    private var animator: UIViewPropertyAnimator?
    private weak var windowTapProbe: UITapGestureRecognizer?
    private var canvasScrollGestureStates: [(scrollView: UIScrollView, panWasEnabled: Bool)] = []
    private var desiredOpen = false
    private var gesturing = false
    private var currentOffset: CGFloat = 0
    private var gestureOrigin: CGFloat = 0
    private var animationOrigin: CGFloat = 0
    private var snapHapticSent = false
    private let haptic = UIImpactFeedbackGenerator(style: .rigid)
    private lazy var pan: DirectionalDrawerPanGestureRecognizer = {
        let pan = DirectionalDrawerPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.maximumNumberOfTouches = 1
        // Keep edge-origin touches buffered until the drawer direction is
        // known. Otherwise SwiftUI can bind a child control before the canvas
        // moves and activate the newly exposed sidebar row on release.
        pan.delaysTouchesBegan = true
        pan.delaysTouchesEnded = true
        pan.cancelsTouchesInView = true
        pan.delegate = self
        pan.acceptsStart = { [weak self] point in
            guard let self, !self.blocked else { return false }
            return self.desiredOpen || self.currentOffset > 1 || point.x <= 32
        }
        pan.acceptsDirection = { [weak self] delta in
            guard let self else { return false }
            return self.desiredOpen || self.currentOffset > 1 || delta.x > 0
        }
        return pan
    }()

    init(sidebar: Sidebar, canvas: Canvas, composer: AnyView) {
        sidebarHost = UIHostingController(rootView: sidebar)
        canvasHost = UIHostingController(rootView: canvas)
        composerHost = UIHostingController(rootView: composer)
        sidebarHost.safeAreaRegions = .container
        canvasHost.safeAreaRegions = .container
        // The input is a separate transparent floating host. UIKit positions
        // it once, without SwiftUI creating a full-width bottom safe-area bar.
        composerHost.safeAreaRegions = []
        composerHost.sizingOptions = []
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(MyChatTheme.sidebar)
        view.keyboardLayoutGuide.usesBottomSafeArea = true
        addChild(sidebarHost)
        view.addSubview(sidebarHost.view)
        sidebarHost.view.backgroundColor = UIColor(MyChatTheme.sidebar)
        sidebarHost.didMove(toParent: self)
        view.addSubview(edgeDepth)
        edgeDepth.alpha = 0
        view.addSubview(surface)
        surface.backgroundColor = .clear
        surface.layer.cornerCurve = .continuous
        surface.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        surface.layer.borderColor = UIColor(MyChatTheme.border).resolvedColor(with: traitCollection).cgColor
        surface.clipsToBounds = true
        addChild(canvasHost)
        surface.addSubview(canvasHost.view)
        // One full-height chat background continues behind the floating input,
        // including the entire home gesture area. There is no footer plate.
        canvasHost.view.backgroundColor = UIColor(MyChatTheme.canvas).resolvedColor(with: traitCollection)
        canvasHost.view.isOpaque = true
        canvasHost.view.clipsToBounds = true
        canvasHost.didMove(toParent: self)
        addChild(composerHost)
        surface.addSubview(composerHost.view)
        composerHost.view.backgroundColor = .clear
        composerHost.view.isOpaque = false
        composerHost.view.clipsToBounds = true
        composerHost.view.isHidden = !composerVisible
        composerHost.view.setContentHuggingPriority(.required, for: .vertical)
        composerHost.view.setContentCompressionResistancePriority(.required, for: .vertical)
        composerHost.didMove(toParent: self)
        sidebarHost.view.accessibilityElementsHidden = true
        sidebarHost.view.isUserInteractionEnabled = false
        surface.addSubview(tapShield)
        tapShield.isHidden = true
        tapShield.accessibilityLabel = "关闭侧边栏"
        tapShield.addTarget(self, action: #selector(closeFromTap), for: .touchUpInside)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: DrawerController, _: UITraitCollection) in
            controller.canvasHost.view.backgroundColor = UIColor(MyChatTheme.canvas)
                .resolvedColor(with: controller.traitCollection)
            controller.surface.layer.borderColor = UIColor(MyChatTheme.border)
                .resolvedColor(with: controller.traitCollection).cgColor
        }
        for child in [sidebarHost.view!, edgeDepth, surface, canvasHost.view!, composerHost.view!, tapShield] {
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        let sidebarWidth = sidebarHost.view.widthAnchor.constraint(equalToConstant: drawerWidth)
        sidebarWidthConstraint = sidebarWidth
        let composerHeight = composerHost.view.heightAnchor.constraint(equalToConstant: 98)
        composerHeightConstraint = composerHeight
        let composerBottom = composerHost.view.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        composerBottomConstraint = composerBottom
        NSLayoutConstraint.activate([
            sidebarHost.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebarHost.view.topAnchor.constraint(equalTo: view.topAnchor),
            sidebarHost.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebarWidth,
            edgeDepth.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            edgeDepth.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            edgeDepth.topAnchor.constraint(equalTo: view.topAnchor),
            edgeDepth.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            surface.topAnchor.constraint(equalTo: view.topAnchor),
            surface.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            canvasHost.view.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            canvasHost.view.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            canvasHost.view.topAnchor.constraint(equalTo: surface.topAnchor),
            canvasHost.view.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            composerHost.view.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            composerHost.view.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            composerBottom,
            composerHeight,
            tapShield.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            tapShield.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            tapShield.topAnchor.constraint(equalTo: surface.topAnchor),
            tapShield.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
        ])
        // Attach above both sibling trees. While open, a confirmed horizontal
        // close swipe can then cancel the sidebar row's in-flight touch.
        view.addGestureRecognizer(pan)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(self, selector: #selector(composerHeightChanged),
            name: .myChatComposerHeightChanged, object: nil)
        // Keyboard-guide constraint moves do not run this view controller's
        // layout passes, so the canvas reservation must follow keyboard events
        // directly. Without this, the transcript keeps the keyboard-closed
        // inset while the input rides above the keyboard, and the newest rows
        // stay buried behind the input and the keyboard.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardFrameWillChange),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func attachWindowTapProbeIfNeeded() {
        guard let window = view.window, windowTapProbe == nil else { return }
        let probe = UITapGestureRecognizer(target: self, action: #selector(windowTapProbed(_:)))
        probe.cancelsTouchesInView = false
        probe.delegate = self
        windowTapProbe = probe
        window.addGestureRecognizer(probe)
    }

    @objc private func windowTapProbed(_ recognizer: UITapGestureRecognizer) {
        guard let window = recognizer.view else { return }
        let point = recognizer.location(in: window)
        let hit = window.hitTest(point, with: nil)
        MyChatDebugLog.event("window tap (\(Int(point.x)),\(Int(point.y))) -> \(String(describing: type(of: hit)))")
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for overlayWindow in windowScene.windows where !overlayWindow.isHidden && overlayWindow !== window {
                let overlayHit = overlayWindow.hitTest(point, with: nil)
                MyChatDebugLog.event("other window level=\(overlayWindow.windowLevel.rawValue) -> \(overlayHit.map { String(describing: type(of: $0)) } ?? "nil")")
            }
        }
    }

    // The canvas keeps its system safe area unchanged. Only chat content gets
    // bottom clearance, so UIKit cannot shift the entire scroll view when a
    // keyboard extension updates its frame or candidate bar.
    private func canvasBottomInset() -> CGFloat {
        guard composerVisible else { return 0 }
        let restingTop = view.bounds.maxY - view.safeAreaInsets.bottom
        let keyboardTop = keyboardEndFrame.map { view.convert($0, from: nil).minY } ?? restingTop
        let top = min(max(keyboardTop, 0), restingTop)
        return max(0, view.bounds.maxY - top + (composerHeightConstraint?.constant ?? 98)
                   - (composerBottomConstraint?.constant ?? 0) + 8)
    }

    @objc private func composerHeightChanged(_ note: Notification) {
        guard let height = note.object as? CGFloat, height.isFinite,
              let constraint = composerHeightConstraint else { return }
        let bounded = max(98, height)
        guard abs(constraint.constant - bounded) > 0.5 else { return }
        constraint.constant = bounded
        setCanvasBottomInset(canvasBottomInset())
        view.setNeedsLayout()
    }

    private func setCanvasBottomInset(_ inset: CGFloat) {
        canvasLayout?.setBottomOcclusion(inset)
    }

    @objc private func keyboardFrameWillChange(_ note: Notification) {
        guard isViewLoaded, composerVisible,
              let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        // One target and one measured editor height own the reservation.
        // Never re-read an intermediate keyboard-guide frame or apply a
        // delayed correction after the system animation has finished.
        keyboardEndFrame = end
        canvasLayout?.keyboardTiming = KeyboardTransitionTiming(note)
        let overlap = view.bounds.intersection(view.convert(end, from: nil))
        composerBottomConstraint?.constant = !overlap.isNull && overlap.height > 100 ? -8 : 0
        setCanvasBottomInset(canvasBottomInset())
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if keyboardMotionAudit == nil, composerVisible, view.window != nil,
           ProcessInfo.processInfo.arguments.contains(where: { $0 == "--keyboard-layout-probe" || $0 == "--welcome-motion-probe" }) {
            keyboardMotionAudit = KeyboardMotionAudit(root: view, canvas: canvasHost.view, composer: composerHost.view)
        }
        // The native editor follows the keyboard. The canvas never changes
        // its safe-area rectangle as a side effect of keyboard avoidance.
        setCanvasBottomInset(canvasBottomInset())
        if MyChatLayoutAudit.enabled {
            MyChatLayoutAudit.record("keyboard-guide", frame: view.keyboardLayoutGuide.layoutFrame)
            MyChatLayoutAudit.record("native-canvas", frame: canvasHost.view.frame,
                detail: "root=\(view.bounds) safe=\(view.safeAreaInsets) keyboard=\(view.keyboardLayoutGuide.layoutFrame) host-safe=\(canvasHost.view.safeAreaInsets)")
            MyChatLayoutAudit.record("native-surface", frame: surface.frame,
                detail: "background=\(String(describing: surface.backgroundColor))")
            MyChatLayoutAudit.record("native-input-host", frame: composerHost.view.frame,
                detail: "safe=\(composerHost.view.safeAreaInsets) background=\(String(describing: composerHost.view.backgroundColor))")
        }
        if animator == nil, !gesturing {
            applyOffset(desiredOpen ? drawerWidth : 0)
            lockInteraction(false)
        }
    }

    @objc private func applicationDidBecomeActive() {
        // UIKit can suspend a property animator while the app backgrounds.
        // Restore a stable end state so neither the tap shield nor disabled
        // sidebar remains stranded across a return to the app.
        animator?.stopAnimation(true)
        animator = nil
        gesturing = false
        setCanvasScrollGestureLocked(false)
        applyOffset(desiredOpen ? drawerWidth : 0)
        lockInteraction(false)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        view.setNeedsLayout()
    }

    func setOpen(_ open: Bool) {
        guard desiredOpen != open, !gesturing else { return }
        desiredOpen = open
        guard isViewLoaded else { return }
        if open { dismissComposer() }
        animate(to: open, velocity: 0)
    }

    private func dismissComposer() {
        NotificationCenter.default.post(name: .myChatDismissComposer, object: nil)
        view.window?.endEditing(true)
    }

    private func applyOffset(_ offset: CGFloat) {
        currentOffset = min(max(0, offset), drawerWidth)
        let progress = drawerWidth > 0 ? currentOffset / drawerWidth : 0
        surface.transform = CGAffineTransform(translationX: currentOffset, y: 0)
        edgeDepth.transform = surface.transform
        edgeDepth.alpha = progress
        surface.layer.cornerRadius = 42 * progress
        surface.layer.borderWidth = 0.5 * progress
        // No per-frame shadow rasterization or SwiftUI layout during a pan.
        tapShield.isHidden = currentOffset < 0.5
    }

    private func interruptAnimation() {
        guard let animator else { return }
        let presented = surface.layer.presentation()?.affineTransform().tx ?? animationOrigin
        animator.stopAnimation(true)
        self.animator = nil
        applyOffset(presented)
    }

    private func setCanvasScrollGestureLocked(_ locked: Bool) {
        if locked {
            guard canvasScrollGestureStates.isEmpty else { return }
            var pending = [canvasHost.view!, composerHost.view!]
            var scrollViews: [UIScrollView] = []
            while let view = pending.popLast() {
                if let scrollView = view as? UIScrollView {
                    scrollViews.append(scrollView)
                }
                pending.append(contentsOf: view.subviews)
            }
            canvasScrollGestureStates = scrollViews.map { ($0, $0.panGestureRecognizer.isEnabled) }
            for entry in canvasScrollGestureStates where entry.panWasEnabled {
                entry.scrollView.panGestureRecognizer.isEnabled = false
            }
        } else {
            let states = canvasScrollGestureStates
            canvasScrollGestureStates.removeAll(keepingCapacity: true)
            for entry in states where entry.scrollView.panGestureRecognizer.isEnabled != entry.panWasEnabled {
                entry.scrollView.panGestureRecognizer.isEnabled = entry.panWasEnabled
            }
        }
    }

    private func lockInteraction(_ active: Bool) {
        sidebarHost.view.isUserInteractionEnabled = !active && desiredOpen
        sidebarHost.view.accessibilityElementsHidden = !desiredOpen || active
        canvasHost.view.accessibilityElementsHidden = desiredOpen || active
        composerHost.view.accessibilityElementsHidden = !composerVisible || desiredOpen || active
        let visible = desiredOpen || active
        if lastDrawerVisible != visible {
            lastDrawerVisible = visible
            NotificationCenter.default.post(name: .myChatDrawerVisibilityChanged, object: visible)
        }
        if lastInteractionActive != active {
            lastInteractionActive = active
            NotificationCenter.default.post(name: .myChatDrawerInteractionChanged, object: active)
        }
    }

    private func animate(to open: Bool, velocity: CGFloat) {
        interruptAnimation()
        lockInteraction(true)
        let target = open ? drawerWidth : 0
        let distance = target - currentOffset
        guard abs(distance) > 0.5 else {
            applyOffset(target)
            lockInteraction(false)
            return
        }
        let timing: UITimingCurveProvider
        let duration: TimeInterval
        if reduceMotion {
            timing = UICubicTimingParameters(animationCurve: .easeOut)
            duration = 0.12
        } else {
            // UIKit's spring starts at the live position and measured finger
            // velocity. Releasing a fling does not restart from rest.
            timing = UISpringTimingParameters(dampingRatio: 1,
                initialVelocity: CGVector(dx: min(max(velocity / distance, -20), 20), dy: 0))
            duration = 0.27
        }
        let next = UIViewPropertyAnimator(duration: duration, timingParameters: timing)
        animationOrigin = currentOffset
        animator = next
        next.addAnimations { [weak self] in self?.applyOffset(target) }
        next.addCompletion { [weak self, weak next] _ in
            guard let self, self.animator === next else { return }
            self.animator = nil
            self.applyOffset(target)
            self.lockInteraction(false)
        }
        next.startAnimation()
    }

    @objc private func closeFromTap() {
        HapticFeedback.impact()
        desiredOpen = false
        onOpenChanged(false)
        animate(to: false, velocity: 0)
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: view).x
        switch recognizer.state {
        case .began:
            // Direction has been classified as horizontal. Cancel every active
            // vertical scroll pan inside the moving canvas until this same
            // touch ends; small vertical finger drift can no longer move both.
            setCanvasScrollGestureLocked(true)
            interruptAnimation()
            gesturing = true
            gestureOrigin = currentOffset
            snapHapticSent = false
            dismissComposer()
            haptic.prepare()
            lockInteraction(true)
        case .changed:
            // Transform and layer properties only: no @State, layout, or
            // scroll-to call on the frame-by-frame touch path.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            applyOffset(gestureOrigin + translation)
            CATransaction.commit()
            let crossed = desiredOpen ? currentOffset < drawerWidth * 0.5 : currentOffset > drawerWidth * 0.5
            if crossed, !snapHapticSent {
                snapHapticSent = true
                haptic.impactOccurred(intensity: 0.9)
            }
        case .ended, .cancelled:
            let velocity = recognizer.velocity(in: view).x
            let open = recognizer.state == .cancelled ? desiredOpen
                : currentOffset + velocity * 0.18 > drawerWidth * 0.52
            gesturing = false
            setCanvasScrollGestureLocked(false)
            if open != desiredOpen, !snapHapticSent { haptic.impactOccurred(intensity: 0.9) }
            desiredOpen = open
            onOpenChanged(open)
            animate(to: open, velocity: recognizer.state == .cancelled ? 0 : velocity)
        default: break
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard !blocked else { return false }
        let velocity = pan.velocity(in: view)
        return abs(velocity.x) > abs(velocity.y) * 1.4
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // The drawer's horizontal transform and the canvas's vertical pan are
        // mutually exclusive. Direction is decided while this recognizer is
        // still possible, so vertical scrolling remains native and a confirmed
        // drawer pan cannot also move the transcript vertically.
        false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
        shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan,
              !desiredOpen,
              currentOffset <= 1,
              let scrollView = otherGestureRecognizer.view as? UIScrollView,
              scrollView.isDescendant(of: canvasHost.view) else { return false }
        // At the drawer edge, let the direction classifier settle first. A
        // horizontal pan wins; a vertical intent fails quickly and hands the
        // touch straight back to UIKit scrolling.
        return true
    }
}

// Opt-in geometry-only diagnostics. Records no pixels, text, or audio. The
// ordinary launch path never creates a display link or touches focus for this.
@MainActor final class KeyboardMotionAudit: NSObject {
    static var phase = "startup"
    static var messageFrame: CGRect?
    static var assistantFrame: CGRect?
    static var lastContentChangeTime = CACurrentMediaTime()
    static var currentReplyState: (() -> (complete: Bool, characters: Int))?
    static var welcomeReady = false
    private weak var root: UIView?
    private weak var canvas: UIView?
    private weak var composer: UIView?
    private weak var scroll: UIScrollView?
    private weak var welcome: WelcomeMotionSurface?
    private var link: CADisplayLink?
    private var observer: NSObjectProtocol?
    private var frames: [[String: Any]] = []
    private var lastContentHeight: CGFloat?
    private let started = CACurrentMediaTime()

    init(root: UIView, canvas: UIView, composer: UIView) {
        self.root = root; self.canvas = canvas; self.composer = composer
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(sample))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        self.link = link
        link.add(to: .main, forMode: .common)
        observer = NotificationCenter.default.addObserver(forName: .myChatKeyboardProbeFinished,
            object: nil, queue: .main) { [weak self] _ in self?.finish() }
    }

    @objc private func sample() {
        guard let root, let composer, frames.count < 7200 else { finish(); return }
        if scroll == nil, let canvas {
            var queue = [canvas]
            while !queue.isEmpty {
                let view = queue.removeFirst()
                if let found = view as? UIScrollView { scroll = found; break }
                queue.append(contentsOf: view.subviews)
            }
        }
        if welcome == nil, let canvas {
            var queue = [canvas]
            while !queue.isEmpty {
                let view = queue.removeFirst()
                if let found = view as? WelcomeMotionSurface { welcome = found; break }
                queue.append(contentsOf: view.subviews)
            }
        }
        let presented = composer.layer.presentation()?.frame ?? composer.frame
        let reply = Self.currentReplyState?() ?? (complete: false, characters: 0)
        var frame: [String: Any] = ["time": CACurrentMediaTime() - started,
            "phase": Self.phase, "composerY": presented.minY, "composerHeight": presented.height,
            "replyComplete": reply.complete, "replyCharacters": reply.characters,
            "canvasTopInset": canvas?.safeAreaInsets.top ?? 0,
            "canvasBottomInset": canvas?.safeAreaInsets.bottom ?? 0,
            "keyboardTop": root.keyboardLayoutGuide.layoutFrame.minY]
        if let scroll {
            if lastContentHeight == nil || abs((lastContentHeight ?? 0) - scroll.contentSize.height) > 0.5 {
                Self.lastContentChangeTime = CACurrentMediaTime()
                lastContentHeight = scroll.contentSize.height
            }
            frame["contentOriginY"] = scroll.convert(.zero, to: root).y
            frame["offsetY"] = scroll.contentOffset.y
            frame["scrollTopInset"] = scroll.adjustedContentInset.top
            frame["scrollHeight"] = scroll.bounds.height
            frame["contentHeight"] = scroll.contentSize.height
            frame["tracking"] = scroll.isTracking
            frame["dragging"] = scroll.isDragging
            frame["decelerating"] = scroll.isDecelerating
        }
        if let welcome {
            Self.welcomeReady = welcome.logo.bounds.width > 0 && welcome.window != nil
            let origin = welcome.convert(CGPoint.zero, to: root)
            let logo = welcome.logo.layer.presentation() ?? welcome.logo.layer
            let label = welcome.greeting.layer.presentation() ?? welcome.greeting.layer
            frame["heroY"] = origin.y + logo.frame.midY
            frame["greetingY"] = origin.y + label.frame.midY
            frame["heroAlpha"] = logo.opacity
            frame["heroWidth"] = logo.frame.width
            frame["greetingAlpha"] = label.opacity
            if let ghost = welcome.privateLogo {
                let layer = ghost.layer.presentation() ?? ghost.layer
                frame["privateY"] = origin.y + layer.frame.midY
                frame["privateAlpha"] = layer.opacity
                frame["privateWidth"] = layer.frame.width
            }
        }
        if let message = Self.messageFrame { frame["messageY"] = message.minY; frame["messageHeight"] = message.height }
        if let assistant = Self.assistantFrame { frame["assistantY"] = assistant.minY; frame["assistantHeight"] = assistant.height }
        frames.append(frame)
    }

    private func finish() {
        link?.invalidate(); link = nil
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        guard !frames.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: frames, options: [.sortedKeys]),
              let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? data.write(to: folder.appendingPathComponent("keyboard-motion-audit.json"), options: .atomic)
    }
    deinit { link?.invalidate(); if let observer { NotificationCenter.default.removeObserver(observer) } }
}

@MainActor enum MyChatLayoutAudit {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--layout-audit")
    private static var frames: [String: CGRect] = [:]
    private static var samples: [String: Int] = [:]
    private static let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("layout-audit.log")

    static func record(_ label: String, frame: CGRect, detail: String = "") {
        guard enabled, frames[label] != frame, (samples[label] ?? 0) < 600 else { return }
        frames[label] = frame
        samples[label, default: 0] += 1
        line("MYCHAT_LAYOUT \(label) frame=\(frame) \(detail)")
    }

    static func line(_ text: String) {
        guard enabled else { return }
        print(text)
        guard let data = (text + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file, options: .atomic)
        }
    }
}

private final class DirectionalDrawerPanGestureRecognizer: UIPanGestureRecognizer {
    var acceptsStart: ((CGPoint) -> Bool)?
    var acceptsDirection: ((CGPoint) -> Bool)?
    private var initialLocation: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, let view else {
            super.touchesBegan(touches, with: event); return
        }
        let point = touch.location(in: view)
        MyChatDebugLog.event("canvas touch (\(Int(point.x)),\(Int(point.y))) panState=\(state.rawValue)")
        guard acceptsStart?(point) != false else { state = .failed; return }
        initialLocation = point
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first, let view, let initialLocation else {
            super.touchesMoved(touches, with: event); return
        }
        let point = touch.location(in: view)
        let delta = CGPoint(x: point.x - initialLocation.x, y: point.y - initialLocation.y)
        // Classify once. Changing a recognized pan to .failed when the finger
        // curves vertically interrupts its live transform and release velocity.
        if state == .possible {
            if abs(delta.y) >= 3, abs(delta.y) > abs(delta.x) * 1.2 { state = .failed; return }
            if abs(delta.x) >= 3, acceptsDirection?(delta) == false { state = .failed; return }
        }
        super.touchesMoved(touches, with: event)
    }

    override func reset() { initialLocation = nil; super.reset() }
}

private struct NavigationOnlyHeader: View {
    let title: String?
    let openSidebar: () -> Void

    var body: some View {
        ZStack {
            if let title {
                Text(title)
                    .font(MyChatTypography.pageTitleUtility)
            }

            HStack {
                Button(action: openSidebar) {
                    Image(systemName: "line.3.horizontal")
                        .font(MyChatSystemFont.appFont(size: 16, weight: .medium))
                        .foregroundStyle(MyChatTheme.text)
                }
                .buttonStyle(MyChatIconButtonStyle(size: 44))
                .accessibilityLabel("打开侧边栏")

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 62)
    }
}

private struct EmptyChatHeader: View {
    @ObservedObject var appModel: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let openSidebar: () -> Void

    var body: some View {
        ZStack {
            Text("Incognito chat").font(MyChatTypography.navigation)
                .opacity(appModel.isPrivateChat ? 1 : 0)
                .scaleEffect(appModel.isPrivateChat ? 1 : 0.98)
                .offset(y: appModel.isPrivateChat ? 0 : -4)
                .accessibilityHidden(!appModel.isPrivateChat)
            HStack {
                Button(action: openSidebar) {
                    ChatMenuGlyph().stroke(style: StrokeStyle(lineWidth: 1.35, lineCap: .round))
                        .frame(width: 16, height: 16).foregroundStyle(MyChatTheme.text)
                }
                .buttonStyle(MyChatIconButtonStyle(size: 44))
                .accessibilityLabel("打开侧边栏")
                Spacer(minLength: 0)
                Button {
                    HapticFeedback.impact()
                    if appModel.isPrivateChat { appModel.beginNewChat() } else { appModel.beginPrivateChat() }
                } label: {
                    PrivacyChatGlyph(foreground: MyChatTheme.text, eyeColor: MyChatTheme.canvas, filled: appModel.isPrivateChat)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(MyChatIconButtonStyle(size: 44))
                .accessibilityLabel(appModel.isPrivateChat ? "退出隐私聊天" : "开始隐私聊天")
                .accessibilityIdentifier("header.private-chat")
            }
        }
        .padding(.horizontal, 20).frame(height: 52).offset(y: -4)
        .animation(reduceMotion ? nil : .smooth(duration: 0.34, extraBounce: 0), value: appModel.isPrivateChat)
    }
}

private struct PrivateChatHeader: View {
    let openSidebar: () -> Void
    let closePrivateChat: () -> Void

    var body: some View {
        ZStack {
            Text("Incognito chat")
                .font(MyChatTypography.navigation)

            HStack {
                Button(action: openSidebar) {
                    ChatMenuGlyph().stroke(style: StrokeStyle(lineWidth: 1.35, lineCap: .round))
                        .frame(width: 16, height: 16)
                        .foregroundStyle(MyChatTheme.text)
                }
                .buttonStyle(MyChatIconButtonStyle(size: 44))
                .accessibilityLabel("打开侧边栏")

                Spacer(minLength: 0)

                Button(action: closePrivateChat) {
                    PrivacyChatGlyph(foreground: MyChatTheme.text, eyeColor: MyChatTheme.canvas)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(MyChatIconButtonStyle(size: 44))
                .accessibilityLabel("退出隐私聊天")
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .offset(y: -4)
    }
}

private struct ProjectChatHeader: View {
    let projectName: String
    let appModel: AppModel
    let conversation: ConversationRecord?
    let backToProject: () -> Void
    let newProjectChat: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: backToProject) {
                Image(systemName: "chevron.left")
                    .font(MyChatSystemFont.appFont(size: 16, weight: .medium))
                    .foregroundStyle(MyChatTheme.text)
            }
            .buttonStyle(MyChatIconButtonStyle(size: 44))
            .accessibilityLabel("返回项目")

            HStack(spacing: 7) {
                Image(systemName: "archivebox")
                    .font(MyChatSystemFont.appFont(size: 15, weight: .medium))
                Text(projectName)
                    .font(MyChatTypography.chip)
                    .lineLimit(1)
            }
            .padding(.horizontal, 13)
            .frame(height: 44)
            .modifier(MyChatFloatingSurface(shape: Capsule()))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("当前项目：\(projectName)")

            Spacer(minLength: 0)
            ConversationFilesButton(appModel: appModel).padding(.trailing, 2)

            if conversation != nil {
                HStack(spacing: 0) {
                    Button {
                        HapticFeedback.impact()
                        newProjectChat()
                    } label: {
                        NewChatHeaderGlyph()
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(MyChatBubblePressStyle())
                    .accessibilityLabel("在项目中新建聊天")
                    .accessibilityIdentifier("header.new-project-chat")

                    ConversationActionMenu(appModel: appModel, conversation: conversation)
                }
                .padding(.horizontal, 6)
                .modifier(MyChatFloatingSurface(shape: Capsule(), isInteractive: true))
            } else {
                Button {
                    HapticFeedback.impact()
                    newProjectChat()
                } label: {
                    NewChatHeaderGlyph().frame(width: 24, height: 24)
                }
                .buttonStyle(MyChatIconButtonStyle(size: 44))
                .accessibilityLabel("在项目中新建聊天")
                .accessibilityIdentifier("header.new-project-chat")
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .offset(y: -4)
    }
}

private struct HeaderView: View {
    @EnvironmentObject private var appModel: AppModel
    let openSidebar: () -> Void
    let beginNewChat: () -> Void
    let conversation: ConversationRecord?

    var body: some View {
        HStack(spacing: 0) {
            Button(action: openSidebar) {
                ChatMenuGlyph().stroke(style: StrokeStyle(lineWidth: 1.35, lineCap: .round))
                    .frame(width: 16, height: 16)
                    .foregroundStyle(MyChatTheme.text)
            }
            .buttonStyle(MyChatIconButtonStyle(size: 44))
            .accessibilityLabel("打开侧边栏")

            Spacer(minLength: 0)

            ConversationFilesButton(appModel: appModel).padding(.trailing, 12)

            if hasStartedChat {
                // iOS 26 merges adjacent bar buttons into one glass capsule;
                // mirror that instead of two independent circles.
                HStack(spacing: 0) {
                    Button(action: beginNewChat) {
                        NewChatHeaderGlyph()
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(MyChatBubblePressStyle())
                    .accessibilityLabel("新建聊天")
                    .accessibilityIdentifier("header.new-chat")

                    ConversationActionMenu(appModel: appModel, conversation: conversation)
                }
                .padding(.horizontal, 6)
                .modifier(MyChatFloatingSurface(shape: Capsule(), isInteractive: true))
            } else {
                Button { HapticFeedback.impact(); appModel.beginPrivateChat() } label: {
                    PrivacyChatGlyph(foreground: MyChatTheme.text, eyeColor: MyChatTheme.canvas).frame(width: 20, height: 20)
                }
                .buttonStyle(MyChatIconButtonStyle(size: 44))
                .accessibilityLabel("开始隐私聊天")
                .accessibilityIdentifier("header.private-chat")
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .offset(y: -4)
    }

    private var hasStartedChat: Bool {
        conversation != nil || !appModel.messages.isEmpty
    }
}

private struct ConversationActionMenu: View {
    let appModel: AppModel
    let conversation: ConversationRecord?
    @State private var actionError: String?

    var body: some View {
        Menu {
            Menu {
                if appModel.projects.isEmpty {
                    Button("No projects yet") {}
                        .disabled(true)
                } else {
                    ForEach(appModel.projects) { project in
                        Button {
                            guard let conversation else { return }
                            Task {
                                do {
                                    try await appModel.setConversationProject(conversation, project: project)
                                } catch {
                                    actionError = error.localizedDescription
                                }
                            }
                        } label: {
                            if conversation?.projectID?.lowercased() == project.id.lowercased() {
                                Label(project.name, systemImage: "checkmark")
                            } else {
                                Text(project.name)
                            }
                        }
                    }
                }
            } label: {
                Label("Add to Project", systemImage: "folder.badge.plus")
            }
            .disabled(conversation == nil || appModel.projects.isEmpty)

            Button(role: .destructive) {
                guard let conversation else { return }
                Task {
                    do {
                        try await appModel.deleteConversation(conversation)
                    } catch {
                        actionError = error.localizedDescription
                    }
                }
            } label: {
                Label("Delete conversation", systemImage: "trash")
            }
            .disabled(conversation == nil)
        } label: {
            Image(systemName: "ellipsis")
                .font(MyChatSystemFont.appFont(size: 15, weight: .semibold))
                .foregroundStyle(MyChatTheme.text)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .accessibilityLabel("更多聊天选项")
        .alert(
            "Conversation action failed",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(PresentationText.plain(actionError ?? ""))
        }
    }
}

private struct NewChatHeaderGlyph: View {
    var body: some View {
        ZStack {
            NewChatCirclePath().fill(MyChatTheme.newChatGlyphFill)
            Path { p in
                p.move(to: CGPoint(x: 8, y: 11)); p.addLine(to: CGPoint(x: 16, y: 11))
                p.move(to: CGPoint(x: 12, y: 7)); p.addLine(to: CGPoint(x: 12, y: 15))
            }.stroke(MyChatTheme.newChatGlyphPlus, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        }.frame(width: 24, height: 24)
    }
}
private struct NewChatCirclePath: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 4, y: 17)); p.addLine(to: CGPoint(x: 2, y: 21)); p.addLine(to: CGPoint(x: 12, y: 21))
        p.addCurve(to: CGPoint(x: 22, y: 11), control1: CGPoint(x: 17.5, y: 21), control2: CGPoint(x: 22, y: 16.5))
        p.addCurve(to: CGPoint(x: 12, y: 1), control1: CGPoint(x: 22, y: 5.5), control2: CGPoint(x: 17.5, y: 1))
        p.addCurve(to: CGPoint(x: 2, y: 11), control1: CGPoint(x: 6.5, y: 1), control2: CGPoint(x: 2, y: 5.5))
        p.addCurve(to: CGPoint(x: 4, y: 17), control1: CGPoint(x: 2, y: 13.2), control2: CGPoint(x: 2.7, y: 15.3))
        return p.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
    }
}

struct ChatMenuGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (fraction, width) in [(CGFloat(0.08), CGFloat(1)), (CGFloat(0.5), CGFloat(1)), (CGFloat(0.92), CGFloat(0.5))] {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * fraction))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * width, y: rect.minY + rect.height * fraction))
        }
        return path
    }
}

struct PrivacyChatGlyph: View {
    var foreground: Color = MyChatTheme.text
    var eyeColor: Color = MyChatTheme.canvas
    var filled = true
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            if filled {
                PrivacyGhostOutline().fill(foreground).frame(width: size, height: size * 25 / 24)
            } else {
                PrivacyGhostOutline().stroke(foreground, style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
                    .frame(width: size, height: size * 25 / 24)
            }

            HStack(spacing: 5 * size / 24) {
                Circle().frame(width: 2.7 * size / 24, height: 2.7 * size / 24)
                Circle().frame(width: 2.7 * size / 24, height: 2.7 * size / 24)
            }
            .foregroundStyle(filled ? eyeColor : foreground)
            .offset(y: -size / 24)
        }
        .accessibilityHidden(true)
    }
}

private struct PrivacyGhostOutline: Shape {
    func path(in rect: CGRect) -> Path {
        let left: CGFloat = 2
        let right: CGFloat = 22
        let top: CGFloat = 1.5
        let bottom: CGFloat = 23.5
        let middle: CGFloat = 12
        var path = Path()

        path.move(to: CGPoint(x: left, y: bottom - 1))
        path.addLine(to: CGPoint(x: left, y: top + 10))
        path.addCurve(
            to: CGPoint(x: middle, y: top),
            control1: CGPoint(x: left, y: top + 3),
            control2: CGPoint(x: middle - 5.8, y: top)
        )
        path.addCurve(
            to: CGPoint(x: right, y: top + 10),
            control1: CGPoint(x: middle + 5.8, y: top),
            control2: CGPoint(x: right, y: top + 3)
        )
        path.addLine(to: CGPoint(x: right, y: bottom - 1))
        path.addCurve(
            to: CGPoint(x: middle + 4, y: bottom - 4),
            control1: CGPoint(x: right - 3.3, y: bottom - 1),
            control2: CGPoint(x: right - 5.5, y: bottom - 5.8)
        )
        path.addCurve(
            to: CGPoint(x: middle, y: bottom),
            control1: CGPoint(x: middle + 2.5, y: bottom - 2),
            control2: CGPoint(x: middle + 1.2, y: bottom)
        )
        path.addCurve(
            to: CGPoint(x: middle - 4, y: bottom - 4),
            control1: CGPoint(x: middle - 1.2, y: bottom),
            control2: CGPoint(x: middle - 2.5, y: bottom - 2)
        )
        path.addCurve(
            to: CGPoint(x: left, y: bottom - 1),
            control1: CGPoint(x: left + 5.5, y: bottom - 5.8),
            control2: CGPoint(x: left + 3.3, y: bottom - 1)
        )
        path.closeSubpath()
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 25)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

private struct EmptyChatCanvas: View {
    let isPrivate: Bool
    let bottomOcclusion: CGFloat
    let systemBottomInset: CGFloat
    let timing: KeyboardTransitionTiming
    @State private var greeting = "What shall we think through?"
    var body: some View {
        WelcomeMotionView(greeting: greeting, isPrivate: isPrivate,
            bottomOcclusion: bottomOcclusion, systemBottomInset: systemBottomInset, timing: timing)
            .onAppear { greeting = nextGreeting() }
    }
    private func nextGreeting() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        let choices = hour < 5 || hour >= 22
            ? ["Hello, night owl", "Up late? What's on your mind?", "What shall we think through?"]
            : ["What's on your mind?", "What shall we think through?", "Where shall we start?"]
        let previous = UserDefaults.standard.string(forKey: "mychat.home.last-greeting")
        let selected = choices.filter { $0 != previous }.randomElement() ?? choices[0]
        UserDefaults.standard.set(selected, forKey: "mychat.home.last-greeting")
        return selected
    }
}

private struct ProjectsLanding: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var createProjectPresented = false
    @State private var selectedProject: ProjectRecord?
    @State private var deletionError: String?
    @State private var searchText = ""

    var body: some View {
        ZStack(alignment: .bottom) {
            projectContent
                .padding(.bottom, 126)

            VStack(alignment: .trailing, spacing: 12) {
                Button {
                    createProjectPresented = true
                } label: {
                    Label("New project", systemImage: "plus")
                        .font(MyChatTypography.button)
                        .foregroundStyle(MyChatTheme.canvas)
                        .padding(.horizontal, 22)
                        .frame(minHeight: 50)
                        .background(MyChatTheme.text, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("新建项目")

                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(MyChatSystemFont.appFont(size: 19, weight: .medium))
                        .foregroundStyle(MyChatTheme.secondaryText)
                    TextField("Search", text: $searchText)
                        .font(MyChatTypography.cardBody)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 17)
                .frame(minHeight: 52)
                .background(MyChatTheme.raised, in: Capsule())
                .overlay {
                    Capsule().stroke(MyChatTheme.border.opacity(0.74), lineWidth: 0.7)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await appModel.reloadWorkspaceData()
        }
        .fullScreenCover(isPresented: $createProjectPresented) {
            CreateProjectView()
                .environmentObject(appModel)
        }
        .fullScreenCover(item: $selectedProject) { project in
            ProjectDetailView(project: project)
                .environmentObject(appModel)
        }
        .alert(
            "Couldn’t delete project",
            isPresented: Binding(
                get: { deletionError != nil || appModel.projectDeletionError != nil },
                set: { if !$0 { deletionError = nil; appModel.clearProjectDeletionError() } }
            )
        ) {
            Button("OK", role: .cancel) { deletionError = nil; appModel.clearProjectDeletionError() }
        } message: {
            Text(PresentationText.plain(deletionError ?? appModel.projectDeletionError ?? ""))
        }
    }

    @ViewBuilder
    private var projectContent: some View {
        if appModel.projects.isEmpty {
            VStack(spacing: 18) {
                if appModel.workspacePhase == .loading {
                    ProgressView()
                } else {
                    Image(systemName: "archivebox")
                        .font(MyChatSystemFont.appFont(size: 24, weight: .medium))
                        .frame(width: 58, height: 58)
                        .background(MyChatTheme.selected, in: Circle())
                }
                Text(PresentationText.plain(appModel.projectsError ?? "No projects yet"))
                    .font(MyChatTypography.cardTitle)
                Text("Create a project to keep its chats, instructions, files, and memories together.")
                    .font(MyChatTypography.metadata)
                    .foregroundStyle(MyChatTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 330)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredProjects.isEmpty {
            Text("No matching projects")
                .font(MyChatTypography.cardBody)
                .foregroundStyle(MyChatTheme.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredProjects) { project in
                        HStack(spacing: 0) {
                            Button {
                                selectedProject = project
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(project.name)
                                        .font(MyChatTypography.cardTitle)
                                        .lineLimit(1)
                                    if !project.instructions.isEmpty {
                                        Text(project.instructions)
                                            .font(MyChatTypography.metadata)
                                            .foregroundStyle(MyChatTheme.secondaryText)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Menu {
                                Button(role: .destructive) {
                                    Task {
                                        do {
                                            try await appModel.deleteProject(project)
                                        } catch {
                                            deletionError = error.localizedDescription
                                        }
                                    }
                                } label: {
                                    Label("Delete project", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(MyChatSystemFont.appFont(size: 17, weight: .semibold))
                                    .frame(width: 46, height: 66)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("项目操作")
                        }

                        if project.id != filteredProjects.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
            .refreshable { await appModel.reloadWorkspaceData() }
        }
    }

    private var filteredProjects: [ProjectRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return appModel.projects }
        return appModel.projects.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.instructions.localizedCaseInsensitiveContains(query)
        }
    }
}

private struct CreateProjectView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var instructions = ""
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        ZStack {
            MyChatTheme.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                ZStack {
                    Text("Create a project")
                        .font(MyChatTypography.pageTitleUtility)
                    HStack {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark")
                                .font(MyChatSystemFont.appFont(size: 18, weight: .medium))
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(MyChatIconButtonStyle())
                        .accessibilityLabel("关闭")
                        Spacer()

                        Button(action: saveProject) {
                            Group {
                                if isSaving {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "checkmark")
                                        .font(MyChatSystemFont.appFont(size: 19, weight: .semibold))
                                }
                            }
                        }
                        .buttonStyle(MyChatIconButtonStyle())
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
                        .opacity(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.36 : 1)
                        .accessibilityLabel("创建项目")
                    }
                }
                .padding(.horizontal, 18)
                .frame(height: 62)

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("What are you working on?")
                                .font(MyChatTypography.cardTitle)
                                .foregroundStyle(MyChatTheme.secondaryText)
                            TextField("Project name", text: $name)
                                .font(MyChatTypography.cardBody)
                                .focused($nameFocused)
                                .padding(.horizontal, 16)
                                .frame(minHeight: 58)
                                .background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                                        .stroke(MyChatTheme.border.opacity(0.8), lineWidth: 0.7)
                                }
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("What are you trying to achieve?")
                                .font(MyChatTypography.cardTitle)
                                .foregroundStyle(MyChatTheme.secondaryText)
                            TextField("Describe your project, goals, subject, and instructions…", text: $instructions, axis: .vertical)
                                .font(MyChatTypography.cardBody)
                                .lineLimit(6...10)
                                .padding(16)
                                .background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                                        .stroke(MyChatTheme.border.opacity(0.8), lineWidth: 0.7)
                                }
                        }

                        if let errorMessage {
                            Text(PresentationText.plain(errorMessage))
                                .font(MyChatSystemFont.appFont(for: .subheadline, weight: .regular))
                                .foregroundStyle(Color.red)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 20)
                    .padding(.bottom, 30)
                }
            }
        }
        .foregroundStyle(MyChatTheme.text)
        .onAppear { nameFocused = true }
    }

    private func saveProject() {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                _ = try await appModel.createProject(
                    name: name,
                    instructions: instructions
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

private struct ProjectDetailView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    let project: ProjectRecord
    @State private var instructions: String
    @State private var isStarred = false
    @State private var fileImporterPresented = false
    @State private var instructionsPresented = false
    @State private var errorMessage: String?

    init(project: ProjectRecord) {
        self.project = project
        _instructions = State(initialValue: project.instructions)
    }

    var body: some View {
        ZStack {
            MyChatTheme.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                projectHeader

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(MyChatTheme.secondaryText)
                    Text(instructions.isEmpty ? "No project instructions" : instructions)
                        .font(MyChatTypography.cardBody)
                        .lineSpacing(MyChatTypography.utilityLineSpacing)
                        .foregroundStyle(instructions.isEmpty ? MyChatTheme.secondaryText : MyChatTheme.text)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 15)
                .background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.horizontal, 18)
                .padding(.top, 10)

                HStack(spacing: 10) {
                    projectActionButton("Add files", systemImage: "doc.badge.plus") {
                        HapticFeedback.impact()
                        fileImporterPresented = true
                    }
                    projectActionButton("Add instructions", systemImage: "text.badge.plus") {
                        instructionsPresented = true
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)

                if projectConversations.isEmpty {
                    Spacer(minLength: 20)
                    VStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(MyChatSystemFont.appFont(size: 22, weight: .regular))
                            .frame(width: 58, height: 58)
                            .background(MyChatTheme.selected, in: Circle())
                        Text("No chats in this project")
                            .font(MyChatTypography.cardTitle)
                        Text("Start a conversation to see it here.")
                            .font(MyChatTypography.metadata)
                            .foregroundStyle(MyChatTheme.secondaryText)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 20)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(projectConversations) { conversation in
                                Button {
                                    appModel.openConversation(conversation)
                                    dismiss()
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "bubble.left.and.bubble.right")
                                            .font(MyChatSystemFont.appFont(size: 16, weight: .regular))
                                            .frame(width: 24)
                                        Text(conversation.title.isEmpty ? "Untitled" : conversation.title)
                                            .font(MyChatTypography.cardBody)
                                            .lineLimit(1)
                                        Spacer(minLength: 8)
                                        Image(systemName: "chevron.right")
                                            .font(MyChatSystemFont.appFont(for: .caption1, weight: .semibold))
                                            .foregroundStyle(MyChatTheme.secondaryText)
                                    }
                                    .frame(minHeight: 54)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                if conversation.id != projectConversations.last?.id {
                                    Divider().padding(.leading, 36)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
                    }
                }

                if let errorMessage {
                    Text(PresentationText.plain(errorMessage))
                        .font(MyChatTypography.metadata)
                        .foregroundStyle(Color.red)
                        .padding(.horizontal, 18)
                }

                Button {
                    appModel.beginNewChat(in: project)
                    dismiss()
                } label: {
                    Label("New chat", systemImage: "plus")
                        .font(MyChatTypography.button)
                        .foregroundStyle(MyChatTheme.canvas)
                        .padding(.horizontal, 22)
                        .frame(minHeight: 50)
                        .background(MyChatTheme.text, in: Capsule())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
        }
        .foregroundStyle(MyChatTheme.text)
        .fileImporter(
            isPresented: $fileImporterPresented,
            allowedContentTypes: [.text, .json],
            allowsMultipleSelection: true,
            onCompletion: importProjectFiles
        )
        .sheet(isPresented: $instructionsPresented) {
            ProjectInstructionsEditor(initialValue: instructions) { value in
                try await appModel.updateProject(project, name: project.name, instructions: value)
                instructions = value
            }
            .presentationDetents([.fraction(0.7)])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(34)
            .presentationBackground(MyChatTheme.canvas)
        }
    }

    private var projectHeader: some View {
        ZStack {
            Text(project.name)
                .font(MyChatTypography.pageTitleUtility)
                .lineLimit(1)
                .padding(.horizontal, 110)

            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(MyChatSystemFont.appFont(size: 18, weight: .semibold))
                }
                .buttonStyle(MyChatIconButtonStyle())
                .accessibilityLabel("返回")

                Spacer()

                HStack(spacing: 0) {
                    Button { isStarred.toggle() } label: {
                        Image(systemName: isStarred ? "star.fill" : "star")
                            .font(MyChatSystemFont.appFont(size: 18, weight: .medium))
                            .frame(width: 42, height: 42)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isStarred ? "取消项目置顶" : "项目置顶")

                    Divider().frame(height: 22)

                    Menu {
                        Button(role: .destructive) {
                            deleteProject()
                        } label: {
                            Label("Delete project", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(MyChatSystemFont.appFont(size: 18, weight: .semibold))
                            .frame(width: 42, height: 42)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("项目操作")
                }
                .padding(.horizontal, 3)
                .background(MyChatTheme.raised, in: Capsule())
                .overlay {
                    Capsule().stroke(MyChatTheme.border.opacity(0.78), lineWidth: 0.7)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 62)
    }

    private var projectConversations: [ConversationRecord] {
        appModel.conversations.filter { $0.projectID == project.id }
    }

    private func projectActionButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(MyChatTypography.button)
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.plain)
        .background(MyChatTheme.raised, in: Capsule())
        .overlay {
            Capsule().stroke(MyChatTheme.border.opacity(0.78), lineWidth: 0.7)
        }
    }

    private func deleteProject() {
        HapticFeedback.impact()
        dismiss()
        Task {
            do {
                try await appModel.deleteProject(project)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func importProjectFiles(_ result: Result<[URL], Error>) {
        Task {
            do {
                for url in try result.get() {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer {
                        if accessing { url.stopAccessingSecurityScopedResource() }
                    }
                    let data = try Data(contentsOf: url)
                    guard let content = String(data: data, encoding: .utf8) else {
                        throw CocoaError(.fileReadInapplicableStringEncoding)
                    }
                    _ = try await appModel.addProjectFile(
                        to: project,
                        name: url.lastPathComponent,
                        content: content
                    )
                }
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct ProjectInstructionsEditor: View {
    @Environment(\.dismiss) private var dismiss
    let save: (String) async throws -> Void
    @State private var value: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(initialValue: String, save: @escaping (String) async throws -> Void) {
        self.save = save
        _value = State(initialValue: initialValue)
    }

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Text("Project instructions")
                    .font(MyChatTypography.pageTitleUtility)
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(MyChatIconButtonStyle())
                    Spacer()
                    Button(action: persist) {
                        if isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "checkmark")
                        }
                    }
                    .buttonStyle(MyChatIconButtonStyle())
                    .disabled(isSaving)
                }
            }
            .frame(height: 52)

            TextEditor(text: $value)
                .font(MyChatTypography.cardBody)
                .scrollContentBackground(.hidden)
                .padding(14)
                .background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(MyChatTheme.border.opacity(0.78), lineWidth: 0.7)
                }

            if let errorMessage {
                Text(PresentationText.plain(errorMessage))
                    .font(MyChatTypography.metadata)
                    .foregroundStyle(Color.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .foregroundStyle(MyChatTheme.text)
        .background(MyChatTheme.canvas)
    }

    private func persist() {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await save(value)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

private struct ArtifactsLanding: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var searchText = ""
    @State private var selectedFilter = ArtifactFilter.all
    let openSidebar: () -> Void
    let openArtifact: (ArtifactRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Text("Artifacts").font(MyChatTypography.pageTitleUtility)
                HStack {
                    Button(action: openSidebar) {
                        Image(systemName: "line.3.horizontal")
                            .font(MyChatSystemFont.appFont(size: 16, weight: .medium))
                    }
                    .buttonStyle(MyChatIconButtonStyle())
                    .accessibilityLabel("打开侧边栏")
                    Spacer()
                    Menu {
                        Picker("Filter artifacts", selection: $selectedFilter) {
                            ForEach(ArtifactFilter.allCases) { filter in
                                Text(filter.rawValue).tag(filter)
                            }
                        }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(MyChatSystemFont.appFont(size: 17, weight: .regular))
                            .foregroundStyle(selectedFilter == .all ? MyChatTheme.text : MyChatTheme.thinking)
                    }
                    .buttonStyle(MyChatIconButtonStyle())
                    .accessibilityLabel("Filter artifacts")
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 62)

            if filteredArtifacts.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    if appModel.workspacePhase == .loading {
                        ProgressView()
                    } else {
                        Image(systemName: "square.on.square")
                            .font(MyChatSystemFont.appFont(size: 20, weight: .regular))
                            .frame(width: 48, height: 48)
                            .background(MyChatTheme.selected, in: Circle())
                    }
                    Text(searchText.isEmpty ? "No artifacts yet" : "No matching artifacts")
                        .font(MyChatTypography.navigation)
                    Text(searchText.isEmpty
                        ? (appModel.artifactsError ?? "Artifacts created in MyChat will appear here.")
                        : "Try a different search or filter.")
                        .font(MyChatTypography.metadata)
                        .foregroundStyle(MyChatTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 330)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredArtifacts) { artifact in
                            Button {
                                openArtifact(artifact)
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: artifact.raw.localizedCaseInsensitiveContains("<code")
                                        ? "chevron.left.forwardslash.chevron.right"
                                        : "doc.richtext")
                                        .font(MyChatSystemFont.appFont(size: 18, weight: .medium))
                                        .frame(width: 42, height: 42)
                                        .background(MyChatTheme.selected, in: RoundedRectangle(cornerRadius: 12))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(artifact.title.isEmpty ? "Untitled artifact" : artifact.title)
                                            .font(MyChatTypography.cardTitle)
                                            .lineSpacing(MyChatTypography.utilityLineSpacing)
                                            .lineLimit(1)
                                        Text(artifact.projectID == nil ? "Artifact" : "Project artifact")
                                            .font(MyChatTypography.caption)
                                            .lineSpacing(MyChatTypography.captionLineSpacing)
                                            .foregroundStyle(MyChatTheme.secondaryText)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right")
                                        .font(MyChatSystemFont.appFont(for: .caption1, weight: .semibold))
                                        .foregroundStyle(MyChatTheme.secondaryText)
                                }
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("artifact-record-\(artifact.id)")

                            if artifact.id != filteredArtifacts.last?.id {
                                Divider()
                                    .padding(.leading, 56)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
                .refreshable { await appModel.reloadWorkspaceData() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MyChatTheme.libraryCanvas.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                TextField("Search", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .font(MyChatTypography.navigation)
            .foregroundStyle(MyChatTheme.secondaryText)
            .padding(.horizontal, 14)
            .frame(height: 46)
            .modifier(MyChatFloatingSurface(shape: Capsule(), isInteractive: true))
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
        }
        .task {
            if appModel.workspacePhase == .idle {
                await appModel.reloadWorkspaceData()
            }
            await appModel.recoverHistoricalArtifacts()
        }
    }

    private var filteredArtifacts: [ArtifactRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return appModel.artifacts.filter { artifact in
            let matchesQuery = query.isEmpty
                || artifact.title.localizedCaseInsensitiveContains(query)
                || artifact.raw.localizedCaseInsensitiveContains(query)
            guard matchesQuery else { return false }
            switch selectedFilter {
            case .all: return true
            case .documents:
                return !artifact.raw.localizedCaseInsensitiveContains("<code")
            case .code:
                return artifact.raw.localizedCaseInsensitiveContains("<code")
                    || artifact.raw.localizedCaseInsensitiveContains("<pre")
            }
        }
    }

    private enum ArtifactFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case documents = "Docs"
        case code = "Code"

        var id: String { rawValue }
    }
}

private struct ArtifactLibraryDetail: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let artifact: ArtifactRecord
    @State private var deleteConfirmation = false
    @State private var errorMessage: String?
    @State private var documents: [ChatDocument]?
    @State private var blocks: [ChatArtifactBlock] = []

    var body: some View {
        ZStack {
            MyChatTheme.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                ZStack {
                    Text(artifact.title.isEmpty ? "Artifact" : artifact.title)
                        .font(MyChatSystemFont.appFont(size: 19, weight: .semibold))
                        .lineLimit(1)
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left")
                                .font(MyChatSystemFont.appFont(size: 18, weight: .semibold))
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("退出作品预览")
                        .accessibilityIdentifier("artifact-preview-close")
                        Spacer()
                        Button { deleteConfirmation = true } label: {
                            Image(systemName: "trash")
                                .font(MyChatSystemFont.appFont(size: 17, weight: .medium))
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("删除作品")
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 62)

                if let documents {
                    if documents.count > 1 && documents.count == blocks.count {
                        ConversationFilesSheet(documents: documents, showsHeader: false)
                    } else if let document = documents.first, document.isMarkdown {
                        DocumentTextContent(document: document)
                    } else if blocks.contains(where: { ChatDocument.from($0) == nil }) {
                        ScrollView {
                            VStack(spacing: 18) {
                                ForEach(blocks) { block in
                                    if let document = ChatDocument.from(block) {
                                        GeneratedDocumentCard(document: document)
                                    } else {
                                        InlineArtifactBlockView(artifact: block)
                                            .accessibilityIdentifier("artifact-native-preview-" + block.kind.rawValue)
                                    }
                                }
                            }.padding(16)
                        }
                    } else {
                        ArtifactSandboxView(rawHTML: documents.first?.content ?? artifact.raw, colorScheme: colorScheme)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if let errorMessage {
                    Text(PresentationText.plain(errorMessage))
                        .font(MyChatSystemFont.appFont(for: .subheadline, weight: .regular))
                        .foregroundStyle(Color.red)
                        .padding(16)
                }
            }
        }
        .foregroundStyle(MyChatTheme.text)
        .task(id: artifact.raw) {
            let presentation = await Task.detached(priority: .userInitiated) {
                (ChatArtifactParser.parse(artifact.raw).blocks.filter(\.isComplete),
                 ChatDocument.documents(in: artifact.raw, namespace: artifact.id))
            }.value
            guard !Task.isCancelled else { return }
            blocks = presentation.0
            documents = presentation.1
        }
        .confirmationDialog("Delete this artifact?", isPresented: $deleteConfirmation) {
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        try await appModel.deleteArtifact(artifact)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }
}

private struct CodeLanding: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var newSessionPresented = false
    @State private var selectedSession: CodeSessionRecord?
    @State private var deletionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Code")
                .font(MyChatTypography.pageTitleEditorial)
                .lineSpacing(MyChatTypography.editorialTitleLineSpacing)
                .padding(.horizontal, 20)
                .padding(.top, 8)
            if appModel.codeSessions.isEmpty {
                Spacer()
                VStack(spacing: 20) {
                    if appModel.workspacePhase == .loading {
                        ProgressView()
                            .frame(width: 62, height: 62)
                    } else {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(MyChatSystemFont.appFont(size: 25, weight: .medium))
                            .frame(width: 62, height: 62)
                            .background(MyChatTheme.selected, in: Circle())
                    }
                    Text(PresentationText.plain(appModel.codeError ?? "Code sessions will show up here"))
                        .font(MyChatTypography.cardBody)
                        .lineSpacing(MyChatTypography.utilityLineSpacing)
                        .foregroundStyle(MyChatTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(appModel.codeSessions) { session in
                            HStack(spacing: 0) {
                                Button {
                                    selectedSession = session
                                } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                                            .font(MyChatSystemFont.appFont(size: 17, weight: .medium))
                                            .frame(width: 42, height: 42)
                                            .background(MyChatTheme.selected, in: RoundedRectangle(cornerRadius: 12))
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(session.title)
                                                .font(MyChatTypography.cardTitle)
                                                .lineSpacing(MyChatTypography.utilityLineSpacing)
                                                .lineLimit(1)
                                            Text(session.repository)
                                                .font(MyChatTypography.caption)
                                                .lineSpacing(MyChatTypography.captionLineSpacing)
                                                .foregroundStyle(MyChatTheme.secondaryText)
                                                .lineLimit(1)
                                        }
                                        Spacer(minLength: 8)
                                        Image(systemName: "chevron.right")
                                            .font(MyChatSystemFont.appFont(for: .caption1, weight: .semibold))
                                            .foregroundStyle(MyChatTheme.secondaryText)
                                    }
                                    .padding(.leading, 12)
                                    .padding(.vertical, 12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Menu {
                                    Button(role: .destructive) {
                                        Task {
                                            do {
                                                try await appModel.deleteCodeSession(session)
                                            } catch {
                                                deletionError = error.localizedDescription
                                            }
                                        }
                                    } label: {
                                        Label("Delete session", systemImage: "trash")
                                    }
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .font(MyChatSystemFont.appFont(size: 17, weight: .semibold))
                                        .frame(width: 48, height: 66)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Code 会话操作")
                            }
                            .background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 18)
                }
                .refreshable { await appModel.reloadWorkspaceData() }
            }
            Button {
                newSessionPresented = true
            } label: {
                Text("New session")
                    .font(MyChatSystemFont.appFont(size: 18, weight: .semibold))
                    .foregroundStyle(MyChatTheme.canvas)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(MyChatTheme.text, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if appModel.workspacePhase == .idle {
                await appModel.reloadWorkspaceData()
            }
        }
        .fullScreenCover(isPresented: $newSessionPresented) {
            CodeNewSessionView()
                .environmentObject(appModel)
        }
        .fullScreenCover(item: $selectedSession) { session in
            CodeSessionDetailView(session: session)
                .environmentObject(appModel)
        }
        .alert(
            "Couldn’t delete Code session",
            isPresented: Binding(
                get: { deletionError != nil },
                set: { if !$0 { deletionError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { deletionError = nil }
        } message: {
            Text(PresentationText.plain(deletionError ?? ""))
        }
    }
}

private struct CodeSessionDetailView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    let session: CodeSessionRecord
    let initialTurn: CodeTurnStart?
    @State private var messages: [CodeMessageRecord] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var draft = ""
    @State private var activeAdmission: CodeAdmission?
    @State private var streamedResponseID: UUID?
    @State private var streamedContent = ""
    @State private var steps: [CodeAgentStep] = []
    @State private var memoryChanges: [ChatMemoryEvent] = []
    @State private var plans: [CodePlanAction] = []
    @State private var lastTaskID: UUID?
    @State private var confirmation: CodeConfirmationRequest?
    @State private var isApplying = false
    @State private var receipt: CodeOperationReceipt?
    @State private var consumedInitialTurn = false
    @State private var commandDestination: CodeCommandDestination?
    @State private var presentedSession: CodeSessionRecord?
    @FocusState private var composerFocused: Bool

    init(session: CodeSessionRecord, initialTurn: CodeTurnStart? = nil) {
        self.session = session
        self.initialTurn = initialTurn
    }

    var body: some View {
        ZStack {
            MyChatTheme.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                ZStack {
                    VStack(spacing: 2) {
                        Text(session.title)
                            .font(MyChatSystemFont.appFont(size: 19, weight: .semibold))
                            .lineLimit(1)
                        Text(session.repository)
                            .font(MyChatSystemFont.appFont(for: .caption1, weight: .regular))
                            .foregroundStyle(MyChatTheme.secondaryText)
                            .lineLimit(1)
                    }
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left")
                                .font(MyChatSystemFont.appFont(size: 18, weight: .semibold))
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        if let activeAdmission {
                            Button {
                                Task { await stop(activeAdmission) }
                            } label: {
                                Image(systemName: "stop.fill")
                                    .font(MyChatSystemFont.appFont(size: 14, weight: .bold))
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("停止 Code 任务")
                        }
                        Menu {
                            Button(role: .destructive) {
                                Task {
                                    do {
                                        try await appModel.deleteCodeSession(session)
                                        dismiss()
                                    } catch {
                                        errorMessage = error.localizedDescription
                                    }
                                }
                            } label: {
                                Label("Delete session", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(MyChatSystemFont.appFont(size: 18, weight: .semibold))
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(activeAdmission != nil)
                        .accessibilityLabel("Code 会话操作")
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 66)

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage, messages.isEmpty {
                    VStack(spacing: 14) {
                        Text(PresentationText.plain(errorMessage))
                            .foregroundStyle(MyChatTheme.secondaryText)
                            .multilineTextAlignment(.center)
                        Button("Retry") { Task { await load() } }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(messages) { message in
                                CodeConversationMessage(
                                    role: message.role,
                                    content: content(for: message)
                                )
                            }

                            if !steps.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Label("Agent activity", systemImage: "terminal")
                                        .font(MyChatSystemFont.appFont(for: .caption1, weight: .semibold))
                                        .foregroundStyle(MyChatTheme.secondaryText)
                                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                                        Label(PresentationText.plain(step.label), systemImage: "checkmark.circle")
                                            .font(MyChatSystemFont.appFont(size: 14, design: .monospaced, weight: .regular))
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            ForEach(Array(memoryChanges.enumerated()), id: \.offset) { _, change in
                                HStack(spacing: 8) {
                                    Image(systemName: memoryActivitySymbol(change))
                                        .font(MyChatSystemFont.appFont(size: 14, weight: .regular))
                                    Text(memoryActivityLabel(change))
                                        .lineLimit(2)
                                }
                                .font(MyChatTypography.appStatus)
                                .foregroundStyle(MyChatTheme.secondaryText)
                                .accessibilityElement(children: .combine)
                            }

                            if !plans.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Planned changes")
                                        .font(MyChatSystemFont.appFont(for: .caption1, weight: .semibold))
                                        .foregroundStyle(MyChatTheme.secondaryText)
                                    ForEach(plans) { action in
                                        Label(PresentationText.plain(action.summary), systemImage: planSymbol(action.kind))
                                            .font(MyChatSystemFont.appFont(size: 14, design: .monospaced, weight: .regular))
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            if let receipt {
                                CodeReceiptView(receipt: receipt)
                            }

                            if let errorMessage, !errorMessage.isEmpty {
                                Text(PresentationText.plain(errorMessage))
                                    .font(MyChatSystemFont.appFont(for: .subheadline, weight: .regular))
                                    .foregroundStyle(Color.red)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            if canRequestPublish {
                                Button {
                                    Task { await requestPublish() }
                                } label: {
                                    Label(
                                        isProvisionalRepository ? "Create repository" : "Publish pull request",
                                        systemImage: "arrow.up.right.square"
                                    )
                                    .font(MyChatSystemFont.appFont(size: 16, weight: .semibold))
                                    .frame(maxWidth: .infinity, minHeight: 50)
                                    .background(MyChatTheme.text, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .foregroundStyle(MyChatTheme.canvas)
                                }
                                .buttonStyle(.plain)
                                .disabled(isApplying)
                            }
                        }
                        .padding(16)
                    }
                    .refreshable { await load() }
                }

                HStack(alignment: .bottom, spacing: 10) {
                    Button {
                        composerFocused = false
                        commandDestination = .commands
                    } label: {
                        Image(systemName: "plus")
                            .font(MyChatSystemFont.appFont(size: 20, weight: .regular))
                            .frame(width: 42, height: 42)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 6)
                    .padding(.bottom, 5)
                    .accessibilityLabel("Open Code actions")

                    TextField("Message MyChat Code", text: $draft, axis: .vertical)
                        .lineLimit(1...5)
                        .focused($composerFocused)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 12)
                    Button {
                        Task { await send() }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(MyChatSystemFont.appFont(size: 17, weight: .bold))
                            .foregroundStyle(MyChatTheme.onBrand)
                            .frame(width: 42, height: 42)
                            .background(MyChatTheme.brand, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .opacity(canSend ? 1 : 0.45)
                    .padding(.trailing, 6)
                    .padding(.bottom, 5)
                }
                .background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(MyChatTheme.border.opacity(0.8), lineWidth: 0.7)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }

        }
        .foregroundStyle(MyChatTheme.text)
        .task {
            await load()
            guard !consumedInitialTurn, let initialTurn else { return }
            consumedInitialTurn = true
            prepare(initialTurn)
            await consume(initialTurn.admission)
        }
        .sheet(item: $commandDestination) { destination in
            commandSheet(destination)
                .environmentObject(appModel)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(34)
            .presentationBackground(MyChatTheme.canvas)
        }
        .fullScreenCover(item: $presentedSession) { selected in
            CodeSessionDetailView(session: selected)
                .environmentObject(appModel)
        }
        .sheet(item: $confirmation) { request in
            CodeConfirmationSheet(
                request: request,
                isApplying: isApplying,
                confirm: { Task { await confirmPublish(request) } },
                cancel: { confirmation = nil }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(MyChatTheme.canvas)
        }
    }

    private func load() async {
        isLoading = messages.isEmpty
        do {
            messages = try await appModel.codeMessages(for: session)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && activeAdmission == nil
            && !isApplying
            && appModel.selectedModelCanRunCode
    }

    private var isProvisionalRepository: Bool {
        session.repository.hasPrefix("__mychat_new__/")
    }

    private var canRequestPublish: Bool {
        activeAdmission == nil
            && lastTaskID != nil
            && (!isProvisionalRepository || !plans.isEmpty)
            && receipt == nil
    }

    private func content(for message: CodeMessageRecord) -> String {
        guard let responseID = streamedResponseID,
              message.id.lowercased() == responseID.uuidString.lowercased(),
              !streamedContent.isEmpty else { return message.content }
        return streamedContent
    }

    private func memoryActivityLabel(_ event: ChatMemoryEvent) -> String {
        guard event.ok else {
            if event.reason == "sensitive_consent_required" { return "未保存 · 敏感记忆尚未开启" }
            if event.reason == "prohibited_content" { return "未保存 · 此类信息不能存储" }
            return "记忆更新失败"
        }
        let action: String
        switch event.action {
        case "create": action = "已保存"
        case "update": action = "已更新"
        case "delete": action = "已移除"
        case "duplicate": action = "已经保存"
        default: action = "已更新"
        }
        if event.sensitive == true { return "\(action)敏感记忆" }
        let topic = event.topic?.trimmingCharacters(in: .whitespacesAndNewlines)
        return topic.flatMap { $0.isEmpty ? nil : "\(action)记忆 · \($0)" } ?? "\(action)记忆"
    }

    private func memoryActivitySymbol(_ event: ChatMemoryEvent) -> String {
        guard event.ok else { return "exclamationmark.circle" }
        return event.action == "delete" ? "checkmark.circle" : "brain"
    }

    private func send() async {
        guard canSend else { return }
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        errorMessage = nil
        do {
            let start = try await appModel.startCodeTurn(in: session, prompt: prompt)
            prepare(start)
            await load()
            await consume(start.admission)
        } catch {
            errorMessage = error.localizedDescription
            if draft.isEmpty { draft = prompt }
            await load()
        }
    }

    @ViewBuilder
    private func commandSheet(_ destination: CodeCommandDestination) -> some View {
        switch destination {
        case .commands:
            CodeCommandSheet(
                repository: session.repository,
                close: { commandDestination = nil },
                select: selectCommand
            )
        case .model:
            ModelPickerSheet(codeOnly: true)
        case .effort:
            CodeEffortSheet(close: { commandDestination = nil })
        case .memory:
            CodeMemorySheet(
                repository: session.repository,
                close: { commandDestination = nil }
            )
        case .context:
            CodeContextSheet(
                messages: messages,
                streamedContent: streamedContent,
                close: { commandDestination = nil }
            )
        case .resume:
            CodeResumeSheet(
                repository: session.repository,
                sessions: appModel.codeSessions,
                close: { commandDestination = nil },
                select: openSession
            )
        case .tasks:
            CodeTasksSheet(
                repository: session.repository,
                close: { commandDestination = nil }
            )
        }
    }

    private func selectCommand(_ command: CodeSlashCommand) {
        switch command.command {
        case "/new":
            commandDestination = nil
            Task { await createNewSession() }
        case "/model": commandDestination = .model
        case "/effort": commandDestination = .effort
        case "/memory": commandDestination = .memory
        case "/context": commandDestination = .context
        case "/resume": commandDestination = .resume
        case "/tasks": commandDestination = .tasks
        default:
            commandDestination = nil
        }
    }

    private func createNewSession() async {
        do {
            let repository = isProvisionalRepository ? nil : session.repository
            let record = try await appModel.createCodeSession(
                repository: repository,
                title: "New session"
            )
            presentedSession = record
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openSession(_ record: CodeSessionRecord) {
        commandDestination = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            presentedSession = record
        }
    }

    private func prepare(_ start: CodeTurnStart) {
        activeAdmission = start.admission
        streamedResponseID = start.admission.responseID
        streamedContent = ""
        steps = []
        memoryChanges = []
        plans = []
        receipt = nil
        lastTaskID = start.admission.taskID
        if !messages.contains(where: { $0.id == start.userMessage.id }) {
            messages.append(start.userMessage)
        }
    }

    private func consume(_ admission: CodeAdmission) async {
        do {
            let events = try await appModel.codeEvents(for: admission)
            eventLoop: for try await event in events {
                switch event.payload {
                case let .textDelta(text):
                    streamedContent += text
                case let .snapshot(snapshot):
                    streamedContent = snapshot.content
                case let .agentStep(step):
                    if steps.last != step { steps.append(step) }
                case let .memoryChange(change):
                    if !memoryChanges.contains(change) { memoryChanges.append(change) }
                    Task { await appModel.reloadMemoryData() }
                case let .agentPlan(plan):
                    if !plans.contains(where: { samePlan($0, plan) }) { plans.append(plan) }
                case let .terminal(terminal):
                    streamedContent = terminal.content
                    receipt = terminal.codeReceipt
                    break eventLoop
                case .thinkingDelta, .reasoningSummaryDelta, .toolSearch, .toolActivity, .modelOutputCompleted, .connectorApp:
                    break
                }
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        activeAdmission = nil
        await load()
        if !memoryChanges.isEmpty { await appModel.reloadMemoryData() }
    }

    private func stop(_ admission: CodeAdmission) async {
        do { try await appModel.cancelCodeRun(admission) }
        catch { errorMessage = error.localizedDescription }
    }

    private func requestPublish() async {
        guard let taskID = lastTaskID else { return }
        isApplying = true
        errorMessage = nil
        do {
            let response = try await appModel.requestCodeApply(
                applyCommand(taskID: taskID, confirmation: nil)
            )
            switch response {
            case let .confirmation(request):
                confirmation = request
            case let .accepted(admission):
                activeAdmission = admission
                await consume(admission)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isApplying = false
    }

    private func confirmPublish(_ request: CodeConfirmationRequest) async {
        isApplying = true
        errorMessage = nil
        do {
            let response = try await appModel.requestCodeApply(
                applyCommand(taskID: request.taskID, confirmation: request)
            )
            guard case let .accepted(admission) = response else {
                throw CodeAPIError.invalidResponse
            }
            confirmation = nil
            activeAdmission = admission
            await consume(admission)
        } catch {
            errorMessage = error.localizedDescription
        }
        isApplying = false
    }

    private func applyCommand(
        taskID: UUID,
        confirmation: CodeConfirmationRequest?
    ) -> CodeApplyCommand {
        CodeApplyCommand(
            repository: isProvisionalRepository ? nil : session.repository,
            actions: isProvisionalRepository ? plans : [],
            message: "Publish MyChat Code changes",
            taskID: taskID,
            mode: isProvisionalRepository ? .directPush : .workspacePullRequest,
            confirmationID: confirmation?.confirmationID,
            confirmationToken: confirmation?.confirmationToken
        )
    }

    private func samePlan(_ lhs: CodePlanAction, _ rhs: CodePlanAction) -> Bool {
        lhs.kind == rhs.kind && lhs.name == rhs.name && lhs.path == rhs.path
            && lhs.newContent == rhs.newContent
    }

    private func planSymbol(_ kind: CodePlanAction.Kind) -> String {
        switch kind {
        case .createRepository: return "folder.badge.plus"
        case .writeFile: return "doc.badge.plus"
        case .deleteFile: return "trash"
        case .enablePages: return "globe"
        }
    }
}

private struct CodeConversationMessage: View {
    let role: String
    let content: String

    var body: some View {
        if role == "user" {
            HStack {
                Spacer(minLength: 54)
                Text(content)
                    .font(MyChatSystemFont.appFont(size: 17, weight: .regular))
                    .textSelection(.enabled)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background(
                        MyChatTheme.userBubble,
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                    )
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            Text(content)
                .font(MyChatSystemFont.appFont(size: 17, weight: .regular))
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CodeSlashCommand: Identifiable {
    var id: String { command }
    let command: String
    let description: String
    let symbol: String

    static let all: [CodeSlashCommand] = [
        .init(command: "/new", description: "在当前项目内开启新对话", symbol: "plus.message"),
        .init(command: "/model", description: "打开统一模型列表", symbol: "square.stack.3d.up"),
        .init(command: "/effort", description: "选择当前模型的真实思考深度", symbol: "brain.head.profile"),
        .init(command: "/memory", description: "查看或编辑本仓库记忆", symbol: "memorychip"),
        .init(command: "/context", description: "查看当前上下文用量", symbol: "text.line.first.and.arrowtriangle.forward"),
        .init(command: "/resume", description: "恢复本仓库的历史排查", symbol: "clock.arrow.circlepath"),
        .init(command: "/tasks", description: "查看 Agent 任务列表与状态", symbol: "checklist"),
    ]
}

private enum CodeCommandDestination: String, Identifiable {
    case commands, model, effort, memory, context, resume, tasks
    var id: String { rawValue }
}

private struct CodeCommandSheet: View {
    let repository: String
    let close: () -> Void
    let select: (CodeSlashCommand) -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Code commands", close: close)
            VStack(alignment: .leading, spacing: 5) {
                Text(repository)
                    .font(MyChatSystemFont.appFont(for: .caption1, weight: .regular))
                    .foregroundStyle(MyChatTheme.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(CodeSlashCommand.all) { command in
                        Button {
                            select(command)
                        } label: {
                            HStack(spacing: 13) {
                                Image(systemName: command.symbol)
                                    .font(MyChatSystemFont.appFont(size: 17, weight: .medium))
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(command.command)
                                        .font(MyChatSystemFont.appFont(size: 17, design: .monospaced, weight: .semibold))
                                    Text(command.description)
                                        .font(MyChatSystemFont.appFont(for: .caption1, weight: .regular))
                                        .foregroundStyle(MyChatTheme.secondaryText)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 60)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .foregroundStyle(MyChatTheme.text)
        .background(MyChatTheme.canvas)
    }
}

private struct CodeEffortSheet: View {
    @EnvironmentObject private var appModel: AppModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Thinking depth", close: close)
            if appModel.availableReasoningEfforts.isEmpty {
                ContentUnavailableView(
                    "No thinking depth",
                    systemImage: "brain.head.profile",
                    description: Text("The selected model does not expose adjustable reasoning levels.")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(appModel.availableReasoningEfforts, id: \.self) { effort in
                            Button {
                                appModel.setReasoningEnabled(true)
                                appModel.setReasoningEffort(effort)
                                close()
                            } label: {
                                HStack {
                                    Text(appModel.reasoningEffortLabel(effort))
                                        .font(MyChatSystemFont.appFont(size: 18, weight: .regular))
                                    Spacer()
                                    if effort == appModel.reasoningEffort {
                                        Image(systemName: "checkmark")
                                            .font(MyChatSystemFont.appFont(size: 15, weight: .semibold))
                                    }
                                }
                                .padding(.horizontal, 20)
                                .frame(minHeight: 58)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if effort != appModel.availableReasoningEfforts.last {
                                Divider().padding(.leading, 20)
                            }
                        }
                    }
                    .background(
                        MyChatTheme.raised,
                        in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                    )
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
        }
        .foregroundStyle(MyChatTheme.text)
        .background(MyChatTheme.canvas)
    }
}

private struct CodeMemorySheet: View {
    @EnvironmentObject private var appModel: AppModel
    let repository: String
    let close: () -> Void
    @State private var memories: [CodeMemoryRecord]?
    @State private var draft = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Repository memory", close: close)
            Text(repository)
                .font(MyChatSystemFont.appFont(for: .caption1, weight: .regular))
                .foregroundStyle(MyChatTheme.secondaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 8) {
                    if memories == nil {
                        ProgressView().padding(.top, 32)
                    } else if memories?.isEmpty == true {
                        Text("No repository memories yet")
                            .foregroundStyle(MyChatTheme.secondaryText)
                            .padding(.top, 28)
                    } else {
                        ForEach(memories ?? []) { memory in
                            HStack(alignment: .top, spacing: 10) {
                                Text(memory.content)
                                    .font(MyChatSystemFont.appFont(size: 16, weight: .regular))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button(role: .destructive) {
                                    Task { await delete(memory) }
                                } label: {
                                    Image(systemName: "trash")
                                        .frame(width: 40, height: 40)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Delete memory")
                            }
                            .padding(14)
                            .background(
                                MyChatTheme.raised,
                                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                            )
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }

            if let errorMessage {
                Text(PresentationText.plain(errorMessage))
                    .font(MyChatSystemFont.appFont(for: .caption1, weight: .regular))
                    .foregroundStyle(Color.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 6)
            }

            HStack(spacing: 10) {
                TextField("Add memory", text: $draft, axis: .vertical)
                    .lineLimit(1...3)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 46)
                    .background(
                        MyChatTheme.raised,
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                    )
                Button {
                    Task { await add() }
                } label: {
                    if isSaving {
                        ProgressView().frame(width: 46, height: 46)
                    } else {
                        Image(systemName: "plus")
                            .font(MyChatSystemFont.appFont(size: 18, weight: .semibold))
                            .foregroundStyle(MyChatTheme.onBrand)
                            .frame(width: 46, height: 46)
                            .background(MyChatTheme.brand, in: Circle())
                    }
                }
                .buttonStyle(.plain)
                .disabled(isSaving || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
        }
        .foregroundStyle(MyChatTheme.text)
        .background(MyChatTheme.canvas)
        .task { await load() }
    }

    private func load() async {
        do {
            memories = try await appModel.codeMemories(for: repository)
            errorMessage = nil
        } catch {
            memories = []
            errorMessage = error.localizedDescription
        }
    }

    private func add() async {
        let content = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        isSaving = true
        do {
            let record = try await appModel.createCodeMemory(
                repository: repository,
                content: content
            )
            memories = (memories ?? []) + [record]
            draft = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }

    private func delete(_ memory: CodeMemoryRecord) async {
        let previous = memories ?? []
        memories?.removeAll { $0.id == memory.id }
        do {
            try await appModel.deleteCodeMemory(memory)
            errorMessage = nil
        } catch {
            memories = previous
            errorMessage = error.localizedDescription
        }
    }
}

private struct CodeContextSheet: View {
    @EnvironmentObject private var appModel: AppModel
    let messages: [CodeMessageRecord]
    let streamedContent: String
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Context", close: close)
            VStack(spacing: 18) {
                metric("Messages", value: "\(messages.count)")
                metric("Estimated tokens", value: "\(estimatedTokens.formatted()) / \(limit.formatted())")
                ProgressView(value: Double(min(estimatedTokens, limit)), total: Double(limit))
                    .tint(MyChatTheme.brand)
                Text("Estimated from the current Code conversation")
                    .font(MyChatSystemFont.appFont(for: .caption1, weight: .regular))
                    .foregroundStyle(MyChatTheme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)
            .background(
                MyChatTheme.raised,
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .padding(.horizontal, 20)
            Spacer(minLength: 12)
        }
        .foregroundStyle(MyChatTheme.text)
        .background(MyChatTheme.canvas)
    }

    private var estimatedTokens: Int {
        let characters = messages.reduce(0) { $0 + $1.content.count } + streamedContent.count
        return max(0, Int((Double(characters) / 3).rounded()))
    }

    private var limit: Int {
        max(appModel.selectedModel?.contextLength ?? 128_000, 1)
    }

    private func metric(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(MyChatTheme.secondaryText)
            Spacer()
                        Text(value).font(MyChatSystemFont.appFont(for: .body, design: .monospaced, weight: .regular))
        }
    }
}

private struct CodeResumeSheet: View {
    let repository: String
    let sessions: [CodeSessionRecord]
    let close: () -> Void
    let select: (CodeSessionRecord) -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Resume", close: close)
            ScrollView {
                LazyVStack(spacing: 8) {
                    if matchingSessions.isEmpty {
                        Text("No previous sessions in this repository")
                            .foregroundStyle(MyChatTheme.secondaryText)
                            .padding(.top, 30)
                    } else {
                        ForEach(matchingSessions) { session in
                            Button { select(session) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .frame(width: 28)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(session.title)
                                            .font(MyChatSystemFont.appFont(size: 16, weight: .medium))
                                            .lineLimit(1)
                                        Text(session.repository)
                                            .font(MyChatSystemFont.appFont(for: .caption1, weight: .regular))
                                            .foregroundStyle(MyChatTheme.secondaryText)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(MyChatSystemFont.appFont(for: .caption1, weight: .semibold))
                                        .foregroundStyle(MyChatTheme.secondaryText)
                                }
                                .padding(.horizontal, 14)
                                .frame(minHeight: 58)
                                .background(
                                    MyChatTheme.raised,
                                    in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .foregroundStyle(MyChatTheme.text)
        .background(MyChatTheme.canvas)
    }

    private var matchingSessions: [CodeSessionRecord] {
        sessions.filter { $0.repository == repository }
    }
}

private struct CodeTasksSheet: View {
    @EnvironmentObject private var appModel: AppModel
    let repository: String
    let close: () -> Void
    @State private var tasks: [CodeTaskRecord]?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Agent tasks", close: close)
            ScrollView {
                LazyVStack(spacing: 8) {
                    if tasks == nil {
                        ProgressView().padding(.top, 32)
                    } else if let errorMessage {
                        Text(PresentationText.plain(errorMessage))
                            .foregroundStyle(Color.red)
                            .padding(.top, 24)
                    } else if tasks?.isEmpty == true {
                        Text("No Agent tasks in this repository")
                            .foregroundStyle(MyChatTheme.secondaryText)
                            .padding(.top, 30)
                    } else {
                        ForEach(tasks ?? []) { task in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(statusColor(task.status))
                                        .frame(width: 8, height: 8)
                                    Text(PresentationText.plain(task.status.replacingOccurrences(of: "_", with: " ").capitalized))
                                        .font(MyChatSystemFont.appFont(for: .caption1, weight: .semibold))
                                    Spacer()
                                }
                                Text(task.goal)
                                    .font(MyChatSystemFont.appFont(size: 16, weight: .regular))
                                    .lineLimit(3)
                                if let error = task.error, !error.isEmpty {
                                    Text(PresentationText.plain(error))
                                        .font(MyChatSystemFont.appFont(for: .caption1, weight: .regular))
                                        .foregroundStyle(Color.red)
                                        .lineLimit(2)
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                MyChatTheme.raised,
                                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                            )
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .foregroundStyle(MyChatTheme.text)
        .background(MyChatTheme.canvas)
        .task { await load() }
    }

    private func load() async {
        do {
            tasks = try await appModel.codeTasks(for: repository)
            errorMessage = nil
        } catch {
            tasks = []
            errorMessage = error.localizedDescription
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "completed": return .green
        case "failed", "cancelled": return .red
        case "waiting_for_user": return MyChatTheme.brand
        default: return MyChatTheme.secondaryText
        }
    }
}

private struct CodeNewSessionView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var composerFocused: Bool
    @State private var draft = ""
    @State private var repositoryPickerVisible = false
    @State private var modelPickerVisible = false
    @State private var selectedRepository: GitHubRepositoryRecord?
    @State private var createNewRepository = false
    @State private var isStarting = false
    @State private var errorMessage: String?
    @State private var startedSession: CodeSessionStart?

    var body: some View {
        if let startedSession {
            CodeSessionDetailView(
                session: startedSession.session,
                initialTurn: startedSession.turn
            )
            .environmentObject(appModel)
        } else {
            ZStack {
            MyChatTheme.canvas.ignoresSafeArea()
            CodeSparkleField()
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                ZStack {
                    Text("New session")
                        .font(MyChatSystemFont.appFont(size: 29, design: .default, weight: .semibold))
                    HStack {
                        Button {
                            dismiss()
                        } label: {
                            Label("Code", systemImage: "chevron.left")
                                .font(MyChatSystemFont.appFont(for: .body, weight: .regular))
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        Spacer()
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 60)

                Spacer()

                VStack(spacing: 0) {
                    Text("let’s git together and code")
                        .font(MyChatSystemFont.appFont(size: 19, design: .monospaced, weight: .regular))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                Spacer()

                VStack(alignment: .leading, spacing: 8) {
                    TextField("Code anything…", text: $draft, axis: .vertical)
                        .font(MyChatSystemFont.appFont(size: 20, weight: .regular))
                        .lineLimit(1...5)
                        .focused($composerFocused)
                        .padding(.horizontal, 18)
                        .padding(.top, 18)

                    HStack(spacing: 10) {
                        Button {
                            repositoryPickerVisible = true
                        } label: {
                            Text(repositoryLabel)
                                .font(MyChatSystemFont.appFont(for: .subheadline, weight: .medium))
                                .padding(.horizontal, 13)
                                .frame(minHeight: 36)
                                .background(MyChatTheme.selected, in: Capsule())
                        }
                        .buttonStyle(.plain)

                        Button {
                            modelPickerVisible = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "cpu")
                                    .font(MyChatSystemFont.appFont(size: 13, weight: .semibold))
                                Text(appModel.selectedModel?.name ?? "选择模型")
                                    .font(MyChatSystemFont.appFont(for: .subheadline, weight: .medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .padding(.horizontal, 12)
                            .frame(maxWidth: 126, minHeight: 36)
                            .background(MyChatTheme.selected, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("code-model-selector")

                        Spacer()

                        Image(systemName: "icloud")
                            .font(MyChatSystemFont.appFont(for: .title3, weight: .regular))
                            .frame(width: 44, height: 44)

                        Button {
                            Task { await startSession() }
                        } label: {
                            if isStarting {
                                ProgressView()
                                    .tint(MyChatTheme.onBrand)
                                    .frame(width: 46, height: 46)
                                    .background(MyChatTheme.brand, in: Circle())
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(MyChatSystemFont.appFont(for: .title3, weight: .semibold))
                                    .foregroundStyle(MyChatTheme.onBrand)
                                    .frame(width: 46, height: 46)
                                    .background(MyChatTheme.brand, in: Circle())
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!canStart)
                        .opacity(canStart ? 1 : 0.45)
                        .accessibilityHint("选择仓库或新建仓库后发送")
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 9)
                }
                .background(MyChatTheme.raised)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(MyChatTheme.border.opacity(0.82), lineWidth: 0.7)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

                if let errorMessage {
                    Text(PresentationText.plain(errorMessage))
                        .font(MyChatSystemFont.appFont(for: .subheadline, weight: .regular))
                        .foregroundStyle(Color.red)
                        .padding(.horizontal, 18)
                        .padding(.bottom, 8)
                }
            }
        }
        .foregroundStyle(MyChatTheme.text)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                composerFocused = true
            }
        }
        .sheet(isPresented: $repositoryPickerVisible) {
            CodeRepositoryPickerView { repository in
                selectedRepository = repository
                createNewRepository = repository == nil
                repositoryPickerVisible = false
            }
                .environmentObject(appModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(MyChatTheme.canvas)
        }
        .sheet(isPresented: $modelPickerVisible) {
            ModelPickerSheet(codeOnly: true)
                .environmentObject(appModel)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(MyChatTheme.canvas)
        }
        }
    }

    private var repositoryLabel: String {
        if createNewRepository { return "New repository" }
        return selectedRepository?.fullName ?? "Choose repository"
    }

    private var canStart: Bool {
        !isStarting
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (selectedRepository != nil || createNewRepository)
            && appModel.selectedModelCanRunCode
    }

    private func startSession() async {
        guard canStart else { return }
        isStarting = true
        errorMessage = nil
        do {
            startedSession = try await appModel.startCodeSession(
                repository: createNewRepository ? nil : selectedRepository?.fullName,
                prompt: draft
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        isStarting = false
    }
}

private struct CodeSparkleField: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                sparkle(size: 12)
                    .position(x: proxy.size.width * 0.16, y: proxy.size.height * 0.18)
                sparkle(size: 10)
                    .position(x: proxy.size.width * 0.70, y: proxy.size.height * 0.10)
                sparkle(size: 11)
                    .position(x: proxy.size.width * 0.91, y: proxy.size.height * 0.29)
                sparkle(size: 9)
                    .position(x: proxy.size.width * 0.29, y: proxy.size.height * 0.53)
            }
        }
    }

    private func sparkle(size: CGFloat) -> some View {
        Image(systemName: "asterisk")
            .font(MyChatSystemFont.appFont(size: size, weight: .bold))
            .foregroundStyle(MyChatTheme.brand.opacity(0.78))
    }
}

private struct CodeRepositoryPickerView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var authenticator = GitHubWebAuthenticator()
    @State private var searchText = ""
    @State private var repositories: [GitHubRepositoryRecord] = []
    @State private var isLoading = true
    @State private var isConnecting = false
    @State private var connection: GitHubConnectionStatus?
    @State private var errorMessage: String?
    let select: (GitHubRepositoryRecord?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Choose repository", close: { dismiss() })

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(MyChatTheme.secondaryText)
                TextField("Search repositories", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 15)
            .frame(minHeight: 48)
            .background(MyChatTheme.selected, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .padding(.horizontal, 18)

            Button {
                select(nil)
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: "folder.badge.plus")
                        .frame(width: 38, height: 38)
                        .background(MyChatTheme.selected, in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Create a new repository")
                            .font(MyChatSystemFont.appFont(size: 16, weight: .semibold))
                        Text("MyChat Code will prepare the files first")
                            .font(MyChatSystemFont.appFont(for: .caption1, weight: .regular))
                            .foregroundStyle(MyChatTheme.secondaryText)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(MyChatSystemFont.appFont(for: .caption1, weight: .semibold))
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18)
            .padding(.top, 14)

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if connection?.connected != true {
                VStack(spacing: 12) {
                    Image(systemName: "link.badge.plus")
                        .font(MyChatSystemFont.appFont(size: 24, weight: .medium))
                    Text("GitHub is not 个已连接")
                        .font(MyChatSystemFont.appFont(size: 18, weight: .semibold))
                    Text(PresentationText.plain(errorMessage ?? "Connect GitHub in MyChat Web, then refresh this page."))
                        .font(MyChatSystemFont.appFont(for: .subheadline, weight: .regular))
                        .foregroundStyle(MyChatTheme.secondaryText)
                        .multilineTextAlignment(.center)
                    Button {
                        Task { await connectGitHub() }
                    } label: {
                        if isConnecting {
                            ProgressView()
                                .frame(minWidth: 120)
                        } else {
                            Text("Connect GitHub")
                                .frame(minWidth: 120)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isConnecting)
                    Button("Refresh") { Task { await load() } }
                        .buttonStyle(.bordered)
                }
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredRepositories.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(MyChatSystemFont.appFont(size: 24, weight: .medium))
                    Text(searchText.isEmpty ? "No repositories yet" : "No matching repositories")
                        .font(MyChatSystemFont.appFont(size: 18, weight: .semibold))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredRepositories) { repository in
                            Button {
                                select(repository)
                            } label: {
                                HStack(spacing: 13) {
                                    Image(systemName: repository.isPrivate ? "lock" : "folder")
                                        .frame(width: 38, height: 38)
                                        .background(MyChatTheme.selected, in: RoundedRectangle(cornerRadius: 11))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(repository.fullName)
                                            .font(MyChatSystemFont.appFont(size: 16, weight: .semibold))
                                            .lineLimit(1)
                                        if !repository.description.isEmpty {
                                            Text(repository.description)
                                                .font(MyChatSystemFont.appFont(for: .caption1, weight: .regular))
                                                .foregroundStyle(MyChatTheme.secondaryText)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(11)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(MyChatTheme.text)
        .background(MyChatTheme.canvas)
        .task { await load() }
    }

    private var filteredRepositories: [GitHubRepositoryRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return repositories }
        return repositories.filter {
            $0.fullName.localizedCaseInsensitiveContains(query)
                || $0.description.localizedCaseInsensitiveContains(query)
        }
    }

    private func load() async {
        isLoading = true
        do {
            let status = try await appModel.githubConnectionStatus()
            connection = status
            repositories = status.connected ? try await appModel.githubRepositories() : []
            errorMessage = nil
        } catch {
            connection = GitHubConnectionStatus(connected: false, login: nil)
            repositories = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func connectGitHub() async {
        guard !isConnecting else { return }
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        do {
            let authorizationURL = try await appModel.githubAuthorizationURL()
            let callbackURL = try await authenticator.authenticate(using: authorizationURL)
            try GitHubWebAuthenticator.validateConnectedCallback(callbackURL)
            await load()
        } catch let error as ASWebAuthenticationSessionError
            where error.code == .canceledLogin {
            errorMessage = nil
        } catch {
            connection = GitHubConnectionStatus(connected: false, login: nil)
            repositories = []
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
private final class GitHubWebAuthenticator: NSObject, ObservableObject,
    ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func authenticate(using url: URL) async throws -> URL {
        guard session == nil else { throw GitHubWebAuthenticationError.alreadyRunning }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: "mychat"
            ) { [weak self] callbackURL, error in
                Task { @MainActor in
                    self?.session = nil
                    if let callbackURL {
                        continuation.resume(returning: callbackURL)
                    } else {
                        continuation.resume(
                            throwing: error ?? GitHubWebAuthenticationError.invalidCallback
                        )
                    }
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            guard session.start() else {
                self.session = nil
                continuation.resume(throwing: GitHubWebAuthenticationError.unableToStart)
                return
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let keyWindow = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return keyWindow
        }
        if let scene = scenes.first {
            return UIWindow(windowScene: scene)
        }
        return UIWindow(frame: .zero)
    }

    static func validateConnectedCallback(_ url: URL) throws {
        guard url.scheme?.lowercased() == "mychat",
              url.host?.lowercased() == "oauth",
              url.path == "/github",
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.filter({ $0.name == "status" }).count == 1,
              !items.contains(where: { $0.name.localizedCaseInsensitiveContains("token") }) else {
            throw GitHubWebAuthenticationError.invalidCallback
        }
        guard items.first(where: { $0.name == "status" })?.value == "connected" else {
            throw GitHubWebAuthenticationError.connectionFailed
        }
    }
}

private enum GitHubWebAuthenticationError: LocalizedError {
    case alreadyRunning
    case unableToStart
    case invalidCallback
    case connectionFailed

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "GitHub 授权正在进行"
        case .unableToStart:
            return "无法打开 GitHub 授权页面"
        case .invalidCallback:
            return "GitHub 返回了无效的授权结果"
        case .connectionFailed:
            return "GitHub 授权未完成，请重试"
        }
    }
}

private struct CodeConfirmationSheet: View {
    let request: CodeConfirmationRequest
    let isApplying: Bool
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(request.risk.title)
                    .font(MyChatSystemFont.appFont(size: 22, weight: .semibold))
                Spacer()
                Button(action: cancel) {
                    Image(systemName: "xmark")
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.plain)
            }
            Text(request.risk.reason)
                .font(MyChatSystemFont.appFont(size: 16, weight: .regular))
                .foregroundStyle(MyChatTheme.secondaryText)

            if !request.risk.files.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Files")
                        .font(MyChatSystemFont.appFont(for: .caption1, weight: .semibold))
                        .foregroundStyle(MyChatTheme.secondaryText)
                    ForEach(request.risk.files.prefix(12), id: \.self) { file in
                        Label(file, systemImage: "doc")
                            .font(MyChatSystemFont.appFont(size: 14, design: .monospaced, weight: .regular))
                    }
                }
            }

            Spacer()
            Button(action: confirm) {
                Group {
                    if isApplying { ProgressView().tint(MyChatTheme.canvas) }
                    else { Text("Confirm and publish") }
                }
                .font(MyChatSystemFont.appFont(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 52)
                .foregroundStyle(MyChatTheme.canvas)
                .background(MyChatTheme.text, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isApplying)
        }
        .padding(20)
        .foregroundStyle(MyChatTheme.text)
        .background(MyChatTheme.canvas)
    }
}

private struct CodeReceiptView: View {
    let receipt: CodeOperationReceipt

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Published", systemImage: "checkmark.circle.fill")
                .font(MyChatSystemFont.appFont(size: 17, weight: .semibold))
                .foregroundStyle(Color.green)
            if let repository = receipt.repository {
                Text(repository)
                    .font(MyChatSystemFont.appFont(size: 15, design: .monospaced, weight: .regular))
            }
            if let repositoryURL = receipt.repositoryURL {
                Link("Open repository", destination: repositoryURL)
            }
            if let pullRequestURL = receipt.pullRequestURL {
                Link("Open pull request", destination: pullRequestURL)
            }
            if let pagesURL = receipt.pagesURL {
                Link("Open website", destination: pagesURL)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ModelPickerSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    let codeOnly: Bool

    init(codeOnly: Bool = false) {
        self.codeOnly = codeOnly
    }

    @ViewBuilder var body: some View {
        if codeOnly { legacyBody } else { ChatModelSelectionSheet() }
    }

    private var legacyBody: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Select model", close: { dismiss() })
            Group {
                if !appModel.models.isEmpty {
                    modelCatalogList
                } else {
                    switch appModel.catalogPhase {
                    case .idle, .loading:
                    ProgressView("正在载入模型")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case let .failed(message):
                        ContentUnavailableView {
                            Label("模型目录不可用", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text(PresentationText.plain(message))
                        } actions: {
                            Button("重试") { Task { await appModel.reloadModels() } }
                        }
                    case .loaded:
                        ContentUnavailableView("没有可用模型", systemImage: "cpu")
                    }
                }
            }
        }
        .foregroundStyle(MyChatTheme.text)
        .background(MyChatTheme.canvas)
    }

    private var modelCatalogList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(groupedModels, id: \.provider) { group in
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(spacing: 9) {
                                        if group.provider == "自定义模型" {
                                            Image(systemName: "network")
                                                .font(MyChatSystemFont.appFont(size: 14, weight: .regular))
                                        } else {
                                        ProviderBadge(
                                            provider: group.provider,
                                            modelID: group.models.first?.id ?? "",
                                            size: 16
                                        )
                                        }
                                        Text(group.provider)
                                            .font(MyChatSystemFont.appFont(size: 14, weight: .regular))
                                    }
                                    .foregroundStyle(MyChatTheme.secondaryText)
                                    .padding(.horizontal, 4)

                                    VStack(spacing: 0) {
                                        if group.models.isEmpty {
                                            Text("可在设置中添加自定义 API 与 URL")
                                                .font(MyChatSystemFont.appFont(for: .footnote, weight: .regular))
                                                .foregroundStyle(MyChatTheme.secondaryText)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .padding(.vertical, 16)
                                        }
                                        ForEach(group.models) { model in
                                    Button {
                                        appModel.selectModel(model)
                                        dismiss()
                                    } label: {
                                        ModelRow(model: model, selected: model.id == appModel.selectedModelID)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!model.isSelectable)

                                            if model.id != group.models.last?.id {
                                                Divider()
                                                    .padding(.horizontal, 4)
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 18)
                                    .background(
                                        MyChatTheme.raised,
                                        in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    )
                                }
                            }

                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 10)
                        .padding(.bottom, 32)
                    }
    }

    private var groupedModels: [(provider: String, models: [ModelCatalogItem])] {
        let candidates = appModel.models.filter { model in
            !codeOnly || (model.outputKind == .chat && (model.endpointID != nil || model.tools))
        }
        var seenModelIDs = Set<String>()
        let availableModels = candidates.filter { seenModelIDs.insert($0.id).inserted }
        let groups = Dictionary(
            grouping: availableModels.filter { $0.endpointID == nil },
            by: \.provider
        )
        let builtInGroups = groups.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { provider in
                (
                    provider: provider,
                    models: groups[provider, default: []].sorted {
                        if $0.flagship != $1.flagship { return $0.flagship && !$1.flagship }
                        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                )
            }
        let customModels = availableModels.filter { $0.endpointID != nil }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return [(provider: "自定义模型", models: customModels)] + builtInGroups
    }
}


private struct ChatModelSelectionSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var path: [Page] = []
    @State private var detent: PresentationDetent = .fraction(0.63)
    private enum Page: Hashable { case models, more, effort }
    private let selectionColor = Color(red: 95.0 / 255, green: 157.0 / 255, blue: 221.0 / 255)
    private var primary: [ModelCatalogItem] {
        let candidates = appModel.models.filter { $0.outputKind == .chat && $0.endpointID == nil }
        return ["fable", "opus", "sonnet", "haiku"].compactMap { family in
            candidates.filter { ($0.name + " " + $0.id).lowercased().contains(family) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedDescending }.first
        }
    }
    private var others: [ModelCatalogItem] {
        let ids = Set(primary.map(\.id))
        var seen = Set<String>()
        return appModel.models.filter { !ids.contains($0.id) && seen.insert($0.id).inserted }
    }
    var body: some View {
        NavigationStack(path: $path) {
            pageBody(.models)
                .navigationDestination(for: Page.self) { page in pageBody(page) }
        }
        .presentationDetents([.fraction(0.56), .fraction(0.63), .large], selection: $detent)
        .onChange(of: path) { _, pages in
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.32)) {
                detent = pages.isEmpty ? .fraction(0.63) : .fraction(0.56)
            }
        }
    }
    private func pageBody(_ page: Page) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Text(page == .effort ? "Effort" : page == .more ? "More models" : "Select model")
                    .font(MyChatTypography.pageTitleUtility)
                HStack {
                    Button {
                        HapticFeedback.impact()
                        if page == .models { dismiss() } else { path.removeLast() }
                    } label: {
                        Image(systemName: page == .models ? "xmark" : "chevron.left")
                    }.buttonStyle(MyChatIconButtonStyle(size: 42)).accessibilityLabel(page == .models ? "关闭" : "Back")
                    Spacer()
                }
            }.padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if page == .effort { effortRows }
                    else if page == .more {
                        let custom = others.filter { $0.endpointID != nil }
                        if !custom.isEmpty {
                            Text("Custom models").font(MyChatTypography.metadata).foregroundStyle(MyChatTheme.secondaryText).padding(.leading, 18)
                            modelRows(custom)
                        }
                        let builtIn = others.filter { $0.endpointID == nil }
                        if !builtIn.isEmpty { modelRows(builtIn) }
                        if others.isEmpty { Text("No more models").foregroundStyle(MyChatTheme.secondaryText).padding(18) }
                    } else {
                        if !primary.isEmpty { modelRows(primary) }
                        if appModel.models.isEmpty {
                            if appModel.catalogPhase == .loading { ProgressView().frame(maxWidth: .infinity).padding(30) }
                            else { Button("Retry") { Task { await appModel.reloadModels() } }.padding(18) }
                        }
                        if appModel.selectedModelSupportsReasoning {
                            Button { HapticFeedback.impact(); path.append(.effort) } label: {
                                NativeSettingsRow(title: "Effort", icon: "", detail: appModel.reasoningEnabled ? effortLabel(appModel.reasoningEffort) : "Off")
                            }.buttonStyle(ModelSelectionPressStyle()).background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 22))
                                .accessibilityIdentifier("model.effort")
                        }
                        Button { HapticFeedback.impact(); path.append(.more) } label: {
                            NativeSettingsRow(title: "More models", icon: "")
                        }.buttonStyle(ModelSelectionPressStyle()).background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 22))
                            .accessibilityIdentifier("model.more")
                    }
                }.padding(.horizontal, 26).padding(.bottom, 28)
            }.scrollIndicators(.hidden)
        }.foregroundStyle(MyChatTheme.text).background(MyChatTheme.canvas)
            .toolbar(.hidden, for: .navigationBar)
    }
    private func modelRows(_ models: [ModelCatalogItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(models) { model in
                Button { HapticFeedback.impact(); appModel.selectModel(model); dismiss() } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(model.chatDisplayName).font(MyChatTypography.navigation)
                            Text(description(model)).font(MyChatTypography.metadata).foregroundStyle(MyChatTheme.secondaryText)
                        }
                        Spacer()
                        if model.id == appModel.selectedModelID { Image(systemName: "checkmark").foregroundStyle(selectionColor).font(.system(size: 20, weight: .medium)) }
                    }.frame(minHeight: 68).contentShape(Rectangle())
                }.buttonStyle(ModelSelectionPressStyle()).disabled(!model.isSelectable).opacity(model.isSelectable ? 1 : 0.5)
                if model.id != models.last?.id { Divider() }
            }
        }.padding(.horizontal, 18).background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 22))
    }
    private func description(_ model: ModelCatalogItem) -> String {
        let name = (model.name + model.id).lowercased()
        if name.contains("fable") { return "For your toughest challenges" }
        if name.contains("opus") { return "For complex work and everyday tasks" }
        if name.contains("sonnet") { return "Most efficient for simpler tasks" }
        if name.contains("haiku") { return "Fastest for quick answers" }
        return model.provider
    }
    private func effortLabel(_ value: String) -> String { value == "xhigh" ? "Extra" : appModel.reasoningEffortLabel(value) }
    private var orderedEfforts: [String] {
        let order = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
        return (appModel.selectedModel?.reasoningEfforts ?? []).filter { $0 != "none" }
            .sorted { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }
    }
    private var effortRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                ForEach(orderedEfforts, id: \.self) { value in
                    Button {
                        HapticFeedback.impact()
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
                            if value == "none" { appModel.setReasoningEnabled(false) } else { appModel.setReasoningEffort(value) }
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Text(effortLabel(value)).font(MyChatTypography.navigation)
                            if value == "medium" || (!orderedEfforts.contains("medium") && value == appModel.selectedModel?.defaultReasoningEffort) {
                                Text("Recommended").font(MyChatTypography.caption).foregroundStyle(MyChatTheme.secondaryText)
                                    .padding(.horizontal, 7).padding(.vertical, 3).background(MyChatTheme.selected, in: Capsule())
                            }
                            Spacer()
                            if value == appModel.reasoningEffort {
                                Image(systemName: "checkmark").foregroundStyle(selectionColor).font(.system(size: 20, weight: .medium))
                                    .transition(.scale(scale: 0.75).combined(with: .opacity))
                            }
                        }.frame(minHeight: 49).contentShape(Rectangle())
                    }.buttonStyle(ModelSelectionPressStyle()).accessibilityIdentifier("effort." + value)
                    if value != orderedEfforts.last { Divider() }
                }
            }.padding(.horizontal, 18).background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 22))
            Text("Higher effort takes longer.").font(MyChatTypography.metadata).foregroundStyle(MyChatTheme.secondaryText).padding(.horizontal, 18)
        }
    }
}

private struct ModelSelectionPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .smooth(duration: 0.18), value: configuration.isPressed)
    }
}

private struct SheetHeader: View {
    let title: String
    let close: () -> Void

    var body: some View {
        ZStack {
            Text(title)
                .font(MyChatTypography.pageTitleUtility)
                .lineSpacing(MyChatTypography.utilityTitleLineSpacing)

            HStack {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(MyChatSystemFont.appFont(size: 16, weight: .regular))
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .modifier(MyChatFloatingSurface(shape: Circle(), isInteractive: true))
                .accessibilityLabel("关闭")

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(minHeight: 58)
    }
}

private struct ModelRow: View {
    let model: ModelCatalogItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(model.name)
                        .font(MyChatTypography.navigation)
                        .lineSpacing(MyChatTypography.utilityLineSpacing)
                        .lineLimit(1)
                    if model.flagship {
                        Text("旗舰")
                            .font(MyChatTypography.chip)
                            .lineSpacing(MyChatTypography.captionLineSpacing)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(MyChatTheme.selected, in: Capsule())
                    }
                }
                if !capabilityText.isEmpty {
                    Text(capabilityText)
                        .font(MyChatTypography.metadata)
                        .lineSpacing(MyChatTypography.metadataLineSpacing)
                        .foregroundStyle(MyChatTheme.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark")
                    .font(MyChatSystemFont.appFont(size: 17, weight: .medium))
                    .foregroundStyle(MyChatTheme.brand)
                    .frame(width: 24, height: 24)
            } else if !model.isSelectable {
                Image(systemName: "lock")
                    .foregroundStyle(MyChatTheme.secondaryText)
            }
        }
        .frame(minHeight: 66)
        .contentShape(Rectangle())
        .opacity(model.isSelectable ? 1 : 0.58)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(model.name)，\(model.provider)")
        .accessibilityValue(selected ? "已选择" : model.isSelectable ? "" : "不可用")
    }

    private var capabilityText: String {
        [model.vision ? "视觉" : nil, model.tools ? "工具" : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

private struct ModelPriceIndicators: View {
    let model: ModelCatalogItem

    var body: some View {
        HStack(spacing: 7) {
            Label(price(model.promptPrice), systemImage: "arrow.down")
            Label(price(model.completionPrice), systemImage: "arrow.up")
        }
        .font(MyChatTypography.caption)
        .lineSpacing(MyChatTypography.captionLineSpacing)
        .foregroundStyle(MyChatTheme.secondaryText)
        .fixedSize()
        .accessibilityLabel("输入价格 \(price(model.promptPrice))，输出价格 \(price(model.completionPrice))")
    }

    private func price(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...4)))
    }
}

struct ProviderBadge: View {
    let provider: String
    let modelID: String
    let size: CGFloat

    private var identity: ProviderIdentity {
        ProviderIdentity.resolve(provider: provider, modelID: modelID)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(MyChatTheme.raised)
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .stroke(MyChatTheme.border.opacity(0.82), lineWidth: 0.7)
                }

            badgeGlyph
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var badgeGlyph: some View {
        if let logo = identity.logo, let image = logo.image {
            Image(uiImage: image)
                .renderingMode(logo.monochrome ? .template : .original)
                .resizable()
                .scaledToFit()
                .foregroundStyle(MyChatTheme.text)
                .frame(width: size * 0.58, height: size * 0.58)
        } else {
            Text(identity.fallbackGlyph)
                .font(MyChatSystemFont.appFont(size: size * 0.3, design: .rounded, weight: .bold))
                .foregroundStyle(MyChatTheme.secondaryText)
        }
    }
}

private struct ProviderIdentity {
    struct Logo {
        let resourceName: String
        let monochrome: Bool

        var image: UIImage? {
            guard let url = Bundle.main.url(
                forResource: resourceName,
                withExtension: "png"
            ) else { return nil }
            return UIImage(contentsOfFile: url.path)
        }
    }

    enum Kind {
        case openAI, anthropic, google, xAI, deepSeek, moonshot, qwen, zhipu
        case miniMax, byteDance, meta, mistral, cohere, tencent, baidu, openRouter, other
    }

    let kind: Kind
    let fallbackGlyph: String

    var logo: Logo? {
        switch kind {
        case .anthropic: return Logo(resourceName: "provider-claude", monochrome: false)
        case .deepSeek: return Logo(resourceName: "provider-deepseek", monochrome: false)
        case .google: return Logo(resourceName: "provider-gemini", monochrome: false)
        case .miniMax: return Logo(resourceName: "provider-minimax", monochrome: false)
        case .openAI: return Logo(resourceName: "provider-openai", monochrome: true)
        case .moonshot: return Logo(resourceName: "provider-kimi", monochrome: true)
        case .xAI: return Logo(resourceName: "provider-grok", monochrome: true)
        case .zhipu: return Logo(resourceName: "provider-zai", monochrome: true)
        default: return nil
        }
    }

    static func resolve(provider: String, modelID: String) -> ProviderIdentity {
        let source = "\(provider) \(modelID)"
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "/", with: "")

        let mapping: [(Kind, [String])] = [
            (.anthropic, ["anthropic", "claude"]),
            (.openAI, ["openai", "azureopenai", "gpt"]),
            (.google, ["google", "gemini"]),
            (.xAI, ["xai", "grok"]),
            (.deepSeek, ["deepseek"]),
            (.moonshot, ["moonshot", "kimi"]),
            (.qwen, ["qwen", "alibaba", "dashscope"]),
            (.zhipu, ["zhipu", "bigmodel", "glm"]),
            (.miniMax, ["minimax"]),
            (.byteDance, ["bytedance", "doubao", "volcengine"]),
            (.meta, ["meta", "llama"]),
            (.mistral, ["mistral", "mixtral"]),
            (.cohere, ["cohere", "command"]),
            (.tencent, ["tencent", "hunyuan"]),
            (.baidu, ["baidu", "ernie", "wenxin"]),
            (.openRouter, ["openrouter"]),
        ]

        if let match = mapping.first(where: { pair in
            pair.1.contains(where: source.contains)
        }) {
            return ProviderIdentity(kind: match.0, fallbackGlyph: "")
        }

        let glyph = provider
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .compactMap(\.first)
            .prefix(2)
            .map { String($0).uppercased() }
            .joined()
        return ProviderIdentity(kind: .other, fallbackGlyph: glyph.isEmpty ? "AI" : glyph)
    }
}

private struct ToolToggleRow: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool
    var disabled = false

    var body: some View {
        Toggle(isOn: $isOn) {
            Label {
                Text(title)
                    .font(MyChatTypography.navigation)
                    .lineSpacing(MyChatTypography.utilityLineSpacing)
            } icon: {
                Image(systemName: symbol)
                    .font(MyChatSystemFont.appFont(size: 20, weight: .regular))
                    .frame(width: 28)
            }
        }
        .tint(MyChatTheme.accent)
        .frame(minHeight: 62)
        .contentShape(Rectangle())
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }
}

private struct ConnectorToolToggleRow: View {
    let connector: MCPConnectorRecord
    @Binding var isOn: Bool
    let disabled: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(connector.name)
                        .font(MyChatTypography.cardTitle)
                        .lineLimit(1)
                    Text("\(connector.toolCount) 个工具")
                        .font(MyChatTypography.metadata)
                        .foregroundStyle(MyChatTheme.secondaryText)
                }
            } icon: {
                Image(systemName: "puzzlepiece.extension")
                    .font(MyChatSystemFont.appFont(size: 20, weight: .regular))
                    .frame(width: 28)
            }
        }
        .tint(MyChatTheme.accent)
        .frame(minHeight: 62)
        .contentShape(Rectangle())
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .accessibilityIdentifier("tools.connector.\(connector.id)")
    }
}

private struct ThinkingDepthRow: View {
    @EnvironmentObject private var appModel: AppModel

    private var disabled: Bool {
        !appModel.reasoningEnabled || appModel.availableReasoningEfforts.isEmpty
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "brain.head.profile")
                .font(MyChatSystemFont.appFont(size: 19, weight: .regular))
                .frame(width: 28)
            Text("Thinking depth")
                .font(MyChatTypography.navigation)
                .lineSpacing(MyChatTypography.utilityLineSpacing)
            Spacer()
            Menu {
                ForEach(appModel.availableReasoningEfforts, id: \.self) { effort in
                    Button {
                        appModel.setReasoningEffort(effort)
                    } label: {
                        if effort == appModel.reasoningEffort {
                            Label(appModel.reasoningEffortLabel(effort), systemImage: "checkmark")
                        } else {
                            Text(appModel.reasoningEffortLabel(effort))
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                Text(appModel.reasoningEnabled ? appModel.selectedReasoningEffortLabel : "Off")
                    .font(MyChatTypography.metadata)
                    .lineSpacing(MyChatTypography.metadataLineSpacing)
                    .foregroundStyle(MyChatTheme.secondaryText)
                Image(systemName: "chevron.right")
                    .font(MyChatSystemFont.appFont(for: .caption1, weight: .semibold))
                    .foregroundStyle(MyChatTheme.secondaryText)
                }
                .padding(.leading, 16)
                .frame(minHeight: 50)
                .contentShape(Rectangle())
            }
            .menuOrder(.fixed)
            .buttonStyle(.plain)
        }
        .frame(minHeight: 50)
        .disabled(disabled)
        .opacity(disabled ? 0.48 : 1)
        .accessibilityLabel("Thinking depth")
        .accessibilityValue(appModel.reasoningEnabled ? appModel.selectedReasoningEffortLabel : "Off")
    }
}

private struct ToolsSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var fileImporterVisible = false
    @State private var cameraVisible = false
    @State private var isPreparingAttachment = false
    @State private var attachmentError: String?
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Add to Chat").font(MyChatTypography.pageTitleUtility)
                HStack {
                    Button(action: close) { Image(systemName: "xmark").font(MyChatSystemFont.appFont(size: 17, weight: .regular)) }
                        .buttonStyle(MyChatIconButtonStyle()).accessibilityLabel("关闭")
                    Spacer()
                    PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 4, matching: .images) {
                        Text("Photos").font(MyChatTypography.navigation).foregroundStyle(MyChatTheme.text)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12)
            RecentPhotoStrip(camera: openCamera, selected: { data, name in await importCameraImage(data, name: name) })
                .padding(.bottom, 14)

            NavigationStack {
                ScrollView {
                    VStack(spacing: 16) {
                        VStack(spacing: 0) {
                            Button { fileImporterVisible = true } label: { NativeSettingsRow(title: "Add files", icon: "doc.badge.arrow.up") }
                                .buttonStyle(.plain).accessibilityLabel("添加文件")
                            Divider().padding(.leading, 50)
                            NavigationLink { projectChoices } label: {
                                NativeSettingsRow(title: "Add to project", icon: "archivebox", detail: appModel.projects.first { $0.id.lowercased() == appModel.activeProjectID?.uuidString.lowercased() }?.name ?? "None")
                            }.buttonStyle(.plain).disabled(appModel.isPrivateChat)
                        }.background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 22))
                        NavigationLink { connectorToolControls.padding(20).navigationTitle("Connectors").navigationBarTitleDisplayMode(.inline).background(MyChatTheme.canvas) } label: {
                            NativeSettingsRow(title: "Connectors", icon: "square.grid.2x2")
                        }.buttonStyle(.plain).background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 22))
                    }.padding(.horizontal, 26).padding(.top, 8).padding(.bottom, 32)
                }.scrollIndicators(.hidden).background(MyChatTheme.canvas)
            }.tint(MyChatTheme.text)
        }
        .overlay {
            if isPreparingAttachment {
                ZStack {
                    Color.black.opacity(0.12).ignoresSafeArea()
                    ProgressView("正在处理附件")
                        .padding(.horizontal, 20)
                        .frame(minHeight: 64)
                        .background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 18))
                }
            }
        }
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
            Task { await importPhotos(items) }
        }
        .fileImporter(
            isPresented: $fileImporterVisible,
            allowedContentTypes: [.pdf, .text, .plainText, .sourceCode, .data],
            allowsMultipleSelection: true
        ) { result in
            Task { await importFiles(result) }
        }
        .fullScreenCover(isPresented: $cameraVisible) {
            CameraImagePicker { data in
                cameraVisible = false
                guard let data else { return }
                Task { await importCameraImage(data) }
            }
            .ignoresSafeArea()
        }
        .foregroundStyle(MyChatTheme.text)
        .background(MyChatTheme.canvas)
        .onChange(of: appModel.attachmentError) { _, error in attachmentError = error }
        .alert("无法添加附件", isPresented: Binding(get: { attachmentError != nil }, set: { if !$0 { attachmentError = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(attachmentError ?? "") }
    }

    @ViewBuilder
    private var connectorToolControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("本次对话的连接器")
                .font(MyChatTypography.cardTitle)
                .frame(minHeight: 42, alignment: .leading)

            if appModel.isPrivateChat {
                Label("私密对话不使用连接器", systemImage: "eye.slash")
                    .font(MyChatTypography.metadata)
                    .foregroundStyle(MyChatTheme.secondaryText)
                    .frame(minHeight: 48, alignment: .leading)
            } else if case .loading = appModel.connectorsPhase {
                ProgressView("正在加载连接器")
                    .font(MyChatTypography.metadata)
                    .frame(minHeight: 52, alignment: .leading)
            } else if case .failed = appModel.connectorsPhase {
                Button("重新加载连接器") {
                    Task { await appModel.reloadConnectors() }
                }
                .font(MyChatTypography.metadata)
                .frame(minHeight: 52, alignment: .leading)
            } else if appModel.connectors.isEmpty {
                Text("No connectors")
                    .font(MyChatTypography.metadata)
                    .foregroundStyle(MyChatTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 52, alignment: .leading)
            } else {
                Picker(
                    "工具调用方式",
                    selection: Binding(
                        get: { appModel.activeChatConnectorAccessMode },
                        set: { appModel.setConnectorAccessModeInCurrentChat($0) }
                    )
                ) {
                    ForEach(ChatConnectorAccessMode.allCases, id: \.self) { mode in
                        Text(mode.segmentTitle).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("连接器工具调用方式")

                Text("Tool access")
                    .font(MyChatTypography.metadata)
                    .foregroundStyle(MyChatTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 5)

                ForEach(appModel.connectors) { connector in
                    ConnectorToolToggleRow(
                        connector: connector,
                        isOn: Binding(
                            get: { appModel.connectorIsAvailableInCurrentChat(connector) },
                            set: { appModel.setConnectorAvailableInCurrentChat(connector, available: $0) }
                        ),
                        disabled: !connector.enabled
                    )
                }
                Text("These choices apply to this conversation.")
                    .font(MyChatTypography.metadata)
                    .foregroundStyle(MyChatTheme.secondaryText)
                    .padding(.vertical, 8)
            }
        }
    }

    private var projectChoices: some View {
        ScrollView {
            VStack(spacing: 0) {
                Button { chooseProject(nil) } label: { NativeSettingsRow(title: "None", icon: "") }.buttonStyle(.plain)
                ForEach(appModel.projects) { project in
                    Divider().padding(.leading, 18)
                    Button { chooseProject(project) } label: { NativeSettingsRow(title: project.name, icon: "archivebox") }.buttonStyle(.plain)
                }
            }.background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 22)).padding(20)
        }.background(MyChatTheme.canvas).navigationTitle("Add to project").navigationBarTitleDisplayMode(.inline)
    }
    private func chooseProject(_ project: ProjectRecord?) {
        Task {
            do { try await appModel.assignCurrentChat(to: project); close() }
            catch { attachmentError = error.localizedDescription }
        }
    }

    private func openCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            appModel.setAttachmentError("这台设备没有可用相机")
            return
        }
        if [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .video)) {
            appModel.setAttachmentError("相机权限已关闭，请在系统设置中允许 MyChat 使用相机")
            return
        }
        cameraVisible = true
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        isPreparingAttachment = true
        defer {
            isPreparingAttachment = false
            selectedPhotos = []
        }
        var imported = false
        for (index, item) in items.prefix(4).enumerated() {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw AttachmentPreparationError.invalidImage
                }
                let attachment = try await Task.detached(priority: .userInitiated) {
                    try AttachmentPreparation.prepareImage(
                        data: data,
                        name: "照片-\(index + 1).jpg"
                    )
                }.value
                appModel.addPendingAttachment(attachment)
                imported = true
            } catch {
                appModel.setAttachmentError(error.localizedDescription)
            }
        }
        if imported { close() }
    }

    private func importCameraImage(_ data: Data, name: String = "相机照片.jpg") async {
        isPreparingAttachment = true
        defer { isPreparingAttachment = false }
        do {
            let attachment = try await Task.detached(priority: .userInitiated) {
                try AttachmentPreparation.prepareImage(data: data, name: name)
            }.value
            appModel.addPendingAttachment(attachment)
            close()
        } catch {
            appModel.setAttachmentError(error.localizedDescription)
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) async {
        do {
            let urls = try result.get()
            guard !urls.isEmpty else { return }
            isPreparingAttachment = true
            defer { isPreparingAttachment = false }
            var imported = false
            for url in urls.prefix(8) {
                let accessGranted = url.startAccessingSecurityScopedResource()
                defer { if accessGranted { url.stopAccessingSecurityScopedResource() } }
                do {
                    let attachment = try await Task.detached(priority: .userInitiated) {
                        let values = try url.resourceValues(forKeys: [.contentTypeKey, .nameKey])
                        let data = try Data(contentsOf: url, options: .mappedIfSafe)
                        return try AttachmentPreparation.prepareFile(
                            data: data,
                            name: values.name ?? url.lastPathComponent,
                            mimeType: values.contentType?.preferredMIMEType
                        )
                    }.value
                    appModel.addPendingAttachment(attachment)
                    imported = true
                } catch {
                    appModel.setAttachmentError(error.localizedDescription)
                }
            }
            if imported { close() }
        } catch {
            appModel.setAttachmentError(error.localizedDescription)
        }
    }
}

private struct AttachmentActionTile: View {
    let title: String
    let symbol: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(MyChatSystemFont.appFont(size: 19, weight: .regular))
            Text(title)
                .font(MyChatTypography.caption)
                .lineSpacing(MyChatTypography.captionLineSpacing)
        }
        .frame(maxWidth: .infinity, minHeight: 74)
        .background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(MyChatTheme.border.opacity(0.8), lineWidth: 0.7)
        }
        .contentShape(Rectangle())
    }
}
