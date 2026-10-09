import AVFoundation
import Combine
import CoreText
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

struct ChatConversationView: View, Equatable {
    private let appModel: AppModel
    @StateObject private var updates: ChatTranscriptUpdates
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var canvasLayout: ChatCanvasLayout
    @State private var sourceMessageID: UUID?
    // Reference storage, without observing its button publisher in this tree.
    @State private var scrollController = ChatScrollController()
    @State private var nativeViewport: CGRect?
    @State private var reservedReadingPadding: CGFloat?
    @State private var paddingReleaseTask: Task<Void, Never>?

    init(appModel: AppModel) {
        self.appModel = appModel
        _updates = StateObject(wrappedValue: ChatTranscriptUpdates(appModel))
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.appModel === rhs.appModel }

    private var usesVirtualizedTranscript: Bool { updates.snapshot.messages.count > 64 }

    @ViewBuilder private var transcriptRows: some View {
        ForEach(updates.snapshot.messages) { message in
            VStack(alignment: .leading, spacing: 3) {
                MessageBlock(
                    message: message,
                    isGenerating: updates.snapshot.isGenerating && message.id == updates.snapshot.messages.last?.id,
                    processEntries: updates.snapshot.processEntries[message.id] ?? [],
                    searches: updates.snapshot.searches[message.id] ?? [],
                    memoryChanges: updates.snapshot.memoryChanges[message.id] ?? [],
                    toolActivities: updates.snapshot.toolActivities[message.id] ?? [],
                    connectorApps: updates.snapshot.connectorApps[message.id] ?? [],
                    appModel: appModel,
                    showsResponseCompanion: message.id == updates.snapshot.messages.last(where: { $0.role == .assistant })?.id,
                    companionSuspended: sourceMessageID != nil,
                    accessToken: updates.snapshot.accessToken,
                    canRegenerate: message.role == .assistant && !updates.snapshot.isGenerating
                        && updates.snapshot.canRegenerate,
                    removesLaterMessages: updates.snapshot.messages.last?.id != message.id,
                    regenerate: { appModel.regenerate(message) },
                    openSources: { sourceMessageID = message.id },
                    openHistorySource: openHistoryConversation,
                    isEditingUserMessage: updates.snapshot.editingMessageID == message.id,
                    canEditUserMessage: updates.snapshot.canEditMessages
                )
                .equatable()
            }
            .background(ReadingAnchorMarker(messageID: message.id, controller: scrollController))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("message.row." + message.id.uuidString)
            .background {
                if ProcessInfo.processInfo.arguments.contains("--keyboard-layout-probe"),
                   (message.role == .user && message.id == updates.snapshot.messages.first?.id
                    || message.role == .assistant && message.id == updates.snapshot.messages.last?.id) {
                    Color.clear.onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .global)
                    } action: { frame in
                        if message.role == .user { KeyboardMotionAudit.messageFrame = frame }
                        else { KeyboardMotionAudit.assistantFrame = frame }
                    }
                }
            }
        }
        if let error = updates.snapshot.error {
            InlineChatError(message: PresentationText.plain(error), retry: appModel.retryCurrentGeneration)
        }
    }

    @ViewBuilder private var transcriptStack: some View {
        if usesVirtualizedTranscript {
            LazyVStack(alignment: .leading, spacing: 24) { transcriptRows }
        } else {
            VStack(alignment: .leading, spacing: 24) { transcriptRows }
        }
    }

    var body: some View {
        GeometryReader { viewport in
        let readingPadding = ChatReadingAnchor.bottomPadding(viewport: nativeViewport ?? viewport.frame(in: .global),
            composerTop: canvasLayout.composerTopInWindow, minimum: canvasLayout.bottomOcclusion)
        let laidOutPadding = max(readingPadding, reservedReadingPadding ?? readingPadding)
        ScrollView {
            transcriptStack
            // Keep every row at the scroll viewport width, then inset the
            // transcript content once. User rows own their trailing alignment
            // inside this fixed-width viewport.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 74)
            .background(alignment: .bottomLeading) {
                NativeChatScrollObserver(controller: scrollController, conversationID: updates.snapshot.conversationID,
                    loadPending: updates.snapshot.isConversationLoadPending)
                    .frame(width: 0, height: 0)
            }
            // Keep real scrollable breathing room below the reading anchor;
            // the floating input must not pull a completed reply to the bottom.
            .padding(.bottom, laidOutPadding)
        }
        .containerRelativeFrame(.horizontal)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Extend the real scroll viewport behind the floating composer and
        // home indicator. Clipping at the inset edge creates a full-width plate.
        .ignoresSafeArea(.container, edges: .bottom)
        .background {
            if MyChatLayoutAudit.enabled {
                Color.clear
                    .onAppear {
                        MyChatLayoutAudit.line("MYCHAT_VIEWPORT size=\(viewport.size) safeBottom=\(viewport.safeAreaInsets.bottom) pad=\(canvasLayout.bottomOcclusion)")
                    }
                    .onChange(of: canvasLayout.bottomOcclusion) { _, bottom in
                        MyChatLayoutAudit.line("MYCHAT_VIEWPORT size=\(viewport.size) safeBottom=\(viewport.safeAreaInsets.bottom) pad=\(bottom)")
                    }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(TapGesture().onEnded {
            NotificationCenter.default.post(name: .myChatDismissComposer, object: nil)
        })
        .modifier(ChatScrollActivity(controller: scrollController))
        .environment(\.chatScrollController, scrollController)
        .onAppear {
            scrollController.useReadingPositions(canvasLayout.readingPositions, remembersPosition: !appModel.isPrivateChat)
            scrollController.resumeFollowAnimation()
            scrollController.onViewportChanged = { nativeViewport = $0 }
            nativeViewport = scrollController.viewportInWindow
            scrollController.presentedComposerTop = { [weak canvasLayout] in canvasLayout?.presentedComposerTop?() }
            scrollController.onInteractionChanged = { updates.setInteracting($0) }
            scrollController.setGenerationActive(updates.snapshot.isGenerating)
        }
        .onChange(of: updates.snapshot.isGenerating) { _, active in
            scrollController.setGenerationActive(active)
        }
        .onChange(of: readingPadding, initial: true) { _, padding in
            reserveReadingSpace(padding)
        }
        .onChange(of: ChatComposerGeometry(bottomPadding: laidOutPadding,
            topInWindow: canvasLayout.composerTopInWindow), initial: true) { _, geometry in
            scrollController.setComposerGeometry(geometry)
        }
        .onReceive(NotificationCenter.default.publisher(for: .myChatDrawerInteractionChanged)) { note in
            scrollController.setDrawerInteractionActive(note.object as? Bool ?? false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .myChatModalVisibilityChanged)) { note in
            updates.setModalVisible(note.object as? Bool ?? false)
        }
        .onDisappear {
            paddingReleaseTask?.cancel()
            scrollController.onViewportChanged = { _ in }
            scrollController.onInteractionChanged = { _ in }
            scrollController.setInteractionActive(false)
            scrollController.setDrawerInteractionActive(false)
            scrollController.pauseFollowAnimation()
            updates.setInteracting(false)
        }
        .overlay(alignment: .topLeading) {
            LatestMessageButton(controller: scrollController)
                .position(x: viewport.size.width / 2,
                    y: max(22, min(viewport.size.height - 22, (canvasLayout.composerTopInWindow.map { $0 - viewport.frame(in: .global).minY }
                        ?? viewport.size.height - canvasLayout.bottomOcclusion) - 30)))
                .animation(canvasLayout.keyboardTiming.animation, value: canvasLayout.composerTopInWindow)
        }
        .sheet(isPresented: Binding(
            get: { sourceMessageID != nil },
            set: { if !$0 { sourceMessageID = nil } }
        )) {
            if let messageID = sourceMessageID {
                SourcesSheet(
                    searches: (updates.snapshot.searches[messageID] ?? []).filter(\.isWebSearch),
                    openHistorySource: openHistoryConversation
                )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(34)
                    .presentationBackground(MyChatTheme.canvas)
            }
        }
        }
    }

    private func reserveReadingSpace(_ padding: CGFloat) {
        paddingReleaseTask?.cancel()
        guard let current = reservedReadingPadding, padding < current,
              scrollController.keyboardIsMoving else { reservedReadingPadding = padding; return }
        // Retain the old range until the keyboard finishes, so UIKit cannot
        // clamp an in-flight offset into a prematurely shortened transcript.
        paddingReleaseTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(canvasLayout.keyboardTiming.duration + 0.06)) }
            catch { return }
            reservedReadingPadding = padding
        }
    }

    private func openHistoryConversation(_ conversationID: String) {
        guard let conversation = appModel.conversations.first(where: { $0.id == conversationID }) else { return }
        sourceMessageID = nil
        appModel.openConversation(conversation)
    }

}

struct TranscriptSnapshot {
    var messages: [ChatMessage]
    var processEntries: [UUID: [ChatProcessEntry]]
    var searches: [UUID: [ChatToolSearch]]
    var memoryChanges: [UUID: [ChatMemoryEvent]]
    var toolActivities: [UUID: [ChatToolActivity]]
    var connectorApps: [UUID: [ChatConnectorAppEvent]]
    var accessToken: String?
    var conversationID: UUID?
    var isConversationLoadPending: Bool
    var isGenerating: Bool
    var canRegenerate: Bool
    var error: String?
    var editingMessageID: UUID?
    var canEditMessages: Bool

    @MainActor init(_ model: AppModel) {
        messages = model.messages
        processEntries = model.processEntriesByMessageID
        searches = model.searchesByMessageID
        memoryChanges = model.memoryChangesByMessageID
        toolActivities = model.toolActivitiesByMessageID
        connectorApps = model.connectorAppsByMessageID
        accessToken = model.authSession?.accessToken
        conversationID = model.activeConversationID
        isConversationLoadPending = model.isConversationLoadPending
        isGenerating = model.isCurrentConversationGenerating
        canRegenerate = model.selectedModel != nil && model.authSession != nil
            && !model.isCurrentConversationBusy
        error = model.currentConversationError
        editingMessageID = model.editingMessageID
        canEditMessages = model.canEditMessages
    }
}

@MainActor final class ChatTranscriptUpdates: ObservableObject {
    @Published private(set) var snapshot: TranscriptSnapshot
    private let model: AppModel
    private var subscription: AnyCancellable?
    private var assistantMessageSubscription: AnyCancellable?
    private var processEntriesSubscription: AnyCancellable?
    private var interacting = false
    private var modalVisible = false
    private var scheduled = false
    private var pending = false

    init(_ model: AppModel) {
        self.model = model
        snapshot = TranscriptSnapshot(model)
        assistantMessageSubscription = model.$messages.dropFirst().sink { [weak self] messages in
            guard let self else { return }
            if let conversationID = self.snapshot.conversationID,
               conversationID == model.activeConversationID,
               model.generatingConversationIDs.contains(conversationID) {
                // Canonical publications are first ink/media, checkpoints, or
                // terminal state. Update only already-visible streaming rows;
                // a correction must not wait for scrolling or a sheet to end.
                var next = self.snapshot
                var changed = false
                let streamingIDs = Set(next.messages.lazy.filter {
                    $0.role == .assistant && ($0.localGenerationState == .streaming
                        || $0.localGenerationState == .completedPendingPersistence)
                }.map(\.id))
                for message in messages where message.role == .assistant
                    && (streamingIDs.contains(message.id) || message.localGenerationState == .streaming
                        || message.localGenerationState == .completedPendingPersistence) {
                    guard let index = next.messages.firstIndex(where: { $0.id == message.id }),
                          next.messages[index] != message else { continue }
                    next.messages[index] = message
                    changed = true
                }
                if changed { self.snapshot = next; return }
            }
            guard !self.interacting, !self.modalVisible,
                  let last = messages.last, last.role == .assistant, !last.content.isEmpty,
                  self.snapshot.messages.first(where: { $0.id == last.id })?.content.isEmpty != false else { return }
            // Use the publisher's new value in this same actor turn: @Published
            // fires before the stored array changes. First ink need not wait
            // for an additional main-queue hop.
            var next = TranscriptSnapshot(model)
            next.messages = messages
            self.snapshot = next
        }
        processEntriesSubscription = model.$processEntriesByMessageID.dropFirst().sink { [weak self] entries in
            guard let self, self.snapshot.conversationID == model.activeConversationID else { return }
            // Publish each streamed process delta in this main-actor turn. Scroll
            // anchoring and bottom-follow stay owned by ChatScrollController.
            var next = self.snapshot
            next.processEntries = entries
            self.snapshot = next
        }
        let changes: [AnyPublisher<Void, Never>] = [
            model.$messages.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$editingMessageID.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$queuedCommands.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$searchesByMessageID.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$memoryChangesByMessageID.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$toolActivitiesByMessageID.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$connectorAppsByMessageID.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$activeConversationID.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$isConversationLoadPending.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$generatingConversationIDs.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$modelOutputCompletedConversationIDs.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$conversationErrors.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$selectedModelID.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$models.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$customModelEndpoints.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$authSession.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()
        ]
        subscription = Publishers.MergeMany(changes).sink { [weak self] _ in self?.schedule() }
    }

    func setInteracting(_ active: Bool) {
        interacting = active
        if !active, !modalVisible, pending { schedule() }
    }

    func setModalVisible(_ active: Bool) {
        modalVisible = active
        if !active, !interacting, pending { schedule() }
    }

    private func schedule() {
        pending = true
        // While UIKit owns an active drag or deceleration, defer non-stream layout state.
        // Live processEntries publish separately without changing the scroll target.
        if (interacting || modalVisible), snapshot.conversationID == model.activeConversationID { return }
        guard !scheduled else { return }
        scheduled = true
        // @Published sends before the model changes; read once after the write.
        // Only non-stream state takes this next-turn snapshot. Text and public
        // summary deltas publish synchronously through processEntriesSubscription.
        let delay: DispatchTimeInterval = .milliseconds(0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            guard !(self.interacting || self.modalVisible)
                    || self.snapshot.conversationID != self.model.activeConversationID else { return }
            self.pending = false
            let next = TranscriptSnapshot(self.model)
            // Avoid synthesized Equatable here: comparing snapshots walks the
            // complete transcript, including every historical message body,
            // on every streamed output update.
            self.snapshot = next
        }
    }
}

private struct AssistantResponseFooter: View {
    @StateObject private var presentation: AssistantFooterPresentation
    private let positionID: UUID
    let isSuspended: Bool
    @Environment(\.chatScrollController) private var scrollController

    init(appModel: AppModel, messageID: UUID, isSuspended: Bool) {
        _presentation = StateObject(wrappedValue: AssistantFooterPresentation(appModel, messageID: messageID))
        self.positionID = messageID
        self.isSuspended = isSuspended
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            StableDotCompanion(isGenerating: presentation.isGenerating, isSuspended: isSuspended,
                controller: scrollController, positionID: positionID)
                .frame(width: 48, height: 48)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }
}

// Artwork and internal motion are unchanged; only placement is compensated
// while newly wrapped text and the transcript scroll catch up with each other.
private struct StableDotCompanion: UIViewRepresentable {
    let isGenerating: Bool
    let isSuspended: Bool
    let controller: ChatScrollController?
    let positionID: UUID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeUIView(context: Context) -> DotAnimationSurface { DotAnimationSurface() }
    func updateUIView(_ view: DotAnimationSurface, context: Context) {
        view.configure(isGenerating: isGenerating, reduceMotion: reduceMotion, isSuspended: isSuspended,
                       positionID: positionID)
        controller?.registerCompanion(view)
        KeyboardMotionAudit.companionView = view
    }
    static func dismantleUIView(_ view: DotAnimationSurface, coordinator: ()) {
        view.stop(); view.transform = .identity
    }
}

// Scroll position remains native during user interaction. Live process entries
// publish separately; ChatScrollController owns follow and reading-anchor motion.
@MainActor final class AssistantFooterPresentation: ObservableObject {
    @Published private(set) var isGenerating: Bool
    @Published private(set) var showsDisclaimer: Bool
    private var subscription: AnyCancellable?

    init(_ model: AppModel, messageID: UUID) {
        isGenerating = Self.isGenerating(model, messageID: messageID)
        showsDisclaimer = Self.showsDisclaimer(model, messageID: messageID)
        let changes: [AnyPublisher<Void, Never>] = [
            model.$messages.map { $0.last?.id }.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$messages.map { $0.last.map { $0.completedReplyIsVisible && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false }
                .removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$activeConversationID.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$generatingConversationIDs.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            model.$modelOutputCompletedConversationIDs.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher()
        ]
        subscription = Publishers.MergeMany(changes)
            .receive(on: DispatchQueue.main)
            .map { [weak model] _ in
                guard let model else { return FooterState(isGenerating: false, showsDisclaimer: false) }
                return FooterState(isGenerating: Self.isGenerating(model, messageID: messageID),
                    showsDisclaimer: Self.showsDisclaimer(model, messageID: messageID))
            }
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                if self.isGenerating != state.isGenerating { self.isGenerating = state.isGenerating }
                if self.showsDisclaimer != state.showsDisclaimer { self.showsDisclaimer = state.showsDisclaimer }
            }
    }

    private static func isGenerating(_ model: AppModel, messageID: UUID) -> Bool {
        model.isCurrentConversationGenerating && model.messages.last?.id == messageID
    }
    private struct FooterState: Equatable { let isGenerating: Bool; let showsDisclaimer: Bool }
    private static func showsDisclaimer(_ model: AppModel, messageID: UUID) -> Bool {
        guard !model.isCurrentConversationGenerating,
              let message = model.messages.last(where: { $0.role == .assistant }), message.id == messageID else { return false }
        return message.completedReplyIsVisible && !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct LatestMessageButton: View {
    @ObservedObject var controller: ChatScrollController
    var body: some View {
        if !controller.latestVisible {
            HeaderActionButton(action: { controller.jumpToLatest() }) {
                Image(systemName: "arrow.down")
                    .font(MyChatSystemFont.appFont(size: 18, weight: .medium))
            }
            .frame(width: 44, height: 44)
            .modifier(MyChatFloatingSurface(shape: Circle()))
            .accessibilityLabel("跳到最新消息")
            .accessibilityIdentifier("chat.jump-to-latest")
        }
    }
}

private struct ChatScrollControllerKey: EnvironmentKey {
    static let defaultValue: ChatScrollController? = nil
}
private extension EnvironmentValues {
    var chatScrollController: ChatScrollController? {
        get { self[ChatScrollControllerKey.self] }
        set { self[ChatScrollControllerKey.self] = newValue }
    }
}

struct ChatComposerGeometry: Equatable {
    let bottomPadding: CGFloat
    let topInWindow: CGFloat?
}

/// Ephemeral, account-scoped UI state only. It never changes a generation,
/// persists message text or stores a private conversation's reading position.
@MainActor final class ChatReadingPositionStore {
    struct Position {
        let offset: CGFloat
        let anchorID: UUID?
        let anchorDistance: CGFloat
        let following: Bool
        let explicitBottom: Bool
    }
    private var owner: String?
    private var positions: [UUID: Position] = [:]
    private var recency: [UUID] = []
    func setOwner(_ owner: String?) {
        guard self.owner != owner else { return }
        self.owner = owner; positions.removeAll(); recency.removeAll()
    }
    func position(for id: UUID) -> Position? { positions[id] }
    func save(_ position: Position, for id: UUID) {
        positions[id] = position
        recency.removeAll { $0 == id }; recency.append(id)
        if recency.count > 64 { positions.removeValue(forKey: recency.removeFirst()) }
    }
}

private struct ReadingAnchorMarker: UIViewRepresentable {
    let messageID: UUID
    let controller: ChatScrollController
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.isUserInteractionEnabled = false
        controller.registerReadingAnchor(view, id: messageID)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        controller.registerReadingAnchor(view, id: messageID)
    }
}

/// The transcript reserves keyboard space in its content. Its real last row
/// must end above the input exactly once, even if a navigation controller also
/// changes the scroll viewport or installs a keyboard content inset.
enum ChatBottomAnchor {
    static func offset(contentHeight: CGFloat, bottomPadding: CGFloat,
                       viewport: CGRect, composerTop: CGFloat, topInset: CGFloat) -> CGFloat {
        let bodyBottom = max(0, contentHeight - max(0, bottomPadding))
        let visibleBottom = min(viewport.maxY, max(viewport.minY, composerTop - 8))
        return max(-topInset, bodyBottom - (visibleBottom - viewport.minY))
    }
}

/// Follow the end of the reply at eye level, with scrollable space below it.
/// Short transcripts keep their natural top position rather than being pulled up.
enum ChatReadingAnchor {
    static func readingHeight(viewport: CGRect, composerTop: CGFloat?) -> CGFloat {
        let visibleBottom = min(viewport.maxY, composerTop.map { max(viewport.minY, $0 - 8) } ?? viewport.maxY)
        return max(0, visibleBottom - viewport.minY) * (2.0 / 3.0)
    }

    static func bottomPadding(viewport: CGRect, composerTop: CGFloat?, minimum: CGFloat) -> CGFloat {
        max(minimum, viewport.height - readingHeight(viewport: viewport, composerTop: composerTop))
    }

    static func offset(contentHeight: CGFloat, bottomPadding: CGFloat,
                       viewport: CGRect, composerTop: CGFloat?, topInset: CGFloat) -> CGFloat {
        let bodyBottom = max(0, contentHeight - max(0, bottomPadding))
        return max(-topInset, bodyBottom - readingHeight(viewport: viewport, composerTop: composerTop))
    }
}

@MainActor final class ChatScrollController: NSObject, ObservableObject {
    @Published private(set) var latestVisible = true
    private weak var scrollView: UIScrollView?
    private var observations: [NSKeyValueObservation] = []
    private var conversationID: UUID?
    private var conversationLoadPending = false
    private var followingLatest = true
    private var explicitBottomFollow = false
    private var generationActive = false
    private var completedCompanionFollow = false
    private var interactionActive = false
    private var drawerInteractionActive = false
    private var followScheduled = false
    private var visibilityScheduled = false
    private var followDisplayLink: CADisplayLink?
    private var previousFollowTimestamp: CFTimeInterval?
    private var followPaused = false
    private var initialPositionPending = true
    private var idleFollowResponseTime: Double = 0.1
    private var composerGeometry = ChatComposerGeometry(bottomPadding: 0, topInWindow: nil)
    private var laidOutBodyBottom: CGFloat?
    private var keyboardMotionUntil: CFTimeInterval = 0
    var presentedComposerTop: (() -> CGFloat?)?
    private let companions = NSHashTable<UIView>.weakObjects()
    var onInteractionChanged: (Bool) -> Void = { _ in }
    var onViewportChanged: (CGRect) -> Void = { _ in }
    private var lastPublishedViewport: CGRect?
    private var viewportPublicationScheduled = false
    var keyboardIsMoving: Bool { CACurrentMediaTime() < keyboardMotionUntil }
    var viewportInWindow: CGRect? {
        guard let scrollView, let window = scrollView.window else { return nil }
        let measured = scrollView.convert(scrollView.bounds, to: window)
        return CGRect(x: 0, y: measured.minY, width: measured.width, height: measured.height)
    }
    private var deferredPublications: [UUID: () -> Void] = [:]
    private var legacyIdleTask: Task<Void, Never>?
    private var readingPositions = ChatReadingPositionStore()
    private var remembersPosition = true
    private var pendingRestoration: ChatReadingPositionStore.Position?
    private var restorationScheduled = false
    private final class WeakAnchor { weak var view: UIView?; init(_ view: UIView) { self.view = view } }
    private var readingAnchors: [UUID: WeakAnchor] = [:]

    func useReadingPositions(_ store: ChatReadingPositionStore, remembersPosition: Bool) {
        guard readingPositions !== store || self.remembersPosition != remembersPosition else { return }
        readingPositions = store; self.remembersPosition = remembersPosition
        restoreConversationPosition()
    }

    func registerReadingAnchor(_ view: UIView, id: UUID) {
        readingAnchors[id] = WeakAnchor(view)
        if pendingRestoration?.anchorID == id { scheduleRestoration() }
    }

    private func rememberReadingPosition() {
        guard remembersPosition, let conversationID, let scrollView,
              scrollView.contentSize.height > 0, pendingRestoration == nil else { return }
        readingAnchors = readingAnchors.filter { $0.value.view != nil }
        let top = scrollView.contentOffset.y + scrollView.adjustedContentInset.top + 74
        let anchor = readingAnchors.compactMap { id, weakAnchor -> (UUID, CGRect)? in
            guard let view = weakAnchor.view, view.window != nil, view.bounds.height > 0 else { return nil }
            let frame = view.convert(view.bounds, to: scrollView)
            return frame.maxY > top && frame.minY < scrollView.contentOffset.y + scrollView.bounds.height ? (id, frame) : nil
        }.min { $0.1.minY < $1.1.minY }
        readingPositions.save(.init(offset: scrollView.contentOffset.y, anchorID: anchor?.0,
            anchorDistance: (anchor?.1.minY ?? scrollView.contentOffset.y) - scrollView.contentOffset.y,
            following: followingLatest, explicitBottom: explicitBottomFollow), for: conversationID)
    }

    private func restoreConversationPosition() {
        guard remembersPosition, let conversationID,
              let position = readingPositions.position(for: conversationID) else { return }
        followingLatest = position.following
        explicitBottomFollow = position.explicitBottom
        if !position.following {
            initialPositionPending = false
            stopSmoothFollow()
            pendingRestoration = position
            scheduleRestoration()
        }
    }

    private func scheduleRestoration() {
        guard pendingRestoration != nil, !restorationScheduled else { return }
        restorationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.restorationScheduled = false
            guard let position = self.pendingRestoration, !self.nativeInteractionActive,
                  let scroll = self.scrollView, scroll.window != nil, scroll.contentSize.height > 0 else { return }
            let anchor = position.anchorID.flatMap { self.readingAnchors[$0]?.view }
            let anchorReady = anchor?.window != nil && (anchor?.bounds.height ?? 0) > 0
            let target = anchorReady
                ? anchor!.convert(anchor!.bounds, to: scroll).minY - position.anchorDistance : position.offset
            let maximum = max(-scroll.adjustedContentInset.top,
                scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            let offset = min(maximum, max(-scroll.adjustedContentInset.top, target))
            if abs(scroll.contentOffset.y - offset) > 0.5 {
                scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: offset), animated: false)
            }
            if anchorReady || position.anchorID == nil { self.pendingRestoration = nil }
            self.publishVisibility()
        }
    }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardGeometryWillChange),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func keyboardGeometryWillChange(_ note: Notification) {
        let duration = KeyboardTransitionTiming(note).duration
        idleFollowResponseTime = max(0.06, min(0.18, duration / 3))
        keyboardMotionUntil = CACurrentMediaTime() + duration + 0.05
        startSmoothFollow()
    }

    func registerCompanion(_ view: UIView) {
        companions.add(view)
        updateCompanions()
    }

    private func updateCompanions() {
        let correction = (generationActive || completedCompanionFollow) && followingLatest && !nativeInteractionActive
            ? -(followOffset - (scrollView?.contentOffset.y ?? 0)) : 0
        for view in companions.allObjects {
            view.transform = CGAffineTransform(translationX: 0, y: correction)
            (view as? DotAnimationSurface)?.synchronizeCompletedPlacement()
        }
    }

    func setLaidOutBodyBottom(_ bottom: CGFloat) {
        guard bottom.isFinite, bottom >= 0, laidOutBodyBottom != bottom else { return }
        laidOutBodyBottom = bottom
        updateCompanions()
        contentGeometryChanged()
    }

    func publishWhenIdle(id: UUID, _ action: @escaping () -> Void) {
        if nativeInteractionActive { deferredPublications[id] = action }
        else { action() }
    }

    private func flushDeferredPublications() {
        guard !nativeInteractionActive else { return }
        let actions = Array(deferredPublications.values)
        deferredPublications.removeAll()
        actions.forEach { $0() }
    }

    func attach(_ scrollView: UIScrollView, conversationID: UUID?, loadPending: Bool = false) {
        let loadStateChanged = conversationLoadPending != loadPending
        conversationLoadPending = loadPending
        if loadPending && followingLatest {
            initialPositionPending = true
            stopSmoothFollow()
        }
        publishViewportAfterLayout()
        if self.scrollView !== scrollView {
            initialPositionPending = true
            stopSmoothFollow()
            observations.removeAll()
            self.scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(legacyPanChanged))
            self.scrollView = scrollView
            scrollView.panGestureRecognizer.addTarget(self, action: #selector(legacyPanChanged))
            scrollView.decelerationRate = .normal
            observations = [
                scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.contentGeometryChanged() } },
                scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.offsetChanged() } },
                scrollView.observe(\.bounds, options: [.old, .new]) { [weak self] _, change in
                    guard change.oldValue?.size != change.newValue?.size else { return }
                    MainActor.assumeIsolated {
                        if change.oldValue?.width != change.newValue?.width, self?.followingLatest == false {
                            self?.restoreConversationPosition()
                        }
                        self?.contentGeometryChanged()
                    }
                }
            ]
            DispatchQueue.main.async { [weak self, weak scrollView] in
                guard let self, scrollView != nil else { return }
                self.logScrollGeometry("attach")
            }
            followingLatest = generationActive ? isNearBottom : true
            scheduleFollow()
        }
        if self.conversationID != conversationID {
            completedCompanionFollow = false
            pendingRestoration = nil
            laidOutBodyBottom = nil
            stopSmoothFollow()
            scrollView.setContentOffset(scrollView.contentOffset, animated: false)
            initialPositionPending = true
            explicitBottomFollow = false
            self.conversationID = conversationID
            followingLatest = true
            setInteractionActive(false)
            restoreConversationPosition()
            scheduleFollow()
        }
        if loadStateChanged && !loadPending { scheduleFollow() }
    }

    func setGenerationActive(_ active: Bool) {
        guard generationActive != active else { return }
        generationActive = active
        completedCompanionFollow = !active
        if active {
            if followingLatest { startSmoothFollow() }
        } else if followingLatest {
            startSmoothFollow()
        }
        publishVisibility()
    }

    func setComposerGeometry(_ geometry: ChatComposerGeometry) {
        guard geometry != composerGeometry else { return }
        composerGeometry = geometry
        resumeFollowIfNeeded()
    }

    func setInteractionActive(_ active: Bool) {
        guard interactionActive != active else { return }
        interactionActive = active
        onInteractionChanged(active || drawerInteractionActive)
        if active {
            pendingRestoration = nil
            followingLatest = false
            explicitBottomFollow = false
            stopSmoothFollow()
        }
        else {
            // Releasing a drag preserves the chosen reading position. Only
            // the explicit latest-message action resumes automatic following.
            DispatchQueue.main.async { [weak self] in
                self?.flushDeferredPublications()
                self?.rememberReadingPosition()
                self?.publishVisibility()
                self?.resumeFollowIfNeeded()
            }
        }
    }

    @objc private func legacyPanChanged(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            legacyIdleTask?.cancel()
            setInteractionActive(true)
        case .ended, .cancelled:
            if #available(iOS 18.0, *) { return }
            legacyIdleTask?.cancel()
            legacyIdleTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                    guard let self, let scroll = self.scrollView else { return }
                    if !scroll.isTracking && !scroll.isDragging && !scroll.isDecelerating {
                        self.setInteractionActive(false)
                        return
                    }
                }
            }
        default: break
        }
    }

    func setDrawerInteractionActive(_ active: Bool) {
        guard drawerInteractionActive != active else { return }
        drawerInteractionActive = active
        onInteractionChanged(active || interactionActive)
        if active { stopSmoothFollow() }
        if !active {
            DispatchQueue.main.async { [weak self] in
                self?.flushDeferredPublications()
                self?.resumeFollowIfNeeded()
            }
        }
    }

    private var nativeInteractionActive: Bool {
        if drawerInteractionActive || interactionActive { return true }
        guard let scrollView else { return false }
        return scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
    }

    private var readingOffset: CGFloat {
        guard let scrollView else { return 0 }
        let composerTop = scrollView.window == nil ? nil
            : (presentedComposerTop?() ?? composerGeometry.topInWindow).flatMap { $0.isFinite ? $0 : nil }
        let viewport = scrollView.window.map { scrollView.convert(scrollView.bounds, to: $0) }
            ?? CGRect(origin: .zero, size: scrollView.bounds.size)
        // Measure the body without padding in its own layout transaction;
        // mixing a new reservation with an old contentSize made targets jump.
        let desired = ChatReadingAnchor.offset(contentHeight: laidOutBodyBottom ?? scrollView.contentSize.height,
            bottomPadding: laidOutBodyBottom == nil ? composerGeometry.bottomPadding : 0,
            viewport: viewport,
            composerTop: composerTop, topInset: scrollView.adjustedContentInset.top)
        let physicalMaximum = max(-scrollView.adjustedContentInset.top,
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
        return min(desired, physicalMaximum)
    }

    private var followOffset: CGFloat {
        guard explicitBottomFollow, let scrollView else { return readingOffset }
        // Explicit bottom means the complete, currently laid-out scroll range,
        // including the extra reading space and adjusted content insets.
        return max(-scrollView.adjustedContentInset.top,
            scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
    }

    fileprivate func logScrollGeometry(_ label: String) {
        guard MyChatLayoutAudit.enabled, let scrollView else { return }
        MyChatLayoutAudit.record("scroll-\(label)",
            frame: CGRect(x: scrollView.adjustedContentInset.bottom, y: scrollView.contentSize.height,
                width: scrollView.bounds.width, height: scrollView.bounds.height),
            detail: "offset=\(scrollView.contentOffset) content=\(scrollView.contentSize) bounds=\(scrollView.bounds.size) adjustedBottom=\(scrollView.adjustedContentInset.bottom) insetBottom=\(scrollView.contentInset.bottom)")
    }

    private var isNearBottom: Bool {
        guard let scrollView else { return true }
        return readingOffset - scrollView.contentOffset.y < 48
    }

    private func offsetChanged() {
        updateCompanions()
        if nativeInteractionActive {
            // The drawer also pauses scrolling, but its inset/layout changes
            // are not a request to abandon reading follow. Vertical intent is
            // owned exclusively by setInteractionActive / the native pan.
            stopSmoothFollow()
            // UIKit owns drag and deceleration. Do not enqueue SwiftUI work
            // for every offset tick or change transcript height mid-fling.
            return
        }
        flushDeferredPublications()
        publishVisibility()
    }

    private func publishVisibility() {
        let visible = followingLatest || isNearBottom
        guard latestVisible != visible, !visibilityScheduled else { return }
        visibilityScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.visibilityScheduled = false
            let visible = self.followingLatest || self.isNearBottom
            // Crossing this boundary is the only scroll-position publication.
            // Scrolling never invalidates the message tree on every frame.
            if self.latestVisible != visible { self.latestVisible = visible }
        }
    }

    private func contentGeometryChanged() {
        publishViewportAfterLayout()
        if pendingRestoration != nil { scheduleRestoration(); return }
        if conversationLoadPending {
            if followingLatest { initialPositionPending = true; stopSmoothFollow() }
            return
        }
        guard followingLatest else {
            publishVisibility()
            return
        }
        if generationActive { startSmoothFollow() }
        else { scheduleFollow() }
    }

    private func publishViewportAfterLayout() {
        guard !viewportPublicationScheduled else { return }
        viewportPublicationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.viewportPublicationScheduled = false
            guard let viewport = self.viewportInWindow, viewport != self.lastPublishedViewport else { return }
            if let previous = self.lastPublishedViewport, previous.width != viewport.width, !self.followingLatest {
                self.restoreConversationPosition()
            }
            self.lastPublishedViewport = viewport
            self.onViewportChanged(viewport)
        }
    }

    private func scheduleFollow() {
        guard !followPaused else { return }
        if conversationLoadPending {
            if followingLatest { initialPositionPending = true; stopSmoothFollow() }
            return
        }
        if generationActive && !initialPositionPending {
            startSmoothFollow()
            return
        }
        guard followingLatest, !nativeInteractionActive, !followScheduled else { return }
        followScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.followScheduled = false
            if self.conversationLoadPending {
                if self.followingLatest { self.initialPositionPending = true; self.stopSmoothFollow() }
                return
            }
            // Check UIKit again at execution time. A touch may have started
            // after the layout callback scheduled this block.
            guard self.followingLatest, !self.followPaused, !self.nativeInteractionActive,
                  let scrollView = self.scrollView, scrollView.window != nil else { return }
            guard !self.generationActive || self.initialPositionPending else {
                self.startSmoothFollow()
                return
            }
            let bottom = self.followOffset
            self.logScrollGeometry("scheduleFollow bottom=\(bottom)")
            if abs(scrollView.contentOffset.y - bottom) > 0.5 {
                if self.initialPositionPending || UIAccessibility.isReduceMotionEnabled {
                    scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: bottom), animated: false)
                } else { self.startSmoothFollow() }
            }
            if scrollView.contentSize.height > 0 { self.initialPositionPending = false }
            self.publishVisibility()
        }
    }

    private func resumeFollowIfNeeded() {
        guard followingLatest, !followPaused else { return }
        if generationActive { startSmoothFollow() }
        else { scheduleFollow() }
    }

    private func startSmoothFollow() {
        guard !initialPositionPending, followDisplayLink == nil, followingLatest, !followPaused, !nativeInteractionActive,
              let scrollView, scrollView.window != nil,
              abs(followOffset - scrollView.contentOffset.y) > 0.5 || CACurrentMediaTime() < keyboardMotionUntil else { return }
        let displayLink = CADisplayLink(target: self, selector: #selector(advanceSmoothFollow(_:)))
        if #available(iOS 15.0, *) {
            displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        }
        previousFollowTimestamp = nil
        followDisplayLink = displayLink
        displayLink.add(to: .main, forMode: .common)
    }

    @objc private func advanceSmoothFollow(_ displayLink: CADisplayLink) {
        guard followingLatest, !nativeInteractionActive, let scrollView, scrollView.window != nil else {
            stopSmoothFollow()
            return
        }

        let remaining = followOffset - scrollView.contentOffset.y
        let keyboardMoving = displayLink.timestamp < keyboardMotionUntil
        guard abs(remaining) > 0.5 || keyboardMoving else {
            logScrollGeometry("smoothFollowSettled")
            stopSmoothFollow()
            publishVisibility()
            return
        }

        let elapsed = min(max(displayLink.timestamp - (previousFollowTimestamp ?? displayLink.timestamp - displayLink.duration),
                              1.0 / 120.0), 1.0 / 30.0)
        previousFollowTimestamp = displayLink.timestamp
        // UIKit already animates the keyboard: sample that presentation,
        // rather than easing toward its animated position a second time.
        let progress = keyboardMoving ? 1 : 1 - exp(-elapsed / (generationActive ? 0.06 : idleFollowResponseTime))
        let previousOffset = scrollView.contentOffset
        let nextOffset = previousOffset.y + remaining * progress
        scrollView.setContentOffset(CGPoint(x: previousOffset.x, y: nextOffset), animated: false)
        if scrollView.contentOffset.y == previousOffset.y, abs(remaining) > 0.5 {
            // UIKit can round a subpixel request back to the current offset.
            // Make bounded progress so the existing half-point stop is reachable.
            let pixel = 1 / max(1, scrollView.traitCollection.displayScale)
            let step = min(abs(remaining), pixel) * (remaining < 0 ? -1 : 1)
            scrollView.setContentOffset(CGPoint(x: previousOffset.x, y: previousOffset.y + step), animated: false)
        }
        updateCompanions()
        publishVisibility()
    }

    private func stopSmoothFollow() {
        followDisplayLink?.invalidate()
        followDisplayLink = nil
        previousFollowTimestamp = nil
    }

    func pauseFollowAnimation() {
        rememberReadingPosition()
        followPaused = true
        stopSmoothFollow()
    }

    func resumeFollowAnimation() {
        followPaused = false
        resumeFollowIfNeeded()
    }

    func jumpToLatest(animated: Bool = true) {
        guard let scrollView else { return }
        pendingRestoration = nil
        stopSmoothFollow()
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        // End the same interaction transaction used by scrolling. Directly
        // flipping the flag left the transcript frozen with stale geometry.
        setInteractionActive(false)
        flushDeferredPublications()
        scrollView.layoutIfNeeded()
        followingLatest = true
        explicitBottomFollow = true
        // Hide as soon as the explicit action is accepted. Stream following
        // keeps it hidden until the user deliberately scrolls away again.
        if !latestVisible { latestVisible = true }
        let bottom = followOffset
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: bottom),
            animated: animated && !UIAccessibility.isReduceMotionEnabled)
        publishVisibility()
        rememberReadingPosition()
    }
}

private struct NativeChatScrollObserver: UIViewRepresentable {
    let controller: ChatScrollController
    let conversationID: UUID?
    let loadPending: Bool

    func makeUIView(context: Context) -> ScrollMarker {
        let marker = ScrollMarker()
        marker.isUserInteractionEnabled = false
        marker.attach = { [weak controller] scroll in controller?.attach(scroll, conversationID: conversationID, loadPending: loadPending) }
        marker.bodyBottom = { [weak controller] bottom in controller?.setLaidOutBodyBottom(bottom) }
        marker.onLayout = { [weak controller] in controller?.logScrollGeometry("marker-layout") }
        return marker
    }
    func updateUIView(_ marker: ScrollMarker, context: Context) {
        marker.attach = { [weak controller] scroll in controller?.attach(scroll, conversationID: conversationID, loadPending: loadPending) }
        marker.bodyBottom = { [weak controller] bottom in controller?.setLaidOutBodyBottom(bottom) }
        marker.onLayout = { [weak controller] in controller?.logScrollGeometry("marker-layout") }
        marker.findScrollView()
    }

    final class ScrollMarker: UIView {
        var bodyBottom: (CGFloat) -> Void = { _ in }
        var attach: (UIScrollView) -> Void = { _ in }
        var onLayout: () -> Void = {}
        override func didMoveToWindow() { super.didMoveToWindow(); findScrollView() }
        override func layoutSubviews() { super.layoutSubviews(); findScrollView(); onLayout() }
        func findScrollView() {
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView {
                    attach(scroll); bodyBottom(convert(.zero, to: scroll).y); return
                }
                ancestor = view.superview
            }
        }
    }
}

private struct ChatScrollActivity: ViewModifier {
    let controller: ChatScrollController
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, phase in
                controller.setInteractionActive(phase == .tracking || phase == .interacting || phase == .decelerating)
            }
        } else { content }
    }
}

private struct MessageBlock: View, Equatable {
    let message: ChatMessage
    let isGenerating: Bool
    let processEntries: [ChatProcessEntry]
    let searches: [ChatToolSearch]
    let memoryChanges: [ChatMemoryEvent]
    let toolActivities: [ChatToolActivity]
    let connectorApps: [ChatConnectorAppEvent]
    let appModel: AppModel
    let showsResponseCompanion: Bool
    let companionSuspended: Bool
    let accessToken: String?
    let canRegenerate: Bool
    let removesLaterMessages: Bool
    let regenerate: () -> Void
    let openSources: () -> Void
    let openHistorySource: (String) -> Void
    let isEditingUserMessage: Bool
    let canEditUserMessage: Bool
    @State private var confirmRegeneration = false
    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var speechState: SpeechPlaybackState = .idle
    @State private var speechError: String?
    @State private var hasThoughtEntry = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message && lhs.isGenerating == rhs.isGenerating
            && lhs.processEntries == rhs.processEntries
            && lhs.searches == rhs.searches
            && lhs.memoryChanges == rhs.memoryChanges
            && lhs.toolActivities == rhs.toolActivities
            && lhs.connectorApps == rhs.connectorApps
            && lhs.showsResponseCompanion == rhs.showsResponseCompanion
            && lhs.companionSuspended == rhs.companionSuspended
            && lhs.accessToken == rhs.accessToken
            && lhs.canRegenerate == rhs.canRegenerate
            && lhs.removesLaterMessages == rhs.removesLaterMessages
            && lhs.isEditingUserMessage == rhs.isEditingUserMessage && lhs.canEditUserMessage == rhs.canEditUserMessage
    }

    var body: some View {
        switch message.role {
        case .user:
            UserMessageRow(message: message, isEditing: isEditingUserMessage, canEdit: canEditUserMessage,
                edit: { appModel.beginEditingMessage(message) })
        case .assistant:
            VStack(alignment: .leading, spacing: 3) {
            VStack(alignment: .leading, spacing: 10) {
                if showsProcessTimeline {
                    ForEach(processEntries) { entry in
                        switch entry.content {
                        case let .text(text):
                            AssistantMessageBody(text, isStreaming: isGenerating && entry.id == processEntries.last?.id,
                                messageID: message.id, completedReply: message.completedReplyIsVisible,
                                searches: searches, segmentID: entry.id)
                        case let .step(step):
                            AssistantProgressRow(label: step.label, summary: nil)
                        case .thinking:
                            // Provider reasoning is private and must never be rendered as chat copy.
                            EmptyView()
                        case let .reasoningSummary(summary):
                            AssistantProgressRow(label: "思考摘要", summary: summary)
                        case .search(_):
                            EmptyView()
                        case let .tool(activity):
                            AssistantActivityTrace(memoryChanges: [], toolActivities: [activity])
                        case let .memory(change):
                            AssistantActivityTrace(memoryChanges: [change], toolActivities: [])
                        }
                    }
                }
                if !showsProcessTimeline, (!memoryChanges.isEmpty || !toolActivities.isEmpty) {
                    AssistantActivityTrace(
                        memoryChanges: memoryChanges,
                        toolActivities: toolActivities
                    )
                }

                if !showsProcessTimeline, !message.content.isEmpty {
                    AssistantMessageBody(
                        message.content,
                        isStreaming: isGenerating,
                        messageID: message.id,
                        completedReply: message.completedReplyIsVisible,
                        reasoningSummary: ChatReasoningSummaryStorage.decode(message.thinking),
                        searches: searches
                    )
                }

                ForEach(connectorApps) { app in
                    ConnectorAppInlineCard(appModel: appModel, app: app)
                }

                if let media = message.media, !media.isEmpty {
                    VStack(spacing: 12) {
                        ForEach(Array(media.enumerated()), id: \.offset) { _, item in
                            GeneratedMediaView(media: item)
                        }
                    }
                }

                if !message.content.isEmpty, !isGenerating {
                    HStack(spacing: 0) {
                        copyButton
                        speechButton
                        messageAction("arrow.clockwise", label: "重新回复") {
                            if removesLaterMessages {
                                confirmRegeneration = true
                            } else {
                                regenerate()
                            }
                        }
                        .disabled(!canRegenerate)
                        Spacer(minLength: 8)
                        if sourceCount > 0, message.completedReplyIsVisible {
                            Button(action: openSources) {
                                HStack(spacing: 5) {
                                    HStack(spacing: -7) {
                                        ForEach(Array(sourceResults.prefix(3).enumerated()), id: \.offset) { _, result in
                                            SourceFavicon(urlString: result.url, size: 20, faviconURL: result.faviconURL)
                                        }
                                    }
                                    Text("\(sourceCount) sources")
                                        .font(MyChatSystemFont.appFont(size: 13))
                                        .lineLimit(1)
                                }.frame(minHeight: 44).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(sourceCount) sources")
                            .accessibilityIdentifier("message.sources." + message.id.uuidString)
                        }
                    }
                    .padding(.leading, -10)
                    .foregroundStyle(MyChatTheme.secondaryText)
                }
            }
                if showsResponseCompanion, !hasThoughtEntry {
                    AssistantResponseFooter(appModel: appModel, messageID: message.id, isSuspended: companionSuspended)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onPreferenceChange(ThoughtEntryPresenceKey.self) { hasThoughtEntry = $0 }
            .onDisappear { copyResetTask?.cancel() }
            .onAppear { speechState = SpeechPlaybackController.shared.state(for: message.id) }
            .onReceive(NotificationCenter.default.publisher(for: .myChatSpeechPlaybackDidChange)) { note in
                guard let messageID = note.userInfo?["messageID"] as? UUID,
                      messageID == message.id,
                      let rawState = note.userInfo?["state"] as? String,
                      let state = SpeechPlaybackState(rawValue: rawState) else { return }
                speechState = state
                speechError = note.userInfo?["error"] as? String
            }
            .alert("云端朗读失败", isPresented: Binding(
                get: { speechError != nil }, set: { if !$0 { speechError = nil } }
            )) {
                Button("使用系统朗读") {
                    speechError = nil
                    SpeechPlaybackController.shared.useSystemVoice(for: message.id)
                }
                Button("取消", role: .cancel) { speechError = nil }
            } message: {
                Text(speechError ?? "请稍后重试")
            }
            .confirmationDialog("从这一条重新回复？", isPresented: $confirmRegeneration, titleVisibility: .visible) {
                Button("重新回复", role: .destructive) { regenerate() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("会保留这条问题和之前的消息，替换这条回复及之后的对话。")
            }
        }
    }

    private var showsProcessTimeline: Bool {
        guard !processEntries.isEmpty else { return false }
        let text = processEntries.compactMap { entry -> String? in
            if case let .text(value) = entry.content { return value }; return nil
        }.joined()
        if isGenerating || message.localGenerationState == .streaming
            || message.localGenerationState == .completedPendingPersistence {
            return text.hasPrefix(message.content) || message.content.hasPrefix(text)
        }
        return !text.isEmpty && text == message.content
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = message.content
            HapticFeedback.play(.success)
            copyResetTask?.cancel()
            withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.7)) { copied = true }
            copyResetTask = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(1.6)) } catch { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { copied = false }
            }
        } label: {
            Group {
                if copied {
                    Image(systemName: "checkmark")
                        .font(MyChatSystemFont.appFont(size: 16, weight: .medium))
                } else {
                    CopyMessageGlyph()
                        .stroke(MyChatTheme.secondaryText, style: StrokeStyle(lineWidth: 1.35, lineJoin: .round))
                        .frame(width: 16, height: 17)
                }
            }
                .contentTransition(.symbolEffect(.replace))
                .scaleEffect(copied ? 1.12 : 1)
                .foregroundStyle(copied ? MyChatTheme.brand : MyChatTheme.secondaryText)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "已复制" : "复制")
        .accessibilityValue(copied ? "复制成功" : "")
    }

    private var speechButton: some View {
        Button {
            guard accessToken != nil else { return }
            HapticFeedback.impact()
            SpeechPlaybackController.shared.toggle(
                messageID: message.id,
                text: message.content,
                accessToken: { try await appModel.accessTokenForAudioPlayback() }
            )
        } label: {
            Image(systemName: speechState == .playing ? "speaker.wave.2.fill" : "speaker.wave.2")
                .font(MyChatSystemFont.appFont(size: 16, weight: .medium))
                .foregroundStyle(MyChatTheme.secondaryText)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(
                    .pulse,
                    options: .repeating,
                    isActive: (speechState == .loading || speechState == .playing) && !reduceMotion
                )
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .disabled(accessToken == nil)
        .accessibilityLabel(speechState.accessibilityLabel)
    }

    private var sourceCount: Int {
        sourceResults.count
    }

    private var sourceResults: [ChatSearchResult] {
        var seen = Set<String>()
        return searches.filter(\.isWebSearch).flatMap(\.results).filter { !$0.isHistoryReference && ["http", "https"].contains(URL(string: $0.url)?.scheme?.lowercased() ?? "") && seen.insert($0.url).inserted }
    }

    private func messageAction(
        _ symbol: String,
        label: String,
        selected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            HapticFeedback.impact()
            action()
        } label: {
            Image(systemName: selected ? "\(symbol).fill" : symbol)
                .font(MyChatSystemFont.appFont(size: 16, weight: .medium))
                .foregroundStyle(selected ? MyChatTheme.brand : MyChatTheme.secondaryText)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

}

private struct ConnectorAppInlineCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var host: ConnectorAppHostModel
    @State private var isFullscreen = false
    private let app: ChatConnectorAppEvent

    init(appModel: AppModel, app: ChatConnectorAppEvent) {
        self.app = app
        _host = StateObject(wrappedValue: ConnectorAppHostModel(appModel: appModel, app: app))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.payload.connectorName)
                        .font(MyChatTypography.chip)
                        .foregroundStyle(MyChatTheme.secondaryText)
                        .lineLimit(1)
                    Text(app.payload.toolTitle)
                        .font(MyChatTypography.cardTitle)
                        .foregroundStyle(MyChatTheme.text)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if host.canExpand {
                    Button {
                        HapticFeedback.impact()
                        host.setDisplayMode("fullscreen")
                        isFullscreen = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(MyChatSystemFont.appFont(size: 14, weight: .medium))
                            .foregroundStyle(MyChatTheme.secondaryText)
                            .frame(width: 38, height: 38)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("全屏打开连接器界面")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            appContent
        }
        .background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: MyChatTheme.chatCardRadius, style: .continuous))
        .overlay {
            if host.resource?.prefersBorder != false {
                RoundedRectangle(cornerRadius: MyChatTheme.chatCardRadius, style: .continuous)
                    .stroke(MyChatTheme.border.opacity(0.8), lineWidth: 0.7)
                    .allowsHitTesting(false)
            }
        }
        .task {
            host.updateTheme(colorScheme)
            await host.loadResource()
        }
        .onChange(of: colorScheme) { _, value in host.updateTheme(value) }
        .onChange(of: host.requestedDisplayMode) { _, mode in
            guard let mode else { return }
            isFullscreen = mode == "fullscreen"
            host.clearDisplayModeRequest()
        }
        .onChange(of: isFullscreen) { _, expanded in
            if !expanded { host.setDisplayMode("inline") }
        }
        .sheet(isPresented: $isFullscreen) {
            NavigationStack {
                Group {
                    if host.resource != nil {
                        ConnectorAppWebView(host: host)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(MyChatTheme.canvas)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .navigationTitle(app.payload.toolTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { isFullscreen = false }
                            .foregroundStyle(MyChatTheme.text)
                    }
                }
            }
            .presentationDragIndicator(.visible)
            .presentationBackground(MyChatTheme.canvas)
        }
        .confirmationDialog(
            "允许运行连接器操作？",
            isPresented: Binding(
                get: { host.pendingCall != nil },
                set: { if !$0 { host.cancelPendingCall() } }
            ),
            titleVisibility: .visible
        ) {
            Button("允许运行") { Task { await host.confirmPendingCall() } }
            Button("取消", role: .cancel) { host.cancelPendingCall() }
        } message: {
            if let pending = host.pendingCall {
                Text("\(app.payload.connectorName) · \(pending.toolName)\n\(host.pendingArgumentsSummary)")
            }
        }
        .alert(
            "连接器操作失败",
            isPresented: Binding(
                get: { host.callError != nil },
                set: { if !$0 { host.callError = nil } }
            )
        ) {
            Button("好", role: .cancel) { host.callError = nil }
        } message: {
            Text(PresentationText.plain(host.callError ?? ""))
        }
    }

    @ViewBuilder
    private var appContent: some View {
        if host.isLoading && host.resource == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
        } else if host.resource != nil {
            ConnectorAppWebView(host: host)
                .frame(height: webViewHeight)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(PresentationText.plain(host.loadError ?? "无法载入连接器界面"))
                    .font(MyChatTypography.metadata)
                    .foregroundStyle(MyChatTheme.secondaryText)
                Button("重试") {
                    Task { await host.loadResource() }
                }
                .font(MyChatTypography.button)
                .foregroundStyle(MyChatTheme.text)
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }

    private var webViewHeight: CGFloat {
        min(max(host.preferredHeight, CGFloat(180)), CGFloat(560))
    }
}

private struct ConnectorAppWebView: UIViewRepresentable {
    @ObservedObject var host: ConnectorAppHostModel

    func makeUIView(context: Context) -> WKWebView {
        host.webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}

private struct PendingConnectorAppCall: Equatable {
    let requestID: JSONValue
    let toolName: String
    let arguments: [String: JSONValue]
}

@MainActor
private final class ConnectorAppHostModel: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var resource: ChatConnectorAppResource?
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?
    @Published private(set) var preferredHeight: CGFloat = 320
    @Published private(set) var pendingCall: PendingConnectorAppCall?
    @Published private(set) var canExpand = false
    @Published private(set) var requestedDisplayMode: String?
    @Published var callError: String?

    private let appModel: AppModel
    private let app: ChatConnectorAppEvent
    private var colorScheme: ColorScheme = .light
    private var appDisplayModes = Set<String>()
    private var initialized = false
    private var webViewStorage: WKWebView?
    private var appResult: [String: Any]?

    init(appModel: AppModel, app: ChatConnectorAppEvent) {
        self.appModel = appModel
        self.app = app
        super.init()
    }

    var pendingArgumentsSummary: String {
        guard let pendingCall,
              let data = try? JSONEncoder().encode(pendingCall.arguments),
              let summary = String(data: data, encoding: .utf8) else { return "{}" }
        return String(summary.prefix(560))
    }

    var webView: WKWebView {
        if let webViewStorage { return webViewStorage }
        let contentController = WKUserContentController()
        contentController.add(WeakConnectorAppMessageHandler(host: self), name: "mcpHost")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.isOpaque = false
        view.backgroundColor = UIColor(MyChatTheme.raised)
        view.scrollView.backgroundColor = UIColor(MyChatTheme.raised)
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.isDirectionalLockEnabled = true
        view.allowsBackForwardNavigationGestures = false
        if #available(iOS 16.4, *) { view.isInspectable = false }
        webViewStorage = view
        if resource != nil { loadSandboxShell(in: view) }
        return view
    }

    func loadResource() async {
        guard resource == nil, !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let resource = try await appModel.fetchConnectorAppResource(for: app)
            guard resource.resourceUri == app.payload.resourceUri else {
                throw AccountSettingsError.invalidResponse
            }
            self.resource = resource
            if let webViewStorage { loadSandboxShell(in: webViewStorage) }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func updateTheme(_ colorScheme: ColorScheme) {
        guard self.colorScheme != colorScheme else { return }
        self.colorScheme = colorScheme
        guard initialized else { return }
        sendToApp([
            "jsonrpc": "2.0",
            "method": "ui/notifications/host-context-changed",
            "params": ["theme": themeName, "styles": ["variables": themeVariables]],
        ])
    }

    func setDisplayMode(_ mode: String) {
        guard mode == "inline" || (mode == "fullscreen" && canExpand) else { return }
        guard currentDisplayMode != mode else { return }
        currentDisplayMode = mode
        requestedDisplayMode = mode
        guard initialized else { return }
        sendToApp([
            "jsonrpc": "2.0",
            "method": "ui/notifications/host-context-changed",
            "params": ["displayMode": mode],
        ])
    }

    func clearDisplayModeRequest() { requestedDisplayMode = nil }

    func cancelPendingCall() {
        guard let pendingCall else { return }
        self.pendingCall = nil
        sendToApp([
            "jsonrpc": "2.0",
            "id": foundationValue(pendingCall.requestID),
            "error": ["code": -32000, "message": "用户拒绝了连接器操作"],
        ])
        sendToApp([
            "jsonrpc": "2.0",
            "method": "ui/notifications/tool-cancelled",
            "params": ["reason": "用户拒绝了连接器操作"],
        ])
    }

    func confirmPendingCall() async {
        guard let pendingCall else { return }
        self.pendingCall = nil
        callError = nil
        do {
            let result = try await appModel.callConnectorAppTool(
                connectorID: app.payload.connectorId,
                toolName: pendingCall.toolName,
                arguments: pendingCall.arguments
            )
            let resultObject = try jsonDictionary(result)
            sendToApp([
                "jsonrpc": "2.0",
                "id": foundationValue(pendingCall.requestID),
                "result": resultObject,
            ])
            sendToApp([
                "jsonrpc": "2.0",
                "method": "ui/notifications/tool-input",
                "params": ["arguments": pendingCall.arguments.mapValues(foundationValue)],
            ])
            sendToApp([
                "jsonrpc": "2.0",
                "method": "ui/notifications/tool-result",
                "params": resultObject,
            ])
            if result.isError == true {
                callError = result.content.first?.text ?? "连接器报告了操作错误"
            }
        } catch {
            callError = error.localizedDescription
            sendToApp([
                "jsonrpc": "2.0",
                "id": foundationValue(pendingCall.requestID),
                "error": ["code": -32000, "message": PresentationText.plain(error.localizedDescription)],
            ])
        }
    }

    fileprivate func receive(_ body: Any) {
        guard let message = body as? [String: Any],
              message["jsonrpc"] as? String == "2.0",
              let method = message["method"] as? String else { return }
        let id = message["id"].flatMap(jsonValue)
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "ui/initialize":
            guard let id else { return }
            let capabilities = params["appCapabilities"] as? [String: Any] ?? [:]
            let declared = capabilities["availableDisplayModes"] as? [String] ?? ["inline"]
            appDisplayModes = Set(declared.filter { $0 == "inline" || $0 == "fullscreen" })
            canExpand = appDisplayModes.contains("fullscreen")
            let width = max(Double(webViewStorage?.bounds.width ?? 0), 320)
            let toolInfo = (try? jsonDictionary(app.payload.tool)) ?? [:]
            let result: [String: Any] = [
                "protocolVersion": "2026-01-26",
                "hostCapabilities": ["serverTools": ["listChanged": false]],
                "hostInfo": ["name": "MyChat", "version": "1.0.0"],
                "hostContext": [
                    "toolInfo": ["tool": toolInfo],
                    "theme": themeName,
                    "styles": ["variables": themeVariables],
                    "displayMode": currentDisplayMode,
                    "availableDisplayModes": ["inline", "fullscreen"],
                    "containerDimensions": ["width": width, "maxHeight": 560],
                    "locale": Locale.current.identifier,
                    "timeZone": TimeZone.current.identifier,
                    "userAgent": "MyChat iOS",
                    "platform": "mobile",
                    "deviceCapabilities": ["touch": true, "hover": false],
                    "safeAreaInsets": ["top": 0, "right": 0, "bottom": 0, "left": 0],
                ],
            ]
            sendToApp(["jsonrpc": "2.0", "id": foundationValue(id), "result": result])

        case "ui/notifications/initialized":
            guard !initialized else { return }
            initialized = true
            sendInitialToolData()

        case "ui/notifications/size-changed":
            if let height = (params["height"] as? NSNumber)?.doubleValue, height.isFinite {
                preferredHeight = min(max(CGFloat(height), 180), 560)
            }

        case "ui/request-display-mode":
            guard let id else { return }
            let requested = params["mode"] as? String ?? ""
            if (requested == "inline" || requested == "fullscreen") && appDisplayModes.contains(requested) {
                currentDisplayMode = requested
                requestedDisplayMode = requested
                sendToApp(["jsonrpc": "2.0", "id": foundationValue(id), "result": ["mode": requested]])
                sendToApp([
                    "jsonrpc": "2.0",
                    "method": "ui/notifications/host-context-changed",
                    "params": ["displayMode": requested],
                ])
            } else {
                sendToApp(["jsonrpc": "2.0", "id": foundationValue(id), "result": ["mode": currentDisplayMode]])
            }

        case "tools/call":
            guard let id else { return }
            guard pendingCall == nil,
                  let toolName = params["name"] as? String,
                  let rawArguments = params["arguments"] as? [String: Any],
                  let arguments = jsonObject(rawArguments),
                  let encoded = try? JSONEncoder().encode(arguments),
                  encoded.count <= 160 * 1024 else {
                sendRPCError(id, code: -32602, message: "连接器工具请求无效")
                return
            }
            pendingCall = PendingConnectorAppCall(requestID: id, toolName: toolName, arguments: arguments)

        case "ping":
            if let id { sendToApp(["jsonrpc": "2.0", "id": foundationValue(id), "result": [:]]) }

        case "notifications/message", "ui/notifications/log":
            break

        default:
            if let id { sendRPCError(id, code: -32601, message: "MyChat 不支持此方法") }
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame?.isMainFrame == true,
              let url = navigationAction.request.url,
              (url.scheme == "about" || url.host == "mcpapp.invalid") else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    private var currentDisplayMode = "inline"
    private var themeName: String { colorScheme == .dark ? "dark" : "light" }
    private var themeVariables: [String: String] {
        [
            "--color-background-primary": "light-dark(#F9F9F7, #151515)",
            "--color-background-secondary": "light-dark(#FDFDFB, #1B1B1B)",
            "--color-background-tertiary": "light-dark(#EFEFED, #2E2E2C)",
            "--color-text-primary": "light-dark(#131313, #F8F8F6)",
            "--color-text-secondary": "light-dark(#686862, #B5B5AD)",
            "--color-text-tertiary": "light-dark(#80807B, #9A9A93)",
            "--color-border-primary": "light-dark(#DADAD6, #2B2B29)",
            "--color-border-secondary": "light-dark(#E8E8E4, #343432)",
            "--font-sans": "-apple-system, BlinkMacSystemFont, sans-serif",
            "--font-mono": "ui-monospace, SFMono-Regular, monospace",
        ]
    }

    private func sendInitialToolData() {
        guard initialized,
              let result = appResult ?? (try? jsonDictionary(app.payload.result)) else { return }
        sendToApp([
            "jsonrpc": "2.0",
            "method": "ui/notifications/tool-input",
            "params": ["arguments": app.payload.arguments.mapValues(foundationValue)],
        ])
        sendToApp([
            "jsonrpc": "2.0",
            "method": "ui/notifications/tool-result",
            "params": result,
        ])
        appResult = result
    }

    private func loadSandboxShell(in webView: WKWebView) {
        guard let resource else { return }
        let html = javaScriptLiteral(resource.html)
        let csp = javaScriptLiteral(contentSecurityPolicy(resource.csp))
        let shell = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,viewport-fit=cover"><style>html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden;background:transparent}iframe{display:block;width:100%;height:100%;border:0;background:transparent}</style></head><body><iframe id="mcp-app" sandbox="allow-scripts" referrerpolicy="no-referrer"></iframe><script>
        (()=>{const frame=document.getElementById('mcp-app');const rawHTML=\(html);const policy=\(csp);window.__mychatDeliver=(message)=>{if(frame.contentWindow)frame.contentWindow.postMessage(message,'*')};window.addEventListener('message',(event)=>{if(event.source!==frame.contentWindow)return;const data=event.data;if(!data||typeof data!=='object'||data.jsonrpc!=='2.0'||typeof data.method!=='string')return;window.webkit.messageHandlers.mcpHost.postMessage(data)});const parsed=new DOMParser().parseFromString(rawHTML,'text/html');for(const meta of Array.from(parsed.querySelectorAll('meta[http-equiv]'))){if((meta.getAttribute('http-equiv')||'').toLowerCase()==='content-security-policy')meta.remove()}const cspMeta=parsed.createElement('meta');cspMeta.httpEquiv='Content-Security-Policy';cspMeta.content=policy;parsed.head.prepend(cspMeta);frame.srcdoc='<!doctype html>'+parsed.documentElement.outerHTML})();
        </script></body></html>
        """
        webView.loadHTMLString(shell, baseURL: URL(string: "https://mcpapp.invalid/")!)
    }

    private func sendRPCError(_ id: JSONValue, code: Int, message: String) {
        sendToApp([
            "jsonrpc": "2.0",
            "id": foundationValue(id),
            "error": ["code": code, "message": message],
        ])
    }

    private func sendToApp(_ object: [String: Any]) {
        guard let webViewStorage,
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed]),
              var json = String(data: data, encoding: .utf8) else { return }
        json = json.replacingOccurrences(of: "</", with: "<\\/")
        webViewStorage.evaluateJavaScript("window.__mychatDeliver && window.__mychatDeliver(\(json));")
    }

    private func jsonValue(_ value: Any) -> JSONValue? {
        guard JSONSerialization.isValidJSONObject(["value": value]),
              let data = try? JSONSerialization.data(withJSONObject: ["value": value]),
              let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return nil }
        return decoded["value"]
    }

    private func jsonObject(_ value: [String: Any]) -> [String: JSONValue]? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    private func jsonDictionary<Value: Encodable>(_ value: Value) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AccountSettingsError.invalidResponse
        }
        return object
    }

    private func foundationValue(_ value: JSONValue) -> Any {
        switch value {
        case let .string(value): value
        case let .integer(value): value
        case let .number(value): value
        case let .bool(value): value
        case let .object(value): value.mapValues(foundationValue)
        case let .array(value): value.map(foundationValue)
        case .null: NSNull()
        }
    }

    private func javaScriptLiteral(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return json.replacingOccurrences(of: "<", with: "\\u003c")
    }

    private func contentSecurityPolicy(_ csp: ChatConnectorAppCSP) -> String {
        func safeOrigins(_ input: [String], schemes: Set<String>) -> [String] {
            var output: [String] = []
            for raw in input.prefix(32) {
                guard raw.utf8.count <= 512,
                      !raw.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                      let components = URLComponents(string: raw),
                      let scheme = components.scheme?.lowercased(), schemes.contains(scheme),
                      let host = components.host?.lowercased(), !host.isEmpty,
                      components.user == nil, components.password == nil,
                      components.path.isEmpty || components.path == "/",
                      components.query == nil, components.fragment == nil else { continue }
                if host.hasPrefix("*.") {
                    let suffix = host.dropFirst(2)
                    guard suffix.contains("."), suffix.split(separator: ".").allSatisfy({
                        !$0.isEmpty && $0.first != "-" && $0.last != "-"
                    }) else { continue }
                } else if host.contains("*") {
                    continue
                }
                let defaultPort = scheme == "https" ? 443 : (scheme == "wss" ? 443 : nil)
                let port = components.port.flatMap { $0 == defaultPort ? nil : $0 }
                let origin = "\(scheme)://\(host)\(port.map { ":\($0)" } ?? "")"
                if !output.contains(origin) { output.append(origin) }
            }
            return output
        }
        let connect = safeOrigins(csp.connectDomains, schemes: ["https", "wss"])
        let resources = safeOrigins(csp.resourceDomains, schemes: ["https"])
        let frames = safeOrigins(csp.frameDomains, schemes: ["https"])
        let bases = safeOrigins(csp.baseUriDomains, schemes: ["https"])
        return [
            "default-src 'none'",
            "script-src 'self' 'unsafe-inline' \(resources.joined(separator: " "))",
            "style-src 'self' 'unsafe-inline' \(resources.joined(separator: " "))",
            "connect-src 'self' \(connect.joined(separator: " "))",
            "img-src 'self' data: blob: \(resources.joined(separator: " "))",
            "font-src 'self' data: \(resources.joined(separator: " "))",
            "media-src 'self' data: blob: \(resources.joined(separator: " "))",
            "frame-src \(frames.isEmpty ? "'none'" : frames.joined(separator: " "))",
            "object-src 'none'",
            "base-uri \(bases.isEmpty ? "'self'" : bases.joined(separator: " "))",
            "form-action 'none'",
        ].joined(separator: "; ")
    }
}

@MainActor
private final class WeakConnectorAppMessageHandler: NSObject, WKScriptMessageHandler {
    weak var host: ConnectorAppHostModel?

    init(host: ConnectorAppHostModel) { self.host = host }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        host?.receive(message.body)
    }
}

private struct AssistantProgressRow: View {
    let label: String
    let summary: String?
    @State private var expanded = false
    private var previewText: String { PublicReasoningSummaryPreview.text(summary) ?? label }
    var body: some View {
        Button { if summary != nil { expanded = true } } label: {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath").font(MyChatSystemFont.appFont(size: 15))
                Text(previewText).font(MyChatTypography.appStatus).lineLimit(1)
                if summary != nil { Image(systemName: "chevron.right").font(MyChatSystemFont.appFont(size: 12)) }
            }
            .foregroundStyle(MyChatTheme.secondaryText)
            .frame(minHeight: 36, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(summary == nil)
        .accessibilityIdentifier(summary == nil ? "chat.progress.step" : "chat.progress.summary")
        .sheet(isPresented: $expanded) {
            VStack(spacing: 0) {
                ChatSheetHeader(title: "思考摘要")
                ScrollView { MarkdownBody(summary ?? "", typography: .reasoningSummary).padding(20) }
            }
            .background(MyChatTheme.canvas)
            .presentationDetents([.medium, .large]).presentationCornerRadius(34)
        }
    }
}

private struct AssistantActivityTrace: View {
    let memoryChanges: [ChatMemoryEvent]
    let toolActivities: [ChatToolActivity]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(toolActivities, id: \.toolCallID) { activity in
                HStack(spacing: 8) {
                    if activity.isComplete {
                        Image(systemName: "checkmark.circle")
                            .font(MyChatSystemFont.appFont(size: 14, weight: .regular))
                    } else {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(toolLabel(activity.toolName))
                        .lineLimit(1)
                }
            }

            ForEach(Array(memoryChanges.enumerated()), id: \.offset) { _, change in
                HStack(spacing: 8) {
                    Image(systemName: memorySymbol(change))
                        .font(MyChatSystemFont.appFont(size: 14, weight: .regular))
                    Text(memoryLabel(change))
                        .lineLimit(2)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .font(MyChatTypography.appStatus)
        .foregroundStyle(MyChatTheme.secondaryText)
        .padding(.bottom, 4)
    }

    private func toolLabel(_ rawName: String) -> String {
        switch rawName {
        case "web_search": "网页搜索"
        case "fetch_url": "读取网页"
        case "search_connector_tools": "搜索连接工具"
        case "call_connector_tool": "调用连接服务"
        case "remember", "remember_project", "update_memory", "update_project_memory", "forget", "forget_project":
            "更新记忆"
        default:
            rawName.hasPrefix("mcp_") ? "调用连接服务" : "调用工具"
        }
    }

    private func memoryLabel(_ event: ChatMemoryEvent) -> String {
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
        let topic = event.topic?.trimmingCharacters(in: .whitespacesAndNewlines)
        let topicSuffix = topic.flatMap { $0.isEmpty ? nil : $0 }
        if event.sensitive == true { return "\(action)敏感记忆" }
        return topicSuffix.map { "\(action)记忆 · \($0)" } ?? "\(action)记忆"
    }

    private func memorySymbol(_ event: ChatMemoryEvent) -> String {
        guard event.ok else { return "exclamationmark.circle" }
        return event.action == "delete" ? "checkmark.circle" : "brain"
    }
}

private struct SearchTraceView: View {
    let searches: [ChatToolSearch]
    let openAllSources: () -> Void
    let openHistorySource: (String) -> Void
    @State private var expanded = false

    private var latestQuery: String {
        PresentationText.plain(searches.last?.query ?? "")
    }

    private var latestSearchIsImages: Bool {
        searches.last?.isImageSearch == true
    }

    private var latestSearchIsHistory: Bool {
        searches.last?.kind == "history"
    }

    private var latestSearchIsConnector: Bool {
        searches.last?.kind == "connector"
    }

    private var results: [ChatSearchResult] {
        var seen = Set<String>()
        return searches
            .flatMap(\.results)
            .filter { seen.insert($0.url).inserted }
    }

    private var connectorResults: [ChatSearchResult] {
        var seen = Set<String>()
        return searches
            .filter { $0.kind == "connector" }
            .flatMap(\.results)
            .filter { seen.insert($0.url).inserted }
    }

    private var imageReferences: [MessageImageReference] {
        searchImageReferences(in: searches)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: latestSearchIsConnector
                        ? "wrench.and.screwdriver"
                        : latestSearchIsHistory ? "clock.arrow.circlepath" : latestSearchIsImages ? "photo" : "globe")
                        .font(MyChatSystemFont.appFont(size: 14, weight: .regular))
                    Text(latestSearchIsConnector
                        ? (latestQuery.isEmpty ? "已搜索连接工具" : "已搜索连接工具：“\(latestQuery)”")
                        : latestSearchIsHistory
                            ? (latestQuery.isEmpty ? "已搜索历史对话" : "已搜索历史对话：“\(latestQuery)”")
                            : latestSearchIsImages
                                ? (latestQuery.isEmpty ? "图片搜索" : "已搜索图片：“\(latestQuery)”")
                                : (latestQuery.isEmpty ? "已搜索网页" : "已搜索：“\(latestQuery)”"))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(MyChatSystemFont.appFont(for: .caption1, weight: .semibold))
                }
                        .font(MyChatTypography.metadata)
                .lineSpacing(MyChatTypography.utilityLineSpacing)
                .foregroundStyle(MyChatTheme.secondaryText)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                if latestSearchIsConnector {
                    if connectorResults.isEmpty {
                        Text("没有找到匹配的连接工具")
                            .font(MyChatTypography.caption)
                            .foregroundStyle(MyChatTheme.secondaryText)
                            .frame(minHeight: 38, alignment: .leading)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(connectorResults.prefix(8)), id: \.url) { result in
                                ConnectorToolSearchResultCard(result: result)
                            }
                        }
                    }
                } else if latestSearchIsImages {
                    if imageReferences.isEmpty {
                        Text("没有可预览的图片")
                            .font(MyChatTypography.caption)
                            .foregroundStyle(MyChatTheme.secondaryText)
                            .frame(minHeight: 38, alignment: .leading)
                    } else {
                        SearchImageCarousel(images: imageReferences)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(results.prefix(5)), id: \.url) { result in
                            if let conversationID = result.conversationID {
                                HistorySearchResultCard(result: result) {
                                    openHistorySource(conversationID)
                                }
                            } else {
                                SearchResultCard(result: result)
                            }
                        }
                        if results.count > 5 {
                            Button(action: openAllSources) {
                                Text("查看全部 \(results.count) 个来源")
                                    .font(MyChatTypography.button)
                                    .foregroundStyle(MyChatTheme.secondaryText)
                                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .transition(.opacity)
                }
            }
        }
    }
}

private struct ConnectorToolSearchResultCard: View {
    let result: ChatSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(MyChatSystemFont.appFont(size: 12, weight: .medium))
                    .foregroundStyle(MyChatTheme.secondaryText)
                Text(PresentationText.plain(result.title))
                    .font(MyChatTypography.cardBody)
                    .lineLimit(1)
            }
            if let snippet = result.snippet, !snippet.isEmpty {
                Text(PresentationText.plain(snippet))
                    .font(MyChatTypography.caption)
                    .lineLimit(2)
                    .foregroundStyle(MyChatTheme.secondaryText)
                    .padding(.leading, 20)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: MyChatTheme.chatCardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MyChatTheme.chatCardRadius, style: .continuous)
                .stroke(MyChatTheme.border.opacity(0.72), lineWidth: 0.6)
        }
        .accessibilityElement(children: .combine)
    }
}

private func searchImageReferences(in searches: [ChatToolSearch]) -> [MessageImageReference] {
    var seen = Set<String>()
    let candidates = searches.filter(\.isImageSearch).flatMap { search in
        let images = (search.images ?? []).compactMap { image -> MessageImageReference? in
            guard let url = safeExternalImageURL(image.url) else { return nil }
            return MessageImageReference(url: url.absoluteString, alt: image.description ?? "")
        }
        let thumbnails = search.results.compactMap { result -> MessageImageReference? in
            guard let thumbnailURL = result.thumbnailURL,
                  let url = safeExternalImageURL(thumbnailURL) else { return nil }
            return MessageImageReference(url: url.absoluteString, alt: result.title)
        }
        return images + thumbnails
    }
    return candidates.filter { seen.insert($0.url).inserted }.prefix(12).map { $0 }
}

private func safeExternalImageURL(_ value: String) -> URL? {
    guard let url = URL(string: value),
          url.scheme?.lowercased() == "https",
          let host = url.host?.lowercased(),
          host != "localhost", !host.hasSuffix(".local"),
          host != "127.0.0.1", host != "::1" else { return nil }
    return url
}

struct ThinkingOrbitalIndicator: View {
    var body: some View { DotThinkingView().frame(width: 48, height: 48) }
}

private struct UserMessageRow: View {
    let message: ChatMessage
    let isEditing: Bool
    let canEdit: Bool
    let edit: () -> Void
    @State private var selectingText = false
    @State private var cardFrame: CGRect = .zero

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 0)
            UserMessageCard(message: message)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    cardFrame = frame
                }
                .contextMenu {
                    Section {
                        Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.content }
                        Button("选择文本", systemImage: "text.cursor") { selectingText = true }
                        Button("编辑", systemImage: "pencil", action: edit).disabled(!canEdit)
                    } header: { Text(message.createdAt.formatted(.dateTime.hour().minute())) }
                } preview: {
                    UserMessageCard(message: message)
                        .frame(width: max(44, min(360, cardFrame.width)), alignment: .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 360, alignment: .trailing)
        }
        // The transcript supplies the viewport's finite width. Expand this
        // row to that width first, then let the spacer anchor every user
        // payload (text, files, and images) to the same trailing edge.
        .frame(maxWidth: .infinity, alignment: .trailing)
        if isEditing {
            Text("编辑这条消息后，对话将从这里重新开始。")
                .font(MyChatSystemFont.appFont(size: 13)).foregroundStyle(MyChatTheme.secondaryText)
                .multilineTextAlignment(.trailing).frame(maxWidth: 340, alignment: .trailing)
        }
        }
        .sheet(isPresented: $selectingText) { MessageTextSelectionSheet(text: message.content) }
    }
}

private struct MessageTextSelectionSheet: View {
    let text: String
    var body: some View {
        VStack(spacing: 0) {
            ChatSheetHeader(title: "选择文本")
            SelectableMessageText(text: text).padding(.horizontal, 16)
        }.background(MyChatTheme.canvas).presentationDetents([.large]).presentationCornerRadius(42)
    }
}
private struct SelectableMessageText: UIViewRepresentable {
    let text: String
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(); view.text = text; view.isEditable = false; view.isSelectable = true
        view.backgroundColor = .clear; view.textColor = UIColor(MyChatTheme.text)
        view.font = MyChatSystemFont.appUIFont(size: 17)
        view.accessibilityIdentifier = "message.selectable-text"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak view] in
            guard let view, view.window != nil else { return }
            view.becomeFirstResponder(); view.selectAll(nil)
        }
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {}
}

private struct UserMessageCard: View {
    let message: ChatMessage
    @State private var selectedImage: ChatImagePreviewItem?

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let images = message.sourceImages, !images.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(Array(images.enumerated()), id: \.offset) { index, source in
                            ChatSourceImage(source: source) {
                                selectedImage = ChatImagePreviewItem(source: source)
                            }
                            .accessibilityLabel("查看第 \(index + 1) 张图片，共 \(images.count) 张")
                            .accessibilityIdentifier("message.image.\(message.id).\(index)")
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxWidth: min(360, CGFloat(images.count) * 104 + CGFloat(images.count - 1) * 8))
                .frame(height: 104)
            }

            if let files = message.filePreviews, !files.isEmpty {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(140), spacing: 8), count: min(files.count, 2)), alignment: .trailing, spacing: 8) {
                    ForEach(files) { file in UploadedFileCard(file: file) }
                }
                .frame(width: CGFloat(min(files.count, 2)) * 140 + (files.count > 1 ? 8 : 0), alignment: .trailing)
            }

            if (message.filePreviews?.isEmpty ?? true), let names = message.attachedFileNames, !names.isEmpty {
                ForEach(names, id: \.self) { name in
                    Label(name, systemImage: name.lowercased().hasSuffix(".pdf") ? "doc.richtext" : "doc.text")
                        .font(MyChatSystemFont.appFont(for: .caption1, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(minHeight: 38)
                        .background(MyChatTheme.raised.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                }
            }

            if !message.content.isEmpty {
                MarkdownBody(message.content, fillsWidth: false, typography: .user)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(MyChatTheme.userBubble, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
        }
        .fullScreenCover(item: $selectedImage) { item in
            ChatImagePreview(source: item.source)
        }
    }
}

private struct CopyMessageGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(in: CGRect(x: 0, y: 0, width: rect.width * 0.72, height: rect.height * 0.75), cornerSize: CGSize(width: 1.2, height: 1.2))
        path.addRoundedRect(in: CGRect(x: rect.width * 0.28, y: rect.height * 0.25, width: rect.width * 0.72, height: rect.height * 0.75), cornerSize: CGSize(width: 1.2, height: 1.2))
        return path
    }
}

private struct ChatImagePreviewItem: Identifiable {
    let id = UUID()
    let source: String
}

private struct ChatSourceImage: View {
    let source: String
    let open: () -> Void
    @State private var localImage: UIImage?
    @State private var localLoadFinished = false
    @State private var reloadID = UUID()

    var body: some View {
        Button(action: open) {
            Group {
                if let image = localImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else if let url = URL(string: source), url.scheme?.lowercased() == "https" {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case let .success(image): image.resizable().scaledToFill()
                        case .failure: imageFailure
                        default: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .id(reloadID)
                } else if source.hasPrefix("data:image/"), !localLoadFinished {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    imageFailure
                }
            }
            // Fixed geometry before and after decoding prevents the transcript
            // moving when a portrait photo replaces its loading placeholder.
            .frame(width: 104, height: 104)
            .background(MyChatTheme.selected)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("放大查看图片")
        .contextMenu {
            Button("重新加载图片", systemImage: "arrow.clockwise") { reloadID = UUID() }
        }
        .task(id: source) {
            localImage = nil; localLoadFinished = false
            let image = await Task.detached(priority: .userInitiated) { ChatImageThumbnailCache.image(source) }.value
            guard !Task.isCancelled else { return }
            localImage = image; localLoadFinished = true
        }
    }

    private var imageFailure: some View {
        Image(systemName: "photo.badge.exclamationmark")
            .font(MyChatSystemFont.appFont(size: 19, weight: .regular))
            .foregroundStyle(MyChatTheme.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum ChatImageThumbnailCache {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>(); cache.countLimit = 24; cache.totalCostLimit = 16 * 1024 * 1024; return cache
    }()
    static func image(_ source: String) -> UIImage? {
        if let image = cache.object(forKey: source as NSString) { return image }
        guard let comma = source.firstIndex(of: ","),
              let bytes = Data(base64Encoded: String(source[source.index(after: comma)...])),
              let cgSource = CGImageSourceCreateWithData(bytes as CFData, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(cgSource, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 600
              ] as CFDictionary) else { return nil }
        let image = UIImage(cgImage: thumb)
        cache.setObject(image, forKey: source as NSString, cost: thumb.width * thumb.height * 4 + source.utf8.count)
        return image
    }
}

private struct ChatImagePreview: View {
    @Environment(\.dismiss) private var dismiss
    let source: String

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            Group {
                if let image = UIImage(dataURLSource: source) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else if let url = URL(string: source), url.scheme?.lowercased() == "https" {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case let .success(image): image.resizable().scaledToFit()
                        case .failure: Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.white)
                        default: ProgressView().tint(.white)
                        }
                    }
                } else {
                    Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(MyChatSystemFont.appFont(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 16)
            .padding(.trailing, 18)
            .accessibilityLabel("关闭图片预览")
        }
        .preferredColorScheme(.dark)
    }
}

private extension UIImage {
    convenience init?(dataURLSource: String) {
        guard let comma = dataURLSource.firstIndex(of: ","),
              dataURLSource[..<comma].lowercased().hasPrefix("data:image/"),
              let data = Data(base64Encoded: String(dataURLSource[dataURLSource.index(after: comma)...]))
        else { return nil }
        self.init(data: data)
    }
}

private struct ThoughtEntryPresenceKey: PreferenceKey {
    static var defaultValue: Bool { false }
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

private struct AssistantMessageBody: View {
    private let source: String
    private let isStreaming: Bool
    private let isThinking: Bool
    private let completedReply: Bool
    private let reasoningSummary: String?
    private let cacheKey: String
    private let responseMessageID: UUID?
    private let searches: [ChatToolSearch]
    @Environment(\.chatScrollController) private var scrollController
    @StateObject private var renderer: MessageRenderModel
    @State private var selectedArtifact: ChatArtifactBlock?
    @State private var renderSuspensionReasons: Set<String> = []

    init(
        _ source: String,
        isStreaming: Bool = false,
        messageID: UUID? = nil,
        thinking: Bool = false,
        completedReply: Bool = true,
        reasoningSummary: String? = nil,
        searches: [ChatToolSearch] = [],
        segmentID: String? = nil
    ) {
        let clean = thinking ? PresentationText.rich(source) : source
        self.source = clean
        self.isStreaming = isStreaming
        isThinking = thinking
        self.completedReply = completedReply
        self.reasoningSummary = reasoningSummary
        self.searches = searches
        let key = ChatPresentationCache.key(messageID: messageID, source: clean, thinking: thinking)
            + (segmentID.map { ":" + $0 } ?? "")
        cacheKey = key
        responseMessageID = messageID
        _renderer = StateObject(wrappedValue: MessageRenderModel(key: key, source: clean, isStreaming: isStreaming))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
                if let document = firstDocument {
                    DocumentThoughtRow(summary: document.summary, reasoningSummary: reasoningSummary, isGenerating: isStreaming)
                } else if let reasoningSummary, !reasoningSummary.isEmpty {
                    DocumentThoughtRow(summary: nil, reasoningSummary: reasoningSummary, isGenerating: isStreaming)
                }
                ForEach(presentedBlocks.enumerated().map { MessageBlockSlot(index: $0.offset, block: $0.element) }) { slot in
                    if case let .artifact(artifact) = slot.block {
                        artifactContent(artifact)
                    } else {
                        MessageMarkdownBlockView(block: slot.block, searches: searches, thinking: isThinking).equatable()
                    }
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .preference(key: ThoughtEntryPresenceKey.self,
            value: firstDocument != nil || reasoningSummary?.isEmpty == false)
        .environment(\.responseIsStreaming, isStreaming)
        .environment(\.responseMessageID, responseMessageID)
        .task(id: MessageRenderInput(source: source, isStreaming: isStreaming)) {
            await renderer.update(key: cacheKey, source: source, isStreaming: isStreaming, scrollController: scrollController)
        }
        .onChange(of: hasPresentedMarkdown, initial: true) { _, published in
            guard published, isStreaming, let responseMessageID else { return }
            ChatGenerationDiagnostics.markFirstMarkdownPublished(
                assistantMessageID: responseMessageID,
                receivedAt: ProcessInfo.processInfo.systemUptime
            )
        }
        .onChange(of: isStreaming, initial: true) { _, active in
            guard active, hasPresentedMarkdown, let responseMessageID else { return }
            ChatGenerationDiagnostics.markFirstMarkdownPublished(
                assistantMessageID: responseMessageID,
                receivedAt: ProcessInfo.processInfo.systemUptime
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .myChatDrawerInteractionChanged)) { note in
            setRenderSuspended("drawer", active: note.object as? Bool ?? false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .myChatModalVisibilityChanged)) { note in
            setRenderSuspended("modal", active: note.object as? Bool ?? false)
        }
        .transaction { $0.animation = nil }
        .sheet(item: $selectedArtifact, onDismiss: {
            setRenderSuspended("artifact", active: false)
        }) { artifact in
            ArtifactBlockDetail(artifact: artifact)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(34)
                .presentationBackground(MyChatTheme.canvas)
        }
    }

    private var firstDocument: ChatDocument? {
        for block in presentedBlocks {
            if case let .artifact(artifact) = block, artifact.kind == .document,
               let document = ChatDocument.from(artifact) { return document }
        }
        return nil
    }

    @ViewBuilder private func artifactContent(_ artifact: ChatArtifactBlock) -> some View {
                if artifact.kind == .document, let document = ChatDocument.from(artifact) {
                    if !isStreaming && completedReply && artifact.isComplete { GeneratedDocumentCard(document: document) }
                } else if artifact.kind == .artifact, let document = ChatDocument.from(artifact) {
                    GeneratedDocumentCard(document: document, complete: artifact.isComplete)
                } else {
                    InlineArtifactBlockView(artifact: artifact)
                }
    }

    private var presentedBlocks: [MessageMarkdownBlock] {
        renderer.document.blocks
    }

    private var hasPresentedMarkdown: Bool {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return presentedBlocks.contains { block in
            if case .artifact = block { return false }
            return true
        }
    }

    private func artifactSymbol(_ kind: ChatArtifactBlock.Kind) -> String {
        switch kind {
        case .vega: return "chart.bar"
        case .mermaid: return "point.3.connected.trianglepath.dotted"
        case .functionPlot: return "function"
        case .inlineArtifact: return "scribble.variable"
        case .artifact: return "doc.richtext"
        case .document: return "doc.text"
        }
    }

    private func setRenderSuspended(_ reason: String, active: Bool) {
        var reasons = renderSuspensionReasons
        if active { reasons.insert(reason) } else { reasons.remove(reason) }
        guard reasons != renderSuspensionReasons else { return }
        renderSuspensionReasons = reasons
        renderer.setSuspended(!reasons.isEmpty)
    }
}

private struct MessageBlockSlot: Identifiable {
    let index: Int
    let block: MessageMarkdownBlock
    var id: String {
        if case let .artifact(artifact) = block { return "artifact:" + artifact.id.uuidString }
        return "text:" + String(index)
    }
}

private struct MessageRenderInput: Hashable { let source: String; let isStreaming: Bool }
@MainActor final class MessageRenderModel: ObservableObject {
    @Published private(set) var document: RenderedMessage
    private var requestedRevision = 0
    private var submittedRevision = 0
    private var publishedRevision = 0
    private var latestRequest: RenderRequest?
    private var renderTask: Task<Void, Never>?
    private var isSuspended = false

    init(key: String, source: String, isStreaming: Bool) {
        document = ChatPresentationCache.document(key: key, source: source, streaming: isStreaming)
    }

    func update(key: String, source: String, isStreaming: Bool, scrollController _: ChatScrollController?) async {
        requestedRevision += 1
        if !isSuspended, document.blocks.isEmpty, !source.isEmpty, source.utf8.count <= 1_024 {
            document = ChatPresentationCache.document(key: key, source: source, streaming: isStreaming)
            submittedRevision = requestedRevision
            publishedRevision = requestedRevision
            return
        }
        latestRequest = RenderRequest(key: key, source: source, isStreaming: isStreaming)
        scheduleRender()
    }

    func setSuspended(_ suspended: Bool) {
        guard isSuspended != suspended else { return }
        isSuspended = suspended
        if !suspended { scheduleRender() }
    }

    private func scheduleRender() {
        guard !isSuspended, renderTask == nil, requestedRevision > submittedRevision else { return }
        renderTask = Task { [weak self] in
            guard let self else { return }
            await self.renderLatestRequests()
            self.renderTask = nil
            self.scheduleRender()
        }
    }

    private func renderLatestRequests() async {
        while !Task.isCancelled, !isSuspended, requestedRevision > submittedRevision {
            // Parse as soon as work is available. There is no token, character,
            // or time threshold; a busy parser catches up to the latest source.
            guard !Task.isCancelled, !isSuspended, let request = latestRequest else { return }
            let targetRevision = requestedRevision
            let result = await Task.detached(priority: .userInitiated) {
                ChatPresentationCache.document(
                    key: request.key,
                    source: request.source,
                    streaming: request.isStreaming
                )
            }.value
            guard !Task.isCancelled else { return }
            // A newer chunk must not starve a completed render. Publish these
            // monotonic snapshots, then parse the newest coalesced request.
            submittedRevision = targetRevision
            let publish = { [weak self] in
                guard let self, targetRevision > self.publishedRevision else { return }
                guard !self.isSuspended else {
                    if self.document != result {
                        self.submittedRevision = min(self.submittedRevision, targetRevision - 1)
                    }
                    return
                }
                self.publishedRevision = targetRevision
                if self.document != result { self.document = result }
            }
            // Reading-position anchoring belongs to ChatScrollController.
            // Received body text must not wait for a drag/deceleration to end.
            publish()
        }
    }

    private struct RenderRequest: Sendable {
        let key: String
        let source: String
        let isStreaming: Bool
    }
}

struct InlineArtifactBlockView: View {
    @State private var canvasHeight: CGFloat = 160
    @State private var layoutPublicationID = UUID()
    @Environment(\.chatScrollController) private var scrollController
    @Environment(\.colorScheme) private var colorScheme
    let artifact: ChatArtifactBlock

    var body: some View {
        Group {
            if artifact.kind == .inlineArtifact {
                ArtifactSandboxView(
                    rawHTML: artifact.raw,
                    colorScheme: colorScheme,
                    isStreaming: !artifact.isComplete,
                    inline: true,
                    contentHeight: updateCanvasHeight
                )
                .frame(height: canvasHeight)
            } else if artifact.isComplete {
                switch artifact.kind {
                case .inlineArtifact:
                    EmptyView()
                case .vega:
                    VegaLiteArtifactView(raw: artifact.raw)
                        .frame(height: 390)
                case .functionPlot:
                    FunctionPlotArtifactView(raw: artifact.raw)
                        .frame(height: 400)
                case .mermaid:
                    MermaidArtifactView(raw: artifact.raw)
                        .frame(height: 360)
                case .artifact, .document:
                    EmptyView()
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在渲染\(artifact.kind.displayName)…")
                        .font(MyChatSystemFont.appFont(size: 15, weight: .regular))
                        .foregroundStyle(MyChatTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func updateCanvasHeight(_ height: CGFloat) {
        let next = max(160, height)
        let publish = { if abs(canvasHeight - next) > 0.5 { canvasHeight = next } }
        if let scrollController { scrollController.publishWhenIdle(id: layoutPublicationID, publish) }
        else { publish() }
    }

    private var svgAspectRatio: CGFloat {
        let pattern = #"viewBox\s*=\s*[\"']\s*[-+0-9.eE]+\s+[-+0-9.eE]+\s+([-+0-9.eE]+)\s+([-+0-9.eE]+)\s*[\"']"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(
                  in: artifact.raw,
                  range: NSRange(artifact.raw.startIndex..., in: artifact.raw)
              ),
              let widthRange = Range(match.range(at: 1), in: artifact.raw),
              let heightRange = Range(match.range(at: 2), in: artifact.raw),
              let width = Double(artifact.raw[widthRange]),
              let height = Double(artifact.raw[heightRange]),
              width > 0,
              height > 0 else {
            return 4 / 3
        }
        return min(max(CGFloat(width / height), 0.4), 3.5)
    }
}

private struct ArtifactBlockDetail: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let artifact: ChatArtifactBlock

    var body: some View {
        VStack(spacing: 0) {
            ChatSheetHeader(title: ChatArtifactParser.title(for: artifact))
            Group {
                switch artifact.kind {
                case .document:
                    if let document = ChatDocument.from(artifact) { DocumentTextContent(document: document) }
                case .artifact, .inlineArtifact:
                    InteractiveArtifactView(rawHTML: artifact.raw, colorScheme: colorScheme)
                case .vega:
                    VegaLiteArtifactView(raw: artifact.raw)
                case .mermaid:
                    MermaidArtifactView(raw: artifact.raw)
                case .functionPlot:
                    FunctionPlotArtifactView(raw: artifact.raw)
                }
            }
        }
        .foregroundStyle(MyChatTheme.text)
        .background(MyChatTheme.canvas)
    }
}

struct MessageMarkdownBlockView: View, Equatable {
    let block: MessageMarkdownBlock
    let searches: [ChatToolSearch]
    let thinking: Bool
    var paragraphLineSpacing: CGFloat? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.block == rhs.block && lhs.searches == rhs.searches && lhs.thinking == rhs.thinking && lhs.paragraphLineSpacing == rhs.paragraphLineSpacing
    }

    @ViewBuilder
    var body: some View {
        switch block {
        case .artifact:
            EmptyView() // Artifact presentation is owned by AssistantMessageBody.
        case let .paragraph(text):
            MarkdownBody(text, typography: thinking ? .thought : .response, lineSpacingOverride: paragraphLineSpacing)
        case let .heading(level, text):
            ResponseHeadingText(text: inlineMarkdown(text))
                .font(headingFont(level))
                .lineSpacing(headingLineSpacing(level))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, level == 1 ? 2 : 0)
        case let .bullets(items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 11) {
                        Text("•")
                            .font(thinking ? MyChatTypography.thoughtStrong : MyChatTypography.responseStrong)
                        MarkdownBody(item, typography: thinking ? .thought : .response, lineSpacingOverride: paragraphLineSpacing)
                    }
                }
            }
        case let .numbered(start, items, loose):
            VStack(alignment: .leading, spacing: loose ? 18 : 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(start + index).")
                            .font(thinking ? MyChatTypography.thoughtStrong : MyChatTypography.responseStrong)
                            .frame(minWidth: 22, alignment: .trailing)
                        MarkdownBody(item, typography: thinking ? .thought : .response, lineSpacingOverride: paragraphLineSpacing)
                    }
                }
            }
        case let .quote(text):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(MyChatTheme.secondaryText.opacity(0.62))
                    .frame(width: 2)
                MarkdownBody(text, typography: thinking ? .thought : .response, lineSpacingOverride: paragraphLineSpacing)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 4)
        case let .table(headers, alignments, rows):
            MessageMarkdownTable(headers: headers, alignments: alignments, rows: rows, thinking: thinking)
        case let .code(language, text):
            CopyableMessageCodeBlock(language: language, text: text)
        case let .imageGallery(references):
            let matchingSearch = searches.first { search in
                (search.images ?? []).contains { image in
                    references.contains(where: { $0.url == image.url })
                }
            }
            if let matchingSearch, let images = matchingSearch.images, !images.isEmpty {
                SearchImageCarousel(images: images.compactMap { image in
                    guard let url = URL(string: image.url), url.scheme?.lowercased() == "https" else { return nil }
                    return MessageImageReference(url: url.absoluteString, alt: image.description ?? "")
                })
            } else {
                SearchImageCarousel(images: references)
            }
        case let .math(expression):
            LaTeXMathView(expression: expression)
        case .mathPending:
            FormulaPendingView()
        case .mathIncomplete:
            FormulaIncompleteView()
        case .divider:
            Divider()
                .padding(.vertical, 4)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return MyChatTypography.responseH1
        case 2: return MyChatTypography.responseH2
        default: return MyChatTypography.responseH3
        }
    }

    private func headingLineSpacing(_ level: Int) -> CGFloat {
        switch level {
        case 1: return MyChatTypography.responseH1LineSpacing
        case 2: return MyChatTypography.responseH2LineSpacing
        default: return MyChatTypography.responseH3LineSpacing
        }
    }
}

private struct MessageMarkdownTable: View {
    let headers: [String]
    let alignments: [MarkdownTableAlignment]
    let rows: [[String]]
    var thinking = false
    @State private var availableWidth: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(headers.indices, id: \.self) { column in
                        cell(headers[column], column: column, isHeader: true)
                    }
                }
                .background(MyChatTheme.raised)

                ForEach(rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(headers.indices, id: \.self) { column in
                            cell(rows[row][column], column: column, isHeader: false)
                        }
                    }
                    .background(alignment: .bottom) {
                        Rectangle()
                            .fill(MyChatTheme.border.opacity(0.35))
                            .frame(height: 0.5)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .clipShape(RoundedRectangle(cornerRadius: MyChatTheme.markdownTableRadius, style: .continuous))
        .padding(.vertical, 5)
    }

    private func cell(_ value: String, column: Int, isHeader: Bool) -> some View {
        Text(inlineMarkdown(value))
            .font(isHeader
                ? (thinking ? MyChatTypography.thoughtStrong : MyChatTypography.responseStrong)
                : (thinking ? MyChatTypography.thoughtBody : MyChatTypography.responseBody))
            .lineSpacing(thinking ? MyChatTypography.thoughtBodyLineSpacing : MyChatTypography.responseBodyLineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(width: columnWidth, alignment: cellAlignment(column))
            .overlay(alignment: .bottom) {
                if isHeader {
                    Rectangle()
                        .fill(MyChatTheme.border.opacity(0.76))
                        .frame(height: 0.75)
                }
            }
            .textSelection(.enabled)
    }

    private var columnWidth: CGFloat {
        // Column geometry depends on the viewport, never on the latest token.
        // Wider tables remain horizontally scrollable without reflowing old rows.
        max((availableWidth > 0 ? availableWidth : UIScreen.main.bounds.width - 32) / CGFloat(max(headers.count, 1)),
            headers.count > 2 ? 150 : 120)
    }

    private func cellAlignment(_ column: Int) -> Alignment {
        guard alignments.indices.contains(column) else { return .leading }
        switch alignments[column] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

private struct HistorySearchResultCard: View {
    let result: ChatSearchResult
    let openConversation: () -> Void

    var body: some View {
        Button(action: openConversation) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(MyChatSystemFont.appFont(size: 12, weight: .medium))
                    Text("历史对话")
                        .font(MyChatTypography.caption)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(MyChatSystemFont.appFont(size: 11, weight: .medium))
                }
                .foregroundStyle(MyChatTheme.secondaryText)

                Text(PresentationText.plain(result.title.isEmpty ? "未命名对话" : result.title))
                    .font(MyChatTypography.cardTitle)
                    .foregroundStyle(MyChatTheme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let snippet = result.snippet, !snippet.isEmpty {
                    Text(PresentationText.plain(snippet))
                        .font(MyChatTypography.caption)
                        .lineSpacing(MyChatTypography.captionLineSpacing)
                        .foregroundStyle(MyChatTheme.secondaryText)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(15)
            .background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: MyChatTheme.chatCardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: MyChatTheme.chatCardRadius, style: .continuous)
                    .stroke(MyChatTheme.border.opacity(0.72), lineWidth: 0.7)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开历史对话：\(result.title)")
    }
}

private struct SearchResultCard: View {
    let result: ChatSearchResult

    private var destination: URL? {
        guard let url = URL(string: result.url),
              url.scheme?.lowercased() == "https",
              url.host != nil else { return nil }
        return url
    }

    private var thumbnail: URL? {
        guard let value = result.thumbnailURL,
              let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host != nil else { return nil }
        return url
    }

    var body: some View {
        if let destination {
            Link(destination: destination) {
                VStack(alignment: .leading, spacing: 0) {
                    if let thumbnail {
                        AsyncImage(url: thumbnail) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            } else {
                                Rectangle().fill(MyChatTheme.selected)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 142)
                        .clipped()
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text(PresentationText.plain(result.title.isEmpty ? result.url : result.title))
                            .font(MyChatTypography.cardTitle)
                            .foregroundStyle(MyChatTheme.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        if let snippet = result.snippet, !snippet.isEmpty {
                            Text(PresentationText.plain(snippet))
                                .font(MyChatTypography.caption)
                                .lineSpacing(MyChatTypography.captionLineSpacing)
                                .foregroundStyle(MyChatTheme.secondaryText)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                        }

                        HStack(spacing: 7) {
                            SourceFavicon(urlString: result.url, size: 17)
                            Text(destination.host?.replacingOccurrences(of: "www.", with: "") ?? result.url)
                            if let publishedAt = result.publishedAt, !publishedAt.isEmpty {
                                Text("·")
                                Text(publishedAt)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right")
                                .font(MyChatSystemFont.appFont(size: 11, weight: .medium))
                        }
                        .font(MyChatTypography.caption)
                        .foregroundStyle(MyChatTheme.secondaryText)
                    }
                    .padding(.horizontal, 13)
                    .padding(.vertical, 12)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MyChatTheme.raised)
                .clipShape(RoundedRectangle(cornerRadius: MyChatTheme.chatCardRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: MyChatTheme.chatCardRadius, style: .continuous)
                        .stroke(MyChatTheme.border.opacity(0.72), lineWidth: 0.7)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("网页来源：\(result.title)")
        }
    }
}

private struct SearchImageCarousel: View {
    let images: [MessageImageReference]
    @State private var selectedImage: MessageImageReference?

    private let cardWidth: CGFloat = 192
    private let imageHeight: CGFloat = 128

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 10) {
                ForEach(images) { image in
                    Button {
                        selectedImage = image
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            if let url = safeExternalImageURL(image.url) {
                                RemoteSearchImage(url: url, contentMode: .fill)
                                    .frame(width: cardWidth, height: imageHeight)
                                    .clipped()
                            }

                            if !image.alt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(PresentationText.plain(image.alt))
                                    .font(MyChatTypography.caption)
                                    .foregroundStyle(MyChatTheme.secondaryText)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .padding(.horizontal, 9)
                                    .padding(.bottom, 8)
                            }
                        }
                        .frame(width: cardWidth, alignment: .leading)
                        .background(MyChatTheme.raised)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(MyChatTheme.border.opacity(0.72), lineWidth: 0.7)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(image.alt.isEmpty ? "打开图片" : "打开图片：\(image.alt)")
                }
            }
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .fullScreenCover(item: $selectedImage) { image in
            SearchImagePreview(image: image)
        }
    }
}

private struct RemoteSearchImage: View {
    let url: URL
    let contentMode: ContentMode
    var placeholderColor: Color = MyChatTheme.selected
    var progressTint: Color = MyChatTheme.secondaryText
    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var failed = false

    var body: some View {
        ZStack {
            placeholderColor
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if isLoading {
                ProgressView().tint(progressTint)
            } else {
                Image(systemName: "photo")
                    .font(MyChatSystemFont.appFont(size: 20, weight: .regular))
                    .foregroundStyle(progressTint.opacity(failed ? 0.9 : 0.55))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url.absoluteString) {
            await loadImage()
        }
    }

    @MainActor
    private func loadImage() async {
        guard image == nil else { return }
        isLoading = true
        failed = false
        defer { isLoading = false }

        do {
            var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 12)
            request.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            let systemVersion = UIDevice.current.systemVersion.replacingOccurrences(of: ".", with: "_")
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS \(systemVersion) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(UIDevice.current.systemVersion) Mobile/15E148 Safari/604.1",
                forHTTPHeaderField: "User-Agent"
            )
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                failed = true
                return
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 768,
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                failed = true
                return
            }
            image = UIImage(cgImage: thumbnail)
        } catch is CancellationError {
            return
        } catch {
            failed = true
        }
    }
}

private struct SearchImagePreview: View {
    let image: MessageImageReference
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(MyChatSystemFont.appFont(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(.white.opacity(0.14), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭图片")
                }
                Spacer(minLength: 0)
                Group {
                    if let url = safeExternalImageURL(image.url) {
                        RemoteSearchImage(
                            url: url,
                            contentMode: .fit,
                            placeholderColor: .black,
                            progressTint: .white.opacity(0.7)
                        )
                    } else {
                        Image(systemName: "photo")
                            .font(MyChatSystemFont.appFont(size: 42, weight: .light))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Spacer(minLength: 0)
                if !image.alt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(PresentationText.plain(image.alt))
                        .font(MyChatTypography.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 18)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        .statusBarHidden()
    }
}

private struct CopyableMessageCodeBlock: View {
    let language: String?
    let text: String
    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                if let language {
                    Text(language.lowercased())
                        .font(MyChatTypography.caption)
                        .foregroundStyle(MyChatTheme.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button(action: copyBlock) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(MyChatSystemFont.appFont(size: 13, weight: .semibold))
                        .foregroundStyle(copied ? MyChatTheme.text : MyChatTheme.secondaryText)
                        .frame(width: 30, height: 28)
                        .contentTransition(.opacity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "已复制" : "复制代码块")

                Button { expanded = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(MyChatSystemFont.appFont(size: 13, weight: .regular))
                        .foregroundStyle(MyChatTheme.secondaryText)
                        .frame(width: 30, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("展开代码")
            }
            .frame(minHeight: 36)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            Divider().opacity(0.45)

            ScrollView(.horizontal) {
                ResponseHeadingText(text: CodeSyntaxPresentation.highlight(text))
                    .font(MyChatTypography.code)
                    .lineSpacing(MyChatTypography.codeLineSpacing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.top, 7)
                    .padding(.bottom, 13)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(MyChatTheme.border.opacity(0.45), lineWidth: 0.5)
        }
        .onDisappear { resetTask?.cancel() }
        .sheet(isPresented: $expanded) {
            VStack(spacing: 0) {
                ChatSheetHeader(title: language.map { "\($0.capitalized) 代码" } ?? "代码")
                ScrollView([.horizontal, .vertical]) {
                    Text(CodeSyntaxPresentation.highlight(text))
                        .font(MyChatTypography.code)
                        .lineSpacing(MyChatTypography.codeLineSpacing)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(18)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(MyChatTheme.canvas)
            .presentationDetents([.large])
            .presentationCornerRadius(28)
        }
    }

    private func copyBlock() {
        UIPasteboard.general.string = text
        resetTask?.cancel()
        withAnimation(.easeOut(duration: 0.16)) { copied = true }
        resetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.16)) { copied = false }
        }
    }
}

private enum CodeSyntaxPresentation {
    private final class Entry: NSObject {
        let text: AttributedString
        init(_ text: AttributedString) { self.text = text }
    }
    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.totalCostLimit = 4 * 1_024 * 1_024
        cache.countLimit = 100
        return cache
    }()
    private static let tokens = try! NSRegularExpression(pattern:
        #"//[^\n]*|/\*[\s\S]*?\*/|\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|\b(?:let|var|func|return|if|else|for|in|while|class|struct|enum|import|const|function|async|await|def|from|true|false|nil|null|print)\b|\b\d+(?:\.\d+)?\b"#)

    static func highlight(_ source: String) -> AttributedString {
        if let cached = cache.object(forKey: source as NSString) { return cached.text }
        var result = AttributedString(source)
        guard source.utf8.count < 100_000 else { return result }
        for token in tokens.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let range = Range(token.range, in: source),
                  let attributedRange = Range(range, in: result) else { continue }
            let value = source[range]
            let color: Color
            if value.hasPrefix("//") || value.hasPrefix("/*") { color = MyChatTheme.secondaryText }
            else if value.first == "\"" || value.first == "'" {
                color = MyChatTheme.codeString
            } else if value.first?.isNumber == true {
                color = MyChatTheme.codeNumber
            } else { color = MyChatTheme.codeKeyword }
            result[attributedRange].foregroundColor = color
        }
        cache.setObject(Entry(result), forKey: source as NSString, cost: source.utf8.count * 3)
        return result
    }
}

private struct LaTeXMathView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var renderedHeight: CGFloat = 30
    let expression: String

    var body: some View {
        LaTeXMathWebView(
            source: expression,
            mode: .display,
            colorScheme: colorScheme,
            // MathML renders slightly smaller than the surrounding Serif Text
            // on iOS. Keep display equations visibly distinct without making
            // ordinary response copy oversized.
            fontSize: 16,
            paragraphTypography: .response,
            inlineHTML: nil,
            renderedHeight: $renderedHeight
        )
        .frame(height: renderedHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel("数学公式")
        .accessibilityValue(expression)
    }
}

private struct FormulaPendingView: View {
    var body: some View {
        HStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
            Text("正在渲染公式")
                .font(MyChatTypography.metadata)
                .lineSpacing(MyChatTypography.metadataLineSpacing)
        }
        .foregroundStyle(MyChatTheme.secondaryText)
        .frame(minHeight: 38, alignment: .leading)
        .accessibilityLabel("数学公式渲染中")
    }
}

private struct FormulaIncompleteView: View {
    var body: some View {
        Label("公式未完整输出", systemImage: "exclamationmark.triangle")
            .font(MyChatTypography.metadata)
            .lineSpacing(MyChatTypography.metadataLineSpacing)
            .foregroundStyle(MyChatTheme.secondaryText)
            .frame(minHeight: 38, alignment: .leading)
            .accessibilityLabel("数学公式未完整输出")
    }
}

private struct InlineLaTeXTextView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var renderedHeight: CGFloat = 0
    let source: String
    let html: String
    let fontSize: CGFloat
    let paragraphTypography: MathParagraphTypography
    let fallback: AttributedString
    let fallbackFont: Font
    let fallbackLineSpacing: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            if renderedHeight == 0 {
                Text(fallback)
                    .font(fallbackFont)
                    .lineSpacing(fallbackLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            LaTeXMathWebView(
                source: source,
                mode: .inlineDocument,
                colorScheme: colorScheme,
                fontSize: fontSize,
                paragraphTypography: paragraphTypography,
                inlineHTML: html,
                renderedHeight: $renderedHeight
            )
            .frame(height: max(1, renderedHeight))
            .opacity(renderedHeight == 0 ? 0 : 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(source)
    }
}

enum MathRenderMode: String {
    case display
    case inlineDocument
}

enum MathParagraphTypography: String {
    case response
    case thought
    case user
}

struct LaTeXMathWebView: UIViewRepresentable {
    @Environment(\.chatScrollController) private var scrollController
    let source: String
    let mode: MathRenderMode
    let colorScheme: ColorScheme
    let fontSize: CGFloat
    let paragraphTypography: MathParagraphTypography
    let inlineHTML: String?
    @Binding var renderedHeight: CGFloat

    @MainActor private static let processPool = WKProcessPool()

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.processPool = Self.processPool
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.alwaysBounceVertical = false
        view.scrollView.showsVerticalScrollIndicator = false
        view.scrollView.showsHorizontalScrollIndicator = false
        view.allowsLinkPreview = false
        view.isInspectable = false
        load(view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        load(view, coordinator: context.coordinator)
    }

    func load(_ view: WKWebView, coordinator: Coordinator) {
        let signature = "\(colorScheme)-\(mode.rawValue)-\(paragraphTypography.rawValue)-\(fontSize)-\(source)"
        guard coordinator.signature != signature else { return }
        coordinator.signature = signature
        // Keep the last visible math layout while appending text. Resetting
        // its height to zero switched between native fallback and web layout
        // on every chunk, making the reply collapse and flash.
        let documentSignature = "\(colorScheme)-\(mode.rawValue)-\(paragraphTypography.rawValue)-\(fontSize)"
        if coordinator.documentSignature == documentSignature {
            if coordinator.documentReady { coordinator.requestRender(in: view) }
            return
        }
        coordinator.documentSignature = documentSignature
        coordinator.documentReady = false
        coordinator.resetPendingRender()

        let dark = colorScheme == .dark
        let foreground = dark ? "#f8f8f6" : "#131313"
        let muted = dark ? "#9a9a93" : "#80807b"
        let inline = mode == .inlineDocument
        let autoRenderScript = inline
            ? #"<script defer src="https://cdn.jsdelivr.net/npm/katex@0.17.0/dist/contrib/auto-render.min.js"></script>"#
            : ""
        let fallbackAutoRenderScript = inline
            ? #"<script defer src="https://unpkg.com/katex@0.17.0/dist/contrib/auto-render.min.js"></script>"#
            : ""
        let bodyPadding = "0"
        let response = paragraphTypography == .response
        let thought = paragraphTypography == .thought
        let assistant = response || thought
        let textSize = inline ? UIFontMetrics(forTextStyle: .body).scaledValue(for: fontSize) : fontSize
        let hanBaseSize = response ? MyChatTypography.responseHanSize : (thought ? MyChatTypography.thoughtHanSize : 17)
        let hanSize = UIFontMetrics(forTextStyle: .body).scaledValue(for: hanBaseSize)
        let bodyFont = inline
            ? (assistant ? "\(textSize)px MyChatResponseSerif, 'PingFang SC', serif"
                        : "500 \(textSize)px -apple-system, BlinkMacSystemFont, sans-serif")
            : "\(fontSize)px 'Times New Roman', serif"
        let nativeFont = assistant
            ? MyChatSystemFont.uiFont(size: textSize, weight: .medium, serif: true)
            : MyChatSystemFont.appUIFont(size: textSize, weight: .medium)
        let spacing = response ? MyChatTypography.responseBodyLineSpacing
            : (thought ? MyChatTypography.thoughtBodyLineSpacing : MyChatTypography.userMessageLineSpacing)
        let lineHeight = inline ? "\(nativeFont.lineHeight + spacing)px" : "1.08"
        let hanLineHeight = (response ? MyChatSystemFont.hanUIFont(size: hanSize).lineHeight
            : (UIFont(name: "PingFangSC-Medium", size: hanSize)?.lineHeight ?? nativeFont.lineHeight)) + spacing
        let codeColor = "#708CB8"
        let codeSurface = dark ? "#262626" : "#ecece8"
        let minimumHeight = inline ? "24px" : "22px"
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src https://cdn.jsdelivr.net https://unpkg.com; style-src 'unsafe-inline'; connect-src https://cdn.jsdelivr.net https://unpkg.com; img-src data:; font-src data:">
          <script defer src="https://cdn.jsdelivr.net/npm/katex@0.17.0/dist/katex.min.js"></script>
          <script defer src="https://unpkg.com/katex@0.17.0/dist/katex.min.js"></script>
          \(autoRenderScript)
          \(fallbackAutoRenderScript)
          <style>
            \(inline && assistant ? MyChatSystemFont.responseWebFontCSS : "")
            :root { color-scheme: \(dark ? "dark" : "light"); }
            html, body { margin: 0; padding: 0; background: transparent; color: \(foreground); }
            body { padding: \(bodyPadding); overflow-x: auto; overflow-y: hidden; }
            #math { min-height: \(minimumHeight); font: \(bodyFont); line-height: \(lineHeight); white-space: pre-wrap; overflow-wrap: anywhere; }
            #math { font-optical-sizing: none; font-variation-settings: 'opsz' 16; }
            #math .han { font-family: -apple-system, BlinkMacSystemFont, 'PingFang SC', sans-serif; font-size: \(hanSize)px; font-weight: \(assistant ? MyChatSystemFont.responseHanCSSWeight : MyChatSystemFont.appUIWeight); font-style: normal; font-variation-settings: normal; line-height: \(hanLineHeight)px; letter-spacing: \(response ? MyChatTypography.responseHanTracking : (thought ? MyChatTypography.responseHanTracking * (MyChatTypography.thoughtHanSize / MyChatTypography.responseHanSize) : 0))px; }
            #math strong .han { font-weight: \(assistant ? 600 : MyChatSystemFont.appUIWeight); }
            #math .closing { letter-spacing: -0.5em; }
            #math code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: \(assistant ? fontSize * (16 / MyChatTypography.responseBodySize) : 17)px; font-weight: \(assistant ? 400 : 500); color: \(codeColor); background: \(codeSurface); padding: 0.5px 3px; border-radius: 4px; }
            #math-status, .math-fallback { color: \(muted); font: 14px -apple-system, BlinkMacSystemFont, sans-serif; }
            math { font-size: \(inline ? "0.98em" : "0.96em"); }
            .katex-error { color: \(foreground) !important; }
          </style>
        </head>
        <body><div id="math"><span id="math-status">公式加载中</span></div></body>
        </html>
        """
        view.loadHTMLString(html, baseURL: nil)
    }

    private func htmlEscaped(_ source: String) -> String {
        source
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: LaTeXMathWebView
        var signature: String?
        var documentSignature: String?
        var documentReady = false
        private var rendererPending = false
        private let heightPublicationID = UUID()

        private func publishHeight(_ height: CGFloat, signature: String) {
            let publish = { [weak self] in
                guard let self, self.signature == signature else { return }
                if abs(self.parent.renderedHeight - height) > 0.5 { self.parent.renderedHeight = height }
            }
            if let scrollController = parent.scrollController {
                scrollController.publishWhenIdle(id: heightPublicationID, publish)
            } else { publish() }
        }

        init(parent: LaTeXMathWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            documentReady = true
            requestRender(in: webView)
        }

        func resetPendingRender() { rendererPending = false }

        func requestRender(in webView: WKWebView) {
            guard !rendererPending, let documentSignature else { return }
            rendererPending = true
            render(in: webView, signature: documentSignature, attempt: 0)
        }

        private func render(in webView: WKWebView, signature: String, attempt: Int) {
            guard self.documentSignature == signature else { return }
            let readiness = parent.mode == .inlineDocument
                ? "Boolean(window.katex && window.renderMathInElement)"
                : "Boolean(window.katex)"
            webView.evaluateJavaScript(readiness) { [weak self, weak webView] value, _ in
                guard let self, let webView, self.documentSignature == signature else { return }
                guard (value as? Bool) == true else {
                    // First use on a physical phone can need a little longer
                    // to establish the CDN connection.  Do not leave a
                    // completed formula looking like raw LaTeX merely
                    // because the initial renderer load exceeded 2.5 seconds.
                    guard attempt < 160 else {
                        self.rendererPending = false
                        if let latest = self.signature { self.showUnavailable(in: webView, signature: latest) }
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        self.render(in: webView, signature: signature, attempt: attempt + 1)
                    }
                    return
                }
                self.rendererPending = false
                if let latest = self.signature { self.finishRendering(in: webView, signature: latest) }
            }
        }

        private func finishRendering(in webView: WKWebView, signature: String) {
            let encoded = Data((parent.inlineHTML ?? parent.source).utf8).base64EncodedString()
            let renderCall: String
            if parent.mode == .inlineDocument {
                renderCall = """
                node.innerHTML = source;
                try {
                  window.renderMathInElement(node, {
                    delimiters: [
                      {left: '$$', right: '$$', display: true},
                      {left: '\\\\[', right: '\\\\]', display: true},
                      {left: '\\\\(', right: '\\\\)', display: false},
                      {left: '$', right: '$', display: false}
                    ],
                    throwOnError: true,
                    strict: 'ignore',
                    output: 'mathml'
                  });
                  if (node.querySelector('.katex-error')) throw new Error('invalid LaTeX');
                } catch (_) {
                  // A malformed inline formula must not erase the surrounding paragraph.
                  node.innerHTML = source;
                }
                """
            } else {
                renderCall = """
                try {
                  window.katex.render(source, node, {
                    displayMode: true,
                    throwOnError: true,
                    strict: 'ignore',
                    output: 'mathml'
                  });
                } catch (_) {
                  node.innerHTML = '<span class="math-fallback">公式暂不可渲染</span>';
                }
                """
            }
            let script = """
            (() => {
              const node = document.getElementById('math');
              const bytes = Uint8Array.from(atob('\(encoded)'), character => character.charCodeAt(0));
              const source = new TextDecoder().decode(bytes);
              if (!node) return 0;
              \(renderCall)
              return Math.ceil(node.getBoundingClientRect().height);
            })();
            """
            webView.evaluateJavaScript(script) { [weak self] value, _ in
                guard let self, self.signature == signature,
                      let height = value as? NSNumber else { return }
                let bounds: ClosedRange<CGFloat> = self.parent.mode == .inlineDocument
                    ? 24...20_000
                    : 26...520
                let resolved = min(max(CGFloat(truncating: height) + 1, bounds.lowerBound), bounds.upperBound)
                DispatchQueue.main.async {
                    guard self.signature == signature else { return }
                    if self.parent.mode == .inlineDocument,
                       InlineMathLayoutPolicy.height(for: resolved) == nil {
                        // Keep the native text fallback visible when WebKit
                        // reports an implausibly tall inline document. A bad
                        // measurement must not reserve a screen of blank space.
                        return
                    }
                    self.publishHeight(resolved, signature: signature)
                }
            }
        }

        private func showUnavailable(in webView: WKWebView, signature: String) {
            let encoded = Data((parent.inlineHTML ?? parent.source).utf8).base64EncodedString()
            let fallback = parent.mode == .inlineDocument
                ? "node.innerHTML = new TextDecoder().decode(Uint8Array.from(atob('\(encoded)'), c => c.charCodeAt(0)));"
                : "node.innerHTML = '<span class=\"math-fallback\">公式暂不可渲染</span>';"
            let script = """
            (() => {
              const node = document.getElementById('math');
              if (!node) return 0;
              \(fallback)
              return Math.ceil(node.getBoundingClientRect().height);
            })();
            """
            webView.evaluateJavaScript(script) { [weak self] value, _ in
                guard let self, self.signature == signature,
                      let height = value as? NSNumber else { return }
                let minimum: CGFloat = self.parent.mode == .inlineDocument ? 24 : 26
                let maximum: CGFloat = self.parent.mode == .inlineDocument ? 20_000 : 520
                let resolved = min(max(CGFloat(truncating: height) + 1, minimum), maximum)
                DispatchQueue.main.async {
                    guard self.signature == signature else { return }
                    if self.parent.mode == .inlineDocument,
                       InlineMathLayoutPolicy.height(for: resolved) == nil {
                        return
                    }
                    self.publishHeight(resolved, signature: signature)
                }
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            let scheme = navigationAction.request.url?.scheme
            decisionHandler(scheme == "about" ? .allow : .cancel)
        }
    }
}

struct MarkdownBody: View {
    enum Typography {
        case response
        case thought
        case reasoningSummary
        case user

        var diagnosticUIFontSamples: [UIFont] {
            let bodySize: CGFloat
            let baseFonts: [UIFont]
            switch self {
            case .response:
                bodySize = MyChatTypography.responseBodySize
                baseFonts = [
                    MyChatSystemFont.scaledUIFont(MyChatSystemFont.uiFont(size: bodySize, weight: .regular, serif: true), relativeTo: .body),
                    MyChatSystemFont.scaledUIFont(MyChatSystemFont.uiFont(size: bodySize, weight: .bold, serif: true), relativeTo: .body),
                    MyChatSystemFont.scaledUIFont(MyChatSystemFont.uiFont(size: bodySize, weight: .regular, serif: true, italic: true), relativeTo: .body),
                    UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)),
                    UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont.monospacedSystemFont(ofSize: 16, weight: .semibold))
                ]
            case .reasoningSummary:
                bodySize = MyChatTypography.reasoningSummaryBodySize
                baseFonts = [
                    MyChatSystemFont.scaledUIFont(MyChatSystemFont.uiFont(size: bodySize, weight: .regular, serif: true), relativeTo: .body),
                    MyChatSystemFont.scaledUIFont(MyChatSystemFont.uiFont(size: bodySize, weight: .bold, serif: true), relativeTo: .body),
                    MyChatSystemFont.scaledUIFont(MyChatSystemFont.uiFont(size: bodySize, weight: .regular, serif: true, italic: true), relativeTo: .body),
                    UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)),
                    UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont.monospacedSystemFont(ofSize: 16, weight: .semibold))
                ]
            case .thought:
                bodySize = MyChatTypography.thoughtBodySize
                baseFonts = [
                    MyChatSystemFont.scaledUIFont(MyChatSystemFont.uiFont(size: bodySize, weight: .regular, serif: true), relativeTo: .body),
                    MyChatSystemFont.scaledUIFont(MyChatSystemFont.uiFont(size: bodySize, weight: .bold, serif: true), relativeTo: .body),
                    MyChatSystemFont.scaledUIFont(MyChatSystemFont.uiFont(size: bodySize, weight: .regular, serif: true, italic: true), relativeTo: .body),
                    UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont.monospacedSystemFont(ofSize: 16, weight: .regular)),
                    UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont.monospacedSystemFont(ofSize: 16, weight: .semibold))
                ]
            case .user:
                bodySize = 17.5
                baseFonts = [MyChatSystemFont.scaledUIFont(
                    MyChatSystemFont.appUIFont(size: bodySize, weight: .regular), relativeTo: .body)]
            }
            let han = [
                UIFontMetrics(forTextStyle: .body).scaledFont(for: MyChatSystemFont.hanUIFont(size: bodySize, strong: false)),
                UIFontMetrics(forTextStyle: .body).scaledFont(for: MyChatSystemFont.hanUIFont(size: bodySize, strong: true))
            ]
            let samples = baseFonts + han
            let cascades = samples.flatMap { font -> [UIFont] in
                (font.fontDescriptor.fontAttributes[.cascadeList] as? [UIFontDescriptor] ?? [])
                    .map { UIFont(descriptor: $0, size: font.pointSize) }
            }
            return samples + cascades
        }

        var font: Font {
            switch self {
            case .response: return MyChatTypography.responseBody
            case .thought: return MyChatTypography.thoughtBody
            case .reasoningSummary: return MyChatTypography.reasoningSummaryBody
            case .user: return MyChatTypography.userMessage
            }
        }

        var lineSpacing: CGFloat {
            switch self {
            case .response: return MyChatTypography.responseBodyLineSpacing
            case .thought: return MyChatTypography.thoughtBodyLineSpacing
            case .reasoningSummary: return MyChatTypography.reasoningSummaryBodyLineSpacing
            case .user: return MyChatTypography.userMessageLineSpacing
            }
        }

        var mathFontSize: CGFloat {
            switch self {
            case .response: return MyChatTypography.responseBodySize
            case .thought: return MyChatTypography.thoughtBodySize
            case .reasoningSummary: return MyChatTypography.reasoningSummaryBodySize
            case .user: return 17
            }
        }

        var mathParagraphTypography: MathParagraphTypography {
            switch self {
            case .response: return .response
            case .thought: return .thought
            case .reasoningSummary: return .response
            case .user: return .user
            }
        }

        var isUserMessage: Bool {
            if case .user = self { return true }
            return false
        }
    }

    private let source: String
    private let mathSource: String
    private let mathHTML: String
    private let hasInlineMath: Bool
    private let text: AttributedString
    private let codeText: Text?
    private let fillsWidth: Bool
    private let typography: Typography
    private let bodyLineSpacing: CGFloat

    init(
        _ source: String,
        fillsWidth: Bool = true,
        typography: Typography = .response,
        lineSpacingOverride: CGFloat? = nil
    ) {
        self.source = source
        let hasHan = source.unicodeScalars.contains {
            (0x3400...0x9FFF).contains($0.value)
                || (0xF900...0xFAFF).contains($0.value)
                || (0x20000...0x323AF).contains($0.value)
        }
        if let lineSpacingOverride { bodyLineSpacing = lineSpacingOverride }
        else if hasHan {
            switch typography {
            case .response: bodyLineSpacing = MyChatTypography.responseHanLineSpacing
            case .thought: bodyLineSpacing = MyChatTypography.thoughtHanLineSpacing
            case .reasoningSummary: bodyLineSpacing = MyChatTypography.reasoningSummaryHanLineSpacing
            case .user: bodyLineSpacing = typography.lineSpacing
            }
        } else {
            bodyLineSpacing = typography.lineSpacing
        }
        if typography.isUserMessage {
            // A user's message is content, not Markdown. Parsing it here silently
            // turns literal ~~text~~ into a deletion mark and can hide what they wrote.
            mathSource = source
            mathHTML = ""
            hasInlineMath = false
            text = MessageInlinePresentationCache.userMessageText(source)
            codeText = nil
        } else {
            let presentation = MessageInlinePresentationCache.presentation(source)
            mathSource = presentation.mathSource
            mathHTML = presentation.mathHTML
            hasInlineMath = presentation.hasInlineMath
            switch typography {
            case .response:
                text = presentation.responseText
                codeText = presentation.responseCodeText
            case .thought:
                text = presentation.thoughtText
                codeText = presentation.thoughtCodeText
            case .reasoningSummary:
                let scale = MyChatTypography.reasoningSummaryBodySize / MyChatTypography.responseBodySize
                let summaryText = MyChatResponseTypesetting.response(presentation.text, scale: scale)
                text = summaryText
                codeText = MessageInlinePresentationCache.Presentation.codeDecoratedText(summaryText, parsed: presentation.text)
            case .user:
                // The user-message case is handled above to preserve exact input.
                text = AttributedString(source)
                codeText = nil
            }
        }
        self.fillsWidth = fillsWidth
        self.typography = typography
    }

    @ViewBuilder
    var body: some View {
        if hasInlineMath {
            InlineLaTeXTextView(source: mathSource, html: mathHTML, fontSize: typography.mathFontSize,
                                paragraphTypography: typography.mathParagraphTypography,
                                fallback: text, fallbackFont: typography.font,
                                fallbackLineSpacing: bodyLineSpacing)
                .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
        } else {
            responseText
                .font(typography.font)
                .tracking(MyChatTypography.responseTracking)
                .lineSpacing(bodyLineSpacing)
                .modifier(MessageBodyTextSelectionPolicy(isUserMessage: typography.isUserMessage))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .leading)
                .background {
                    if ResponseFontRuntimeDiagnostics.enabled {
                        ResponseFontRuntimeProbe(baseFont: typography.font,
                            runFonts: text.runs.compactMap { $0.font },
                            nativeFonts: typography.diagnosticUIFontSamples)
                    }
                }
        }
    }

    @ViewBuilder private var responseText: some View {
        if #available(iOS 18.0, *), !typography.isUserMessage {
            StreamingResponseText(text: text, codeText: codeText)
        } else { Text(text) }
    }
}

private struct ResponseHeadingText: View {
    let text: AttributedString
    var body: some View {
        if #available(iOS 18.0, *) { StreamingResponseText(text: text) }
        else { Text(text) }
    }
}

private struct ResponseIsStreamingKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var responseIsStreaming: Bool {
        get { self[ResponseIsStreamingKey.self] }
        set { self[ResponseIsStreamingKey.self] = newValue }
    }
}

enum ResponseRevealTiming {
    static func step(added _: Int) -> TimeInterval {
        // All characters in a received delta begin drawing together. Opacity
        // easing is visual only; it must not introduce a typewriter queue.
        0
    }

    static func opacity(now: TimeInterval, born: TimeInterval) -> Double {
        guard now >= born else { return 0 }
        return 0.10 + 0.90 * progress(now: now, born: born)
    }

    static func progress(now: TimeInterval, born: TimeInterval) -> Double {
        guard now >= born else { return 0 }
        let linear = min(1, max(0, (now - born) / 0.24))
        return 1 - pow(1 - linear, 3)
    }

    static func rise(now: TimeInterval, born: TimeInterval) -> CGFloat {
        2.4 * CGFloat(1 - progress(now: now, born: born))
    }

    static func blur(now: TimeInterval, born: TimeInterval) -> CGFloat {
        0.85 * CGFloat(1 - progress(now: now, born: born))
    }
}

// Births belong to native glyph indices, not byte offsets or chopped Text
// fragments. Shaping, ligatures, kerning and Markdown attributes remain intact.
struct ResponseGlyphBirths<Index: Hashable & Comparable> {
    private(set) var values: [Index: TimeInterval] = [:]

    mutating func update(indices: [Index], now: TimeInterval) -> [Index: TimeInterval] {
        let fresh = Set(indices).filter { values[$0] == nil }.sorted()
        let step = ResponseRevealTiming.step(added: fresh.count)
        for (order, index) in fresh.enumerated() {
            values[index] = now + Double(order) * step
        }
        return values
    }
}

@available(iOS 18.0, *)
private final class ResponseRevealLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var glyphs = ResponseGlyphBirths<Text.Layout.CharacterIndex>()
    private var introducedAt = Date.timeIntervalSinceReferenceDate
    private var previous = ""
    private var recordedMessages: Set<UUID> = []

    func shouldRecord(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !previous.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return recordedMessages.insert(id).inserted
    }

    func begin(source: String, now: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if source.isEmpty || (!previous.isEmpty && previous.commonPrefix(with: source).isEmpty) {
            glyphs = ResponseGlyphBirths()
        }
        previous = source
        introducedAt = now
    }

    func births(layout: Text.Layout, now: TimeInterval) -> [Text.Layout.CharacterIndex: TimeInterval] {
        let indices = layout.flatMap { $0.flatMap { $0.characterIndices } }
        lock.lock(); defer { lock.unlock() }
        return glyphs.update(indices: indices, now: min(introducedAt, now))
    }
}

@available(iOS 18.0, *)
private struct ResponseRevealRenderer: TextRenderer {
    let ledger: ResponseRevealLedger
    let now: TimeInterval
    var decorationOnly = false
    var messageID: UUID?

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let births = ledger.births(layout: layout, now: now)
        let firstCharacter = layout.first?.first?.characterIndices.first
        for line in layout {
            for run in line {
                if decorationOnly {
                    guard run[InlineCodeTextAttribute.self] != nil else { continue }
                    var ink = context
                    let opacities = run.characterIndices.compactMap { births[$0] }
                        .map { ResponseRevealTiming.opacity(now: now, born: $0) }
                    ink.opacity *= opacities.isEmpty ? 1 : opacities.reduce(0, +) / Double(opacities.count)
                    let bounds = run.typographicBounds.rect.insetBy(dx: -3, dy: -0.5)
                    ink.fill(Path(roundedRect: bounds, cornerRadius: 4), with: .color(MyChatTheme.inlineCodeSurface))
                } else if run.characterIndices.allSatisfy({ now - (births[$0] ?? 0) >= 0.24 }) {
                    context.draw(run)
                } else {
                    for slice in run {
                        if let firstCharacter, slice.characterIndices.contains(firstCharacter) {
                            // The leading answer glyph is full ink on its first
                            // draw. Only subsequent glyphs use progressive fade.
                            context.draw(slice)
                            continue
                        }
                        var ink = context
                        let born = slice.characterIndices.compactMap { births[$0] }.min() ?? 0
                        ink.opacity *= ResponseRevealTiming.opacity(now: now, born: born)
                        ink.translateBy(x: 0, y: ResponseRevealTiming.rise(now: now, born: born))
                        let blur = ResponseRevealTiming.blur(now: now, born: born)
                        if blur > 0.01 { ink.addFilter(.blur(radius: blur)) }
                        ink.draw(slice)
                    }
                }
            }
        }
        if !decorationOnly, !births.isEmpty, let messageID, ledger.shouldRecord(messageID) {
            ResponseInkDiagnostics.record(messageID: messageID)
        }
    }
}

private struct ResponseMessageIDKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}
private extension EnvironmentValues {
    var responseMessageID: UUID? {
        get { self[ResponseMessageIDKey.self] }
        set { self[ResponseMessageIDKey.self] = newValue }
    }
}

// Numeric first-draw evidence, queued off the rendering path. This does not
// collect text, screenshots, authentication data or model credentials.
private enum ResponseInkDiagnostics {
    private struct Record: Codable, Sendable {
        let messageID: UUID
        let drawnAt: Date
        let monotonicDraw: Double
    }
    private static let writer = DispatchQueue(label: "mychat.response-ink-timing", qos: .utility)
    private static var records: [UUID: Record] = [:]

    static func record(messageID: UUID) {
        let monotonicDraw = ProcessInfo.processInfo.systemUptime
        let record = Record(messageID: messageID, drawnAt: Date(), monotonicDraw: monotonicDraw)
        writer.async {
            // Deduplicate here before scheduling the actor hop so segmented
            // renderers cannot enqueue multiple callbacks for the same message.
            guard records[messageID] == nil else { return }
            if records.count >= 64, let oldest = records.values.min(by: { $0.monotonicDraw < $1.monotonicDraw }) {
                records[oldest.messageID] = nil
            }
            records[messageID] = record
            Task { @MainActor in
                ChatGenerationDiagnostics.markFirstGlyphDrawn(
                    assistantMessageID: messageID, receivedAt: monotonicDraw
                )
            }
            guard let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
                  let data = try? JSONEncoder().encode(Array(records.values)) else { return }
            try? data.write(to: folder.appendingPathComponent("response-ink-timing.json"),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }
}

/// Layout the complete attributed text immediately and fade only native ink.
/// The first glyph has visible ink on its first draw; later glyphs overlap.
@available(iOS 18.0, *)
private struct StreamingResponseText: View {
    let text: AttributedString
    var codeText: Text? = nil
    @Environment(\.responseIsStreaming) private var streaming
    @Environment(\.responseMessageID) private var messageID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ledger = ResponseRevealLedger()
    @State private var previous = ""
    @State private var lastBirth = Date.timeIntervalSinceReferenceDate
    @State private var revealing = true

    var body: some View {
        Group {
            if (streaming || revealing) && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 60, paused: !revealing)) { timeline in
                    ZStack(alignment: .topLeading) {
                        if let codeText {
                            codeText.textRenderer(ResponseRevealRenderer(ledger: ledger,
                                now: timeline.date.timeIntervalSinceReferenceDate, decorationOnly: true))
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                        Text(text).textRenderer(ResponseRevealRenderer(ledger: ledger,
                            now: timeline.date.timeIntervalSinceReferenceDate,
                            messageID: streaming ? messageID : nil))
                    }
                }
                .textSelection(.disabled)
            } else {
                ZStack(alignment: .topLeading) {
                    if let codeText {
                        codeText.textRenderer(InlineCodeTextRenderer())
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                    Text(text)
                }
            }
        }
        .onChange(of: text, initial: true) { _, _ in updateReveal() }
        .onChange(of: reduceMotion) { _, _ in updateReveal() }
        .task(id: lastBirth) {
            let remaining = max(0, lastBirth + 0.32 - Date.timeIntervalSinceReferenceDate)
            try? await Task.sleep(for: .seconds(remaining))
            if !Task.isCancelled { revealing = false }
        }
    }

    private func updateReveal() {
        let current = String(text.characters)
        let now = Date.timeIntervalSinceReferenceDate
        guard !reduceMotion && (streaming || (revealing && !previous.isEmpty)) else {
            previous = current; revealing = false
            return
        }
        ledger.begin(source: current, now: now)
        if current != previous {
            lastBirth = now
            revealing = true
        }
        previous = current
    }
}

private struct MessageBodyTextSelectionPolicy: ViewModifier {
    let isUserMessage: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 27.0, *), !isUserMessage {
            // iOS 27's selectable SwiftUI text path drops the bundled response fonts.
            // Assistant messages keep their existing copy action; user text stays selectable.
            content.textSelection(.disabled)
        } else {
            content.textSelection(.enabled)
        }
    }
}

private struct ResponseFontRuntimeProbe: View {
#if compiler(>=6.2)
    @Environment(\.fontResolutionContext) private var context
#endif
    @Environment(\.colorScheme) private var colorScheme
    let baseFont: Font
    let runFonts: [Font]
    let nativeFonts: [UIFont]

    var body: some View {
        Color.clear.allowsHitTesting(false).task {
#if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                ResponseFontRuntimeDiagnostics.record(fonts: [baseFont] + runFonts,
                    context: context, dark: colorScheme == .dark)
                return
            }
#endif
            // Older SDKs cannot expose SwiftUI's Font.Context. Preserve the opt-in
            // check by recording the exact native UIFont inputs plus their cascades.
            ResponseFontRuntimeDiagnostics.record(nativeFonts: nativeFonts, dark: colorScheme == .dark)
        }
    }
}

private enum ResponseFontRuntimeDiagnostics {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--verify-reference-fonts")
    @MainActor private static var entries: [String: [String: Any]] = [:]

#if compiler(>=6.2)
    @available(iOS 26.0, *) @MainActor
    static func record(fonts: [Font], context: Font.Context, dark: Bool) {
        for font in fonts {
            let resolved = font.resolve(in: context)
            let native = resolved.ctFont
            let axes = Dictionary(uniqueKeysWithValues:
                ((CTFontCopyVariation(native) as? [NSNumber: NSNumber]) ?? [:])
                    .map { (String($0.key.uint32Value), $0.value.doubleValue) })
            let name = CTFontCopyPostScriptName(native) as String
            let key = "\(name):\(resolved.pointSize):\(dark)"
            entries[key] = ["name": name, "size": resolved.pointSize, "axes": axes,
                            "dark": dark, "bold": resolved.isBold]
        }
        save()
    }
#endif

    @MainActor
    static func record(nativeFonts: [UIFont], dark: Bool) {
        for font in nativeFonts {
            let native = font as CTFont
            let axes = Dictionary(uniqueKeysWithValues:
                ((CTFontCopyVariation(native) as? [NSNumber: NSNumber]) ?? [:])
                    .map { (String($0.key.uint32Value), $0.value.doubleValue) })
            let name = CTFontCopyPostScriptName(native) as String
            let key = "\(name):\(font.pointSize):\(dark)"
            entries[key] = ["name": name, "size": font.pointSize, "axes": axes,
                            "dark": dark,
                            "bold": font.fontDescriptor.symbolicTraits.contains(.traitBold)]
        }
        save()
    }

    @MainActor private static func save() {
        guard let data = try? JSONSerialization.data(withJSONObject: Array(entries.values),
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("response-font-resolution.json")
        try? data.write(to: file, options: .atomic)
    }
}

@available(iOS 18.0, *)
private struct InlineCodeTextAttribute: TextAttribute {}

@available(iOS 18.0, *)
private struct InlineCodeTextRenderer: TextRenderer {
    var displayPadding: EdgeInsets { EdgeInsets(top: 1, leading: 3, bottom: 1, trailing: 3) }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        // The selectable foreground is native Text using the same content and
        // layout. SwiftUI bypasses custom renderers for selectable text, so this
        // noninteractive layer paints only decoration, without text duplication
        // in accessibility, added characters, or a layout/state callback.
        for line in layout {
            for run in line where run[InlineCodeTextAttribute.self] != nil {
                let bounds = run.typographicBounds.rect.insetBy(dx: -3, dy: -0.5)
                context.fill(Path(roundedRect: bounds, cornerRadius: 4), with: .color(MyChatTheme.inlineCodeSurface))
            }
        }
    }
}

private func containsInlineMath(_ source: String) -> Bool {
    InlineMathPresentation.hasRenderableFormula(in: source)
}

enum InlineMathLayoutPolicy {
    static let maximumInlineHeight: CGFloat = 520

    static func height(for measuredHeight: CGFloat) -> CGFloat? {
        guard measuredHeight.isFinite,
              measuredHeight >= 24,
              measuredHeight <= maximumInlineHeight else { return nil }
        return measuredHeight
    }
}

private func normalizedInlineMathSource(_ source: String) -> String {
    source.components(separatedBy: .newlines)
        .map(normalizedInlineMathLine)
        .joined(separator: "\n")
        .replacingOccurrences(of: #";\Longleftrightarrow;"#, with: #"\;\Longleftrightarrow\;"#)
        .replacingOccurrences(of: #";\Rightarrow;"#, with: #"\;\Rightarrow\;"#)
        .replacingOccurrences(of: #";\Leftarrow;"#, with: #"\;\Leftarrow\;"#)
}

private func normalizedInlineMathLine(_ source: String) -> String {
    if source.contains("$"), source.filter({ $0 == "$" }).count >= 2 {
        return source
    }
    if source.contains(#"\("#), source.contains(#"\)"#) {
        return source
    }

    guard let command = source.range(
        of: #"\\(?:left|right|d?frac|sqrt|sum|prod|int|lim|alpha|beta|gamma|delta|theta|lambda|mu|pi|sigma|phi|omega|begin|end)\b"#,
        options: [.regularExpression, .caseInsensitive]
    ) else { return source }

    let beforeCommand = source[..<command.lowerBound]
    let separator = beforeCommand.lastIndex(where: { $0 == "：" || $0 == ":" })
    let containsHan = source.range(of: #"\p{Han}"#, options: .regularExpression) != nil
    guard separator != nil || !containsHan else { return source }

    let formulaStart = separator.map { source.index(after: $0) } ?? source.startIndex
    var formulaEnd = source.endIndex
    var trailing = ""
    while formulaEnd > formulaStart {
        let previous = source.index(before: formulaEnd)
        if "。；，、".contains(source[previous]) {
            trailing.insert(source[previous], at: trailing.startIndex)
            formulaEnd = previous
        } else {
            break
        }
    }

    let prefix = String(source[..<formulaStart])
    var formula = source[formulaStart..<formulaEnd]
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !formula.isEmpty else { return source }

    var closingMarkdown = ""
    if formula.hasSuffix("**"), prefix.components(separatedBy: "**").count.isMultiple(of: 2) {
        formula.removeLast(2)
        closingMarkdown = "**"
    }

    var outsideOpening = ""
    var outsideClosing = ""
    if formula.first == "（", formula.last == "）" {
        formula.removeFirst()
        formula.removeLast()
        formula = formula.trimmingCharacters(in: .whitespacesAndNewlines)
        outsideOpening = "（"
        outsideClosing = "）"
    }
    guard !formula.isEmpty else { return source }
    return "\(prefix)\(outsideOpening)$\(formula)$\(outsideClosing)\(closingMarkdown)\(trailing)"
}

private func inlineMarkdown(_ source: String) -> AttributedString {
    MessageInlinePresentationCache.presentation(source).text
}

private enum InlineMathPresentation {
    private static let nonDollarFormulas = try! NSRegularExpression(
        pattern: #"(?<!\\)\$\$([^\n]+?)(?<!\\)\$\$|\\\[([^\n]+?)\\\]|\\\(([^\n]+?)\\\)"#
    )
    private static let dollarFormula = try! NSRegularExpression(
        pattern: #"(?<![\\$])\$(?!\$)([^$\n]+?)(?<!\\)\$(?!\$)"#
    )
    private static let punctuation = CharacterSet(charactersIn: "，。！？：；、（）《》〈〉【】〔〕「」『』")
    private static let quotes = CharacterSet(charactersIn: "“”‘’")
    private static let closing = CharacterSet(charactersIn: "，。！？：；、）》〉】〕」』")

    static func hasRenderableFormula(in source: String) -> Bool {
        !renderableMatches(in: source).isEmpty
    }

    private static func renderableMatches(in source: String) -> [NSTextCheckingResult] {
        let fullRange = NSRange(source.startIndex..., in: source)
        let nonDollar = nonDollarFormulas.matches(in: source, range: fullRange).filter {
            hasMathSignal(in: $0, source: source)
        }
        var dollarMatches: [NSTextCheckingResult] = []
        var searchLocation = 0
        while searchLocation < fullRange.length,
              let match = dollarFormula.firstMatch(
                in: source,
                range: NSRange(location: searchLocation, length: fullRange.length - searchLocation)
              ) {
            if hasMathSignal(in: match, source: source) {
                dollarMatches.append(match)
                searchLocation = NSMaxRange(match.range)
            } else {
                // A currency pair can consume the opening delimiter of a real
                // formula. Retry just after this dollar so later pairs survive.
                searchLocation = match.range.location + 1
            }
        }
        return (nonDollar + dollarMatches).sorted { $0.range.location < $1.range.location }
    }

    private static func hasMathSignal(in match: NSTextCheckingResult, source: String) -> Bool {
        for index in 1..<match.numberOfRanges {
            guard let range = Range(match.range(at: index), in: source) else { continue }
            let formula = String(source[range])
            guard !formula.unicodeScalars.contains(where: isHan) else { return false }
            return formula.range(
                of: #"\\[A-Za-z]+|[=+*^_{}×÷∑∫≤≥≠±]"#,
                options: .regularExpression
            ) != nil
        }
        return false
    }

    static func html(_ source: String) -> String {
        var prefix = "\u{E000}MC"
        while source.contains(prefix) { prefix += "C" }
        let original = source as NSString
        let matches = renderableMatches(in: source)
        var protected = source
        var expressions: [(marker: String, source: String)] = []
        for (index, match) in matches.enumerated().reversed() {
            let marker = "\(prefix)\(index)\u{E001}"
            expressions.append((marker, original.substring(with: match.range)))
            protected = (protected as NSString).replacingCharacters(in: match.range, with: marker)
        }
        // Parse Markdown around protected formulas. TeX underscores, escapes,
        // and operators never pass through the Markdown parser.
        let parsed = parseInlineMarkdown(protected)
        var result = ""
        for run in parsed.runs {
            let value = String(parsed.characters[run.range])
            let intent = run.inlinePresentationIntent
            let isCode = intent?.contains(.code) == true
            var fragment = isCode ? escaped(value) : hanMarkup(value)
            fragment = fragment.replacingOccurrences(of: "$", with: "<span class=\"literal-dollar\">$</span>")
            if isCode { fragment = "<code>\(fragment)</code>" }
            if intent?.contains(.emphasized) == true { fragment = "<em>\(fragment)</em>" }
            if intent?.contains(.stronglyEmphasized) == true { fragment = "<strong>\(fragment)</strong>" }
            if intent?.contains(.strikethrough) == true { fragment = "<s>\(fragment)</s>" }
            result += fragment
        }
        for expression in expressions {
            result = result.replacingOccurrences(of: expression.marker, with: escaped(expression.source))
        }
        return result
    }

    private static func hanMarkup(_ source: String) -> String {
        let hasHan = source.unicodeScalars.contains(where: isHan)
        var result = ""
        for character in source {
            let scalars = character.unicodeScalars
            let han = scalars.contains { isHan($0) || punctuation.contains($0) || (hasHan && quotes.contains($0)) }
            let fragment = escaped(String(character))
            if han {
                let className = scalars.contains(where: closing.contains) ? "han closing" : "han"
                result += "<span class=\"\(className)\">\(fragment)</span>"
            } else {
                result += fragment
            }
        }
        return result
    }

    private static func isHan(_ scalar: UnicodeScalar) -> Bool {
        (0x3400...0x9FFF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value)
            || (0x20000...0x323AF).contains(scalar.value)
    }

    private static func escaped(_ source: String) -> String {
        source.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// The block cache alone was insufficient: each changed paragraph still parsed
// attributed Markdown and ran math regexes on the main thread. Prime this cache
// alongside the document, before publishing a streamed or loaded message.
enum MessageInlinePresentationCache {
    final class Presentation: NSObject {
        let text: AttributedString
        let responseText: AttributedString
        let responseCodeText: Text?
        let thoughtText: AttributedString
        let thoughtCodeText: Text?
        let mathSource: String
        let mathHTML: String
        let hasInlineMath: Bool
        init(_ source: String) {
            let parsed = parseInlineMarkdown(source)
            text = parsed
            responseText = MyChatResponseTypesetting.response(parsed)
            responseCodeText = Self.codeDecoratedText(responseText, parsed: parsed)
            let thoughtScale = MyChatTypography.thoughtBodySize / MyChatTypography.responseBodySize
            thoughtText = MyChatResponseTypesetting.response(parsed, scale: thoughtScale)
            thoughtCodeText = Self.codeDecoratedText(thoughtText, parsed: parsed)
            mathSource = source.contains("\\") || source.contains("$")
                ? normalizedInlineMathSource(source) : source
            hasInlineMath = containsInlineMath(mathSource)
            mathHTML = hasInlineMath ? InlineMathPresentation.html(mathSource) : ""
        }

        fileprivate static func codeDecoratedText(_ text: AttributedString, parsed: AttributedString) -> Text? {
            guard #available(iOS 18.0, *),
                  parsed.runs.contains(where: { $0.inlinePresentationIntent?.contains(.code) == true }) else {
                return nil
            }
            var decorated = Text("")
            for run in text.runs {
                let fragment = Text(AttributedString(text[run.range]))
                decorated = decorated + (run.inlinePresentationIntent?.contains(.code) == true
                    ? fragment.customAttribute(InlineCodeTextAttribute()) : fragment)
            }
            return decorated
        }
    }
    private static let entries: NSCache<NSString, Presentation> = {
        let cache = NSCache<NSString, Presentation>()
        cache.countLimit = 4096
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()
    static func presentation(_ source: String) -> Presentation {
        let key = source as NSString
        if let existing = entries.object(forKey: key) { return existing }
        let parsed = Presentation(source)
        entries.setObject(parsed, forKey: key, cost: source.utf8.count * 12 + 512)
        return parsed
    }
    static func userMessageText(_ source: String) -> AttributedString {
        AttributedString(source)
    }
    static func prime(_ document: RenderedMessage) {
        for block in document.blocks {
            switch block {
            case .paragraph(let source), .heading(_, let source): _ = presentation(source)
            case .bullets(let items), .numbered(_, let items, _): items.forEach { _ = presentation($0) }
            case .code(_, let source): _ = CodeSyntaxPresentation.highlight(source)
            default: break
            }
        }
    }
}

private func parseInlineMarkdown(_ source: String) -> AttributedString {
    if source.rangeOfCharacter(from: CharacterSet(charactersIn: "*_`[<&~\\")) == nil {
        return AttributedString(source)
    }
    return (try? AttributedString(
        markdown: source,
        options: AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
    )) ?? AttributedString(source)
}

private struct InlineChatError: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(PresentationText.plain(message), systemImage: "exclamationmark.circle")
                .font(MyChatSystemFont.appFont(for: .subheadline, weight: .regular))
                .foregroundStyle(Color.red)
            Button("重试", action: retry)
                .font(MyChatSystemFont.appFont(for: .subheadline, weight: .semibold))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: MyChatTheme.chatCardRadius, style: .continuous))
    }
}

private struct SourcesSheet: View {
    let searches: [ChatToolSearch]
    let openHistorySource: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ChatSheetHeader(title: "来源")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(Array(uniqueResults.enumerated()), id: \.offset) { _, result in
                        if let conversationID = result.conversationID {
                            HistorySearchResultCard(result: result) {
                                openHistorySource(conversationID)
                            }
                        } else {
                            SearchResultCard(result: result)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 32)
            }
        }
        .background(MyChatTheme.canvas)
    }

    private var uniqueResults: [ChatSearchResult] {
        var seen = Set<String>()
        return searches.flatMap(\.results).filter { seen.insert($0.url).inserted }
    }
}

private struct SourceFavicon: View {
    let urlString: String
    let size: CGFloat
    var faviconURL: String? = nil

    private var host: String {
        (URL(string: urlString)?.host ?? urlString)
            .replacingOccurrences(of: "www.", with: "")
            .lowercased()
    }

    private var identity: (glyph: String, foreground: Color, background: Color) {
        if host.contains("wikipedia") {
            return ("W", MyChatTheme.text, MyChatTheme.raised)
        }
        if host.contains("zhihu") {
            return ("知", .white, Color(red: 0.12, green: 0.48, blue: 0.96))
        }
        if host.contains("tencent") || host.contains("qq.com") {
            return ("T", .white, Color(red: 0.10, green: 0.45, blue: 0.90))
        }
        if host.contains("36kr") {
            return ("K", .white, Color(red: 0.19, green: 0.48, blue: 0.93))
        }
        if host.contains("cnbc") {
            return ("C", .white, Color(red: 0.04, green: 0.15, blue: 0.36))
        }
        let glyph = String(host.first ?? "•").uppercased()
        return (glyph, MyChatTheme.text, MyChatTheme.selected)
    }

    var body: some View {
        Group {
            if let source = faviconURL, let url = URL(string: source), url.scheme == "https" {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFit() }
                    else { fallback }
                }
            } else { fallback }
        }
        .frame(width: size, height: size).background(identity.background, in: Circle()).clipShape(Circle())
        .overlay { Circle().stroke(MyChatTheme.border.opacity(0.78), lineWidth: 0.7) }
        .accessibilityHidden(true)
    }
    private var fallback: some View {
        Text(identity.glyph)
            .font(MyChatSystemFont.appFont(size: size * 0.48, design: .rounded, weight: .semibold))
            .foregroundStyle(identity.foreground)
            .frame(width: size, height: size)
    }
}

struct ChatSheetHeader: View {
    @Environment(\.dismiss) private var dismiss
    let title: String

    var body: some View {
        ZStack {
            Text(title)
                .font(MyChatSystemFont.appFont(for: .title3, weight: .semibold))

            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(MyChatSystemFont.appFont(size: 17, weight: .regular))
                }
                .buttonStyle(MyChatIconButtonStyle())
                .accessibilityLabel("关闭")

                Spacer()
            }
        }
        .frame(height: 64)
        .padding(.horizontal, 20)
    }
}

@MainActor
private final class MessageSpeechPlayer: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    @Published private var speakingMessageID: UUID?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func isSpeaking(_ id: UUID) -> Bool {
        speakingMessageID == id && synthesizer.isSpeaking
    }

    func toggle(message: ChatMessage) {
        if isSpeaking(message.id) {
            synthesizer.stopSpeaking(at: .immediate)
            speakingMessageID = nil
            return
        }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: message.content)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speakingMessageID = message.id
        synthesizer.speak(utterance)
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.speakingMessageID = nil }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.speakingMessageID = nil }
    }
}
