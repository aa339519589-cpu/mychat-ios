import AVFoundation
import Speech
import SwiftUI

struct ComposerView: View {
    @ObservedObject var layoutBudget: ComposerLayoutBudget
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var focused = false
    @State private var isSidebarPresented = false
    @State private var keyboardVisible = false
    @State private var measuredHeight: CGFloat = 104
    @State private var measuredEditorHeight: CGFloat = 26
    @StateObject private var editor = ComposerEditorSession()
    let openTools: () -> Void
    let openModels: () -> Void
    var drawerIsOpen: () -> Bool = { false }
    @StateObject private var dictation = NativeDictationController()
    @State private var dictationError: String?
    @State private var draftBeforeDictation = ""
    @State private var isCancellingDictation = false
    @State private var initialFocusTask: Task<Void, Never>?
    @State private var keyboardProbeTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            if appModel.editingMessageID != nil {
                HStack(spacing: 10) {
                    Image(systemName: "square.and.pencil").font(MyChatSystemFont.appFont(size: 17))
                    Text("正在编辑消息").font(MyChatSystemFont.appFont(size: 13))
                    Spacer()
                    Button { HapticFeedback.play(.selection); appModel.cancelMessageEdit() } label: {
                        Image(systemName: "xmark").font(MyChatSystemFont.appFont(size: 14)).frame(width: 44, height: 44)
                    }.buttonStyle(.plain).accessibilityLabel("取消编辑")
                }
                .foregroundStyle(MyChatTheme.secondaryText).padding(.leading, 15)
                .frame(height: 48).background(MyChatTheme.selected, in: RoundedRectangle(cornerRadius: 18))
                .padding(.horizontal, 8).padding(.top, 8)
            }
            if !appModel.pendingAttachments.isEmpty {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(appModel.pendingAttachments) { attachment in
                            PendingAttachmentChip(
                                attachment: attachment,
                                remove: { HapticFeedback.play(.selection); appModel.removePendingAttachment(id: attachment.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                }
                .scrollIndicators(.hidden)
                .frame(height: 66)
            }

            ComposerTextInput(text: $appModel.draft, focused: $focused, editor: editor,
                              placeholder: composerPlaceholder,
                              maximumHeight: max(1, layoutBudget.availableHeight - max(0, measuredHeight - measuredEditorHeight))) {
                if appModel.canSendCurrentDraft {
                    sendDraftAndDismissKeyboard()
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measuredEditorHeight = $0 }
            .padding(.horizontal, 13)
            .padding(.top, 14)

            if let error = appModel.attachmentError {
                Text(PresentationText.plain(error))
                    .font(MyChatSystemFont.appFont(for: .caption1, weight: .regular))
                    .foregroundStyle(Color.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.top, 5)
            }

            if let dictationError {
                Text(PresentationText.plain(dictationError))
                    .font(MyChatSystemFont.appFont(for: .caption1, weight: .regular))
                    .foregroundStyle(Color.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.top, 5)
            }

            Group {
                if (dictation.isListening || isWaveformFixture) && !isCancellingDictation {
                    dictationControls
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    standardControls
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: dictation.isListening)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isCancellingDictation)
        }
        .frame(minHeight: 98)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(MyChatTheme.text)
        .modifier(SystemComposerSurface(reduceTransparency: usesOpaqueSurface))
        .background {
            if MyChatLayoutAudit.enabled {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { MyChatLayoutAudit.record("input-bubble", frame: proxy.frame(in: .global)) }
                        .onChange(of: proxy.frame(in: .global)) { _, frame in
                            MyChatLayoutAudit.record("input-bubble", frame: frame)
                        }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("composer.surface")
        .padding(.horizontal, keyboardVisible ? 8 : 16)
        .onAppear { requestInitialFocus(); runKeyboardProbeIfRequested() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) {
            updateKeyboardPresence($0)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            // Hardware keyboards can hide the software keyboard while this
            // editor still owns focus. Keyboard visibility must never resign
            // the editor; native delegate events and explicit dismissal own it.
            keyboardVisible = false
        }
        .onChange(of: ComposerNavigationState(appModel: appModel)) { old, new in
            // Privacy changes reuse the same editor and current keyboard state.
            // A second delayed autofocus must not interrupt that transition.
            if old.isPrivate != new.isPrivate {
                initialFocusTask?.cancel()
                initialFocusTask = nil
            } else {
                requestInitialFocus()
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: appModel.pendingAttachments.map(\.id))
        .onChange(of: appModel.editingMessageID) { _, id in
            if id != nil { initialFocusTask?.cancel(); initialFocusTask = nil; focused = true }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.height } action: { height in
            measuredHeight = height
            NotificationCenter.default.post(name: .myChatComposerHeightChanged, object: height)
        }
    .onChange(of: appModel.selectedDestination) { _, destination in
        if destination == .chats {
            requestInitialFocus()
        } else {
            dismissComposer()
            dictation.stop()
        }
    }
    .onReceive(NotificationCenter.default.publisher(for: .myChatDrawerVisibilityChanged)) { note in
        isSidebarPresented = note.object as? Bool ?? false
        if isSidebarPresented { dismissComposer() }
    }
    .onReceive(NotificationCenter.default.publisher(for: .myChatDismissComposer)) { _ in
        dismissComposer()
    }
    .onDisappear { initialFocusTask?.cancel(); keyboardProbeTask?.cancel(); dictation.stop() }
    }

    private func updateKeyboardPresence(_ notification: Notification) {
        guard let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
              let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows).first(where: \.isKeyWindow) else { return }
        let overlap = window.bounds.intersection(window.convert(frame, from: window.screen.coordinateSpace))
        let visible = !overlap.isNull && overlap.height > window.safeAreaInsets.bottom + 1
            && overlap.maxY >= window.bounds.maxY - 1
        // Publish only keyboard presence transitions. Native keyboard layout
        // still owns all vertical avoidance; no frame/height is stored here.
        if keyboardVisible != visible {
            withAnimation(KeyboardTransitionTiming(notification).animation) { keyboardVisible = visible }
        }
    }

    private var standardControls: some View {
        HStack(spacing: 8) {
                Button {
                openTools()
            } label: {
                    Image(systemName: "plus")
                    .font(MyChatSystemFont.appFont(size: 18, weight: .medium))
                    .foregroundStyle(MyChatTheme.text)
            }
            .buttonStyle(ComposerControlStyle())
            .disabled(appModel.editingMessageID != nil)
            .accessibilityLabel("添加内容和工具")
            .accessibilityIdentifier("composer.add")

            Button {
                HapticFeedback.play(.selection)
                openModels()
            } label: {
                HStack(spacing: 5) {
                    if appModel.selectedModel == nil, appModel.catalogPhase == .loading {
                        ProgressView().controlSize(.mini)
                    }
                    Text(modelNameLabel).foregroundStyle(MyChatTheme.text)
                    if appModel.reasoningEnabled {
                        Text(appModel.selectedReasoningEffortLabel).foregroundStyle(MyChatTheme.secondaryText)
                    }
                }
                .font(MyChatTypography.composerChip)
                .lineLimit(1)
                .minimumScaleFactor(0.84)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(MyChatTheme.composerControlSurface, in: Capsule())
                .overlay {
                    if colorScheme == .dark {
                        Capsule().strokeBorder(MyChatTheme.composerControlBorder, lineWidth: 0.8)
                    }
                }
            }
            .buttonStyle(ComposerActionStyle())
            .accessibilityLabel("选择模型")
            .accessibilityValue(modelPickerLabel)
            .accessibilityIdentifier("composer.model-picker")

            Spacer(minLength: 0)

            trailingAction
        }
        .foregroundStyle(MyChatTheme.text)
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var dictationControls: some View {
        HStack(spacing: 10) {
            Button(action: cancelDictation) {
                Image(systemName: "xmark")
                    .font(MyChatSystemFont.appFont(size: 15, weight: .medium))
                    .foregroundStyle(MyChatTheme.text)
            }
            .buttonStyle(MyChatIconButtonStyle(size: 44))
            .accessibilityLabel("取消语音输入")

            ExpandedDictationWaveform(level: isWaveformFixture ? 0.42 : dictation.level).frame(maxWidth: .infinity)
                .accessibilityIdentifier("composer.waveform")

            Button(action: acceptDictation) {
                Image(systemName: "stop.fill")
                    .font(MyChatSystemFont.appFont(size: 15, weight: .semibold))
                    .foregroundStyle(MyChatTheme.text)
                    .frame(width: 36, height: 36)
                    .background(MyChatTheme.composerControlSurface, in: Circle())
                    .overlay {
                        if colorScheme == .dark {
                            Circle().strokeBorder(MyChatTheme.composerControlBorder, lineWidth: 0.8)
                        }
                    }
            }
            .buttonStyle(ComposerActionStyle())
            .accessibilityLabel("暂停语音输入，检查草稿")

            Button {
                dictation.stop()
                sendDraftAndDismissKeyboard()
            } label: {
                Image(systemName: "arrow.up")
                    .font(MyChatSystemFont.appFont(size: 17))
                    .foregroundStyle(MyChatTheme.sendActionForeground)
                    .frame(width: 36, height: 36)
                    .background(MyChatTheme.sendActionSurface, in: Circle())
                    .overlay {
                        if colorScheme == .dark {
                            Circle().strokeBorder(MyChatTheme.composerControlBorder, lineWidth: 0.8)
                        }
                    }
            }
            .buttonStyle(ComposerActionStyle())
            .disabled(!appModel.canSendCurrentDraft)
            .opacity(appModel.canSendCurrentDraft ? 1 : 0.45)
            .accessibilityLabel("发送语音草稿")
        }
        .padding(.horizontal, 8)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var trailingAction: some View {
        if appModel.isCurrentConversationGenerating {
            Button {
                HapticFeedback.play(.stop)
                appModel.stopCurrentGeneration()
            } label: {
                Group {
                    if appModel.isCurrentConversationCancelling {
                        ProgressView().tint(MyChatTheme.text)
                    } else {
                        Image(systemName: "stop.fill").font(MyChatSystemFont.appFont(size: 13, weight: .semibold))
                    }
                }
                .foregroundStyle(MyChatTheme.text)
                .frame(width: 36, height: 36)
                .background(MyChatTheme.composerControlSurface, in: Circle())
                .overlay {
                    if colorScheme == .dark {
                        Circle().strokeBorder(MyChatTheme.composerControlBorder, lineWidth: 0.8)
                    }
                }
            }
            .buttonStyle(ComposerActionStyle())
            .disabled(appModel.isCurrentConversationCancelling)
            .accessibilityLabel("停止生成")
            .accessibilityIdentifier("composer.stop")
        } else if appModel.canSendCurrentDraft {
            Button(action: sendDraftAndDismissKeyboard) {
                Image(systemName: "arrow.up")
                    .font(MyChatSystemFont.appFont(size: 15, weight: .semibold))
                    .foregroundStyle(MyChatTheme.sendActionForeground)
                    .frame(width: 36, height: 36)
                    .background(MyChatTheme.sendActionSurface, in: Circle())
            }
            .buttonStyle(ComposerActionStyle())
            .disabled(!appModel.canSendCurrentDraft)
            .opacity(appModel.canSendCurrentDraft ? 1 : 0.45)
            .accessibilityLabel("发送")
            .accessibilityIdentifier("composer.send")
        } else {
            Button(action: toggleDictation) {
                Image(systemName: "mic")
                    .font(MyChatSystemFont.appFont(size: 18, weight: .regular))
                    .foregroundStyle(MyChatTheme.text)
            }
            .buttonStyle(ComposerControlStyle())
            .accessibilityLabel("语音转文字")
        }
    }

    private var isWaveformFixture: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--ui-test-mode")
            && ProcessInfo.processInfo.arguments.contains("--ui-test-waveform")
        #else
        return false
        #endif
    }

    private func toggleDictation() {
        HapticFeedback.impact()
        if dictation.isListening || dictation.isStarting {
            dictation.stop()
            return
        }

        dictationError = nil
        editor.commitPendingText()
        let existingDraft = appModel.draft
        let context = ComposerNavigationState(appModel: appModel)
        let accountID = appModel.authSession?.user.id
        draftBeforeDictation = existingDraft
        focused = false
        initialFocusTask?.cancel()
        editor.endEditing()
        dictation.start(
            onTranscript: { transcript in
                guard !transcript.isEmpty, ComposerNavigationState(appModel: appModel) == context,
                      appModel.authSession?.user.id == accountID else { return }
                let separator = existingDraft.isEmpty || existingDraft.last?.isWhitespace == true ? "" : " "
                appModel.draft = existingDraft + separator + transcript
            },
            onError: { message in
                HapticFeedback.play(.error)
                dictationError = message
            }
        )
    }

    private func cancelDictation() {
        guard !isCancellingDictation else { return }
        HapticFeedback.impact()
        isCancellingDictation = true
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
            dictation.stop()
        }
        appModel.draft = draftBeforeDictation
        dictationError = nil
        isCancellingDictation = false
        focused = true
    }

    private func acceptDictation() {
        HapticFeedback.play(.selection)
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
            dictation.stop()
        }
        dictationError = nil
        focused = true
    }

    private func sendDraftAndDismissKeyboard() {
        editor.commitPendingText()
        guard appModel.canSendCurrentDraft else { return }
        HapticFeedback.play(.send)
        // Apply the optimistic message insertion and focus change in the same
        // run-loop turn so SwiftUI and UIKit begin their movement together.
        appModel.sendDraft()
        dismissComposer()
    }

    private func dismissComposer() {
        initialFocusTask?.cancel()
        initialFocusTask = nil
        focused = false
        editor.endEditing()
        dictation.stop()
    }

    private func runKeyboardProbeIfRequested() {
        let welcomeProbe = ProcessInfo.processInfo.arguments.contains("--welcome-motion-probe")
        guard welcomeProbe || ProcessInfo.processInfo.arguments.contains("--keyboard-layout-probe") else { return }
        KeyboardMotionAudit.currentReplyState = { [weak appModel] in
            (appModel?.currentReplyPresentationIsReady ?? false, appModel?.messages.last?.content.count ?? 0)
        }
        initialFocusTask?.cancel()
        keyboardProbeTask = Task { @MainActor in
            do {
                for _ in 0..<100 {
                    if appModel.authSession != nil { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard appModel.authSession != nil, appModel.selectedDestination == .chats else { return }
                focused = false
                if welcomeProbe {
                    appModel.beginNewChat()
                    for _ in 0..<50 {
                        if KeyboardMotionAudit.welcomeReady { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    KeyboardMotionAudit.phase = "home-rest"
                    try await Task.sleep(for: .milliseconds(600))
                    for cycle in 0..<3 {
                        KeyboardMotionAudit.phase = "home-open-\(cycle)"; focused = true
                        try await Task.sleep(for: .milliseconds(850))
                        KeyboardMotionAudit.phase = "home-close-\(cycle)"; focused = false
                        try await Task.sleep(for: .milliseconds(850))
                    }
                    for cycle in 0..<2 {
                        KeyboardMotionAudit.phase = "privacy-enter-\(cycle)"; appModel.beginPrivateChat()
                        try await Task.sleep(for: .milliseconds(650))
                        KeyboardMotionAudit.phase = "privacy-exit-\(cycle)"; appModel.beginNewChat()
                        try await Task.sleep(for: .milliseconds(650))
                    }
                    KeyboardMotionAudit.phase = "privacy-interrupted"; appModel.beginPrivateChat()
                    try await Task.sleep(for: .milliseconds(140))
                    appModel.beginNewChat()
                    try await Task.sleep(for: .milliseconds(650))
                    NotificationCenter.default.post(name: .myChatKeyboardProbeFinished, object: nil)
                    return
                }
                // Inspect a real existing transcript when launched on device;
                // this performs the normal read path without sending a turn.
                if appModel.activeConversationID == nil {
                    for _ in 0..<50 {
                        if let conversation = appModel.conversations.first {
                            appModel.openConversation(conversation)
                            break
                        }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                }
                KeyboardMotionAudit.phase = "waiting-for-completed-reply"
                for _ in 0..<300 {
                    if appModel.currentReplyPresentationIsReady,
                       KeyboardMotionAudit.messageFrame != nil,
                       KeyboardMotionAudit.assistantFrame != nil,
                       CACurrentMediaTime() - KeyboardMotionAudit.lastContentChangeTime >= 0.75 { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard appModel.currentReplyPresentationIsReady, KeyboardMotionAudit.messageFrame != nil,
                      KeyboardMotionAudit.assistantFrame != nil,
                      CACurrentMediaTime() - KeyboardMotionAudit.lastContentChangeTime >= 0.75 else {
                    KeyboardMotionAudit.phase = "reply-not-ready"
                    NotificationCenter.default.post(name: .myChatKeyboardProbeFinished, object: nil)
                    return
                }
                for cycle in 0..<3 {
                    KeyboardMotionAudit.phase = "open-\(cycle)"
                    focused = true
                    try await Task.sleep(for: .milliseconds(850))
                    KeyboardMotionAudit.phase = "close-\(cycle)"
                    focused = false
                    try await Task.sleep(for: .milliseconds(850))
                }
                KeyboardMotionAudit.phase = "finished"
                NotificationCenter.default.post(name: .myChatKeyboardProbeFinished, object: nil)
            } catch { }
        }
    }

    private func requestInitialFocus() {
        initialFocusTask?.cancel()
        guard !ProcessInfo.processInfo.arguments.contains(where: { $0 == "--keyboard-layout-probe" || $0 == "--welcome-motion-probe" }) else { return }
        let fixtureFocus = isKeyboardFixtureLaunch
        let defaultEligible = !isSidebarPresented && !drawerIsOpen()
            && appModel.selectedDestination == .chats
            && appModel.activeConversationID == nil
            && appModel.messages.isEmpty
            && !dictation.isListening
        guard fixtureFocus || defaultEligible else { focused = false; return }
        initialFocusTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard !Task.isCancelled else { return }
            let stillEligible = !isSidebarPresented && !drawerIsOpen()
                && appModel.selectedDestination == .chats
                && appModel.activeConversationID == nil
                && appModel.messages.isEmpty
                && !dictation.isListening
            guard fixtureFocus || stillEligible else { return }
            focused = true
        }
    }

    // Device-installation verification fixture: raises the keyboard over an
    // opened conversation without anyone touching the phone. DEBUG only.
    private var isKeyboardFixtureLaunch: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("--ui-test-open-keyboard")
#else
        false
#endif
    }

    private var usesOpaqueSurface: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-mode"),
           ProcessInfo.processInfo.arguments.contains("--ui-test-reduce-transparency") { return true }
        #endif
        return reduceTransparency
    }

    private var composerPlaceholder: String {
        appModel.messages.isEmpty ? "与 MyChat 对话" : "回复 MyChat"
    }

    private var modelNameLabel: String {
        if let selected = appModel.selectedModel { return compactModelName(selected) }
        if appModel.selectedModelID?.hasPrefix(ChatGPTPlanProvider.modelIDPrefix) == true {
            return "ChatGPT 套餐模型暂不可用"
        }
        return "选择模型"
    }

    private var modelPickerLabel: String {
        let modelName = modelNameLabel
        guard appModel.reasoningEnabled else { return modelName }
        return "\(modelName) \(appModel.selectedReasoningEffortLabel)"
    }

    private func compactModelName(_ model: ModelCatalogItem) -> String {
        var name = model.chatDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = name.lowercased().split(separator: "-")
        if components.count >= 3, components[0] == "claude",
           ["sonnet", "opus", "haiku"].contains(String(components[1])),
           components[2].allSatisfy(\.isNumber) {
            let version = components.dropFirst(2).prefix(2)
                .prefix { $0.count < 4 && $0.allSatisfy(\.isNumber) }
                .joined(separator: ".")
            if !version.isEmpty { return "\(components[1].capitalized) \(version)" }
        }
        let prefixes = [
            model.provider + " ",
            "Anthropic ", "Claude ", "DeepSeek ", "Google ", "Gemini ",
            "MiniMax ", "Moonshot ", "Kimi ", "OpenAI ", "GPT-", "GPT ",
            "xAI ", "Grok ", "Z.ai "
        ]

        var removedPrefix = true
        while removedPrefix {
            removedPrefix = false
            for prefix in prefixes where name.lowercased().hasPrefix(prefix.lowercased()) {
                name = String(name.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                removedPrefix = true
                break
            }
        }
        return name.isEmpty ? model.name : name
    }
}

@MainActor
final class NativeDictationController: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var isStarting = false
    @Published private(set) var level: CGFloat = 0

    private var audioEngineCreated = false
    private lazy var audioEngine: AVAudioEngine = { audioEngineCreated = true; return AVAudioEngine() }()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var transcriptHandler: ((String) -> Void)?
    private var errorHandler: ((String) -> Void)?
    private var utteranceHandler: ((String) -> Void)?
    private var accumulatedTranscript = ""
    private var tapInstalled = false
    private var sessionActivated = false
    private var activeSegmentID: UUID?
    private var activeRecognizer: SFSpeechRecognizer?
    private var startRequestID: UUID?
    private let requestSpeechAuthorization: (@escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) -> Void
    private let requestMicrophonePermission: (@escaping (Bool) -> Void) -> Void

    init(
        requestSpeechAuthorization: @escaping (@escaping (SFSpeechRecognizerAuthorizationStatus) -> Void) -> Void = SFSpeechRecognizer.requestAuthorization,
        requestMicrophonePermission: @escaping (@escaping (Bool) -> Void) -> Void = AVAudioApplication.requestRecordPermission
    ) {
        self.requestSpeechAuthorization = requestSpeechAuthorization
        self.requestMicrophonePermission = requestMicrophonePermission
    }

    func start(
        onTranscript: @escaping (String) -> Void,
        onError: @escaping (String) -> Void,
        onUtterance: ((String) -> Void)? = nil
    ) {
        stop()
        let requestID = UUID()
        startRequestID = requestID
        isStarting = true
        transcriptHandler = onTranscript
        errorHandler = onError
        utteranceHandler = onUtterance
        accumulatedTranscript = ""

        requestSpeechAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self, self.startRequestID == requestID else { return }
                guard status == .authorized else {
                    self.fail("请在系统设置中允许 MyChat 使用语音识别")
                    return
                }
                self.requestMicrophonePermission { granted in
                    DispatchQueue.main.async {
                        guard self.startRequestID == requestID else { return }
                        guard granted else {
                            self.fail("请在系统设置中允许 MyChat 使用麦克风")
                            return
                        }
                        self.beginRecording()
                    }
                }
            }
        }
    }

    func stop() {
        startRequestID = nil
        isStarting = false
        tearDownRecognition()
    }

    private func tearDownRecognition() {
        isListening = false
        activeSegmentID = nil
        if audioEngineCreated && audioEngine.isRunning {
            audioEngine.stop()
        }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        activeRecognizer = nil
        level = 0
        if sessionActivated {
            sessionActivated = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func beginRecording() {
        tearDownRecognition()
        isStarting = false
        guard let recognizer = preferredRecognizer(), recognizer.isAvailable else {
            fail("Apple 语音识别服务暂时不可用")
            return
        }
        activeRecognizer = recognizer

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            sessionActivated = true
            isListening = true
            try startRecognitionSegment(using: recognizer)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func startRecognitionSegment(using recognizer: SFSpeechRecognizer) throws {
        if audioEngineCreated && audioEngine.isRunning {
            audioEngine.stop()
        }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "MyChatSpeech", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "麦克风没有可用音频输入，请检查音频设备后重试"])
        }
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let strength = Self.normalizedLevel(from: buffer)
            DispatchQueue.main.async {
                self?.level = strength
            }
        }
        tapInstalled = true

        let segmentID = UUID()
        activeSegmentID = segmentID
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self,
                      self.isListening,
                      self.activeSegmentID == segmentID else { return }

                if let result {
                    let segment = result.bestTranscription.formattedString
                    self.publish(segment)
                    if result.isFinal {
                        self.commit(segment)
                        if let utteranceHandler = self.utteranceHandler {
                            let utterance = self.accumulatedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                            self.accumulatedTranscript = ""
                            if !utterance.isEmpty {
                                self.stop()
                                utteranceHandler(utterance)
                                return
                            }
                        }
                        self.restartRecognitionAfterFinal()
                        return
                    }
                }
                if let error {
                    self.fail(error.localizedDescription)
                }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func publish(_ segment: String) {
        let segment = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !segment.isEmpty else { return }
        let prefix = accumulatedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        transcriptHandler?(prefix.isEmpty ? segment : prefix + " " + segment)
    }

    private func commit(_ segment: String) {
        let segment = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !segment.isEmpty else { return }
        let prefix = accumulatedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        accumulatedTranscript = prefix.isEmpty ? segment : prefix + " " + segment
    }

    private func restartRecognitionAfterFinal() {
        activeSegmentID = nil
        if audioEngineCreated && audioEngine.isRunning {
            audioEngine.stop()
        }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        request?.endAudio()
        request = nil
        task = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.isListening, let recognizer = self.activeRecognizer else { return }
            do {
                try self.startRecognitionSegment(using: recognizer)
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    private func preferredRecognizer() -> SFSpeechRecognizer? {
        let inputLanguages = UITextInputMode.activeInputModes.compactMap(\.primaryLanguage)
        let preferredLanguages = Locale.preferredLanguages
        var candidates: [String] = ["zh-CN", "zh-Hans-CN", "zh-TW", "zh-HK"]
candidates.append(contentsOf: inputLanguages.filter { $0.lowercased().hasPrefix("zh") })
candidates.append(contentsOf: preferredLanguages.filter { $0.lowercased().hasPrefix("zh") })
candidates.append(contentsOf: preferredLanguages)
candidates.append(contentsOf: inputLanguages)
candidates.append(Locale.current.identifier)
candidates.append("en-US")
        var seen = Set<String>()
        for identifier in candidates {
            let normalized = identifier.replacingOccurrences(of: "_", with: "-")
            guard seen.insert(normalized.lowercased()).inserted else { continue }
            let locale = Locale(identifier: normalized)
            guard SFSpeechRecognizer.supportedLocales().contains(locale) else { continue }
            if let recognizer = SFSpeechRecognizer(locale: locale) {
                return recognizer
            }
        }
        return SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    }

    private func fail(_ message: String) {
        stop()
        errorHandler?(message)
    }

    nonisolated private static func normalizedLevel(from buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<count {
            let sample = channel[index]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(count))
        let decibels = 20 * log10(max(rms, 0.000_01))
        return CGFloat(pow(min(max((decibels + 52) / 32, 0), 1), 0.55))
    }
}

private struct ExpandedDictationWaveform: View {
    let level: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DictationWaveformSurface(level: level, reduceMotion: reduceMotion)
        .frame(height: 40)
        .accessibilityLabel("正在识别语音")
    }
}

private struct DictationWaveformSurface: UIViewRepresentable {
    let level: CGFloat
    let reduceMotion: Bool
    func makeUIView(context: Context) -> NativeDictationWaveSurface { NativeDictationWaveSurface() }
    func updateUIView(_ view: NativeDictationWaveSurface, context: Context) {
        view.level = level; view.reducedMotion = reduceMotion; view.updatePlayback()
    }
    static func dismantleUIView(_ view: NativeDictationWaveSurface, coordinator: ()) { view.stop() }
}
final class NativeDictationWaveSurface: UIView {
    var level: CGFloat = 0
    var reducedMotion = false
    private let waveform = CAShapeLayer()
    private var displayLink: CADisplayLink?
    private var previousTime: CFTimeInterval?
    private var offset: CGFloat = 0
    private var sampleIndex = 0
    private var samples: [CGFloat] = Array(repeating: 0, count: 120)
    private var observers: [NSObjectProtocol] = []
    private lazy var displayTarget = WaveformDisplayTarget(self)
    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = .clear; clipsToBounds = true
        layer.addSublayer(waveform)
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updatePlayback()
            })
        }
    }
    deinit { displayLink?.invalidate(); observers.forEach(NotificationCenter.default.removeObserver) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func layoutSubviews() { super.layoutSubviews(); waveform.frame = bounds; draw() }
    override func didMoveToWindow() { super.didMoveToWindow(); updatePlayback() }
    func updatePlayback() {
        if window != nil && !reducedMotion && UIApplication.shared.applicationState == .active {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: displayTarget, selector: #selector(WaveformDisplayTarget.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            displayLink = link; link.add(to: .main, forMode: .common)
        } else { stop(); draw() }
    }
    fileprivate func tick(_ link: CADisplayLink) {
        let elapsed = min(0.05, max(0, link.timestamp - (previousTime ?? link.timestamp - link.duration)))
        previousTime = link.timestamp
        offset += CGFloat(elapsed) * 70
        while offset >= 5 {
            offset -= 5
            samples[sampleIndex] = min(max(level, 0), 1)
            sampleIndex = (sampleIndex + 1) % samples.count
        }
        draw()
    }
    private func draw() {
        guard bounds.width > 0, bounds.height > 4 else { return }
        let count = min(samples.count, Int(ceil(bounds.width / 5)) + 2)
        let path = UIBezierPath()
        for index in 0..<count {
            let sample = reducedMotion ? level : samples[(sampleIndex + samples.count - count + index) % samples.count]
            let height = min(bounds.height - 4, 3 + max(0, sample) * 36)
            path.append(UIBezierPath(roundedRect: CGRect(x: CGFloat(index) * 5 - offset, y: (bounds.height - height) / 2,
                width: 2.4, height: height), cornerRadius: 1.2))
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        waveform.fillColor = UIColor(MyChatTheme.text).withAlphaComponent(0.82).cgColor
        waveform.path = path.cgPath
        CATransaction.commit()
    }
    func stop() { displayLink?.invalidate(); displayLink = nil; previousTime = nil }
}

private final class WaveformDisplayTarget: NSObject {
    weak var view: NativeDictationWaveSurface?
    init(_ view: NativeDictationWaveSurface) { self.view = view }
    @objc func tick(_ link: CADisplayLink) { view?.tick(link) }
}

private struct PendingAttachmentChip: View {
    let attachment: ChatPendingAttachment
    let remove: () -> Void
    @State private var thumbnail: UIImage?

    @ViewBuilder
    var body: some View {
        if attachment.kind == .image {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = thumbnail {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "photo")
                            .font(MyChatSystemFont.appFont(size: 18, weight: .medium))
                            .foregroundStyle(MyChatTheme.secondaryText)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(MyChatTheme.selected)
                    }
                }
                .frame(width: 54, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(MyChatSystemFont.appFont(size: 9, weight: .bold))
                        .foregroundStyle(MyChatTheme.text)
                        .frame(width: 20, height: 20)
                        .background(MyChatTheme.canvas.opacity(0.94), in: Circle())
                        .frame(width: 44, height: 44, alignment: .topTrailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("移除 \(attachment.name)")
                .accessibilityIdentifier("attachment.remove-" + attachment.id.uuidString)
            }
            .frame(width: 58, height: 58)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("图片附件")
            .accessibilityIdentifier("attachment.image")
            .task(id: attachment.imageDataURL) {
                guard let source = attachment.imageDataURL else { return }
                let image = await Task.detached(priority: .utility) { ChatImageThumbnailCache.image(source) }.value
                guard !Task.isCancelled else { return }
                thumbnail = image
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: attachment.kind == .pdf ? "doc.richtext" : "doc.text")
                    .font(MyChatSystemFont.appFont(size: 17, weight: .medium))
                    .foregroundStyle(MyChatTheme.secondaryText)
                    .frame(width: 34, height: 34)
                    .background(MyChatTheme.selected, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                Text(attachment.name)
                    .font(MyChatSystemFont.appFont(for: .caption1, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: 118, alignment: .leading)

                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(MyChatSystemFont.appFont(size: 11, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.06), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("移除 \(attachment.name)")
                .accessibilityIdentifier("attachment.remove-" + attachment.id.uuidString)
            }
            .padding(.leading, 6)
            .padding(.trailing, 4)
            .frame(height: 48)
            .background(MyChatTheme.raised, in: Capsule())
            .overlay { Capsule().stroke(MyChatTheme.border.opacity(0.8), lineWidth: 0.7) }
        }
    }
}

private struct ComposerNavigationState: Equatable {
    let conversationID: UUID?
    let revision: Int
    let isPrivate: Bool
    @MainActor init(appModel: AppModel) {
        conversationID = appModel.activeConversationID
        revision = appModel.newChatRevision
        isPrivate = appModel.isPrivateChat
    }
}

// UIKit owns editing, marked text, selection and scrolling. SwiftUI only asks
// for the bounded content height; the keyboard never supplies an editor height.
@MainActor final class ComposerEditorSession: ObservableObject {
    weak var textView: UITextView?
    var commit: (() -> Void)?
    func commitPendingText() { textView?.unmarkText(); commit?() }
    func endEditing() { textView?.resignFirstResponder() }
}

struct ComposerTextInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let editor: ComposerEditorSession
    let placeholder: String
    var maximumHeight: CGFloat = .greatestFiniteMagnitude
    let submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ComposerTextView {
        let view = ComposerTextView()
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        view.isScrollEnabled = false
        view.textContainer.lineFragmentPadding = 0
        view.contentInset = .zero
        view.contentInsetAdjustmentBehavior = .never
        view.showsVerticalScrollIndicator = false
        view.returnKeyType = .send
        view.delegate = context.coordinator
        editor.textView = view
        editor.commit = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.commitText(view)
        }
        view.didEnterWindow = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.applyPendingFocus(to: view)
        }
        view.accessibilityLabel = "消息"
        view.accessibilityIdentifier = "composer.input"
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: ComposerTextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.acceptModelText(text)
        view.font = MyChatSystemFont.scaledUIFont(
            MyChatSystemFont.appUIFont(size: 18),
            relativeTo: .body,
            compatibleWith: view.traitCollection
        )
        view.adjustsFontForContentSizeCategory = true
        view.textColor = UIColor(MyChatTheme.text)
        view.tintColor = UIColor(MyChatTheme.secondaryText)
        view.placeholder.text = placeholder
        view.placeholder.font = view.font
        view.placeholder.textColor = UIColor(MyChatTheme.secondaryText)
        if view.text != text, view.markedTextRange == nil, context.coordinator.pendingEdit == nil {
            view.text = text
            view.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
        view.placeholder.isHidden = !view.text.isEmpty
        context.coordinator.requestFocus(focused, in: view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let lineHeight = ceil(uiView.font?.lineHeight ?? 22)
        let natural = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let maximum = max(lineHeight + 4, min(lineHeight * 5 + 4, maximumHeight))
        let scrolls = natural > maximum + 0.5
        if uiView.isScrollEnabled != scrolls { uiView.isScrollEnabled = scrolls }
        if !scrolls, uiView.contentOffset != .zero { uiView.setContentOffset(.zero, animated: false) }
        return CGSize(width: width, height: min(max(ceil(natural), lineHeight + 4), maximum))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextInput
        var pendingEdit: String?
        var focusPublicationPending = false
        private var editRevision = 0
        private var lastModelText = ""
        private var lastPublishedText: String?
        private var consumedFocus = false
        private var pendingFocus = false
        private var focusRevision = 0
        func requestFocus(_ focused: Bool, in view: UITextView) {
            guard focused != consumedFocus else { return }
            if !focused, focusPublicationPending { return }
            consumedFocus = focused
            pendingFocus = focused
            focusRevision += 1
            if focused { applyPendingFocus(to: view) }
            else { view.resignFirstResponder() }
        }
        func applyPendingFocus(to view: UITextView) {
            guard pendingFocus, view.window != nil else { return }
            pendingFocus = false
            if !view.isFirstResponder { view.becomeFirstResponder() }
        }
        func commitText(_ view: UITextView) {
            editRevision += 1
            pendingEdit = nil
            lastPublishedText = view.text ?? ""
            parent.text = view.text ?? ""
        }
        func acceptModelText(_ text: String) {
            guard text != lastModelText else { return }
            lastModelText = text
            // Acknowledging our previous keystroke must not discard a newer
            // native edit which has not yet reached the SwiftUI binding.
            if text != lastPublishedText, let pendingEdit, pendingEdit != text {
                self.pendingEdit = nil; editRevision += 1
            }
        }
        init(_ parent: ComposerTextInput) {
            self.parent = parent
            self.lastModelText = parent.text
        }

        func textViewDidChange(_ view: UITextView) {
            let value = view.text ?? ""
            pendingEdit = value
            editRevision += 1
            let revision = editRevision
            (view as? ComposerTextView)?.placeholder.isHidden = !value.isEmpty
            view.invalidateIntrinsicContentSize()
            // Let UIKit finish its caret/marked-text transaction before
            // notifying SwiftUI. A synchronous write reentered updateUIView
            // with the old selection and inserted the next character in front.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.editRevision == revision else { return }
                self.pendingEdit = nil
                self.lastPublishedText = value
                self.parent.text = value
            }
        }

        func textViewDidBeginEditing(_ view: UITextView) {
            consumedFocus = true
            pendingFocus = false
            focusRevision += 1
            let revision = focusRevision
            focusPublicationPending = true
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self else { return }
                defer { self.focusPublicationPending = false }
                guard self.focusRevision == revision, view?.isFirstResponder == true else { return }
                if !self.parent.focused { self.parent.focused = true }
            }
        }

        func textViewDidEndEditing(_ view: UITextView) {
            // Keep the last true command consumed until SwiftUI acknowledges
            // the native dismissal. A stream/layout redraw cannot refocus it.
            pendingFocus = false
            focusRevision += 1
            let revision = focusRevision
            focusPublicationPending = false
            if !parent.focused { return }
            // UIKit can resign for a sheet or interactive keyboard dismissal.
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, self.focusRevision == revision, view?.isFirstResponder != true else { return }
                self.parent.focused = false
            }
        }

        func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n", view.markedTextRange == nil {
                editRevision += 1
                pendingEdit = nil
                lastPublishedText = view.text ?? ""
                parent.text = view.text
                parent.submit()
                return false
            }
            return true
        }
    }
}

final class ComposerTextView: UITextView {
    let placeholder = UILabel()
    var didEnterWindow: (() -> Void)?
    override func didMoveToWindow() { super.didMoveToWindow(); if window != nil { didEnterWindow?() } }
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholder.isUserInteractionEnabled = false
        placeholder.isAccessibilityElement = false
        addSubview(placeholder)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func layoutSubviews() {
        super.layoutSubviews()
        placeholder.frame = CGRect(x: 0, y: 2, width: bounds.width, height: ceil(font?.lineHeight ?? 22))
    }
}

private struct ComposerControlStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 36, height: 36)
            .background(MyChatTheme.composerControlSurface, in: Circle())
            .overlay {
                if colorScheme == .dark {
                    Circle().strokeBorder(MyChatTheme.composerControlBorder, lineWidth: 0.8)
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .modifier(MyChatBubblePressFeedback(isPressed: configuration.isPressed, glassOwnsFeedback: false))
    }
}

private struct ComposerActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .modifier(MyChatBubblePressFeedback(isPressed: configuration.isPressed, glassOwnsFeedback: false))
    }
}

private struct SystemComposerSurface: ViewModifier {
    let reduceTransparency: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: MyChatTheme.composerRadius, style: .continuous)
        // A stable writing surface: scrolling text/photos cannot tint the
        // editor or alter its contrast. Clip content first; the rounded shape
        // alone casts the small contact shadow, never its rectangular host.
        content
            .background { shape.fill(MyChatTheme.composer) }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(MyChatTheme.border.opacity(contrast == .increased ? 1 : 0.7),
                    lineWidth: contrast == .increased ? 1 : 1 / max(1, displayScale))
            }
            .shadow(color: .black.opacity(reduceTransparency ? 0 : colorScheme == .dark ? 0.18 : 0.055),
                radius: 3, x: 0, y: 1)
    }
}

extension Notification.Name {
    static let myChatKeyboardProbeFinished = Notification.Name("mychat.keyboard.probe.finished")
    static let myChatComposerHeightChanged = Notification.Name("mychat.composer.height")
    static let myChatDrawerVisibilityChanged = Notification.Name("mychat.drawer.visibility")
    static let myChatDrawerInteractionChanged = Notification.Name("mychat.drawer.interaction")
}
