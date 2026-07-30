import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

enum AppPalette {
    static let background = adaptive(
        light: UIColor(red: 0.969, green: 0.965, blue: 0.949, alpha: 1),
        dark: UIColor(red: 0.090, green: 0.094, blue: 0.102, alpha: 1)
    )
    static let surface = adaptive(
        light: UIColor(red: 0.992, green: 0.988, blue: 0.973, alpha: 1),
        dark: UIColor(red: 0.118, green: 0.125, blue: 0.133, alpha: 1)
    )
    static let mutedSurface = adaptive(
        light: UIColor(red: 0.933, green: 0.929, blue: 0.906, alpha: 1),
        dark: UIColor(red: 0.145, green: 0.153, blue: 0.165, alpha: 1)
    )
    static let elevatedSurface = adaptive(
        light: .white,
        dark: UIColor(red: 0.176, green: 0.184, blue: 0.200, alpha: 1)
    )
    static let sidebar = adaptive(
        light: UIColor(red: 0.949, green: 0.945, blue: 0.925, alpha: 1),
        dark: UIColor(red: 0.106, green: 0.110, blue: 0.118, alpha: 1)
    )
    static let border = adaptive(
        light: UIColor(red: 0.745, green: 0.733, blue: 0.690, alpha: 0.48),
        dark: UIColor(red: 0.365, green: 0.380, blue: 0.408, alpha: 0.56)
    )
    static let text = Color(uiColor: .label)
    static let secondaryText = Color(uiColor: .secondaryLabel)
    static let thinking = adaptive(
        light: UIColor(red: 0.160784, green: 0.333333, blue: 0.501961, alpha: 1),
        dark: UIColor(red: 0.160784, green: 0.333333, blue: 0.501961, alpha: 1)
    )

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}

@MainActor
final class SessionStore: ObservableObject {
    enum Phase {
        case restoring
        case signedOut
        case signedIn
    }

    @Published var phase: Phase = .restoring
    let api = APIClient()

    func restore() async {
        phase = await api.restoreSession() ? .signedIn : .signedOut
    }

    func signIn(email: String, password: String) async throws {
        try await api.signIn(email: email, password: password)
        phase = .signedIn
    }

    func signOut() {
        Task { await api.signOut() }
        phase = .signedOut
    }
}

struct RootView: View {
    @StateObject private var session = SessionStore()

    var body: some View {
        Group {
            switch session.phase {
            case .restoring:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppPalette.background)
            case .signedOut:
                LoginView(session: session)
            case .signedIn:
                NativeChatView(api: session.api, onSignOut: session.signOut)
                    .id("native-chat")
            }
        }
        .task {
            RichRendererPrewarmer.shared.prepare()
            guard session.phase == .restoring else { return }
            await session.restore()
        }
    }
}

struct LoginView: View {
    @ObservedObject var session: SessionStore
    @State private var email = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var error: String?
    @FocusState private var focusedField: Field?

    private enum Field {
        case email
        case password
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 10) {
                Text("MyChat")
                    .font(.system(size: 34, weight: .semibold))
                Text("登录后继续你的对话")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 36)

            VStack(spacing: 14) {
                TextField("邮箱", text: $email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .textContentType(.username)
                    .focused($focusedField, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .password }
                    .nativeField()

                SecureField("密码", text: $password)
                    .textContentType(.password)
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { submitLogin() }
                    .nativeField()

                if let error {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(action: submitLogin) {
                    Group {
                        if isSubmitting { ProgressView().tint(.white) }
                        else { Text("登录").fontWeight(.semibold) }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppPalette.background)
                .background(AppPalette.text)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .disabled(email.isEmpty || password.isEmpty || isSubmitting)
                .opacity(email.isEmpty || password.isEmpty ? 0.45 : 1)

            }
            .frame(maxWidth: 420)
            Spacer()
            Text("原生 iPhone 客户端 · 1.1")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 24)
        .background(AppPalette.background.ignoresSafeArea())
    }

    private func submitLogin() {
        guard !email.isEmpty, !password.isEmpty, !isSubmitting else { return }
        Task {
            isSubmitting = true
            error = nil
            defer { isSubmitting = false }
            do {
                try await session.signIn(
                    email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                    password: password
                )
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

}

private extension View {
    func nativeField() -> some View {
        self
            .font(.body)
            .padding(.horizontal, 16)
            .frame(height: 52)
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

@MainActor
final class ChatStore: ObservableObject {
    private struct RetryContext {
        let text: String
        let options: ChatRequestOptions
        let attachments: [ChatAttachment]
        let userID: UUID
        let assistantID: UUID
    }

    @Published var conversations: [Conversation] = []
    @Published var selectedConversation: Conversation?
    @Published var messages: [ChatMessage] = []
    @Published var models: [ModelChoice] = ModelChoice.platform
    @Published var selectedModel: ModelChoice = ModelChoice.platform[1]
    @Published var isLoading = true
    @Published var isSending = false
    @Published var error: String?
    @Published var failedMessageID: UUID?

    private let api: APIClient
    private var replyTask: Task<Void, Never>?
    private var retryContext: RetryContext?

    init(api: APIClient) {
        self.api = api
    }

    deinit {
        replyTask?.cancel()
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            models = try await api.models()
            if !models.contains(selectedModel) {
                selectedModel = models.first ?? ModelChoice.platform[1]
            }
            conversations = try await api.conversations()
            if let first = conversations.first {
                try await select(first)
            } else {
                newConversation()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func reloadModels() async {
        do {
            models = try await api.models()
            if !models.contains(selectedModel) {
                selectedModel = models.first ?? ModelChoice.platform[1]
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func select(_ conversation: Conversation) async throws {
        guard selectedConversation?.id != conversation.id || messages.isEmpty else { return }
        replyTask?.cancel()
        isSending = false
        failedMessageID = nil
        retryContext = nil
        selectedConversation = conversation
        messages = try await api.messages(conversationID: conversation.id)
    }

    func newConversation() {
        replyTask?.cancel()
        selectedConversation = Conversation(id: UUID(), title: "新对话", updatedAt: nil)
        messages = []
        isSending = false
        failedMessageID = nil
        retryContext = nil
    }

    func send(
        _ value: String,
        options: ChatRequestOptions = ChatRequestOptions(),
        attachments: [ChatAttachment] = []
    ) {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        if selectedConversation == nil { newConversation() }
        guard let conversation = selectedConversation else { return }

        let history = messages
        let userID = UUID()
        let assistantID = UUID()
        let generationID = UUID()
        let turnStartedAt = Date()
        let createConversation = !conversations.contains { $0.id == conversation.id }
        failedMessageID = nil
        retryContext = nil
        messages.append(ChatMessage(id: userID, role: "user", content: text, createdAt: Date()))
        messages.append(ChatMessage(id: assistantID, role: "assistant", content: "", createdAt: Date()))
        isSending = true

        replyTask = Task {
            defer { isSending = false }
            do {
                let accepted = try await api.enqueue(
                    text: text,
                    conversationID: conversation.id,
                    history: history,
                    model: selectedModel,
                    options: options,
                    attachments: attachments,
                    createConversation: createConversation,
                    conversationTitle: createConversation ? text : conversation.title,
                    userMessageID: userID,
                    assistantMessageID: assistantID,
                    generationID: generationID
                )
                let reply = try await api.streamAssistantReply(
                    accepted,
                    conversationID: conversation.id,
                    assistantMessageID: assistantID,
                    turnStartedAt: turnStartedAt,
                    onUpdate: { [weak self] content, thinking in
                        guard let self,
                              let index = self.messages.firstIndex(where: { $0.id == assistantID })
                        else { return }
                        self.messages[index].content = content
                        self.messages[index].thinking = thinking
                    }
                )
                if let index = messages.firstIndex(where: { $0.id == assistantID }) {
                    messages[index] = reply
                }
                try await refreshConversationList(conversationID: conversation.id)
            } catch is CancellationError {
                return
            } catch {
                failedMessageID = assistantID
                retryContext = RetryContext(
                    text: text,
                    options: options,
                    attachments: attachments,
                    userID: userID,
                    assistantID: assistantID
                )
                self.error = error.localizedDescription
            }
        }
    }

    func retryFailedMessage() {
        guard let retryContext else { return }
        messages.removeAll {
            $0.id == retryContext.userID || $0.id == retryContext.assistantID
        }
        failedMessageID = nil
        self.retryContext = nil
        send(
            retryContext.text,
            options: retryContext.options,
            attachments: retryContext.attachments
        )
    }

    private func refreshConversationList(conversationID: UUID) async throws {
        failedMessageID = nil
        retryContext = nil
        conversations = try await api.conversations()
        selectedConversation = conversations.first(where: { $0.id == conversationID })
            ?? selectedConversation
    }
}

struct NativeChatView: View {
    let api: APIClient
    let onSignOut: () -> Void
    @StateObject private var store: ChatStore
    @State private var sidebarVisible = false
    @State private var attachmentSheetVisible = false
    @State private var destination: WorkspaceDestination?
    @State private var draft = ""
    @State private var requestOptions = ChatRequestOptions()
    @State private var attachments: [ChatAttachment] = []
    @State private var photoPickerVisible = false
    @State private var fileImporterVisible = false
    @State private var cameraVisible = false
    @State private var selectedPhoto: PhotosPickerItem?
    @FocusState private var composerFocused: Bool

    init(api: APIClient, onSignOut: @escaping () -> Void) {
        self.api = api
        _store = StateObject(wrappedValue: ChatStore(api: api))
        self.onSignOut = onSignOut
    }

    var body: some View {
        ZStack(alignment: .leading) {
            AppPalette.background.ignoresSafeArea()
            VStack(spacing: 0) {
                ChatTopBar(
                    models: store.models,
                    selected: store.selectedModel,
                    openSidebar: { sidebarVisible = true },
                    selectModel: { store.selectedModel = $0 },
                    newConversation: store.newConversation
                )
                if store.messages.isEmpty {
                    Color.clear
                } else {
                    MessageList(
                        messages: store.messages,
                        isSending: store.isSending,
                        failedMessageID: store.failedMessageID,
                        retry: store.retryFailedMessage
                    )
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Composer(
                    draft: $draft,
                    isFocused: $composerFocused,
                    isSending: store.isSending,
                    hasAdditions: !requestOptions.isEmpty || !attachments.isEmpty,
                    canSendWithoutText: !attachments.isEmpty,
                    openAttachments: {
                        composerFocused = false
                        attachmentSheetVisible = true
                    },
                    send: {
                        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && !attachments.isEmpty ? "请查看附件" : draft
                        let options = requestOptions
                        let currentAttachments = attachments
                        composerFocused = false
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil,
                            from: nil,
                            for: nil
                        )
                        draft = ""
                        requestOptions = ChatRequestOptions()
                        attachments = []
                        store.send(
                            value,
                            options: options,
                            attachments: currentAttachments
                        )
                    },
                    reportError: { store.error = $0 }
                )
            }
            .disabled(sidebarVisible)

            if !sidebarVisible {
                Color.clear
                    .frame(width: 18)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 18)
                            .onEnded { value in
                                guard value.translation.width > 54,
                                      value.translation.width > abs(value.translation.height) else { return }
                                lightHaptic()
                                withAnimation(.interactiveSpring(response: 0.3, dampingFraction: 0.9)) {
                                    sidebarVisible = true
                                }
                            }
                    )
            }

            if sidebarVisible {
                SidebarOverlay(
                    conversations: store.conversations,
                    close: { sidebarVisible = false },
                    select: { conversation in
                        sidebarVisible = false
                        Task {
                            do { try await store.select(conversation) }
                            catch { store.error = error.localizedDescription }
                        }
                    },
                    newConversation: {
                        store.newConversation()
                        sidebarVisible = false
                    },
                    openDestination: {
                        destination = $0
                        sidebarVisible = false
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .leading).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .zIndex(2)
            }
        }
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.9), value: sidebarVisible)
        .sheet(isPresented: $attachmentSheetVisible) {
            AttachmentActionsSheet(
                options: $requestOptions,
                choosePhoto: {
                    attachmentSheetVisible = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        photoPickerVisible = true
                    }
                },
                takePhoto: {
                    attachmentSheetVisible = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        cameraVisible = true
                    }
                },
                chooseFile: {
                    attachmentSheetVisible = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        fileImporterVisible = true
                    }
                }
            )
                .presentationDetents([.height(426)])
                .presentationDragIndicator(.visible)
                .presentationBackground(AppPalette.background)
        }
        .fullScreenCover(item: $destination, onDismiss: {
            Task { await store.reloadModels() }
        }) { destination in
            WorkspaceDestinationView(
                destination: destination,
                api: api,
                signOut: onSignOut,
                conversationsDeleted: store.newConversation
            )
        }
        .photosPicker(
            isPresented: $photoPickerVisible,
            selection: $selectedPhoto,
            matching: .images
        )
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task { await importPhoto(item) }
        }
        .fileImporter(
            isPresented: $fileImporterVisible,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            importFiles(result)
        }
        .fullScreenCover(isPresented: $cameraVisible) {
            CameraPicker { image in
                cameraVisible = false
                guard let data = image.jpegData(compressionQuality: 0.86) else { return }
                do {
                    try appendAttachment(
                        ChatAttachment(
                        name: "照片-\(attachments.count + 1).jpg",
                        dataURL: Self.dataURL(data, mimeType: "image/jpeg")
                    )
                    )
                    lightHaptic()
                } catch {
                    store.error = error.localizedDescription
                }
            } cancel: {
                cameraVisible = false
            }
            .ignoresSafeArea()
        }
        .alert(
            "提示",
            isPresented: Binding(
                get: { store.error != nil },
                set: { if !$0 { store.error = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(store.error ?? "")
        }
        .task { await store.load() }
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        defer { selectedPhoto = nil }
        do {
            guard let original = try await item.loadTransferable(type: Data.self) else {
                throw APIError.message("照片读取失败")
            }
            let data = Self.preparedImageData(original)
            let type = item.supportedContentTypes.first
            let mime = data == original ? (type?.preferredMIMEType ?? "image/jpeg") : "image/jpeg"
            let suffix = mime == "image/jpeg" ? "jpg" : (type?.preferredFilenameExtension ?? "jpg")
            try appendAttachment(
                ChatAttachment(
                    name: "照片-\(attachments.count + 1).\(suffix)",
                    dataURL: Self.dataURL(data, mimeType: mime)
                )
            )
            lightHaptic()
        } catch {
            store.error = error.localizedDescription
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        do {
            for url in try result.get().prefix(8) {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count <= 5 * 1_024 * 1_024 else {
                    throw APIError.message("\(url.lastPathComponent) 超过 5 MB")
                }
                let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
                let mime = contentType?.preferredMIMEType ?? "application/octet-stream"
                let text = contentType?.conforms(to: .plainText) == true
                    ? String(data: data, encoding: .utf8)
                    : nil
                try appendAttachment(
                    ChatAttachment(
                        name: url.lastPathComponent,
                        dataURL: Self.dataURL(data, mimeType: mime),
                        isPDF: contentType?.conforms(to: .pdf) == true,
                        text: text
                    )
                )
            }
            lightHaptic()
        } catch {
            store.error = error.localizedDescription
        }
    }

    private static func dataURL(_ data: Data, mimeType: String) -> String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }

    private func appendAttachment(_ attachment: ChatAttachment) throws {
        let attachmentSize = attachment.dataURL.utf8.count + (attachment.text?.utf8.count ?? 0)
        let nextSize = attachments.reduce(attachmentSize) {
            $0 + $1.dataURL.utf8.count + ($1.text?.utf8.count ?? 0)
        }
        guard nextSize <= 7_000_000 else {
            throw APIError.message("附件总大小不能超过 7 MB")
        }
        attachments.append(attachment)
    }

    private static func preparedImageData(_ data: Data) -> Data {
        guard data.count > 4_500_000,
              let image = UIImage(data: data),
              let compressed = image.jpegData(compressionQuality: 0.78) else {
            return data
        }
        return compressed
    }
}

struct ChatTopBar: View {
    let models: [ModelChoice]
    let selected: ModelChoice
    let openSidebar: () -> Void
    let selectModel: (ModelChoice) -> Void
    let newConversation: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: openSidebar) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("打开历史对话")

            Spacer(minLength: 0)
            Menu {
                ForEach(models) { model in
                    Button {
                        lightHaptic()
                        selectModel(model)
                    } label: {
                        HStack(spacing: 8) {
                            Group {
                                if model == selected {
                                    Circle()
                                        .fill(AppPalette.text)
                                } else {
                                    Color.clear
                                }
                            }
                            .frame(width: 6, height: 6)
                            Text(model.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(selected.name)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 190)
                .contentShape(Rectangle())
                .frame(minHeight: 44)
            }
            .accessibilityLabel("当前模型，\(selected.name)")
            Spacer(minLength: 0)

            Button(action: newConversation) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("新对话")
        }
        .foregroundStyle(AppPalette.text)
        .padding(.horizontal, 12)
        .frame(height: 54)
        .background(AppPalette.background)
    }
}

struct MessageList: View {
    let messages: [ChatMessage]
    let isSending: Bool
    let failedMessageID: UUID?
    let retry: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(messages) { message in
                        NativeMessageRow(
                            message: message,
                            isActive: isSending && message.id == messages.last?.id,
                            failed: failedMessageID == message.id,
                            retry: retry
                        )
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 24)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _, _ in
                guard let id = messages.last?.id else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
            .onChange(of: messages.last?.content.count) { _, _ in
                guard isSending, let id = messages.last?.id else { return }
                proxy.scrollTo(id, anchor: .bottom)
            }
            .onChange(of: isSending) { _, _ in
                guard let id = messages.last?.id else { return }
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }
}

struct NativeMessageRow: View {
    let message: ChatMessage
    let isActive: Bool
    let failed: Bool
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == "user" {
                VStack(alignment: .trailing, spacing: 5) {
                    Text("你")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppPalette.secondaryText)
                    Text(displayText)
                        .font(.system(size: 16))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .foregroundStyle(AppPalette.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 54)
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Group {
                        if failed && message.content.isEmpty {
                            HStack(spacing: 12) {
                                Text("回复失败")
                                    .font(.system(size: 15))
                                    .foregroundStyle(AppPalette.secondaryText)
                                Button(action: retry) {
                                    Label("重试", systemImage: "arrow.clockwise")
                                        .font(.system(size: 14, weight: .medium))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(AppPalette.text)
                            }
                        } else {
                            ZStack(alignment: .topLeading) {
                                RichAssistantContent(text: displayText, isStreaming: isActive)
                                    .frame(height: message.content.isEmpty ? 0 : nil)
                                    .opacity(message.content.isEmpty ? 0 : 1)
                                    .allowsHitTesting(!message.content.isEmpty)
                                    .accessibilityHidden(message.content.isEmpty)
                                if message.content.isEmpty && isActive {
                                    NativeThinkingIndicator()
                                        .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 27, alignment: .leading)
                    if failed && !message.content.isEmpty {
                        Button(action: retry) {
                            Label("重试", systemImage: "arrow.clockwise")
                                .font(.system(size: 14, weight: .medium))
                                .frame(minHeight: 36)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeOut(duration: 0.18), value: message.content.isEmpty)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var displayText: String {
        return message.content
    }
}

struct Composer: View {
    @Binding var draft: String
    let isFocused: FocusState<Bool>.Binding
    let isSending: Bool
    let hasAdditions: Bool
    let canSendWithoutText: Bool
    let openAttachments: () -> Void
    let send: () -> Void
    let reportError: (String) -> Void
    @StateObject private var speech = SpeechInput()

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Button {
                lightHaptic()
                openAttachments()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(AppPalette.text)
                    .frame(width: 40, height: 40)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(AppPalette.border, lineWidth: 0.7)
                    }
                    .overlay(alignment: .topTrailing) {
                        if hasAdditions {
                            Circle()
                                .fill(AppPalette.thinking)
                                .frame(width: 6, height: 6)
                                .padding(4)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("添加")
            .disabled(isSending || speech.phase.isActive)

            Group {
                if speech.phase.isActive {
                    VoiceActivityView(speech: speech)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    TextField("Ask anything", text: $draft, axis: .vertical)
                        .font(.system(size: 17))
                        .lineLimit(1...6)
                        .focused(isFocused)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 9)
                        .disabled(isSending)
                        .transition(.opacity)
                }
            }
            .frame(minHeight: 40)
            .animation(.easeOut(duration: 0.2), value: speech.phase)

            Button(action: primaryAction) {
                Group {
                    if speech.phase == .transcribing || speech.phase == .preparing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: actionIcon)
                            .font(.system(size: 18, weight: .semibold))
                    }
                }
                .foregroundStyle(actionForeground)
                .frame(width: 40, height: 40)
                .background(actionBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentTransition(.symbolEffect(.replace))
            }
            .disabled(isSending || speech.phase == .preparing || speech.phase == .transcribing)
            .accessibilityLabel(actionAccessibilityLabel)
        }
        .padding(6)
        .background(AppPalette.surface)
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppPalette.border, lineWidth: 0.7)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.045), radius: 7, x: 0, y: 2)
        .padding(.horizontal, 14)
        .padding(.top, 7)
        .padding(.bottom, 8)
        .background(AppPalette.background)
        .onChange(of: speech.phase) { _, phase in
            guard phase == .ready else { return }
            let value = speech.consumeTranscript()
            guard !value.isEmpty else { return }
            draft = value
            isFocused.wrappedValue = true
            lightHaptic()
        }
        .onChange(of: speech.error) { _, value in
            if let value {
                reportError(value)
                speech.error = nil
            }
        }
        .onDisappear { speech.cancel() }
    }

    private var draftIsEmpty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var actionIcon: String {
        if !draftIsEmpty || canSendWithoutText { return "arrow.up" }
        return speech.isRecording ? "checkmark" : "mic"
    }

    private var actionForeground: Color {
        if !draftIsEmpty || canSendWithoutText { return AppPalette.background }
        return AppPalette.text
    }

    private var actionBackground: Color {
        if !draftIsEmpty || canSendWithoutText { return AppPalette.text }
        return AppPalette.mutedSurface
    }

    private var actionAccessibilityLabel: String {
        if !draftIsEmpty || canSendWithoutText { return "发送" }
        switch speech.phase {
        case .recording: return "结束录音"
        case .preparing: return "正在准备录音"
        case .transcribing: return "正在转写"
        case .idle, .ready: return "语音输入"
        }
    }

    private func primaryAction() {
        lightHaptic()
        if !draftIsEmpty || canSendWithoutText {
            speech.cancel()
            send()
            return
        }
        if speech.phase == .recording {
            speech.finish()
        } else {
            Task { await speech.toggle() }
        }
    }
}

private struct VoiceActivityView: View {
    @ObservedObject var speech: SpeechInput

    var body: some View {
        HStack(spacing: 9) {
            VoiceWaveform(level: speech.audioLevel, active: speech.phase == .recording)
                .frame(width: 31, height: 22)

            Text(statusText)
                .font(.system(size: 14))
                .foregroundStyle(AppPalette.secondaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(durationText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(AppPalette.secondaryText)
                .monospacedDigit()
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 40)
    }

    private var statusText: String {
        if speech.phase == .preparing { return "准备录音" }
        if speech.phase == .transcribing { return "正在转写…" }
        let transcript = speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return transcript.isEmpty ? "正在收听" : transcript
    }

    private var durationText: String {
        let total = max(0, Int(speech.elapsed))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct VoiceWaveform: View {
    let level: CGFloat
    let active: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(AppPalette.thinking)
                    .frame(width: 2.5, height: barHeight(index))
            }
        }
        .frame(maxHeight: .infinity)
        .animation(.linear(duration: 0.09), value: level)
        .opacity(active ? 1 : 0.7)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        guard active else { return index == 2 ? 7 : 4 }
        let weights: [CGFloat] = [0.42, 0.74, 1, 0.66, 0.48]
        return 4 + max(0.08, level) * 17 * weights[index]
    }
}

enum WorkspaceDestination: String, Identifiable {
    case projects
    case artifacts
    case code
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .projects: return "项目"
        case .artifacts: return "作品"
        case .code: return "代码"
        case .settings: return "设置"
        }
    }

    var symbol: String {
        switch self {
        case .projects: return "folder"
        case .artifacts: return "square.grid.2x2"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .settings: return "gearshape"
        }
    }
}

struct SidebarOverlay: View {
    let conversations: [Conversation]
    let close: () -> Void
    let select: (Conversation) -> Void
    let newConversation: () -> Void
    let openDestination: (WorkspaceDestination) -> Void
    @State private var dragAxis: Axis?
    @State private var blocksConversationSelection = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Color.black.opacity(0.22)
                    .ignoresSafeArea()
                    .onTapGesture(perform: close)
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("MyChat")
                            .font(.system(size: 20, weight: .semibold))
                        Spacer()
                    }
                    .padding(.leading, 18)
                    .padding(.trailing, 18)
                    .frame(height: 62)

                    VStack(spacing: 0) {
                        SidebarAction(title: "新对话", symbol: "square.and.pencil") {
                            lightHaptic()
                            newConversation()
                        }
                        SidebarAction(title: "项目", symbol: WorkspaceDestination.projects.symbol) {
                            openDestination(.projects)
                        }
                        SidebarAction(title: "作品", symbol: WorkspaceDestination.artifacts.symbol) {
                            openDestination(.artifacts)
                        }
                        SidebarAction(title: "代码", symbol: WorkspaceDestination.code.symbol) {
                            openDestination(.code)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 2)

                    Text("对话记录")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                        .padding(.bottom, 7)

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(conversations) { conversation in
                                Button {
                                    guard !blocksConversationSelection else { return }
                                    lightHaptic()
                                    select(conversation)
                                } label: {
                                    HStack(spacing: 10) {
                                        Text(conversation.title)
                                            .font(.system(size: 15.5))
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .foregroundStyle(AppPalette.text)
                                    .padding(.horizontal, 8)
                                    .frame(height: 43)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                        .allowsHitTesting(!blocksConversationSelection)
                    }
                    .scrollDisabled(isHorizontalDragging)

                    HStack {
                        Spacer()
                        Button {
                            lightHaptic()
                            openDestination(.settings)
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 16, weight: .medium))
                                .frame(width: 36, height: 32)
                                .background(AppPalette.mutedSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .accessibilityLabel("设置")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppPalette.text)
                    .padding(.horizontal, 18)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
                }
                .frame(width: min(350, geometry.size.width * 0.86))
                .background(AppPalette.sidebar)
                .simultaneousGesture(sidebarDragGesture)
            }
        }
    }

    private var isHorizontalDragging: Bool {
        dragAxis == .horizontal
    }

    private var sidebarDragGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onChanged { value in
                guard dragAxis == nil else { return }
                let horizontalDistance = abs(value.translation.width)
                let verticalDistance = abs(value.translation.height)
                guard max(horizontalDistance, verticalDistance) >= 10 else { return }

                dragAxis = horizontalDistance > verticalDistance ? .horizontal : .vertical
                if dragAxis == .horizontal {
                    blocksConversationSelection = true
                }
            }
            .onEnded { value in
                let shouldClose = dragAxis == .horizontal && value.translation.width < -48
                let shouldKeepBlockingSelection = blocksConversationSelection
                dragAxis = nil

                if shouldClose {
                    close()
                }

                guard shouldKeepBlockingSelection else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    blocksConversationSelection = false
                }
            }
    }
}

private struct SidebarAction: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 45, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppPalette.text)
        .padding(.horizontal, 10)
    }
}

private struct AttachmentActionsSheet: View {
    @Binding var options: ChatRequestOptions
    let choosePhoto: () -> Void
    let takePhoto: () -> Void
    let chooseFile: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("添加")
                .font(.system(size: 20, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)

            AttachmentAction(title: "照片", symbol: "photo", action: choosePhoto)
            AttachmentAction(title: "拍照", symbol: "camera", action: takePhoto)
            AttachmentAction(title: "文件", symbol: "doc", action: chooseFile)

            Rectangle()
                .fill(AppPalette.border)
                .frame(height: 0.5)
                .padding(.horizontal, 20)
                .padding(.vertical, 7)

            AttachmentAction(
                title: "联网",
                symbol: "globe",
                selected: options.web
            ) {
                options.web.toggle()
            }
            AttachmentAction(
                title: "检索",
                symbol: "magnifyingglass",
                selected: options.retrieval
            ) {
                options.retrieval.toggle()
            }
            AttachmentAction(
                title: "深度研究",
                symbol: "sparkles",
                selected: options.deepResearch
            ) {
                options.deepResearch.toggle()
            }
        }
        .foregroundStyle(AppPalette.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppPalette.background)
    }
}

private struct AttachmentAction: View {
    let title: String
    let symbol: String
    var selected: Bool?
    let action: () -> Void

    init(
        title: String,
        symbol: String,
        selected: Bool? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.symbol = symbol
        self.selected = selected
        self.action = action
    }

    var body: some View {
        Button {
            lightHaptic()
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 17))
                Spacer()
                if let selected {
                    Circle()
                        .fill(selected ? AppPalette.thinking : .clear)
                        .frame(width: 6, height: 6)
                        .overlay {
                            Circle()
                                .stroke(selected ? .clear : AppPalette.border, lineWidth: 0.7)
                        }
                        .frame(width: 20, height: 20)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
    }
}

private struct WorkspaceDestinationView: View {
    let destination: WorkspaceDestination
    let api: APIClient
    let signOut: () -> Void
    let conversationsDeleted: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if destination == .settings {
                SettingsHomeView(
                    api: api,
                    signOut: signOut,
                    conversationsDeleted: conversationsDeleted
                )
            } else {
                NavigationStack {
                    WorkspaceContentView(destination: destination)
                        .navigationTitle(destination.title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("完成") { dismiss() }
                                    .foregroundStyle(AppPalette.text)
                            }
                        }
                }
            }
        }
    }
}

private struct CameraPicker: UIViewControllerRepresentable {
    let completion: (UIImage) -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion, cancel: cancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.delegate = context.coordinator
        controller.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera)
            ? .camera
            : .photoLibrary
        controller.cameraCaptureMode = .photo
        return controller
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let completion: (UIImage) -> Void
        let cancel: () -> Void

        init(completion: @escaping (UIImage) -> Void, cancel: @escaping () -> Void) {
            self.completion = completion
            self.cancel = cancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage else {
                cancel()
                return
            }
            completion(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            cancel()
        }
    }
}

func lightHaptic() {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
}
