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
    @State private var historyVisible = false
    @State private var historyConversationVisible = false
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
                navigationKey: CanvasNavigationKey(appModel: appModel, historyVisible: historyVisible,
                    historyConversationVisible: historyConversationVisible),
                sidebar: SidebarView(appModel: appModel, width: drawerWidth, interactionLocked: false,
                    openSettings: openSettings, openAllChats: openAllChats, close: closeSidebar)
                    .equatable().environmentObject(appModel),
                canvas: canvasSurface
                    .environmentObject(appModel).environmentObject(canvasLayout),
                composer: AnyView(FloatingComposerView(appModel: appModel,
                    openTools: { requestSheet(.tools) }, openModels: { requestSheet(.models) },
                    drawerIsOpen: { sidebarVisible }))
            )
        }
        .ignoresSafeArea()
        .sheet(isPresented: $settingsVisible, onDismiss: { setChatRenderSuspended(false) }) {
            MyChatSettingsView(appModel: appModel, close: closeSettings).environmentObject(appModel)
                .presentationDetents([.large]).presentationDragIndicator(.hidden)
                .modifier(MyChatSheetSurface())
        }
        .onChange(of: appModel.pendingDocumentPreview) { _, _ in presentPendingDocument() }
        .onChange(of: settingsVisible) { _, visible in if !visible { presentPendingDocument() } }
        .onChange(of: sidebarVisible) { _, visible in if !visible { presentPendingDocument() } }
        .onChange(of: appModel.activeConversationID) { _, _ in appModel.pendingDocumentPreview = nil }
        .onChange(of: appModel.authSession?.user.id, initial: true) { _, owner in
            canvasLayout.readingPositions.setOwner(owner)
        }
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
            ModelPickerSheet(close: { modelPickerVisible = false })
                .environmentObject(appModel)
                .presentationDetents([.fraction(0.62), .large])
                .presentationContentInteraction(.resizes)
                .presentationDragIndicator(.hidden)
                .modifier(StableSheetPageSizing())
                .modifier(MyChatSheetSurface())
        }
        .sheet(isPresented: $toolsVisible, onDismiss: {
            setChatRenderSuspended(false)
        }) {
            ToolsSheet(close: { toolsVisible = false })
                .environmentObject(appModel)
                .presentationDragIndicator(.hidden)
                .modifier(MyChatSheetSurface())
        }
        .fullScreenCover(item: $appModel.artifactPreview, onDismiss: {
            setChatRenderSuspended(false)
        }) { artifact in
            ArtifactLibraryDetail(artifact: artifact)
                .environmentObject(appModel)
                .presentationBackground(.clear)
        }
    }

    private func presentPendingDocument() {
        guard !settingsVisible, !sidebarVisible, !historyVisible, !toolsVisible, !modelPickerVisible,
              automaticDocument == nil, appModel.selectedDestination == .chats,
              let document = appModel.pendingDocumentPreview else { return }
        NativeDocumentModalActivity.set(documentModalID, active: true)
        automaticDocument = document
        appModel.pendingDocumentPreview = nil
    }

    private func openSidebar() {
        HapticFeedback.impact()
        dismissKeyboard()
        sidebarVisible = true
    }

    private func closeSidebar() {
        // This closure is only called for an explicit destination selection.
        // A drag or tap on the canvas changes the drawer binding directly and
        // preserves the mounted All Chats page beneath it.
        historyVisible = false
        historyConversationVisible = false
        sidebarVisible = false
    }

    private func openAllChats() {
        appModel.discardPrivateChat()
        dismissKeyboard()
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            historyConversationVisible = false
            historyVisible = true
        }
        sidebarVisible = false
    }

    private func openChatFromHistory() {
        withAnimation { historyConversationVisible = true }
    }

    @ViewBuilder private var canvasSurface: some View {
        if historyVisible {
            NavigationStack {
                ConversationHistorySheet(appModel: appModel,
                    openChat: openChatFromHistory, close: openSidebar)
                    .navigationDestination(isPresented: $historyConversationVisible) {
                        mainCanvas.toolbar(.hidden, for: .navigationBar)
                    }
                    .toolbar(.hidden, for: .navigationBar)
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
        } else {
            mainCanvas
        }
    }

    private var mainCanvas: some View {
        MainCanvasView(appModel: appModel,
            openSidebar: openSidebar, openTools: { requestSheet(.tools) },
            openModels: { requestSheet(.models) }, openArtifact: presentArtifact)
            .background(MyChatTheme.canvas.ignoresSafeArea())
            .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    private func openSettings() {
        HapticFeedback.impact()
        dismissKeyboard()
        setChatRenderSuspended(true)
        settingsVisible = true
    }

    private enum SheetTarget: Equatable { case models, tools }

    private func requestSheet(_ target: SheetTarget) {
        guard !settingsVisible, !modelPickerVisible, !toolsVisible,
              automaticDocument == nil, appModel.artifactPreview == nil else { return }
        dismissKeyboard()
        // Suspend before presentation so a streaming layout cannot compete
        // with the native sheet, dimming and interactive transition.
        setChatRenderSuspended(true)
        if target == .models { modelPickerVisible = true }
        else { toolsVisible = true }
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
    let conversationExists: Bool
    let historyVisible: Bool
    let historyConversationVisible: Bool

    @MainActor init(appModel: AppModel, historyVisible: Bool = false, historyConversationVisible: Bool = false) {
        destination = appModel.selectedDestination
        projectID = appModel.activeProjectID
        projectName = appModel.projects.first {
            UUID(uuidString: $0.id) == appModel.activeProjectID
        }?.name
        conversationID = appModel.activeConversationID
        newChatRevision = appModel.newChatRevision
        privateChat = appModel.isPrivateChat
        transcriptIsEmpty = appModel.messages.isEmpty
        conversationExists = appModel.conversations.contains { UUID(uuidString: $0.id) == appModel.activeConversationID }
        self.historyVisible = historyVisible
        self.historyConversationVisible = historyConversationVisible
    }

    func isWelcomePrivacyTransition(to next: Self) -> Bool {
        destination == .chats && next.destination == .chats
            && transcriptIsEmpty && next.transcriptIsEmpty
            && projectID == nil && next.projectID == nil
            && !historyVisible && !next.historyVisible
            && !historyConversationVisible && !next.historyConversationVisible
            && privateChat != next.privateChat
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
                chatHeader
                    .background {
                        if !appModel.messages.isEmpty {
                            Rectangle().fill(.regularMaterial)
                                .mask {
                                    LinearGradient(stops: [
                                        .init(color: .black, location: 0),
                                        .init(color: .black, location: 0.38),
                                        .init(color: .clear, location: 1)
                                    ], startPoint: .top, endPoint: .bottom)
                                }
                                .ignoresSafeArea(.container, edges: .top)
                                .allowsHitTesting(false)
                        }
                    }
                    .zIndex(1)
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

    @ViewBuilder private var chatHeader: some View {
                if appModel.messages.isEmpty, activeProject == nil,
                   appModel.activeConversationID == nil || appModel.isPrivateChat {
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

    @ViewBuilder
    private var destinationContent: some View {
        switch appModel.selectedDestination {
        case .chats:
            ZStack {
            if appModel.messages.isEmpty {
                if appModel.activeConversationID != nil && !appModel.isPrivateChat {
                    // A history load is a chat surface; mounting Welcome here
                    // caused a second full-page swap as its messages arrived.
                    Color.clear
                } else {
                    GeometryReader { proxy in
                        EmptyChatCanvas(isPrivate: appModel.isPrivateChat, bottomOcclusion: canvasLayout.bottomOcclusion,
                            systemBottomInset: proxy.safeAreaInsets.bottom, canvasLayout: canvasLayout)
                    }.transition(.opacity.combined(with: .scale(scale: 0.97)).combined(with: .offset(y: -8)))
                }
            } else {
                ChatConversationView(appModel: appModel)
                    .equatable()
                    .environmentObject(appModel)
                    // Welcome/privacy can crossfade, but transcript geometry
                    // is owned by the scroll and keyboard controllers.
                    .transaction { $0.animation = nil }
                    .transition(.opacity.combined(with: .offset(y: 10)))
            }
            }.animation(.smooth(duration: 0.3, extraBounce: 0), value: appModel.messages.isEmpty)
        case .projects:
            ProjectsLanding()
        case .artifacts:
            ArtifactsLanding(openSidebar: openSidebar, openArtifact: openArtifact)
        case .code:
            CodeLanding()
                .id(appModel.authSession?.user.id)
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
        case .projects: return "项目"
        case .artifacts: return "可视化"
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
    let readingPositions = ChatReadingPositionStore()
    private struct Geometry: Equatable {
        var bottomOcclusion: CGFloat = 140
        var composerTop: CGFloat?
    }
    @Published private var geometry = Geometry()
    var bottomOcclusion: CGFloat { geometry.bottomOcclusion }
    var composerTopInWindow: CGFloat? { geometry.composerTop }
    var presentedComposerTop: (() -> CGFloat?)?
    // Welcome geometry participates in the very same Auto Layout pass as the
    // keyboard-guided input. The published reservation remains for transcripts.
    weak var composerView: UIView?
    var keyboardTiming = KeyboardTransitionTiming()
    private var pendingGeometry = Geometry()
    private var scheduled = false

    func setBottomOcclusion(_ height: CGFloat, composerTop: CGFloat? = nil) {
        if let composerTop, composerTop.isFinite { pendingGeometry.composerTop = composerTop }
        pendingGeometry.bottomOcclusion = height
        guard !scheduled, pendingGeometry != geometry else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            if self.geometry != self.pendingGeometry { self.geometry = self.pendingGeometry }
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
            let previousNavigationKey = controller.lastNavigationKey
            controller.lastNavigationKey = navigationKey
            if previousNavigationKey?.isWelcomePrivacyTransition(to: navigationKey) == true {
                // Keep the existing welcome representable alive and do not
                // suppress UIKit animations: it owns the Logo ↔ privacy glyph
                // cross-fade and scale interaction.
                controller.canvasHost.rootView = canvas
                controller.canvasHost.view.layoutIfNeeded()
                controller.setOpen(isOpen)
                return
            }
            // The hosting tree is separate from SwiftUI's outer transaction.
            // Navigation swaps must not inherit a page-size spring while the
            // keyboard and transcript perform their own native layout.
            var navigationTransaction = Transaction()
            navigationTransaction.disablesAnimations = true
            UIView.performWithoutAnimation {
                withTransaction(navigationTransaction) {
                    controller.canvasHost.rootView = canvas
                    controller.canvasHost.view.layoutIfNeeded()
                }
            }
        }
        controller.setOpen(isOpen)
    }

    private func configure(_ controller: DrawerController<Sidebar, Canvas>) {
        controller.drawerWidth = width
        controller.blocked = blocked
        controller.reduceMotion = reduceMotion
        controller.canvasLayout = canvasLayout
        controller.composerVisible = navigationKey.destination == .chats
            && (!navigationKey.historyVisible || navigationKey.historyConversationVisible)
        controller.onOpenChanged = { isOpen = $0 }
    }
}

enum DrawerPanelGeometry {
    // Measured against the 440 pt Claude reference. This is a fixed silhouette,
    // including at rest; the device's outer display contour finishes the edge.
    static let cornerRadius: CGFloat = 60

    static func path(in bounds: CGRect) -> CGPath {
        UnevenRoundedRectangle(topLeadingRadius: cornerRadius,
            bottomLeadingRadius: cornerRadius, style: .continuous).path(in: bounds).cgPath
    }
}

private final class DrawerPanelSurface: UIView {
    private let contour = CAShapeLayer()
    private var renderedBounds: CGRect = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        contour.fillColor = UIColor.black.cgColor
        layer.mask = contour
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds != renderedBounds else { return }
        renderedBounds = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contour.frame = bounds
        contour.path = DrawerPanelGeometry.path(in: bounds)
        CATransaction.commit()
    }
}

/// Contact and short cast shadow share the exact clipping contour. The opaque
/// panel covers the inside half of the contact stroke; there is no white rim.
private final class DrawerEdgeDepth: UIView {
    private let contact = CAShapeLayer()
    private var renderedBounds: CGRect = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        backgroundColor = .clear
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowRadius = 5.5
        layer.shadowOffset = CGSize(width: -0.75, height: 0)
        contact.fillColor = UIColor.clear.cgColor
        layer.addSublayer(contact)
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (edge: DrawerEdgeDepth, _: UITraitCollection) in
            edge.updateColors()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds != renderedBounds else { return }
        renderedBounds = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = DrawerPanelGeometry.path(in: bounds)
        layer.shadowPath = path
        contact.frame = bounds
        contact.path = path
        contact.lineWidth = 2 / max(1, traitCollection.displayScale)
        CATransaction.commit()
    }

    private func updateColors() {
        let dark = traitCollection.userInterfaceStyle == .dark
        layer.shadowOpacity = dark ? 0.35 : 0.10
        contact.strokeColor = UIColor.black.withAlphaComponent(dark ? 0.28 : 0.14).cgColor
    }
}

enum DrawerMotion {
    enum Intent { case undecided, horizontal, vertical }
    static func intent(_ delta: CGPoint) -> Intent {
        let x = abs(delta.x), y = abs(delta.y)
        if y >= 8, y * 1.8 > x { return .vertical }
        if x >= 12, x >= y * 1.8 { return .horizontal }
        return .undecided
    }
    static func shadeOpacity(progress: CGFloat) -> CGFloat {
        0.38 * (1 - min(1, max(0, progress)))
    }
    static let auditsInput = ProcessInfo.processInfo.arguments.contains("--drawer-motion-audit")
    static func draggedOffset(origin: CGFloat, translation: CGFloat, width: CGFloat) -> CGFloat {
        let proposed = origin + translation
        let excess = max(0, proposed - width)
        return max(0, excess > 0 ? width + 12 * excess / (excess + 48) : proposed)
    }
    static func targetIsOpen(offset: CGFloat, velocity: CGFloat, width: CGFloat,
                             cancelled: Bool, wasOpen: Bool, origin: CGFloat? = nil) -> Bool {
        guard !cancelled, width > 0 else { return wasOpen }
        // A deliberate short drag must work even when the finger slows down
        // before release. Use actual travel; reserve velocity for reversals
        // and movements too small to establish direction.
        let travel = offset - (origin ?? (wasOpen ? width : 0))
        let threshold = min(24, width * 0.08)
        if !wasOpen, travel >= threshold { return velocity >= -60 }
        if wasOpen, travel <= -threshold { return velocity > 60 }
        return offset + velocity * 0.18 > width * 0.52
    }

    static func initialVelocity(_ velocity: CGFloat, distance: CGFloat) -> CGFloat {
        guard abs(distance) > 0.5 else { return 0 }
        return min(max(velocity / distance, -20), 20)
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
    private let surface = DrawerPanelSurface()
    private let sidebarShade = UIView()
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
    #if DEBUG
    private var panelProbeStarted = false
    #endif
    private lazy var pan: DirectionalDrawerPanGestureRecognizer = {
        let pan = DirectionalDrawerPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.maximumNumberOfTouches = 1
        // Keep page touches buffered until the drawer direction is
        // known. Otherwise SwiftUI can bind a child control before the canvas
        // moves and activate the newly exposed sidebar row on release.
        pan.delaysTouchesBegan = true
        pan.delaysTouchesEnded = true
        pan.cancelsTouchesInView = true
        pan.delegate = self
        pan.acceptsStart = { [weak self] _ in
            guard let self, !self.blocked else { return false }
            return true
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
        sidebarShade.backgroundColor = .black
        sidebarShade.isUserInteractionEnabled = false
        sidebarShade.accessibilityElementsHidden = true
        view.addSubview(sidebarShade)
        view.addSubview(edgeDepth)
        edgeDepth.alpha = 0
        view.addSubview(surface)
        surface.backgroundColor = .clear
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
        composerHost.view.clipsToBounds = false
        composerHost.view.isHidden = !composerVisible
        composerHost.view.setContentHuggingPriority(.required, for: .vertical)
        composerHost.view.setContentCompressionResistancePriority(.required, for: .vertical)
        composerHost.didMove(toParent: self)
        canvasLayout?.composerView = composerHost.view
        sidebarHost.view.accessibilityElementsHidden = true
        sidebarHost.view.isUserInteractionEnabled = false
        surface.addSubview(tapShield)
        tapShield.backgroundColor = UIColor(MyChatTheme.canvas).withAlphaComponent(0.60)
        tapShield.isHidden = true
        tapShield.accessibilityLabel = "关闭侧边栏"
        tapShield.addTarget(self, action: #selector(closeFromTap), for: .touchUpInside)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: DrawerController, _: UITraitCollection) in
            controller.canvasHost.view.backgroundColor = UIColor(MyChatTheme.canvas)
                .resolvedColor(with: controller.traitCollection)
        }
        for child in [sidebarHost.view!, sidebarShade, edgeDepth, surface, canvasHost.view!, composerHost.view!, tapShield] {
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
            sidebarShade.leadingAnchor.constraint(equalTo: sidebarHost.view.leadingAnchor),
            sidebarShade.trailingAnchor.constraint(equalTo: sidebarHost.view.trailingAnchor),
            sidebarShade.topAnchor.constraint(equalTo: sidebarHost.view.topAnchor),
            sidebarShade.bottomAnchor.constraint(equalTo: sidebarHost.view.bottomAnchor),
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
        canvasLayout?.presentedComposerTop = { [weak self] in
            guard let self, let composer = self.composerHost.view, let parent = composer.superview else { return nil }
            let top = (composer.layer.presentation()?.frame ?? composer.frame).minY
            return parent.convert(CGPoint(x: 0, y: top), to: nil).y
        }
        // During keyboardWillChange the input is still at its old frame.
        // Publish the target owned by the keyboard guide, including the same
        // clearance used in canvasBottomInset, instead of that stale frame.
        let composerTop = view.window == nil ? nil : view.convert(
            CGPoint(x: 0, y: view.bounds.maxY - inset + 8), to: nil).y
        canvasLayout?.setBottomOcclusion(inset, composerTop: composerTop)
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
        #if DEBUG
        runPanelProbeIfRequested()
        #endif
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
        currentOffset = min(max(0, offset), drawerWidth + 12)
        let progress = drawerWidth > 0 ? min(1, currentOffset / drawerWidth) : 0
        // The recessed sidebar comes into the light as the foreground paper
        // moves away. Opacity shares the same pan/animator position and never
        // intercepts touches or changes the canvas's brightness.
        sidebarShade.alpha = DrawerMotion.shadeOpacity(progress: progress)
        surface.transform = CGAffineTransform(translationX: currentOffset, y: 0)
        edgeDepth.transform = surface.transform
        // Neither curvature nor edge density changes with travel. At closure
        // the fixed edge simply exits the display rather than morphing flat.
        edgeDepth.alpha = 1
        // No per-frame shadow rasterization or SwiftUI layout during a pan.
        tapShield.isHidden = currentOffset < 0.5
        tapShield.alpha = progress
    }

    #if DEBUG
    // Optical regression fixture: use the production positioning path for a
    // held drag with reversals. Actual touch recognition is covered by XCUITest.
    // No haptics are fired; this fixture isolates the visual result.
    private func runPanelProbeIfRequested() {
        guard !panelProbeStarted, view.window != nil, surface.bounds.width > 0,
              ProcessInfo.processInfo.arguments.contains("--panel-visual-probe") else { return }
        panelProbeStarted = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            self.dismissComposer()
            self.interruptAnimation()
            self.gesturing = true
            self.lockInteraction(true)
            self.applyOffset(0)
            let initial = (self.surface.layer.mask as? CAShapeLayer)?.path
            let phases: [(String, CGFloat, Double)] = [
                ("slow-open", 1, 1.2), ("slow-close", 0, 1.2),
                ("fast-open", 1, 0.18), ("fast-close", 0, 0.18),
                ("half-open", 0.5, 0.7), ("reverse-close", 0.2, 0.5),
                ("reverse-open", 1, 0.8), ("repeat-close-1", 0, 0.32),
                ("repeat-open-1", 1, 0.32), ("repeat-close-2", 0, 0.32),
                ("repeat-open-2", 1, 0.32), ("final-close", 0, 0.32)
            ]
            var frames: [[String: Any]] = []
            let began = CACurrentMediaTime()
            for (phase, fraction, duration) in phases {
                let origin = self.currentOffset
                let start = CACurrentMediaTime()
                var progress: Double = 0
                repeat {
                    progress = min(1, (CACurrentMediaTime() - start) / duration)
                    UIView.performWithoutAnimation {
                        self.applyOffset(origin + (self.drawerWidth * fraction - origin) * progress)
                    }
                    let contour = (self.surface.layer.mask as? CAShapeLayer)?.path
                    frames.append(["time": CACurrentMediaTime() - began, "phase": phase,
                        "offset": self.currentOffset,
                        "outlineUnchanged": initial != nil && contour.map { CFEqual($0, initial) } == true,
                        "edgeMatchesOutline": contour != nil && self.edgeDepth.layer.shadowPath.map { CFEqual($0, contour) } == true,
                        "scaleX": self.surface.transform.a, "scaleY": self.surface.transform.d,
                        "edgeOffset": self.edgeDepth.transform.tx])
                    try? await Task.sleep(for: .milliseconds(16))
                } while progress < 1
            }
            self.gesturing = false
            self.desiredOpen = false
            self.onOpenChanged(false)
            self.applyOffset(0)
            self.lockInteraction(false)
            if let data = try? JSONSerialization.data(withJSONObject: frames, options: [.sortedKeys]),
               let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                try? data.write(to: folder.appendingPathComponent("panel-motion-audit.json"), options: .atomic)
            }
        }
    }
    #endif

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
            duration = 0.32
            timing = UISpringTimingParameters(dampingRatio: 1,
                initialVelocity: CGVector(dx: min(3, max(0,
                    DrawerMotion.initialVelocity(velocity, distance: distance))), dy: 0))
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
        desiredOpen = false
        onOpenChanged(false)
        animate(to: false, velocity: 0)
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: view).x
        switch recognizer.state {
        case .began:
            if DrawerMotion.auditsInput { MyChatDebugLog.event("drawer begin offset=\(currentOffset) translation=\(translation)") }
            // Direction has been classified as horizontal. Cancel every active
            // vertical scroll pan inside the moving canvas until this same
            // touch ends; small vertical finger drift can no longer move both.
            setCanvasScrollGestureLocked(true)
            interruptAnimation()
            gesturing = true
            gestureOrigin = currentOffset
            snapHapticSent = false
            dismissComposer()
            HapticFeedback.prepare()
            lockInteraction(true)
            trackGesture(translation: translation)
        case .changed:
            trackGesture(translation: translation)
        case .ended, .cancelled:
            // A fast drag can go straight from began to ended. Apply both
            // samples; waiting for changed dropped its entire displacement.
            if recognizer.state == .ended { trackGesture(translation: translation) }
            let velocity = recognizer.velocity(in: view).x
            let open = DrawerMotion.targetIsOpen(offset: currentOffset, velocity: velocity,
                width: drawerWidth, cancelled: recognizer.state == .cancelled, wasOpen: desiredOpen, origin: gestureOrigin)
            if DrawerMotion.auditsInput { MyChatDebugLog.event("drawer release offset=\(currentOffset) translation=\(translation) velocity=\(velocity) open=\(open)") }
            gesturing = false
            setCanvasScrollGestureLocked(false)
            if open != desiredOpen, !snapHapticSent { HapticFeedback.impact() }
            desiredOpen = open
            onOpenChanged(open)
            animate(to: open, velocity: recognizer.state == .cancelled ? 0 : velocity)
        default: break
        }
    }

    private func trackGesture(translation: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyOffset(DrawerMotion.draggedOffset(origin: gestureOrigin,
            translation: translation, width: drawerWidth))
        CATransaction.commit()
        let crossed = desiredOpen ? currentOffset < drawerWidth * 0.5 : currentOffset > drawerWidth * 0.5
        if crossed, !snapHapticSent {
            snapHapticSent = true
            HapticFeedback.impact()
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if DrawerMotion.auditsInput { MyChatDebugLog.event("drawer shouldBegin blocked=\(blocked) velocity=\(pan.velocity(in: view))") }
        guard !blocked else { return false }
        // UIKit asks before publishing its new translation. Use the intent
        // already classified from the current touch, not that stale value.
        return pan.hasHorizontalIntent
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === pan else { return true }
        if !desiredOpen, currentOffset <= 1 {
            var touchedView = touch.view
            while let candidate = touchedView, candidate !== view {
                if let scroll = candidate as? UIScrollView, scroll.isScrollEnabled,
                   scroll.contentSize.width > scroll.bounds.width + 1 {
                    // Image strips, tables and code already own a horizontal
                    // reading gesture. Opening the drawer must not steal it.
                    return false
                }
                touchedView = candidate.superview
            }
        }
        // A horizontal swipe may start anywhere, including the header. Taps
        // still reach their controls when direction classification fails.
        return true
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
              scrollView.contentSize.width <= scrollView.bounds.width + 1,
              (scrollView.isDescendant(of: canvasHost.view) || scrollView.isDescendant(of: composerHost.view)) else { return false }
        // Across the page, let the direction classifier settle first. A
        // horizontal pan wins; a vertical intent fails quickly and hands the
        // touch straight back to UIKit scrolling.
        return true
    }
}

// Opt-in geometry-only diagnostics. Records no pixels, text, or audio. The
// ordinary launch path never creates a display link or touches focus for this.
@MainActor final class KeyboardMotionAudit: NSObject {
    static weak var companionView: UIView?
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
            if let companion = Self.companionView {
                frame["companionY"] = companion.convert(companion.bounds, to: root).minY
            }
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
    private(set) var hasHorizontalIntent = false
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
        if DrawerMotion.auditsInput { MyChatDebugLog.event("drawer move state=\(state.rawValue) delta=\(delta)") }
        // Classify once. Changing a recognized pan to .failed when the finger
        // curves vertically interrupts its live transform and release velocity.
        if state == .possible {
            switch DrawerMotion.intent(delta) {
            case .vertical: state = .failed; return
            case .undecided: return
            case .horizontal:
                if acceptsDirection?(delta) == false { state = .failed; return }
                hasHorizontalIntent = true
            }
        }
        super.touchesMoved(touches, with: event)
    }

    override func reset() { initialLocation = nil; hasHorizontalIntent = false; super.reset() }
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
                HeaderActionButton(action: openSidebar) {
                    ChatMenuGlyph().stroke(style: StrokeStyle(lineWidth: 1.35, lineCap: .round))
                        .frame(width: 16, height: 16)
                        .foregroundStyle(MyChatTheme.text)
                }
                .frame(width: 44, height: 44)
                .modifier(MyChatFloatingSurface(shape: Circle()))
                .accessibilityLabel("打开侧边栏")
                .accessibilityIdentifier("header.sidebar")

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .offset(y: -4)
    }
}

/// The glyph's painted pixels must not define the header's touch target.
/// A native control owns the entire 44-point frame, including glyph gaps.
struct HeaderActionButton<Label: View>: UIViewRepresentable {
    let action: () -> Void
    let label: Label

    init(action: @escaping () -> Void, @ViewBuilder label: () -> Label) {
        self.action = action
        self.label = label()
    }

    func makeUIView(context: Context) -> HeaderActionControl<Label> {
        HeaderActionControl(label: label, action: action)
    }

    func updateUIView(_ control: HeaderActionControl<Label>, context: Context) {
        control.action = action
        control.labelHost.rootView = label
    }
}

final class HeaderActionControl<Label: View>: UIButton {
    var action: () -> Void
    let labelHost: UIHostingController<Label>

    init(label: Label, action: @escaping () -> Void) {
        self.action = action
        labelHost = UIHostingController(rootView: label)
        super.init(frame: .zero)
        labelHost.view.backgroundColor = .clear
        labelHost.view.isUserInteractionEnabled = false
        labelHost.view.accessibilityElementsHidden = true
        addSubview(labelHost.view)
        labelHost.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            labelHost.view.centerXAnchor.constraint(equalTo: centerXAnchor),
            labelHost.view.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelHost.view.widthAnchor.constraint(equalToConstant: 24),
            labelHost.view.heightAnchor.constraint(equalToConstant: 24),
        ])
        addTarget(self, action: #selector(activate), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    @objc private func activate() { action() }
}

private struct EmptyChatHeader: View {
    @ObservedObject var appModel: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let openSidebar: () -> Void

    var body: some View {
        ZStack {
            Text("隐私对话").font(MyChatTypography.navigation)
                .opacity(appModel.isPrivateChat ? 1 : 0)
                .scaleEffect(appModel.isPrivateChat ? 1 : 0.98)
                .offset(y: appModel.isPrivateChat ? 0 : -4)
                .accessibilityHidden(!appModel.isPrivateChat)
            HStack {
                HeaderActionButton(action: openSidebar) {
                    ChatMenuGlyph().stroke(style: StrokeStyle(lineWidth: 1.35, lineCap: .round))
                        .frame(width: 16, height: 16).foregroundStyle(MyChatTheme.text)
                }
                .frame(width: 44, height: 44)
                .modifier(MyChatFloatingSurface(shape: Circle()))
                .accessibilityLabel("打开侧边栏")
                .accessibilityIdentifier("header.sidebar")
                Spacer(minLength: 0)
                HeaderActionButton {
                    HapticFeedback.impact()
                    if appModel.isPrivateChat { appModel.beginNewChat() } else { appModel.beginPrivateChat() }
                } label: {
                    PrivacyChatGlyph(foreground: MyChatTheme.text, eyeColor: MyChatTheme.canvas, filled: appModel.isPrivateChat)
                        .frame(width: 20, height: 20)
                }
                .frame(width: 44, height: 44)
                .modifier(MyChatFloatingSurface(shape: Circle()))
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
            Text("隐私对话")
                .font(MyChatTypography.navigation)

            HStack {
                HeaderActionButton(action: openSidebar) {
                    ChatMenuGlyph().stroke(style: StrokeStyle(lineWidth: 1.35, lineCap: .round))
                        .frame(width: 16, height: 16)
                        .foregroundStyle(MyChatTheme.text)
                }
                .frame(width: 44, height: 44)
                .modifier(MyChatFloatingSurface(shape: Circle()))
                .accessibilityLabel("打开侧边栏")
                .accessibilityIdentifier("header.sidebar")

                Spacer(minLength: 0)

                HeaderActionButton(action: closePrivateChat) {
                    PrivacyChatGlyph(foreground: MyChatTheme.text, eyeColor: MyChatTheme.canvas)
                        .frame(width: 20, height: 20)
                }
                .frame(width: 44, height: 44)
                .modifier(MyChatFloatingSurface(shape: Circle()))
                .accessibilityLabel("退出隐私聊天")
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .offset(y: -4)
    }
}

struct ProjectChatHeader: View {
    let projectName: String
    let appModel: AppModel
    let conversation: ConversationRecord?
    let backToProject: () -> Void
    let newProjectChat: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HeaderActionButton(action: backToProject) {
                Image(systemName: "arrow.left")
                    .font(MyChatSystemFont.appFont(size: 18, weight: .regular))
                    .foregroundStyle(MyChatTheme.text)
            }
            .frame(width: 44, height: 44)
            .modifier(MyChatFloatingSurface(shape: Circle()))
            .accessibilityLabel("返回项目")
            .accessibilityIdentifier("header.project-back")

            HStack(spacing: 7) {
                MyChatProjectIcon(size: 19)
                Text(projectName)
                    .font(MyChatTypography.chip)
                    .lineLimit(1)
            }
            .accessibilityHidden(true)
            .padding(.horizontal, 13)
            .frame(height: 44)
            .modifier(MyChatFloatingSurface(shape: Capsule()))
            .overlay {
                HeaderActionButton(action: backToProject) { Color.clear }
                    .accessibilityLabel("打开项目：\(projectName)")
                    .accessibilityIdentifier("header.project")
            }

            Spacer(minLength: 0)
            ConversationFilesButton(appModel: appModel).padding(.trailing, 2)

            if conversation != nil {
                HStack(spacing: 0) {
                    HeaderActionButton(action: newProjectChat) { NewChatHeaderGlyph() }
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("在项目中新建聊天")
                    .accessibilityIdentifier("header.new-project-chat")

                    ConversationActionMenu(appModel: appModel, conversation: conversation)
                }
                .padding(.horizontal, 6)
                .modifier(MyChatFloatingSurface(shape: Capsule()))
            } else {
                HeaderActionButton(action: newProjectChat) { NewChatHeaderGlyph() }
                .frame(width: 44, height: 44)
                .modifier(MyChatFloatingSurface(shape: Circle()))
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
            HeaderActionButton(action: openSidebar) {
                ChatMenuGlyph().stroke(style: StrokeStyle(lineWidth: 1.35, lineCap: .round))
                    .frame(width: 16, height: 16)
                    .foregroundStyle(MyChatTheme.text)
            }
            .frame(width: 44, height: 44)
            .modifier(MyChatFloatingSurface(shape: Circle()))
            .accessibilityLabel("打开侧边栏")
            .accessibilityIdentifier("header.sidebar")

            Spacer(minLength: 0)

            ConversationFilesButton(appModel: appModel).padding(.trailing, 12)

            if hasStartedChat {
                // iOS 26 merges adjacent bar buttons into one glass capsule;
                // mirror that instead of two independent circles.
                HStack(spacing: 0) {
                    HeaderActionButton(action: beginNewChat) {
                        NewChatHeaderGlyph()
                    }
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("新建聊天")
                    .accessibilityIdentifier("header.new-chat")

                    ConversationActionMenu(appModel: appModel, conversation: conversation)
                }
                .padding(.horizontal, 6)
                .modifier(MyChatFloatingSurface(shape: Capsule()))
            } else {
                HeaderActionButton(action: { HapticFeedback.impact(); appModel.beginPrivateChat() }) {
                    PrivacyChatGlyph(foreground: MyChatTheme.text, eyeColor: MyChatTheme.canvas).frame(width: 20, height: 20)
                }
                .frame(width: 44, height: 44)
                .modifier(MyChatFloatingSurface(shape: Circle()))
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

    private var nativeMenu: UIMenu {
        let destinations: [UIMenuElement] = appModel.projects.isEmpty
            ? [UIAction(title: "还没有项目", attributes: .disabled) { _ in }]
            : appModel.projects.map { project in
                UIAction(title: project.name,
                    state: conversation?.projectID?.lowercased() == project.id.lowercased() ? .on : .off) { _ in
                    guard let conversation else { return }
                    Task { @MainActor in
                        do { try await appModel.setConversationProject(conversation, project: project) }
                        catch { actionError = error.localizedDescription }
                    }
                }
            }
        let projectMenu = UIMenu(title: "添加到项目", image: MyChatProjectIcon.menuImage,
            children: destinations)
        let deletion = UIAction(title: "删除对话", image: UIImage(systemName: "trash"),
            attributes: conversation == nil ? [.destructive, .disabled] : .destructive) { _ in
            guard let conversation else { return }
            Task { @MainActor in
                do { try await appModel.deleteConversation(conversation) }
                catch { actionError = error.localizedDescription }
            }
        }
        return UIMenu(children: [projectMenu, deletion])
    }

    var body: some View {
        HeaderMenuButton(menu: nativeMenu)
            .frame(width: 44, height: 44)
            .accessibilityIdentifier("header.conversation-menu")
        .accessibilityLabel("更多聊天选项")
        .alert(
            "对话操作失败",
            isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )
        ) {
            Button("好", role: .cancel) { actionError = nil }
        } message: {
            Text(PresentationText.plain(actionError ?? ""))
        }
    }
}

// UIKit owns menu activation over the entire hit target. SwiftUI supplies
// the glyph only, so glass and clear label pixels cannot consume the tap.
struct HeaderMenuButton: UIViewRepresentable {
    let menu: UIMenu

    func makeUIView(context: Context) -> HeaderActionControl<AnyView> {
        let control = HeaderActionControl(label: AnyView(
            Image(systemName: "ellipsis")
                .font(MyChatSystemFont.appFont(size: 15, weight: .semibold))
                .foregroundStyle(MyChatTheme.text)), action: {})
        control.showsMenuAsPrimaryAction = true
        control.menu = menu
        return control
    }

    func updateUIView(_ control: HeaderActionControl<AnyView>, context: Context) {
        control.menu = menu
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
            PrivacyGhostOutline().fill(foreground).frame(width: size, height: size * 25 / 24)
                .opacity(filled ? 1 : 0).scaleEffect(filled ? 1 : 0.92)
            PrivacyGhostOutline().stroke(foreground, style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
                .frame(width: size, height: size * 25 / 24)
                .opacity(filled ? 0 : 1).scaleEffect(filled ? 1.04 : 1)

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
    @AppStorage("mychat.profile.fullName") private var fullName = ""
    let isPrivate: Bool
    let bottomOcclusion: CGFloat
    let systemBottomInset: CGFloat
    let canvasLayout: ChatCanvasLayout
    private var greeting: String {
        let name = fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "你好" : "你好，\(name)"
    }
    var body: some View {
        WelcomeMotionView(greeting: greeting, isPrivate: isPrivate,
            bottomOcclusion: bottomOcclusion, systemBottomInset: systemBottomInset, canvasLayout: canvasLayout)
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
                    Label("新建项目", systemImage: "plus")
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
                    TextField("搜索", text: $searchText)
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
            if appModel.projectsPhase == .idle { await appModel.reloadWorkspaceData() }
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
            "无法删除项目",
            isPresented: Binding(
                get: { deletionError != nil || appModel.projectDeletionError != nil },
                set: { if !$0 { deletionError = nil; appModel.clearProjectDeletionError() } }
            )
        ) {
            Button("好", role: .cancel) { deletionError = nil; appModel.clearProjectDeletionError() }
        } message: {
            Text(PresentationText.plain(deletionError ?? appModel.projectDeletionError ?? ""))
        }
    }

    @ViewBuilder
    private var projectContent: some View {
        if appModel.projects.isEmpty {
            VStack(spacing: 16) {
                MyChatProjectIcon(size: 24)
                    .foregroundStyle(MyChatTheme.secondaryText)
                    .frame(width: 48, height: 48)
                    .background(MyChatTheme.controlSurface, in: Circle())
                if let error = appModel.projectsError {
                    Text("无法刷新项目").font(MyChatTypography.navigation)
                    Text(PresentationText.plain(error)).font(MyChatTypography.metadata)
                        .multilineTextAlignment(.center)
                    Button("重试") { Task { await appModel.reloadWorkspaceData() } }
                } else if appModel.projectsPhase == .loading || appModel.projectsPhase == .idle {
                    Text("正在同步项目…").font(MyChatTypography.metadata)
                } else {
                    VStack(spacing: 6) {
                        Text("还没有项目").font(MyChatTypography.navigation)
                        Text("把相关对话和文件整理到一起。")
                            .font(MyChatTypography.metadata).multilineTextAlignment(.center)
                    }
                }
            }
            .foregroundStyle(MyChatTheme.secondaryText)
            .frame(maxWidth: 330)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredProjects.isEmpty {
            Text("没有匹配的项目")
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
                                    Label("删除项目", systemImage: "trash")
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
                    Text("创建项目")
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
                            Text("你正在做什么？")
                                .font(MyChatTypography.cardTitle)
                                .foregroundStyle(MyChatTheme.secondaryText)
                            TextField("项目名称", text: $name)
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
                            Text("你想实现什么目标？")
                                .font(MyChatTypography.cardTitle)
                                .foregroundStyle(MyChatTheme.secondaryText)
                            TextField("描述项目、目标、主题和指令…", text: $instructions, axis: .vertical)
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
                    Text(instructions.isEmpty ? "没有项目指令" : instructions)
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
                    projectActionButton("添加文件", systemImage: "doc.badge.plus") {
                        fileImporterPresented = true
                    }
                    projectActionButton("添加指令", systemImage: "text.badge.plus") {
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
                        Text("此项目中还没有对话")
                            .font(MyChatTypography.cardTitle)
                        Text("开始对话后会显示在这里。")
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

                NewChatButton {
                    appModel.beginNewChat(in: project)
                    dismiss()
                }
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
                    Image(systemName: "arrow.left")
                        .font(MyChatSystemFont.appFont(size: 18, weight: .regular))
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
                            Label("删除项目", systemImage: "trash")
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
                Text("项目指令")
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
                Text("可视化").font(MyChatTypography.pageTitleUtility)
                HStack {
                    HeaderActionButton(action: openSidebar) {
                        ChatMenuGlyph().stroke(style: StrokeStyle(lineWidth: 1.35, lineCap: .round))
                            .frame(width: 16, height: 16).foregroundStyle(MyChatTheme.text)
                    }
                    .frame(width: 44, height: 44)
                    .modifier(MyChatFloatingSurface(shape: Circle()))
                    .accessibilityLabel("打开侧边栏")
                    .accessibilityIdentifier("header.sidebar")
                    Spacer()
                    Menu {
                        Picker("筛选可视化内容", selection: $selectedFilter) {
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
                    .accessibilityLabel("筛选可视化内容")
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 52)
            .offset(y: -4)

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
                    Text(searchText.isEmpty ? "还没有可视化内容" : "没有匹配的可视化内容")
                        .font(MyChatTypography.navigation)
                    Text(searchText.isEmpty
                        ? (appModel.artifactsError ?? "在 MyChat 中创建的可视化内容会显示在这里。")
                        : "请尝试其他搜索词或筛选条件。")
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
                            ArtifactLibraryCard(artifact: artifact) { openArtifact(artifact) }

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
                TextField("搜索", text: $searchText)
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
                return ChatArtifactParser.parse(artifact.raw).blocks.contains { $0.kind == .document }
            case .code:
                return ChatArtifactParser.parse(artifact.raw).blocks.contains { $0.kind != .document }
            }
        }
    }

    private enum ArtifactFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case documents = "文档"
        case code = "可视化"

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
    @State private var returnOffset: CGFloat = 0
    @State private var returning = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { viewport in
        ZStack {
            MyChatTheme.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                ZStack {
                    Text(artifact.title.isEmpty ? "可视化内容" : artifact.title)
                        .font(MyChatSystemFont.appFont(size: 19, weight: .semibold))
                        .lineLimit(1)
                    HStack {
                        Button { finishReturn(width: viewport.size.width) } label: {
                            Image(systemName: "arrow.left")
                                .font(MyChatSystemFont.appFont(size: 17, weight: .regular))
                        }
                        .buttonStyle(MyChatIconButtonStyle())
                        .accessibilityLabel("退出作品预览")
                        .accessibilityIdentifier("artifact-preview-close")
                        Spacer()
                        Button { deleteConfirmation = true } label: {
                            Image(systemName: "trash")
                                .font(MyChatSystemFont.appFont(size: 17, weight: .regular))
                        }
                        .buttonStyle(MyChatIconButtonStyle())
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
                        InteractiveArtifactView(rawHTML: documents.first?.content ?? artifact.raw, colorScheme: colorScheme)
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
        .overlay(alignment: .leading) {
            Color.clear
                .frame(width: 22)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        guard !returning, value.translation.width > abs(value.translation.height) else { return }
                        returnOffset = max(0, value.translation.width)
                    }
                    .onEnded { value in
                        guard !returning else { return }
                        if returnOffset > viewport.size.width * 0.28 ||
                            (returnOffset > 45 && value.predictedEndTranslation.width > viewport.size.width * 0.55) {
                            finishReturn(width: viewport.size.width)
                        } else {
                            withAnimation(.smooth(duration: 0.25)) { returnOffset = 0 }
                        }
                    })
                .accessibilityHidden(true)
        }
        .offset(x: returnOffset)
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
        .confirmationDialog("删除这个可视化内容？", isPresented: $deleteConfirmation) {
            Button("删除", role: .destructive) {
                Task {
                    do {
                        try await appModel.deleteArtifact(artifact)
                        finishReturn(width: viewport.size.width)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
        }
    }

    private func finishReturn(width: CGFloat) {
        guard !returning else { return }
        returning = true
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.28), completionCriteria: .logicallyComplete) {
            returnOffset = width
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { dismiss() }
        }
    }
}

struct ModelPickerSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    var close: (() -> Void)? = nil
    private func closeSheet() { if let close { close() } else { dismiss() } }
    let codeOnly: Bool

    init(codeOnly: Bool = false, close: (() -> Void)? = nil) {
        self.codeOnly = codeOnly
        self.close = close
    }

    @ViewBuilder var body: some View {
        if codeOnly { legacyBody } else { ChatModelSelectionSheet(close: close) }
    }

    private var legacyBody: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "选择模型", close: { dismiss() })
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
                                        if model.id != appModel.selectedModelID { HapticFeedback.play(.selection) }
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


private struct StableSheetPageSizing: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *) { content.presentationSizing(.page) }
        else { content }
    }
}

private struct ModelSheetScrollSurface: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) { content.scrollEdgeEffectHidden(true, for: .all) }
        else { content }
    }
}

private struct ChatModelSelectionSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var close: (() -> Void)? = nil
    private func closeSheet() { if let close { close() } else { dismiss() } }
    @State private var path: [Page] = []
    private enum Page: Hashable { case models, more, effort }
    private let selectionColor = Color(red: 95.0 / 255, green: 157.0 / 255, blue: 221.0 / 255)
    private var primary: [ModelCatalogItem] {
        ModelCatalogItem.primaryChatModels(appModel.models, selectedID: appModel.selectedModelID)
    }
    private var others: [ModelCatalogItem] {
        let ids = Set(primary.map(\.id))
        var seen = Set<String>()
        return appModel.models.filter { !ids.contains($0.id) && seen.insert($0.id).inserted }
    }
    var body: some View {
        NavigationStack(path: $path) {
            pageSurface(.models)
                .navigationDestination(for: Page.self) { page in
                    pageSurface(page)
                }
        }
        .tint(MyChatTheme.text)
        .ignoresSafeArea(.container, edges: .bottom)
    }
    private func pageSurface(_ page: Page) -> some View {
        VStack(spacing: 0) {
            Capsule().fill(MyChatTheme.secondaryText.opacity(0.32))
                .frame(width: 56, height: 4).padding(.top, 6).padding(.bottom, 6)
                .accessibilityHidden(true)
            ZStack {
                Text(page == .effort ? "思考强度" : page == .more ? "更多模型" : "选择模型")
                    .font(MyChatTypography.pageTitleUtility)
                    .contentTransition(.interpolate)
                HStack {
                    HeaderActionButton {
                        if page == .models { closeSheet() } else { navigate(to: .models) }
                    } label: {
                        Image(systemName: page == .models ? "xmark" : "chevron.left")
                            .contentTransition(.symbolEffect(.replace))
                    }.frame(width: 42, height: 42)
                        .modifier(MyChatFloatingSurface(shape: Circle()))
                        .accessibilityLabel(page == .models ? "关闭" : "返回")
                    Spacer()
                }
            }.padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 22)
            ScrollView {
                pageContent(page)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.hidden)
            .modifier(ModelSheetScrollSurface())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(MyChatTheme.canvas)
        .toolbar(.hidden, for: .navigationBar)
    }
    private func pageContent(_ page: Page) -> some View {
                VStack(alignment: .leading, spacing: 16) {
                    if page == .effort { effortRows }
                    else if page == .more {
                        let custom = others.filter { $0.endpointID != nil }
                        if !custom.isEmpty {
                            Text("自定义模型").font(MyChatTypography.metadata).foregroundStyle(MyChatTheme.secondaryText).padding(.leading, 18)
                            modelRows(custom, raised: false)
                        }
                        let builtIn = others.filter { $0.endpointID == nil }
                        if !builtIn.isEmpty { modelRows(builtIn, raised: false) }
                        if others.isEmpty { Text("没有更多模型").foregroundStyle(MyChatTheme.secondaryText).padding(18) }
                    } else {
                        if !primary.isEmpty { modelRows(primary) }
                        if appModel.models.isEmpty {
                            if appModel.catalogPhase == .loading { ProgressView().frame(maxWidth: .infinity).padding(30) }
                            else { Button("重试") { Task { await appModel.reloadModels() } }.padding(18) }
                        }
                        if appModel.selectedModelSupportsReasoning {
                            Button { navigate(to: .effort) } label: {
                                NativeSettingsRow(title: "思考强度", icon: "", detail: appModel.reasoningEnabled ? effortLabel(appModel.reasoningEffort) : "关闭")
                            }.buttonStyle(ModelSelectionPressStyle()).background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 22))
                                .accessibilityIdentifier("model.effort")
                        }
                        Button { navigate(to: .more) } label: {
                            NativeSettingsRow(title: "更多模型", icon: "")
                        }.buttonStyle(ModelSelectionPressStyle()).background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 22))
                            .accessibilityIdentifier("model.more")
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 34)
                .foregroundStyle(MyChatTheme.text)
    }
    private func navigate(to destination: Page) {
        if destination == .models { path.removeAll() }
        else if path.last != destination { path.append(destination) }
    }
    private func modelRows(_ models: [ModelCatalogItem], raised: Bool = true) -> some View {
        VStack(spacing: 0) {
            ForEach(models) { model in
                Button {
                    if model.id != appModel.selectedModelID { HapticFeedback.play(.selection) }
                    appModel.selectModel(model); closeSheet()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(model.chatDisplayName).font(MyChatTypography.navigation)
                            Text(description(model)).font(MyChatTypography.metadata).foregroundStyle(MyChatTheme.secondaryText)
                        }
                        Spacer()
                        if model.id == appModel.selectedModelID { Image(systemName: "checkmark").foregroundStyle(selectionColor).font(.system(size: 20, weight: .medium)) }
                    }.frame(minHeight: raised ? 70 : 62).contentShape(Rectangle())
                }.buttonStyle(ModelSelectionPressStyle()).disabled(!model.isSelectable).opacity(model.isSelectable ? 1 : 0.5)
                if raised && model.id != models.last?.id { Divider() }
            }
        }
        .padding(.horizontal, 18)
        .background {
            if raised { RoundedRectangle(cornerRadius: 22).fill(MyChatTheme.raised) }
        }
    }
    private func description(_ model: ModelCatalogItem) -> String {
        let name = (model.name + model.id).lowercased()
        if name.contains("fable") { return "应对您最艰巨的挑战" }
        if name.contains("opus") { return "适用于复杂工作与日常任务" }
        if name.contains("sonnet") { return "处理简单任务效率最高" }
        if name.contains("haiku") { return "快速解答的最佳选择" }
        return model.provider
    }
    private func effortLabel(_ value: String) -> String { appModel.reasoningEffortLabel(value) }
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
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
                            if value == "none" { appModel.setReasoningEnabled(false) } else { appModel.setReasoningEffort(value) }
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Text(effortLabel(value)).font(MyChatTypography.navigation)
                            if value == "medium" || (!orderedEfforts.contains("medium") && value == appModel.selectedModel?.defaultReasoningEffort) {
                                Text("推荐").font(MyChatTypography.caption).foregroundStyle(MyChatTheme.secondaryText)
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
            Text("思考强度越高，回复所需时间越长。").font(MyChatTypography.metadata).foregroundStyle(MyChatTheme.secondaryText).padding(.horizontal, 18)
        }
    }
}

private struct ModelSelectionPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SheetHeader: View {
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
                    Text(model.chatDisplayName)
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
        .accessibilityLabel("\(model.chatDisplayName)，\(model.provider)")
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
            Text("思考强度")
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
                Text(appModel.reasoningEnabled ? appModel.selectedReasoningEffortLabel : "关闭")
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
        .accessibilityLabel("思考强度")
        .accessibilityValue(appModel.reasoningEnabled ? appModel.selectedReasoningEffortLabel : "关闭")
    }
}

private struct ToolsSheet: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var fileImporterVisible = false
    @State private var cameraVisible = false
    @State private var createProjectVisible = false
    @State private var projectQuery = ""
    @State private var isPreparingAttachment = false
    @State private var attachmentError: String?
    @State private var path: [Page] = []
    @State private var selectedDetent: PresentationDetent = .fraction(0.56)
    private enum Page: Hashable { case projects, connectors }
    let close: () -> Void

    var body: some View {
        NavigationStack(path: $path) {
            pageSurface(nil)
                .navigationDestination(for: Page.self) { page in pageSurface(page) }
        }
        .tint(MyChatTheme.text)
        .ignoresSafeArea(.container, edges: .bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(MyChatTheme.canvas)
        .modifier(StableSheetPageSizing())
        .presentationDetents([.fraction(0.56), .large], selection: $selectedDetent)
        .presentationContentInteraction(.resizes)
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
        .fullScreenCover(isPresented: $createProjectVisible) {
            CreateProjectView().environmentObject(appModel)
        }
        .foregroundStyle(MyChatTheme.text)
        .background(MyChatTheme.canvas)
        .onChange(of: appModel.attachmentError) { _, error in attachmentError = error }
        .alert("无法添加附件", isPresented: Binding(get: { attachmentError != nil }, set: { if !$0 { attachmentError = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(attachmentError ?? "") }
    }

    private func pageSurface(_ page: Page?) -> some View {
        VStack(spacing: 0) {
            Capsule().fill(MyChatTheme.secondaryText.opacity(0.32))
                .frame(width: 56, height: 4).padding(.top, 6).padding(.bottom, 6)
                .accessibilityHidden(true)
            ZStack {
                Text(page == .projects ? "添加到项目" : page == .connectors ? "连接器" : "添加到聊天")
                    .font(MyChatTypography.pageTitleUtility)
                HStack {
                    HeaderActionButton { if page == nil { close() } else { path.removeAll() } } label: {
                        Image(systemName: page == nil ? "xmark" : "chevron.left")
                            .font(MyChatSystemFont.appFont(size: 17, weight: .regular))
                    }.frame(width: 42, height: 42)
                        .modifier(MyChatFloatingSurface(shape: Circle()))
                        .accessibilityLabel(page == nil ? "关闭" : "返回")
                    Spacer()
                    if page == nil {
                        PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 4, matching: .images) {
                            Text("照片").font(MyChatTypography.navigation).foregroundStyle(MyChatTheme.text)
                        }.buttonStyle(.plain)
                    } else if page == .projects {
                        HeaderActionButton { createProjectVisible = true } label: {
                            Image(systemName: "plus").font(MyChatSystemFont.appFont(size: 19, weight: .regular))
                        }
                        .frame(width: 42, height: 42)
                        .modifier(MyChatFloatingSurface(shape: Circle()))
                        .accessibilityLabel("新建项目")
                        .accessibilityIdentifier("tools.projects.create")
                    }
                }
            }
            .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 22)
            Group {
                if page == .projects { projectChoices }
                else if page == .connectors { ScrollView { connectorToolControls.padding(20) } }
                else { attachmentChoices }
            }
            .scrollIndicators(.hidden)
            .modifier(ModelSheetScrollSurface())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(MyChatTheme.canvas)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var attachmentChoices: some View {
        ScrollView {
            VStack(spacing: 16) {
                RecentPhotoStrip(camera: openCamera, selected: { data, name in await importCameraImage(data, name: name) })
                    .padding(.horizontal, -18)
                VStack(spacing: 0) {
                    Button { fileImporterVisible = true } label: { attachmentRow("添加文件", icon: "doc.badge.arrow.up", disclosure: false) }
                        .buttonStyle(.plain).accessibilityLabel("添加文件")
                    Divider().padding(.leading, 50).padding(.trailing, 18)
                    NavigationLink(value: Page.projects) {
                        attachmentRow("添加到项目", icon: "archivebox", detail: appModel.projects.first { $0.id.lowercased() == appModel.activeProjectID?.uuidString.lowercased() }?.name)
                    }.buttonStyle(.plain).disabled(appModel.isPrivateChat)
                        .accessibilityIdentifier("tools.projects.row")
                }.background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 22))
                NavigationLink(value: Page.connectors) {
                    attachmentRow("连接器", icon: "square.grid.2x2")
                }.buttonStyle(.plain).background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 22))
            }.padding(.horizontal, 18).padding(.bottom, 32)
        }
    }

    private func attachmentRow(_ title: String, icon: String, detail: String? = nil,
                               disclosure: Bool = true) -> some View {
        HStack(spacing: 12) {
            Group {
                if icon == "archivebox" { MyChatProjectIcon(size: 20) }
                else { Image(systemName: icon).font(.system(size: 18, weight: .regular)) }
            }.frame(width: 20).foregroundStyle(MyChatTheme.sidebarSecondary)
            Text(title).font(MyChatTypography.navigation)
            Spacer(minLength: 8)
            if let detail { Text(detail).font(MyChatTypography.metadata).foregroundStyle(MyChatTheme.secondaryText) }
            if disclosure {
                Image(systemName: "chevron.right").font(.system(size: 15, weight: .light))
                    .foregroundStyle(MyChatTheme.secondaryText)
            }
        }
        .padding(.horizontal, 20).frame(height: 52).contentShape(Rectangle())
    }

    @ViewBuilder
    private var connectorToolControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !appModel.isPrivateChat {
                DefaultConnectorsView(ownerID: appModel.authSession?.user.id ?? "")
                    .id(appModel.authSession?.user.id)
                    .padding(.bottom, 20)
            }
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
                EmptyView()
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
            }
        }
    }

    private var projectChoices: some View {
        VStack(spacing: 0) {
            if filteredProjects.isEmpty {
                VStack(spacing: 18) {
                    MyChatProjectIcon(size: 22)
                        .foregroundStyle(MyChatTheme.secondaryText)
                        .frame(width: 48, height: 48)
                        .background(MyChatTheme.controlSurface, in: Circle())
                        .accessibilityHidden(true)
                    VStack(spacing: 6) {
                        Text(appModel.projects.isEmpty ? "暂无项目" : "未找到项目")
                            .font(MyChatTypography.navigation)
                        if appModel.projects.isEmpty {
                            Text("请先创建项目，然后将此对话移入其中。")
                                .font(MyChatTypography.metadata)
                        }
                    }.foregroundStyle(MyChatTheme.secondaryText).multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(filteredProjects.enumerated()), id: \.element.id) { index, project in
                            if index > 0 { Divider().padding(.leading, 50).padding(.trailing, 18) }
                            Button { chooseProject(project) } label: {
                                attachmentRow(project.name, icon: "archivebox")
                            }.buttonStyle(.plain)
                        }
                    }
                    .background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(.horizontal, 18).padding(.top, 8)
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .regular))
                TextField("搜索", text: $projectQuery)
                    .font(MyChatTypography.navigation)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("tools.projects.search")
            }
            .padding(.horizontal, 16).frame(height: 48)
            .modifier(MyChatFloatingSurface(shape: Capsule()))
            .padding(.horizontal, 26).padding(.top, 16).padding(.bottom, 28)
        }
        .background(MyChatTheme.canvas)
    }
    private var filteredProjects: [ProjectRecord] {
        let query = projectQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return appModel.projects.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
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
