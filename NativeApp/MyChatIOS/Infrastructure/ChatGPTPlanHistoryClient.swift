import Foundation

struct ChatGPTPlanHistoryClient {
    private let baseURL = URL(string: "https://mychat-nm6x.onrender.com")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func persistTurn(
        command: ChatAppendCommand,
        assistantMessage: ChatMessage,
        accessToken: String
    ) async throws {
        let body = ChatGPTPlanHistoryTurnBody(command: command, assistantMessage: assistantMessage)
        _ = try await post(body, path: "api/chat/chatgpt-plan-history", accessToken: accessToken)
    }

    func prepareContext(
        command: ChatAppendCommand,
        modelName: String,
        isPrivate: Bool,
        accessToken: String
    ) async throws -> ChatGPTPlanPreparedContext {
        let body = ChatGPTPlanContextRequest(command: command, modelName: modelName, isPrivate: isPrivate)
        let data = try await post(body, path: "api/chat/chatgpt-plan-context", accessToken: accessToken)
        do { return try JSONDecoder().decode(ChatGPTPlanPreparedContext.self, from: data) }
        catch { throw ChatGPTPlanHistoryError.invalidResponse }
    }

    func executeTool(
        name: String,
        arguments: String,
        command: ChatAppendCommand,
        isPrivate: Bool,
        accessToken: String
    ) async throws -> String {
        guard let argumentData = arguments.data(using: .utf8),
              case .object = try JSONDecoder().decode(JSONValue.self, from: argumentData) else {
            throw ChatGPTPlanHistoryError.invalidResponse
        }
        let latestRequest = command.userMessage.content
        let body = ChatGPTPlanToolRequest(
            command: command,
            name: name,
            arguments: try JSONDecoder().decode(JSONValue.self, from: argumentData),
            latestUserRequest: latestRequest,
            isPrivate: isPrivate
        )
        let data = try await post(body, path: "api/chat/chatgpt-plan-tool", accessToken: accessToken)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ChatGPTPlanHistoryError.invalidResponse
        }
        return json
    }

    private func post<T: Encodable>(_ body: T, path: String, accessToken: String) async throws -> Data {
        let data = try JSONEncoder().encode(body)
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = data

        let (responseData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatGPTPlanHistoryError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any]
            let error = object?["error"] as? [String: Any] ?? object ?? [:]
            let message = error["message"] as? String
                ?? error["detail"] as? String
                ?? error["error"] as? String
                ?? "MyChat 套餐功能服务暂时不可用"
            throw ChatGPTPlanHistoryError.server(status: http.statusCode, message: message)
        }
        return responseData
    }
}

private struct ChatGPTPlanContextRequest: Encodable {
    let conversationId: String
    let userMessageId: String
    let assistantMessageId: String
    let createConversation: Bool
    let privateChat: Bool
    let title: String
    let projectId: String?
    let memoryEnabled: Bool
    let content: String
    let images: [String]
    let hasAttachments: Bool
    let createdAt: String
    let modelName: String
    let searchMode: String
    let historyRetrievalEnabled: Bool
    let renderEnabled: Bool
    let connectorAccessMode: String
    let connectorIds: [String]?

    init(command: ChatAppendCommand, modelName: String, isPrivate: Bool) {
        conversationId = command.conversationID.uuidString.lowercased()
        userMessageId = command.userMessage.id.uuidString.lowercased()
        assistantMessageId = command.assistantMessageID.uuidString.lowercased()
        createConversation = command.createConversation
        privateChat = isPrivate
        title = command.title
        projectId = command.projectID?.uuidString.lowercased()
        memoryEnabled = command.conversationMemoryEnabled
        content = command.userMessage.content
        images = (command.userMessage.sourceImages ?? []).filter { $0.hasPrefix("https://") }
        hasAttachments = !command.attachments.isEmpty
        createdAt = ChatGPTPlanHistoryMessageBody.timestamp(command.userMessage.createdAt)
        self.modelName = modelName
        searchMode = command.tools.searchMode.rawValue
        historyRetrievalEnabled = command.tools.historyRetrieval
        renderEnabled = command.tools.renderEnabled
        connectorAccessMode = command.tools.connectorAccessMode.rawValue
        connectorIds = command.tools.connectorIDs?.map { $0.lowercased() }
    }
}

private struct ChatGPTPlanToolRequest: Encodable {
    let conversationId: String
    let userMessageId: String
    let privateChat: Bool
    let toolName: String
    let arguments: JSONValue
    let searchMode: String
    let connectorAccessMode: String
    let connectorIds: [String]?
    let latestUserRequest: String

    init(command: ChatAppendCommand, name: String, arguments: JSONValue, latestUserRequest: String, isPrivate: Bool) {
        conversationId = command.conversationID.uuidString.lowercased()
        userMessageId = command.userMessage.id.uuidString.lowercased()
        privateChat = isPrivate
        toolName = name
        self.arguments = arguments
        searchMode = command.tools.searchMode.rawValue
        connectorAccessMode = command.tools.connectorAccessMode.rawValue
        connectorIds = command.tools.connectorIDs?.map { $0.lowercased() }
        self.latestUserRequest = latestUserRequest
    }
}

struct ChatGPTPlanPreparedContext: Decodable, Sendable {
    let systemPrompt: String
    let messages: [ChatGPTPlanPreparedMessage]
    let tools: [ChatGPTPlanToolDefinition]
    let historySearch: ChatGPTPlanHistorySearchEnvelope?
}

struct ChatGPTPlanPreparedMessage: Decodable, Sendable {
    let id: String
    let role: String
    let content: JSONValue
    let images: [String]?
    let ts: String?

    var chatMessage: ChatMessage? {
        guard let id = UUID(uuidString: id), let role = ChatMessageRole(rawValue: role) else { return nil }
        let text: String
        switch content {
        case let .string(value): text = value
        case let .array(parts):
            text = parts.compactMap { part in
                guard case let .object(object) = part,
                      case let .string(value)? = object["text"] else { return nil }
                return value
            }.joined(separator: "\n")
        case let .object(object):
            if case let .string(value)? = object["text"] { text = value }
            else { text = "" }
        default: text = ""
        }
        let date = Self.parseDate(ts) ?? Date()
        return ChatMessage(
            id: id,
            role: role,
            content: text,
            thinking: nil,
            sourceImages: images?.isEmpty == false ? images : nil,
            createdAt: date
        )
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

struct ChatGPTPlanToolDefinition: Decodable, Sendable {
    let type: String
    let name: String
    let description: String
    let parameters: JSONValue

    var responseObject: [String: Any] {
        ["type": type, "name": name, "description": description,
         "parameters": parameters.foundationValue, "strict": false]
    }
}

struct ChatGPTPlanHistorySearchEnvelope: Decodable, Sendable {
    let search: ChatToolSearch?
}

private extension JSONValue {
    var foundationValue: Any {
        switch self {
        case let .string(value): value
        case let .integer(value): value
        case let .number(value): value
        case let .bool(value): value
        case let .object(value): value.mapValues(\.foundationValue)
        case let .array(value): value.map(\.foundationValue)
        case .null: NSNull()
        }
    }
}

private struct ChatGPTPlanHistoryTurnBody: Encodable {
    let conversationId: String
    let createConversation: Bool
    let title: String
    let projectId: String?
    let userMessage: ChatGPTPlanHistoryMessageBody
    let assistantMessage: ChatGPTPlanHistoryMessageBody
    let regeneration: ChatGPTPlanHistoryRegenerationBody?

    init(command: ChatAppendCommand, assistantMessage: ChatMessage) {
        conversationId = command.conversationID.uuidString.lowercased()
        createConversation = command.createConversation
        title = command.title
        projectId = command.projectID?.uuidString.lowercased()
        userMessage = ChatGPTPlanHistoryMessageBody(message: command.userMessage)
        self.assistantMessage = ChatGPTPlanHistoryMessageBody(message: assistantMessage)
        regeneration = command.regeneration.map(ChatGPTPlanHistoryRegenerationBody.init)
    }

    private enum CodingKeys: String, CodingKey {
        case conversationId, createConversation, title, projectId, userMessage, assistantMessage, regeneration
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(conversationId, forKey: .conversationId)
        try container.encode(createConversation, forKey: .createConversation)
        try container.encode(title, forKey: .title)
        if let projectId { try container.encode(projectId, forKey: .projectId) }
        else { try container.encodeNil(forKey: .projectId) }
        try container.encode(userMessage, forKey: .userMessage)
        try container.encode(assistantMessage, forKey: .assistantMessage)
        try container.encodeIfPresent(regeneration, forKey: .regeneration)
    }
}

private struct ChatGPTPlanHistoryRegenerationBody: Encodable {
    let operation: String
    let expectedTailMessageID: String
    let targetAssistantMessageID: String?

    init(_ regeneration: ChatRegeneration) {
        operation = regeneration.operation
        expectedTailMessageID = regeneration.expectedTailMessageID.uuidString.lowercased()
        targetAssistantMessageID = regeneration.targetAssistantMessageID?.uuidString.lowercased()
    }

    private enum CodingKeys: String, CodingKey {
        case operation, expectedTailMessageID, targetAssistantMessageID
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(operation, forKey: .operation)
        try container.encode(expectedTailMessageID, forKey: .expectedTailMessageID)
        if let targetAssistantMessageID {
            try container.encode(targetAssistantMessageID, forKey: .targetAssistantMessageID)
        } else {
            try container.encodeNil(forKey: .targetAssistantMessageID)
        }
    }
}

private struct ChatGPTPlanHistoryMessageBody: Encodable {
    let id: String
    let role: String
    let content: String
    let thinking: String?
    let images: [String]
    let createdAt: String

    init(message: ChatMessage) {
        id = message.id.uuidString.lowercased()
        role = message.role.rawValue
        content = message.content
        thinking = message.thinking
        images = (message.sourceImages ?? []).filter { $0.hasPrefix("https://") }
        createdAt = Self.timestamp(message.createdAt)
    }

    init(id: UUID, role: String, content: String, images: [String], createdAt: Date) {
        self.id = id.uuidString.lowercased()
        self.role = role
        self.content = content
        self.thinking = nil
        self.images = images
        self.createdAt = Self.timestamp(createdAt)
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

enum ChatGPTPlanHistoryError: LocalizedError {
    case invalidResponse
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "MyChat 历史记录服务返回无效响应"
        case let .server(status, message):
            return "回复已完成，但同步 MyChat 历史记录失败（HTTP \(status)）：\(message)"
        }
    }
}
