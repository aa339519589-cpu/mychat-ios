import AuthenticationServices
import SwiftUI
import UIKit

struct CodeLanding: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var newSessionPresented = false
    @State private var selectedSession: CodeSessionRecord?
    @State private var deletionError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                    Text(PresentationText.plain(appModel.codeError ?? "暂无会话"))
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
                                            .frame(width: 44, height: 44)
                                            .background(MyChatTheme.selected, in: RoundedRectangle(cornerRadius: 12))
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(session.displayTitle)
                                                .font(MyChatTypography.cardTitle)
                                                .lineSpacing(MyChatTypography.utilityLineSpacing)
                                                .lineLimit(1)
                                            if let repository = session.displayRepository {
                                                Text(repository)
                                                    .font(MyChatTypography.caption)
                                                    .lineSpacing(MyChatTypography.captionLineSpacing)
                                                    .foregroundStyle(MyChatTheme.secondaryText)
                                                    .lineLimit(1)
                                            }
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
                                .accessibilityIdentifier("code.session.\(session.id)")

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
                                        Label("删除会话", systemImage: "trash")
                                    }
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .font(MyChatSystemFont.appFont(size: 17, weight: .semibold))
                                        .frame(width: 48, height: 66)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("编程会话操作")
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
                Text("新建会话")
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
            await openPendingLink()
        }
        .onChange(of: appModel.pendingCodeLink) { _, _ in Task { await openPendingLink() } }
        .fullScreenCover(isPresented: $newSessionPresented) {
            CodeNewSessionView()
                .environmentObject(appModel)
        }
        .fullScreenCover(item: $selectedSession) { session in
            CodeSessionDetailView(session: session)
                .environmentObject(appModel)
        }
        .alert(
            "无法删除编程会话",
            isPresented: Binding(
                get: { deletionError != nil },
                set: { if !$0 { deletionError = nil } }
            )
        ) {
            Button("好", role: .cancel) { deletionError = nil }
        } message: {
            Text(PresentationText.plain(deletionError ?? ""))
        }
    }

    private func openPendingLink() async {
        guard let url = appModel.pendingCodeLink else { return }
        let owner = appModel.authSession?.user.id
        appModel.pendingCodeLink = nil
        let parts = url.path.split(separator: "/")
        if parts == ["new"] {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            let repo = values["repo"]
            if let repo, (try? await appModel.githubRepositories().contains { $0.fullName == repo }) != true {
                deletionError = "此仓库未授权，无法打开任务草稿"; return
            }
            guard owner == appModel.authSession?.user.id else { return }
            CodeLocalState.save(CodeDraftRecord(prompt: values["q"] ?? "", repository: repo,
                branch: values["branch"] ?? ""), owner: appModel.authSession?.user.id ?? "", scope: "new")
            newSessionPresented = true
        } else if parts.count == 2 {
            await appModel.reloadWorkspaceData()
            guard let taskID = UUID(uuidString: String(parts[1])),
                  let recovered = try? await appModel.recoverCodeTask(taskID: taskID),
                  let sessionID = recovered.sessionId,
                  let record = appModel.codeSessions.first(where: { $0.id.lowercased() == sessionID.lowercased() }) else {
                deletionError = "会话不存在或尚未授权"; return
            }
            guard owner == appModel.authSession?.user.id else { return }
            selectedSession = record
        }
    }
}

private struct CodeSendButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

private struct CodeSessionDetailView: View {
    @EnvironmentObject private var appModel: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let session: CodeSessionRecord
    let initialTurn: CodeTurnStart?
    @State private var messages: [CodeMessageRecord] = []
    @State private var isLoading = true
    @State private var isAdmitting = false
    @State private var pendingUserID: String?
    @State private var errorMessage: String?
    @State private var draft = ""
    @State private var activeAdmission: CodeAdmission?
    @State private var isCancelling = false
    @State private var eventSubscription: Task<Void, Never>?
    @State private var eventSubscriptionJobID: UUID?
    @State private var eventSubscriptionToken: UUID?
    @State private var cancellationReconciliation: Task<Void, Never>?
    @State private var cancellationReconciliationToken: UUID?
    @State private var cancellationPending = false
    @State private var cancellationRetryAllowed = false
    @State private var streamedResponseID: UUID?
    @State private var streamedContent = ""
    @State private var steps: [CodeAgentStep] = []
    @State private var toolActivities: [ChatToolActivity] = []
    @State private var taskDetail: CodeTaskDetail?
    @State private var isReplayingTerminalRecovery = false
    @State private var branch = ""
    @State private var isRecovering = false
    @State private var hasSavedSettings = false
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
        if let initialTurn {
            let responseID = initialTurn.admission.responseID ?? initialTurn.admission.taskID
            _messages = State(initialValue: [initialTurn.userMessage,
                CodeMessageRecord(id: responseID.uuidString.lowercased(), sessionID: session.id,
                    role: "assistant", content: "", metadata: nil, createdAt: nil)])
            _isLoading = State(initialValue: false)
            _activeAdmission = State(initialValue: initialTurn.admission)
            _streamedResponseID = State(initialValue: responseID)
        }
    }

    var body: some View {
        ZStack {
            MyChatTheme.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                ZStack {
                    VStack(spacing: 2) {
                        Text(session.displayTitle)
                            .font(MyChatSystemFont.appFont(size: 19, weight: .semibold))
                            .lineLimit(1)
                            .accessibilityIdentifier("code.session.title")
                        if let repository = session.displayRepository {
                            Text(repository)
                                .font(MyChatSystemFont.appFont(for: .caption1, weight: .regular))
                                .foregroundStyle(MyChatTheme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "arrow.left")
                                .font(MyChatSystemFont.appFont(size: 18, weight: .regular))
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(MyChatIconButtonStyle())
                        .accessibilityLabel("返回 Code")
                        .accessibilityIdentifier("code.session.back")
                        Spacer()
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 66)
                if !branch.isEmpty { Text(branch).font(MyChatTypography.caption).padding(.vertical, 6) }

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage, messages.isEmpty {
                    VStack(spacing: 14) {
                        Text(PresentationText.plain(errorMessage))
                            .foregroundStyle(MyChatTheme.secondaryText)
                            .multilineTextAlignment(.center)
                        Button("重试") { Task { await load() } }
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
                                .environment(\.responseIsStreaming,
                                    activeAdmission != nil && message.id.lowercased() == streamedResponseID?.uuidString.lowercased())
                            }

                            if isAdmitting || (activeAdmission != nil && !isTerminalCodeStatus(activeAdmission?.status)) {
                                DotThinkingView(isGenerating: true)
                                    .frame(width: 48, height: 48)
                                    .accessibilityLabel("编程任务正在处理")
                            }

                            if isReplayingTerminalRecovery {
                                Label("正在恢复任务记录", systemImage: "arrow.clockwise")
                                    .font(MyChatTypography.caption)
                                    .foregroundStyle(MyChatTheme.secondaryText)
                                    .accessibilityLabel("正在恢复已完成任务的记录")
                                    .accessibilityIdentifier("code.terminal-replay")
                            }

                            if !steps.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Label("智能体活动", systemImage: "terminal")
                                        .font(MyChatSystemFont.appFont(for: .caption1, weight: .semibold))
                                        .foregroundStyle(MyChatTheme.secondaryText)
                                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                                        Label(PresentationText.plain(step.label), systemImage: "checkmark.circle")
                                            .font(MyChatSystemFont.appFont(size: 14, design: .monospaced, weight: .regular))
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            ForEach(toolActivities, id: \.toolCallID) { activity in
                                Label(activity.toolName, systemImage: activity.isComplete ? "checkmark.circle" : "gearshape")
                                    .font(MyChatTypography.appStatus)
                                    .accessibilityLabel("\(activity.toolName)，\(activity.isComplete ? "已完成" : "正在执行")")
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
                                    Text("计划中的更改")
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
                            if let taskDetail { CodeTaskEvidenceView(detail: taskDetail) }

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
                                        isProvisionalRepository ? "创建仓库" : "发布拉取请求",
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
                    .refreshable { await load(); await recover() }
                }

                HStack(alignment: .center, spacing: 4) {
                    Button {
                        composerFocused = false
                        commandDestination = .actions
                    } label: {
                        Image(systemName: "plus")
                            .font(MyChatSystemFont.appFont(size: 20, weight: .regular))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("打开编程操作")
                    .disabled(isReplayingTerminalRecovery)

                    TextField("向 MyChat 编程发送消息", text: $draft, axis: .vertical)
                        .font(MyChatTypography.composerText)
                        .lineLimit(1...5)
                        .focused($composerFocused)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 10)
                        .accessibilityIdentifier("code.session.draft")
                        .disabled(isReplayingTerminalRecovery)
                    Button {
                        if let activeAdmission {
                            Task { await stop(activeAdmission) }
                        } else {
                            Task { await send() }
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(MyChatTheme.brand)
                                .frame(width: 40, height: 40)
                            if isCancelling || (activeAdmission == nil && (isAdmitting || isApplying)) {
                                ProgressView().tint(MyChatTheme.onBrand)
                            } else if activeAdmission != nil {
                                Image(systemName: "stop.fill")
                                    .font(MyChatSystemFont.appFont(size: 15, weight: .bold))
                                    .foregroundStyle(MyChatTheme.onBrand)
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(MyChatSystemFont.appFont(size: 17, weight: .bold))
                                    .foregroundStyle(MyChatTheme.onBrand)
                            }
                        }
                        .frame(width: 44, height: 44)
                    }
                    .buttonStyle(CodeSendButtonStyle())
                    .disabled(isCancelling || (cancellationPending && !cancellationRetryAllowed)
                        || (activeAdmission == nil && (isAdmitting || isApplying || isReplayingTerminalRecovery || !canSend)))
                    .opacity(activeAdmission != nil || canSend ? 1 : 0.45)
                    .accessibilityLabel(activeAdmission != nil
                        ? (isCancelling ? "正在停止 Code 任务"
                            : (cancellationPending
                                ? (cancellationRetryAllowed ? "重试停止 Code 任务" : "等待停止确认")
                                : "停止 Code 任务"))
                        : ((isAdmitting || isApplying) ? "正在处理 Code 任务"
                            : (isReplayingTerminalRecovery ? "正在恢复任务记录" : "发送编程消息")))
                    .accessibilityHint(activeAdmission != nil
                        ? (cancellationPending
                            ? (cancellationRetryAllowed ? "取消状态待确认；可重试同一任务" : "云端正在确认取消")
                            : "取消正在运行的云端任务")
                        : "发送 Code 任务")
                    .accessibilityIdentifier("code.session.send")
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .frame(minHeight: 56)
                .background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(MyChatTheme.border.opacity(0.8), lineWidth: 0.7)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }

        }
        .foregroundStyle(MyChatTheme.text)
        .task {
            let saved = CodeLocalState.draft(owner: appModel.authSession?.user.id ?? "", scope: session.id)
            hasSavedSettings = CodeLocalState.containsDraft(owner: appModel.authSession?.user.id ?? "", scope: session.id)
            draft = saved.prompt; branch = saved.branch
            if !consumedInitialTurn, let initialTurn {
                consumedInitialTurn = true
                prepare(initialTurn)
                isLoading = false
                startConsuming(initialTurn.admission)
            } else {
                await load()
                await recover()
            }
        }
        .onChange(of: draft) { _, value in
            saveSessionDraft()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, activeAdmission == nil, !isReplayingTerminalRecovery {
                Task { await load(); await recover() }
            }
        }
        .sheet(item: $commandDestination) { destination in
            actionSheet(destination)
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
                cancel: { Task {
                    do { try await appModel.rejectCodeOperation(request); confirmation = nil }
                    catch { errorMessage = error.localizedDescription }
                } }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationBackground(MyChatTheme.canvas)
        }

    }

    private func load() async {
        isLoading = messages.isEmpty
        do {
            let persisted = try await appModel.codeMessages(for: session)
            // A refresh must not erase an admitted or still-submitting turn.
            let persistedIDs = Set(persisted.map(\.id))
            let live = messages.filter {
                !persistedIDs.contains($0.id) &&
                ($0.id == pendingUserID || $0.id.lowercased() == streamedResponseID?.uuidString.lowercased())
            }
            messages = persisted + live
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func recover() async {
        guard activeAdmission == nil, !isRecovering, !isReplayingTerminalRecovery else { return }
        isRecovering = true
        defer { isRecovering = false }
        do {
            let recovery = try await appModel.recoverCodeTask(sessionID: session.id)
            taskDetail = recovery.task
            if let task = recovery.task {
                branch = task.branch
            }
            if let admission = recovery.operationAdmission ?? recovery.admission {
                lastTaskID = admission.taskID
                streamedResponseID = recovery.admission?.responseID ?? admission.responseID ?? admission.taskID
                // Replay from zero rebuilds tool plans, receipts and text as one
                // consistent snapshot; the stream verifies monotonic sequence.
                streamedContent = ""
                steps = []
                plans = []
                toolActivities = []
                memoryChanges = []
                receipt = nil
                if isTerminalCodeStatus(recovery.task?.status) || isTerminalCodeStatus(admission.status) {
                    activeAdmission = nil
                    isCancelling = false
                    cancellationPending = false
                    cancellationRetryAllowed = false
                    errorMessage = nil
                    isReplayingTerminalRecovery = true
                    startConsuming(admission, terminalReplay: true)
                } else {
                    activeAdmission = admission
                    isReplayingTerminalRecovery = false
                    startConsuming(admission)
                }
            } else {
                isReplayingTerminalRecovery = false
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func saveSessionDraft() {
        hasSavedSettings = true
        CodeLocalState.save(CodeDraftRecord(prompt: draft, repository: session.repository,
            branch: branch), owner: appModel.authSession?.user.id ?? "", scope: session.id)
    }

    private var canSend: Bool {
        CodeSendEligibility.canSubmit(
            draft: draft,
            isBusy: activeAdmission != nil || isAdmitting || isApplying || isReplayingTerminalRecovery
        )
    }

    private var isProvisionalRepository: Bool {
        session.repository.hasPrefix("__mychat_new__/")
    }

    private var canRequestPublish: Bool {
        activeAdmission == nil
            && !isReplayingTerminalRecovery
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
        if let issue = CodeSendEligibility.modelIssue(appModel.selectedModel) {
            errorMessage = issue
            commandDestination = .model
            return
        }
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let localID = "pending-" + UUID().uuidString
        pendingUserID = localID
        isAdmitting = true
        draft = ""
        composerFocused = false
        errorMessage = nil
        withAnimation(.smooth(duration: 0.32)) {
            messages.append(CodeMessageRecord(id: localID, sessionID: session.id,
                role: "user", content: prompt, metadata: nil, createdAt: nil))
        }
        do {
            let start = try await appModel.startCodeTurn(in: session, prompt: prompt,
                branch: branch.isEmpty ? nil : branch)
            prepare(start)
            isAdmitting = false
            startConsuming(start.admission)
        } catch {
            isAdmitting = false
            messages.removeAll { $0.id == localID }
            pendingUserID = nil
            errorMessage = error.localizedDescription
            if draft.isEmpty { draft = prompt }
        }
    }

    @ViewBuilder
    private func actionSheet(_ destination: CodeCommandDestination) -> some View {
        switch destination {
        case .actions:
            CodeActionSheet(
                repository: session.repository,
                close: { commandDestination = nil },
                select: selectAction
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

    private func selectAction(_ action: CodeAction) {
        switch action.kind {
        case .new:
            commandDestination = nil
            Task { await createNewSession() }
        case .model: commandDestination = .model
        case .effort: commandDestination = .effort
        case .memory: commandDestination = .memory
        case .resume: commandDestination = .resume
        case .tasks: commandDestination = .tasks
        }
    }

    private func createNewSession() async {
        do {
            let repository = isProvisionalRepository ? nil : session.repository
            let record = try await appModel.createCodeSession(
                repository: repository,
                title: "新建会话"
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
        streamedResponseID = start.admission.responseID ?? start.admission.taskID
        streamedContent = ""
        steps = []
        toolActivities = []
        memoryChanges = []
        plans = []
        receipt = nil
        lastTaskID = start.admission.taskID
        if let pendingUserID, let index = messages.firstIndex(where: { $0.id == pendingUserID }) {
            messages[index] = start.userMessage
        } else if !messages.contains(where: { $0.id == start.userMessage.id }) {
            messages.append(start.userMessage)
        }
        pendingUserID = nil
        let responseID = (start.admission.responseID ?? start.admission.taskID).uuidString.lowercased()
        if !messages.contains(where: { $0.id.lowercased() == responseID }) {
            messages.append(CodeMessageRecord(id: responseID, sessionID: session.id,
                role: "assistant", content: "", metadata: nil, createdAt: nil))
        }
    }

    @MainActor private func startConsuming(_ admission: CodeAdmission, terminalReplay: Bool = false) {
        guard eventSubscriptionJobID != admission.jobID || eventSubscription == nil else { return }
        eventSubscription?.cancel()
        let token = UUID()
        eventSubscriptionJobID = admission.jobID
        eventSubscriptionToken = token
        eventSubscription = Task { @MainActor in
            await consume(admission, subscriptionToken: token, terminalReplay: terminalReplay)
            if eventSubscriptionToken == token {
                eventSubscription = nil
                eventSubscriptionJobID = nil
                eventSubscriptionToken = nil
                if terminalReplay { isReplayingTerminalRecovery = false }
            }
        }
    }

    @MainActor private func consume(
        _ admission: CodeAdmission,
        subscriptionToken: UUID,
        terminalReplay: Bool = false
    ) async {
        var terminalError: String?
        var terminalReceived = false
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
                    terminalReceived = true
                    if !terminal.content.isEmpty { streamedContent = terminal.content }
                    receipt = terminal.codeReceipt
                    if terminal.status == .failed {
                        terminalError = terminal.errorCode ?? "编程任务失败，请重试"
                    }
                    break eventLoop
                case let .toolActivity(activity):
                    if let index = toolActivities.firstIndex(where: { $0.toolCallID == activity.toolCallID }) { toolActivities[index] = activity }
                    else { toolActivities.append(activity) }
                case .thinkingDelta, .reasoningSummaryDelta, .toolSearch, .modelOutputCompleted, .connectorApp:
                    break
                }
            }
            errorMessage = terminalError
        } catch is CancellationError {
            if Task.isCancelled { return }
            errorMessage = "Code 任务事件流已取消，请刷新恢复状态"
        } catch {
            errorMessage = error.localizedDescription
        }
        guard eventSubscriptionToken == subscriptionToken,
              eventSubscriptionJobID == admission.jobID else { return }
        // The byte stream has ended. Release its handle before recovery so the
        // same still-running task can be resubscribed with a fresh token.
        eventSubscription = nil
        eventSubscriptionJobID = nil
        eventSubscriptionToken = nil
        if let id = streamedResponseID,
           let index = messages.firstIndex(where: { $0.id.lowercased() == id.uuidString.lowercased() }) {
            messages[index].content = streamedContent
        }
        if terminalReplay {
            if !terminalReceived && errorMessage == nil {
                errorMessage = "已完成任务的事件记录尚未完整，请下拉刷新重试"
            }
            await load()
            if let recovery = try? await appModel.recoverCodeTask(sessionID: session.id) {
                taskDetail = recovery.task
                if let task = recovery.task { branch = task.branch }
            }
            isReplayingTerminalRecovery = false
            if !memoryChanges.isEmpty { await appModel.reloadMemoryData() }
            return
        }
        if cancellationPending && !terminalReceived {
            activeAdmission = admission
            isCancelling = false
            await load()
            do {
                let recovery = try await appModel.recoverCodeTask(sessionID: session.id)
                guard activeAdmission?.jobID == admission.jobID else { return }
                taskDetail = recovery.task
                if let task = recovery.task { branch = task.branch }
                let recoveredAdmission = recovery.operationAdmission ?? recovery.admission
                if isTerminalCodeStatus(recovery.task?.status)
                    || isTerminalCodeStatus(recoveredAdmission?.status) {
                    activeAdmission = nil
                    cancellationPending = false
                    cancellationRetryAllowed = false
                    errorMessage = nil
                    cancellationReconciliation?.cancel()
                    cancellationReconciliation = nil
                    cancellationReconciliationToken = nil
                    await load()
                } else if let recoveredAdmission, recoveredAdmission.jobID == admission.jobID {
                    activeAdmission = recoveredAdmission
                    cancellationRetryAllowed = recoveredAdmission.status.lowercased() != "cancelling"
                    startConsuming(recoveredAdmission)
                }
            } catch {
                errorMessage = "无法确认 Code 任务状态：\(error.localizedDescription)"
            }
            if activeAdmission?.jobID == admission.jobID,
               cancellationPending,
               cancellationReconciliation == nil {
                scheduleCancellationReconciliation(for: admission)
            }
            if !memoryChanges.isEmpty { await appModel.reloadMemoryData() }
            return
        }
        activeAdmission = nil
        isCancelling = false
        cancellationPending = false
        cancellationRetryAllowed = false
        cancellationReconciliation?.cancel()
        cancellationReconciliation = nil
        cancellationReconciliationToken = nil
        await load()
        if let recovery = try? await appModel.recoverCodeTask(sessionID: session.id) {
            taskDetail = recovery.task
            if let task = recovery.task { branch = task.branch }
            if let admission = recovery.operationAdmission ?? recovery.admission,
               !isTerminalCodeStatus(recovery.task?.status),
               !isTerminalCodeStatus(admission.status) {
                lastTaskID = admission.taskID
                activeAdmission = admission
                streamedResponseID = recovery.admission?.responseID ?? admission.responseID ?? admission.taskID
                streamedContent = ""
                steps = []
                plans = []
                toolActivities = []
                startConsuming(admission)
            }
        }
        if !memoryChanges.isEmpty { await appModel.reloadMemoryData() }
    }

    @MainActor private func stop(_ admission: CodeAdmission) async {
        guard !isCancelling,
              (!cancellationPending || cancellationRetryAllowed),
              activeAdmission?.jobID == admission.jobID else { return }
        isCancelling = true
        cancellationRetryAllowed = false
        errorMessage = nil
        do {
            let response = try await appModel.cancelCodeRun(admission)
            guard response.jobID == admission.jobID else {
                isCancelling = false
                errorMessage = "取消响应与当前 Code 任务不匹配"
                return
            }
            if isTerminalCodeStatus(response.status) {
                _ = await reconcileCancellation(admission, confirmedTerminalStatus: response.status)
            } else {
                isCancelling = false
                cancellationPending = true
                cancellationRetryAllowed = !(response.accepted || response.replayed)
                errorMessage = response.accepted || response.replayed
                    ? "取消请求已提交，正在等待云端状态"
                    : "取消请求尚未确认，可以重试"
                scheduleCancellationReconciliation(for: admission)
            }
        } catch {
            errorMessage = error.localizedDescription
            isCancelling = false
            cancellationPending = true
            cancellationRetryAllowed = true
            scheduleCancellationReconciliation(for: admission)
        }
    }

    @MainActor private func scheduleCancellationReconciliation(for admission: CodeAdmission) {
        guard cancellationReconciliation == nil else { return }
        let token = UUID()
        cancellationReconciliationToken = token
        cancellationReconciliation = Task { @MainActor in
            var delay: UInt64 = 2_000_000_000
            while !Task.isCancelled, activeAdmission?.jobID == admission.jobID, cancellationPending {
                do { try await Task.sleep(nanoseconds: delay) }
                catch { break }
                guard activeAdmission?.jobID == admission.jobID, cancellationPending else { break }
                if isCancelling { continue }
                if await reconcileCancellation(admission) { break }
                delay = min(delay * 2, 15_000_000_000)
            }
            if cancellationReconciliationToken == token {
                cancellationReconciliation = nil
                cancellationReconciliationToken = nil
            }
        }
    }

    @MainActor private func reconcileCancellation(_ admission: CodeAdmission, confirmedTerminalStatus: String? = nil) async -> Bool {
        guard activeAdmission?.jobID == admission.jobID else { return true }
        do {
            let recovery = try await appModel.recoverCodeTask(sessionID: session.id)
            guard activeAdmission?.jobID == admission.jobID else { return true }
            taskDetail = recovery.task
            if let task = recovery.task { branch = task.branch }
            let currentAdmission = recovery.operationAdmission ?? recovery.admission
            let terminal = isTerminalCodeStatus(confirmedTerminalStatus)
                || isTerminalCodeStatus(recovery.task?.status)
                || isTerminalCodeStatus(currentAdmission?.status)

            if terminal {
                activeAdmission = nil
                isCancelling = false
                cancellationPending = false
                cancellationRetryAllowed = false
                errorMessage = nil
                cancellationReconciliation = nil
                cancellationReconciliationToken = nil
                let oldSubscription = eventSubscription
                eventSubscription = nil
                eventSubscriptionJobID = nil
                eventSubscriptionToken = nil
                oldSubscription?.cancel()
                await load()
                return true
            }

            if let currentAdmission, currentAdmission.jobID == admission.jobID {
                activeAdmission = currentAdmission
            }
            isCancelling = false
            cancellationPending = true
            let status = currentAdmission?.status ?? recovery.task?.status ?? "未知"
            cancellationRetryAllowed = status.lowercased() != "cancelling"
            errorMessage = status.lowercased() == "cancelling"
                ? "云端仍在处理取消，状态将继续同步"
                : "任务仍在运行（\(status)），可重试停止"
            return false
        } catch {
            guard activeAdmission?.jobID == admission.jobID else { return true }
            if isTerminalCodeStatus(confirmedTerminalStatus) {
                activeAdmission = nil
                isCancelling = false
                cancellationPending = false
                cancellationRetryAllowed = false
                cancellationReconciliation = nil
                cancellationReconciliationToken = nil
                let oldSubscription = eventSubscription
                eventSubscription = nil
                eventSubscriptionJobID = nil
                eventSubscriptionToken = nil
                oldSubscription?.cancel()
                await load()
                errorMessage = "任务已结束，但无法刷新最新状态：\(error.localizedDescription)"
                return true
            }
            isCancelling = false
            cancellationPending = true
            cancellationRetryAllowed = true
            errorMessage = "无法确认 Code 任务状态：\(error.localizedDescription)"
            return false
        }
    }

    private func isTerminalCodeStatus(_ status: String?) -> Bool {
        guard let status else { return false }
        return ["completed", "failed", "cancelled", "canceled"].contains(status.lowercased())
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
                startConsuming(admission)
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
            startConsuming(admission)
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
            message: "发布 MyChat 编程更改",
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

private struct CodeTaskEvidenceView: View {
    let detail: CodeTaskDetail
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(detail.status) · \(detail.branch)", systemImage: "cloud")
                .font(MyChatTypography.caption)
            ForEach(detail.toolCalls) { tool in
                DisclosureGroup("\(tool.toolName) · \(tool.status)") {
                    if let error = tool.error { Text(error).foregroundStyle(.red) }
                    if let output = tool.output,
                       let data = try? JSONEncoder().encode(output),
                       let text = String(data: data, encoding: .utf8) {
                        ScrollView(.horizontal) { Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
                    }
                    if let duration = tool.durationMs { Text("\(duration) ms").font(MyChatTypography.caption) }
                }.padding(.vertical, 8)
            }
            ForEach(detail.artifacts) { artifact in
                DisclosureGroup(artifact.title ?? artifact.kind) {
                    if let content = artifact.content {
                        ScrollView(.horizontal) { Text(content).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
                    }
                }.padding(.vertical, 8)
            }
            if let raw = detail.pullRequestUrl, let url = URL(string: raw),
               url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil {
                Link("打开 GitHub PR", destination: url).frame(minHeight: 44)
            }
        }.accessibilityIdentifier("code.evidence")
    }
}

private struct CodeConversationMessage: View {
    let role: String
    let content: String

    var body: some View {
        if role == "user" {
            HStack {
                Spacer(minLength: 54)
                MarkdownBody(content, fillsWidth: false, typography: .user)
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
            MarkdownBody(content, typography: .response)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CodeAction: Identifiable {
    enum Kind: String { case new, model, effort, memory, resume, tasks }
    var id: Kind { kind }
    let kind: Kind
    let title: String
    let description: String
    let symbol: String

    static let all: [CodeAction] = [
        .init(kind: .new, title: "新建对话", description: "在当前仓库创建持久会话", symbol: "plus.message"),
        .init(kind: .model, title: "模型", description: "选择实际用于云端任务的模型", symbol: "square.stack.3d.up"),
        .init(kind: .effort, title: "思考强度", description: "设置实际发送给模型的思考档位", symbol: "brain.head.profile"),
        .init(kind: .memory, title: "仓库记忆", description: "查看、添加或删除持久记忆", symbol: "memorychip"),
        .init(kind: .resume, title: "历史会话", description: "打开本仓库已有的持久会话", symbol: "clock.arrow.circlepath"),
        .init(kind: .tasks, title: "云端任务", description: "查看已入队任务及其真实状态", symbol: "checklist"),
    ]
}

private enum CodeCommandDestination: String, Identifiable {
    case actions, model, effort, memory, resume, tasks
    var id: String { rawValue }
}

private struct CodeActionSheet: View {
    let repository: String
    let close: () -> Void
    let select: (CodeAction) -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "编程操作", close: close)
            if let repository = CodeDisplay.repository(repository) {
                Text(repository)
                    .font(MyChatSystemFont.appFont(for: .caption1, weight: .regular))
                    .foregroundStyle(MyChatTheme.secondaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)
            }

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(CodeAction.all) { action in
                        Button {
                            select(action)
                        } label: {
                            HStack(spacing: 13) {
                                Image(systemName: action.symbol)
                                    .font(MyChatSystemFont.appFont(size: 17, weight: .medium))
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(action.title)
                                        .font(MyChatSystemFont.appFont(size: 17, weight: .semibold))
                                    Text(action.description)
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
            SheetHeader(title: "思考强度", close: close)
            if appModel.availableReasoningEfforts.isEmpty {
                ContentUnavailableView(
                    "无法调整思考强度",
                    systemImage: "brain.head.profile",
                    description: Text("所选模型不提供可调整的思考强度。")
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
            SheetHeader(title: "仓库记忆", close: close)
            if let repository = CodeDisplay.repository(repository) {
                Text(repository)
                    .font(MyChatSystemFont.appFont(for: .caption1, weight: .regular))
                    .foregroundStyle(MyChatTheme.secondaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 10)
            }

            ScrollView {
                LazyVStack(spacing: 8) {
                    if memories == nil {
                        ProgressView().padding(.top, 32)
                    } else if memories?.isEmpty == true {
                        Text("还没有仓库记忆")
                            .foregroundStyle(MyChatTheme.secondaryText)
                            .padding(.top, 28)
                    } else {
                        ForEach(memories ?? []) { memory in
                            HStack(alignment: .top, spacing: 10) {
                                MarkdownBody(memory.content, typography: .response)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button(role: .destructive) {
                                    Task { await delete(memory) }
                                } label: {
                                    Image(systemName: "trash")
                                        .frame(width: 40, height: 40)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("删除记忆")
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
                TextField("添加记忆", text: $draft, axis: .vertical)
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

private struct CodeResumeSheet: View {
    let repository: String
    let sessions: [CodeSessionRecord]
    let close: () -> Void
    let select: (CodeSessionRecord) -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "恢复会话", close: close)
            ScrollView {
                LazyVStack(spacing: 8) {
                    if matchingSessions.isEmpty {
                        Text("此仓库中没有之前的会话")
                            .foregroundStyle(MyChatTheme.secondaryText)
                            .padding(.top, 30)
                    } else {
                        ForEach(matchingSessions) { session in
                            Button { select(session) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .frame(width: 28)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(session.displayTitle)
                                            .font(MyChatSystemFont.appFont(size: 16, weight: .medium))
                                            .lineLimit(1)
                                        if let repository = session.displayRepository {
                                            Text(repository)
                                                .font(MyChatSystemFont.appFont(for: .caption1, weight: .regular))
                                                .foregroundStyle(MyChatTheme.secondaryText)
                                                .lineLimit(1)
                                        }
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
            SheetHeader(title: "智能体任务", close: close)
            ScrollView {
                LazyVStack(spacing: 8) {
                    if tasks == nil {
                        ProgressView().padding(.top, 32)
                    } else if let errorMessage {
                        Text(PresentationText.plain(errorMessage))
                            .foregroundStyle(Color.red)
                            .padding(.top, 24)
                    } else if tasks?.isEmpty == true {
                        Text("此仓库中没有智能体任务")
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
    @StateObject private var githubAuthenticator = GitHubWebAuthenticator()
    @FocusState private var composerFocused: Bool
    @State private var draft = ""
    @State private var repositoryPickerVisible = false
    @State private var modelPickerVisible = false
    @State private var selectedRepository: GitHubRepositoryRecord?
    @State private var githubConnection: GitHubConnectionStatus?
    @State private var isCheckingGitHub = true
    @State private var isConnectingGitHub = false
    @State private var createNewRepository = false
    @State private var isStarting = false
    @State private var pendingPrompt: String?
    @State private var errorMessage: String?
    @State private var startedSession: CodeSessionStart?
    @State private var branch = ""
    @State private var capabilities: CodeCapabilities?
    @State private var capabilityError: String?
    @State private var branches: [CodeBranches.Branch] = []
    @State private var branchError: String?

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
            if pendingPrompt == nil {
                CodeSparkleField().allowsHitTesting(false)
            }
            VStack(spacing: 0) {
                ZStack {
                    Text("新建会话")
                        .font(MyChatSystemFont.appFont(size: 18, design: .default, weight: .semibold))
                    HStack {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "arrow.left")
                                .font(MyChatSystemFont.appFont(size: 18, weight: .regular))
                        }
                        .buttonStyle(MyChatIconButtonStyle())
                        .accessibilityLabel("返回 Code")
                        .accessibilityIdentifier("code.new.back")
                        Spacer()
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 60)

                if let pendingPrompt {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            CodeConversationMessage(role: "user", content: pendingPrompt)
                            DotThinkingView(isGenerating: true).frame(width: 48, height: 48)
                        }.padding(16)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.offset(y: 24).combined(with: .opacity))
                } else if !composerFocused {
                    Spacer()
                    VStack(spacing: 18) {
                        DotThinkingView(isGenerating: false)
                            .frame(width: 58, height: 58)
                        Text("一起用 Git 编程")
                            .font(MyChatSystemFont.appFont(size: 19, design: .monospaced, weight: .regular))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("目标分支（留空使用仓库默认分支）", text: $branch)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("code.branch")
                        if !branches.isEmpty {
                            Menu {
                                ForEach(branches) { item in Button(item.name) { branch = item.name } }
                            } label: {
                                Label("选择已授权仓库分支", systemImage: "arrow.triangle.branch")
                                    .frame(minHeight: 44)
                            }.accessibilityIdentifier("code.branches")
                        }
                        if let branchError { Text(branchError).font(MyChatTypography.caption).foregroundStyle(.red) }
                        if let capabilities {
                            let isConfigured = capabilities.execution.location == "cloud" && capabilities.execution.configured
                            let isVerified = isConfigured && capabilities.execution.verified
                            let statusLabel = isVerified ? "云端已验证" : (isConfigured ? "云端待验收" : "云端不可用")
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(isVerified ? Color.green : (isConfigured ? MyChatTheme.brand : MyChatTheme.secondaryText))
                                    .frame(width: 6, height: 6)
                                Text(statusLabel).font(MyChatTypography.caption)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("执行状态：\(statusLabel)")
                            .accessibilityIdentifier("code.execution-status")
                        } else {
                            Text(capabilityError ?? "正在检查执行环境…").font(MyChatTypography.caption)
                        }
                    }.padding(.horizontal, 18)
                    TextField("描述你想编写的内容…", text: $draft, axis: .vertical)
                        .font(MyChatSystemFont.appFont(size: 20, weight: .regular))
                        .lineLimit(1...5)
                        .focused($composerFocused)
                        .accessibilityIdentifier("code.draft")
                        .disabled(isStarting)
                        .padding(.horizontal, 18)
                        .padding(.top, 18)

                    HStack(spacing: 10) {
                        Button {
                            if githubConnection?.connected == true {
                                repositoryPickerVisible = true
                            } else {
                                Task { await connectGitHub() }
                            }
                        } label: {
                            HStack(spacing: 7) {
                                if isConnectingGitHub || isCheckingGitHub {
                                    ProgressView().controlSize(.small)
                                }
                                Text(repositoryLabel)
                                    .font(MyChatTypography.metadata)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 13)
                            .frame(minHeight: 44)
                            .background(MyChatTheme.selected, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isCheckingGitHub || isConnectingGitHub)
                        .accessibilityIdentifier("code.repository-selector")

                        Button {
                            modelPickerVisible = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "cpu")
                                    .font(MyChatSystemFont.appFont(size: 13, weight: .semibold))
                                Text(appModel.selectedModel?.chatDisplayName ?? "选择模型")
                                    .font(MyChatSystemFont.appFont(for: .subheadline, weight: .medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .padding(.horizontal, 12)
                            .frame(maxWidth: 126, minHeight: 44)
                            .background(MyChatTheme.selected, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("code-model-selector")

                        Spacer()

                        Button {
                            Task { await startSession() }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(MyChatTheme.sendActionSurface)
                                    .frame(width: 40, height: 40)
                                if isStarting {
                                    ProgressView().tint(MyChatTheme.sendActionForeground)
                                } else {
                                    Image(systemName: "arrow.up")
                                        .font(MyChatSystemFont.appFont(size: 15, weight: .semibold))
                                        .foregroundStyle(MyChatTheme.sendActionForeground)
                                }
                            }
                            .frame(width: 44, height: 44)
                        }
                        .buttonStyle(CodeSendButtonStyle())
                        .disabled(!canStart)
                        .opacity(canStart ? 1 : 0.45)
                        .accessibilityHint("发送 Code 任务；仓库可以稍后选择")
                        .accessibilityLabel("发送编程任务")
                        .accessibilityIdentifier("code.send")
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
        .task { await restoreDraft() }
        .onChange(of: draft) { _, _ in saveDraft() }
        .onChange(of: branch) { _, _ in saveDraft() }
        .onChange(of: selectedRepository) { _, _ in saveDraft() }
        .task(id: selectedRepository?.fullName) {
            branches = []; branchError = nil
            guard let repo = selectedRepository?.fullName else { return }
            do {
                let result = try await appModel.codeBranches(repository: repo)
                guard !Task.isCancelled, selectedRepository?.fullName == repo else { return }
                branches = result.branches
                if branch.isEmpty { branch = result.defaultBranch ?? "" }
            } catch { if !Task.isCancelled { branchError = error.localizedDescription } }
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
        if createNewRepository { return "新仓库" }
        if let selectedRepository { return selectedRepository.fullName }
        return githubConnection?.connected == true ? "选择仓库" : "连接 GitHub"
    }

    private var canStart: Bool {
        CodeSendEligibility.canSubmit(draft: draft, isBusy: isStarting)
            && capabilities?.execution.location == "cloud"
            && capabilities?.execution.configured == true
    }

    private func saveDraft() {
        guard !isStarting else { return }
        CodeLocalState.save(CodeDraftRecord(prompt: draft, repository: selectedRepository?.fullName,
            branch: branch), owner: appModel.authSession?.user.id ?? "", scope: "new")
    }

    private func restoreDraft() async {
        let value = CodeLocalState.draft(owner: appModel.authSession?.user.id ?? "", scope: "new")
        draft = value.prompt; branch = value.branch

        isCheckingGitHub = true
        do {
            githubConnection = try await appModel.githubConnectionStatus()
        } catch {
            githubConnection = nil
            if value.repository != nil { errorMessage = error.localizedDescription }
        }
        isCheckingGitHub = false

        do { capabilities = try await appModel.codeCapabilities() }
        catch { capabilityError = error.localizedDescription }

        if let repo = value.repository, githubConnection?.connected == true {
            do {
                selectedRepository = try await appModel.githubRepositories().first { $0.fullName == repo }
                if selectedRepository == nil { errorMessage = "已选仓库不可用，请重新选择" }
            } catch { errorMessage = error.localizedDescription }
        } else if value.repository != nil {
            errorMessage = "GitHub 未连接，请重新选择仓库"
        }
    }

    private func connectGitHub() async {
        guard !isConnectingGitHub, !isCheckingGitHub else { return }
        isConnectingGitHub = true
        errorMessage = nil
        defer { isConnectingGitHub = false }

        do {
            let authorizationURL = try await appModel.githubAuthorizationURL()
            let callbackURL = try await githubAuthenticator.authenticate(using: authorizationURL)
            try GitHubMobileOAuthCallback.validateConnectedCallback(callbackURL)

            let status = try await appModel.githubConnectionStatus()
            guard status.connected else { throw GitHubWebAuthenticationError.connectionFailed }
            githubConnection = status

            let savedRepository = selectedRepository?.fullName
                ?? CodeLocalState.draft(owner: appModel.authSession?.user.id ?? "", scope: "new").repository
            if let savedRepository {
                let repositories = try await appModel.githubRepositories()
                if let match = repositories.first(where: { $0.fullName == savedRepository }) {
                    selectedRepository = match
                    createNewRepository = false
                    return
                }
                errorMessage = "已选仓库不可用，请重新选择"
            }
            repositoryPickerVisible = true
        } catch let error as ASWebAuthenticationSessionError
            where error.code == .canceledLogin {
            // OAuth cancellation does not create a repository or workspace.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startSession() async {
        guard canStart else { return }
        if let issue = CodeSendEligibility.modelIssue(appModel.selectedModel) {
            errorMessage = issue
            modelPickerVisible = true
            return
        }
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        isStarting = true
        errorMessage = nil
        composerFocused = false
        withAnimation(.smooth(duration: 0.38)) {
            pendingPrompt = prompt
            draft = ""
        }
        do {
            let started = try await appModel.startCodeSession(
                repository: createNewRepository ? nil : selectedRepository?.fullName,
                prompt: prompt,
                branch: branch.isEmpty ? nil : branch
            )
            CodeLocalState.clear(owner: appModel.authSession?.user.id ?? "", scope: "new")
            CodeLocalState.save(CodeDraftRecord(repository: selectedRepository?.fullName, branch: branch),
                owner: appModel.authSession?.user.id ?? "", scope: started.session.id)
            withAnimation(.smooth(duration: 0.38)) { startedSession = started }
        } catch {
            errorMessage = error.localizedDescription
            withAnimation(.smooth(duration: 0.28)) {
                pendingPrompt = nil
                draft = prompt
            }
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
            SheetHeader(title: "选择仓库", close: { dismiss() })

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(MyChatTheme.secondaryText)
                TextField("搜索仓库", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 15)
            .frame(minHeight: 48)
            .background(MyChatTheme.selected, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .padding(.horizontal, 18)

            if connection?.connected == true {
                Button {
                    select(nil)
                } label: {
                HStack(spacing: 13) {
                    Image(systemName: "folder.badge.plus")
                        .frame(width: 38, height: 38)
                        .background(MyChatTheme.selected, in: RoundedRectangle(cornerRadius: 11))
                    Text("创建新仓库")
                        .font(MyChatSystemFont.appFont(size: 16, weight: .semibold))
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
            }

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if connection?.connected != true {
                VStack(spacing: 12) {
                    Image(systemName: "link.badge.plus")
                        .font(MyChatSystemFont.appFont(size: 24, weight: .medium))
                    Text("GitHub 尚未连接")
                        .font(MyChatSystemFont.appFont(size: 18, weight: .semibold))
                    if let errorMessage {
                        Text(PresentationText.plain(errorMessage))
                            .font(MyChatSystemFont.appFont(for: .caption1, weight: .regular))
                            .foregroundStyle(MyChatTheme.secondaryText)
                            .multilineTextAlignment(.center)
                    }
                    Button {
                        Task { await connectGitHub() }
                    } label: {
                        if isConnecting {
                            ProgressView()
                                .frame(minWidth: 120)
                        } else {
                            Text("连接 GitHub")
                                .frame(minWidth: 120)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isConnecting)
                    .accessibilityIdentifier("code.github.connect")
                }
                .padding(28)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredRepositories.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(MyChatSystemFont.appFont(size: 24, weight: .medium))
                    Text(searchText.isEmpty ? "还没有仓库" : "没有匹配的仓库")
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
                            .accessibilityIdentifier("code.github.repository.\(repository.fullName)")
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
            try GitHubMobileOAuthCallback.validateConnectedCallback(callbackURL)
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

}

enum GitHubMobileOAuthCallback {
    static func validateConnectedCallback(_ url: URL) throws {
        guard url.scheme?.lowercased() == "mychat",
              url.host?.lowercased() == "oauth",
              url.path == "/github",
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.count == 1,
              items[0].name == "status" else {
            throw GitHubWebAuthenticationError.invalidCallback
        }
        guard items[0].value == "connected" else {
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
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
            }
            Text(request.risk.reason)
                .font(MyChatSystemFont.appFont(size: 16, weight: .regular))
                .foregroundStyle(MyChatTheme.secondaryText)

            if !request.risk.files.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("文件")
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
                    else { Text("确认并发布") }
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
            Label("已发布", systemImage: "checkmark.circle.fill")
                .font(MyChatSystemFont.appFont(size: 17, weight: .semibold))
                .foregroundStyle(Color.green)
            if let raw = receipt.repository, let repository = CodeDisplay.repository(raw) {
                Text(repository)
                    .font(MyChatSystemFont.appFont(size: 15, design: .monospaced, weight: .regular))
            }
            if let repositoryURL = receipt.repositoryURL {
                Link("打开仓库", destination: repositoryURL)
            }
            if let pullRequestURL = receipt.pullRequestURL {
                Link("打开拉取请求", destination: pullRequestURL)
            }
            if let pagesURL = receipt.pagesURL {
                Link("打开网站", destination: pagesURL)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MyChatTheme.raised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

