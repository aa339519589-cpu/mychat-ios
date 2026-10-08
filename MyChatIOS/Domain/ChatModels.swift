import Foundation

enum CodeSendEligibility {
    static func canSubmit(draft: String, isBusy: Bool) -> Bool {
        !isBusy && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func modelIssue(_ model: ModelCatalogItem?) -> String? {
        guard let model else { return "请选择 Code 模型" }
        guard model.outputKind == .chat, model.endpointID != nil || model.tools else {
            return "请选择支持文本和工具调用的 Code 模型"
        }
        return nil
    }
}

enum ChatMessageRole: String, Codable, Sendable {
    case user
    case assistant
}

enum LocalChatGenerationState: String, Codable, Sendable {
    case streaming
    case interrupted
    case completedPendingPersistence
    case stopped
    case failed
}

struct ChatConversation: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var title: String
    var projectID: UUID?
    var starred: Bool
    var pinned: Bool
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case projectID = "project_id"
        case starred
        case pinned
        case updatedAt = "updated_at"
    }
}

struct ChatMessage: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let role: ChatMessageRole
    var content: String
    var thinking: String?
    var media: [ChatGeneratedMedia]? = nil
    var sourceImages: [String]? = nil
    var attachedFileNames: [String]? = nil
    var filePreviews: [ChatFilePreview]? = nil
    var localGenerationState: LocalChatGenerationState? = nil
    let createdAt: Date

    var completedReplyIsVisible: Bool {
        role == .assistant && (localGenerationState == nil || localGenerationState == .completedPendingPersistence)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case thinking
        case media
        case sourceImages = "source_images"
        case attachedFileNames = "attached_file_names"
        case filePreviews = "file_previews"
        case localGenerationState = "local_generation_state"
        case createdAt = "created_at"
    }
}

enum ChatSearchMode: String, Codable, Sendable {
    case off
    case web
}

enum ChatConnectorAccessMode: String, Codable, CaseIterable, Sendable {
    case auto
    case alwaysAvailable = "always_available"
    case onDemand = "on_demand"

    var segmentTitle: String {
        switch self {
        case .auto: "自动"
        case .alwaysAvailable: "始终可用"
        case .onDemand: "按需调用"
        }
    }

    var explanation: String {
        switch self {
        case .auto:
            "MyChat 根据每次请求选择相关工具。"
        case .alwaysAvailable:
            "所有已启用的连接器工具均可直接使用。"
        case .onDemand:
            "MyChat 先搜索已启用的工具，再加载匹配项。"
        }
    }
}

enum ChatReasoningEffort: String, Codable, CaseIterable, Sendable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh
    case max
}

struct ChatToolSelection: Codable, Equatable, Sendable {
    var searchMode: ChatSearchMode = .off
    var historyRetrieval = false
    var renderEnabled = false
    var connectorAccessMode: ChatConnectorAccessMode = .auto
    /// nil means all account-enabled connectors; [] means none for this chat.
    var connectorIDs: [String]? = nil
}

/// One durable append turn. The four UUIDs are allocated before admission so a
/// retry sends the identical command and the server can replay it idempotently.
struct ChatRegeneration: Codable, Equatable, Sendable {
    let operation: String
    let expectedTailMessageID: UUID
    let targetAssistantMessageID: UUID?
}

struct ChatAppendCommand: Codable, Equatable, Sendable {
    let conversationID: UUID
    let userMessage: ChatMessage
    let generationID: UUID
    let assistantMessageID: UUID
    let modelID: String
    let endpointID: UUID?
    let outputKind: ModelOutputKind
    let reasoningEffort: ChatReasoningEffort?
    let tools: ChatToolSelection
    let createConversation: Bool
    let conversationMemoryEnabled: Bool
    let title: String
    let projectID: UUID?
    let attachments: [ChatFileAttachment]
    var healthContext: String? = nil
    let regeneration: ChatRegeneration?

    init(
        conversationID: UUID,
        userMessage: ChatMessage,
        generationID: UUID = UUID(),
        assistantMessageID: UUID = UUID(),
        modelID: String,
        endpointID: UUID? = nil,
        outputKind: ModelOutputKind = .chat,
        reasoningEffort: ChatReasoningEffort? = ChatReasoningEffort.none,
        tools: ChatToolSelection = ChatToolSelection(),
        createConversation: Bool,
        conversationMemoryEnabled: Bool = true,
        title: String,
        projectID: UUID? = nil,
        attachments: [ChatFileAttachment] = [],
        regeneration: ChatRegeneration? = nil
    ) {
        self.conversationID = conversationID
        self.userMessage = userMessage
        self.generationID = generationID
        self.assistantMessageID = assistantMessageID
        self.modelID = modelID
        self.endpointID = endpointID
        self.outputKind = outputKind
        self.reasoningEffort = reasoningEffort
        self.tools = tools
        self.createConversation = createConversation
        self.conversationMemoryEnabled = conversationMemoryEnabled
        self.title = title
        self.projectID = projectID
        self.attachments = attachments
        self.regeneration = regeneration
    }

    var userMessageID: UUID { userMessage.id }
}

struct ChatAdmission: Equatable, Sendable {
    let schemaVersion: Int
    let jobID: UUID
    let generationID: UUID
    let userMessageID: UUID
    let assistantMessageID: UUID
    let status: String
    let created: Bool
    let streamURL: URL
    let trialRemaining: Int?
    let trialLimit: Int?
}

/// An authenticated, server-owned snapshot used when reattaching to a turn
/// after the app was suspended or relaunched. The stream resumes at the
/// captured sequence so already-applied output is not appended twice.
struct ChatGenerationRecovery: Equatable, Sendable {
    let admission: ChatAdmission
    let sequence: Int
    let content: String
    let thinking: String
    let media: [ChatGeneratedMedia]
    let terminal: ChatTerminalSnapshot?
}

/// A one-request SSE conversation that intentionally has no durable job or
/// conversation record. `jobID` is local-only identity used to verify the
/// event envelope that comes back on this single connection.
struct PrivateChatStreamRequest: Sendable {
    let endpoint: URL
    let body: Data
    let jobID: UUID
}

struct ChatCancelResponse: Equatable, Sendable {
    let jobID: UUID
    let accepted: Bool
    let replayed: Bool
    let status: String
    let eventSequence: Int?
}

struct ChatGeneratedMedia: Codable, Equatable, Sendable {
    enum MediaType: String, Codable, Sendable {
        case image
        case video
    }

    let type: MediaType
    let url: String
    let mimeType: String?
    let alt: String?
}

struct ChatTokenUsage: Codable, Equatable, Sendable {
    let inputTokens: Int
    let outputTokens: Int
}

struct ChatSearchResult: Codable, Equatable, Sendable {
    let title: String
    let url: String
    let snippet: String?
    let publishedAt: String?
    let faviconURL: String?
    let thumbnailURL: String?
    let conversationID: String?
    let messageStartID: String?

    enum CodingKeys: String, CodingKey {
        case title, url, snippet
        case publishedAt = "published_at"
        case faviconURL = "favicon_url"
        case thumbnailURL = "thumbnail_url"
        case conversationID = "conversation_id"
        case messageStartID = "message_start_id"
    }

    var isHistoryReference: Bool { conversationID != nil }
}

struct ChatSearchImage: Codable, Equatable, Identifiable, Sendable {
    let url: String
    let description: String?
    var id: String { url }

    enum CodingKeys: String, CodingKey {
        case url
        case description
    }
}

struct ChatToolSearch: Codable, Equatable, Sendable {
    let query: String
    let results: [ChatSearchResult]
    let kind: String?
    let images: [ChatSearchImage]?

    var isImageSearch: Bool { kind == "image" }
    var isWebSearch: Bool {
        if let kind, !["web", "image", "web_search"].contains(kind) { return false }
        return results.contains { !$0.isHistoryReference && ["http", "https"].contains(URL(string: $0.url)?.scheme?.lowercased() ?? "") }
    }
}

struct ChatJobSnapshot: Equatable, Sendable {
    let content: String
    let thinking: String
    let media: [ChatGeneratedMedia]
}

struct ChatMemoryEvent: Decodable, Equatable, Sendable {
    let action: String
    let memoryID: String?
    let content: String?
    let topic: String?
    let sensitive: Bool?
    let ok: Bool
    let timestamp: String?
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case action, content, topic, sensitive, ok, timestamp, reason
        case memoryID = "id"
    }
}

struct ChatToolActivity: Equatable, Sendable {
    let toolCallID: String
    let toolName: String
    var isComplete: Bool
}

struct ChatConnectorAppTool: Codable, Equatable, Sendable {
    let name: String
    let title: String
    let description: String
    let inputSchema: [String: JSONValue]
    let annotations: [String: JSONValue]?
}

struct ChatConnectorAppText: Codable, Equatable, Sendable {
    let type: String
    let text: String
}

struct ChatConnectorAppResult: Codable, Equatable, Sendable {
    let content: [ChatConnectorAppText]
    let structuredContent: [String: JSONValue]?
    let isError: Bool?
}

struct ChatConnectorAppCSP: Codable, Equatable, Sendable {
    let connectDomains: [String]
    let resourceDomains: [String]
    let frameDomains: [String]
    let baseUriDomains: [String]
}

struct ChatConnectorAppResource: Codable, Equatable, Sendable {
    let resourceUri: String
    let html: String
    let csp: ChatConnectorAppCSP
    let prefersBorder: Bool?
}

struct ChatConnectorAppPayload: Decodable, Equatable, Sendable {
    let connectorId: String
    let connectorName: String
    let toolName: String
    let toolTitle: String
    let resourceUri: String
    let tool: ChatConnectorAppTool
    let arguments: [String: JSONValue]
    let result: ChatConnectorAppResult
}

struct ChatConnectorAppEvent: Equatable, Sendable, Identifiable {
    let id: String
    let payload: ChatConnectorAppPayload
}

enum ChatTerminalStatus: String, Codable, Sendable {
    case completed
    case failed
    case cancelled
}

/// This value replaces locally accumulated deltas when `job.terminal` arrives.
struct ChatTerminalSnapshot: Equatable, Sendable {
    let status: ChatTerminalStatus
    let content: String
    let thinking: String
    let sequence: Int
    let errorCode: String?
    let media: [ChatGeneratedMedia]
    let tokenUsage: ChatTokenUsage?
    let codeReceipt: CodeOperationReceipt?
}

enum ChatJobEventPayload: Equatable, Sendable {
    case textDelta(String)
    case thinkingDelta(String)
    case reasoningSummaryDelta(String)
    case toolSearch(ChatToolSearch)
    case memoryChange(ChatMemoryEvent)
    case toolActivity(ChatToolActivity)
    case connectorApp(ChatConnectorAppEvent)
    case agentStep(CodeAgentStep)
    case agentPlan(CodePlanAction)
    case modelOutputCompleted
    case snapshot(ChatJobSnapshot)
    case terminal(ChatTerminalSnapshot)
}

struct ChatProcessEntry: Equatable, Sendable, Identifiable {
    enum Content: Equatable, Sendable {
        case text(String)
        case step(CodeAgentStep)
        case thinking(String)
        case reasoningSummary(String)
        case search(ChatToolSearch)
        case tool(ChatToolActivity)
        case memory(ChatMemoryEvent)
    }
    let id: String
    var content: Content

    static func record(_ event: ChatJobEvent, into entries: inout [ChatProcessEntry]) {
        let id = "\(event.jobID.uuidString):\(event.sequence)"
        switch event.payload {
        case let .snapshot(snapshot) where snapshot.content.isEmpty && snapshot.thinking.isEmpty:
            entries.removeAll()
        case let .textDelta(delta):
            guard !delta.isEmpty else { return }
            if let last = entries.last, case let .text(text) = last.content {
                entries[entries.count - 1].content = .text(text + delta)
            } else { entries.append(Self(id: id, content: .text(delta))) }
        case let .agentStep(step):
            if let identity = step.eventID, entries.contains(where: {
                if case let .step(value) = $0.content { return value.eventID == identity }; return false
            }) { return }
            entries.append(Self(id: id, content: .step(step)))
        case let .thinkingDelta(delta):
            if let last = entries.last, case let .thinking(text) = last.content {
                entries[entries.count - 1].content = .thinking(text + delta)
            } else { entries.append(Self(id: id, content: .thinking(delta))) }
        case let .reasoningSummaryDelta(delta):
            if let last = entries.last, case let .reasoningSummary(text) = last.content {
                entries[entries.count - 1].content = .reasoningSummary(text + delta)
            } else { entries.append(Self(id: id, content: .reasoningSummary(delta))) }
        case let .toolSearch(search): entries.append(Self(id: id, content: .search(search)))
        case let .memoryChange(change): entries.append(Self(id: id, content: .memory(change)))
        case let .toolActivity(activity):
            if let index = entries.firstIndex(where: {
                if case let .tool(value) = $0.content { return value.toolCallID == activity.toolCallID }
                return false
            }) { entries[index].content = .tool(activity) }
            else { entries.append(Self(id: id, content: .tool(activity))) }
        default: break
        }
    }
}

struct ChatJobEvent: Equatable, Sendable {
    let jobID: UUID
    let sequence: Int
    let payload: ChatJobEventPayload
}

/// A small reducer for views. In particular, terminal state always replaces the
/// optimistic text/thinking assembled from earlier deltas.
struct ChatStreamAccumulator: Equatable, Sendable {
    private(set) var content = ""
    private(set) var thinking = ""
    private(set) var reasoningSummary = ""
    private(set) var media: [ChatGeneratedMedia] = []
    private(set) var searches: [ChatToolSearch] = []
    private(set) var terminal: ChatTerminalSnapshot?

    var persistedThinking: String? {
        if let summary = ChatReasoningSummaryStorage.encode(reasoningSummary) { return summary }
        return thinking.isEmpty ? nil : thinking
    }

    mutating func apply(_ event: ChatJobEvent) {
        switch event.payload {
        case let .textDelta(delta):
            content += delta
        case let .thinkingDelta(delta):
            thinking += delta
        case let .reasoningSummaryDelta(delta):
            reasoningSummary += delta
        case let .toolSearch(search):
            searches.append(search)
        case .memoryChange, .toolActivity, .connectorApp, .agentStep, .agentPlan, .modelOutputCompleted:
            break
        case let .snapshot(snapshot):
            content = snapshot.content
            thinking = snapshot.thinking
            if snapshot.content.isEmpty && snapshot.thinking.isEmpty { reasoningSummary = "" }
            if let summary = ChatReasoningSummaryStorage.decode(snapshot.thinking) { reasoningSummary = summary }
            media = snapshot.media
        case let .terminal(snapshot):
            content = snapshot.content
            thinking = snapshot.thinking
            if let summary = ChatReasoningSummaryStorage.decode(snapshot.thinking) { reasoningSummary = summary }
            media = snapshot.media
            terminal = snapshot
        }
    }
}

/// Marks the provider-returned reasoning summary stored in the legacy `thinking`
/// column. Unmarked provider thinking remains private and is never rendered.
enum ChatReasoningSummaryStorage {
    private static let prefix = "[[mychat:reasoning-summary:v1]]\n"

    static func encode(_ summary: String) -> String? {
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return prefix + summary
    }

    static func decode(_ storedValue: String?) -> String? {
        guard let storedValue, storedValue.hasPrefix(prefix) else { return nil }
        let summary = String(storedValue.dropFirst(prefix.count))
        return summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : summary
    }
}

enum ChatTransportError: LocalizedError, Equatable, Sendable {
    case missingAccessToken
    case invalidRequest(String)
    case invalidResponse
    case server(
        status: Int,
        code: String?,
        message: String,
        retryable: Bool,
        requestID: String?
    )
    case unsafeStreamURL
    case mismatchedAdmission
    case mismatchedJob
    case sequenceGap(expected: Int, actual: Int)
    case malformedEnvelope(String)
    case eventKindMismatch(event: String, envelope: String)
    case eventSequenceMismatch(identifier: String, envelope: Int)
    case terminalStatusMissing
    case terminalStatusType(String)
    case terminalStatusValue(String)
    case streamTimedOut

    var isRetryable: Bool {
        switch self {
        case let .server(_, _, _, retryable, _):
            return retryable
        case .streamTimedOut:
            return false
        default:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingAccessToken:
            return "缺少登录凭据"
        case let .invalidRequest(message):
            return message
        case .invalidResponse:
            return "聊天服务返回了无效响应"
        case let .server(_, _, message, _, _):
            return message
        case .unsafeStreamURL:
            return "聊天服务返回了不安全的事件流地址"
        case .mismatchedAdmission:
            return "聊天准入响应与本次请求不一致"
        case .mismatchedJob:
            return "事件流不属于当前聊天任务"
        case let .sequenceGap(expected, actual):
            return "事件序列不连续：应为 \(expected)，实际为 \(actual)"
        case let .malformedEnvelope(kind):
            return "\(kind) 事件封装无法解码"
        case let .eventKindMismatch(event, envelope):
            return "SSE 事件类型不一致：event=\(event)，envelope=\(envelope)"
        case let .eventSequenceMismatch(identifier, envelope):
            return "SSE 事件序号不一致：id=\(identifier)，envelope=\(envelope)"
        case .terminalStatusMissing:
            return "job.terminal 缺少 payload.status"
        case let .terminalStatusType(type):
            return "job.terminal payload.status 类型无效：\(type)"
        case let .terminalStatusValue(value):
            return "job.terminal payload.status 值无效：\(value)"
        case .streamTimedOut:
            return "聊天事件流等待超时"
        }
    }
}
