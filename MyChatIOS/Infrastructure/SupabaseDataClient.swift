import Foundation

protocol SupabaseDataServing: Sendable {
    func fetchConversations(accessToken: String) async throws -> [ConversationRecord]
    func fetchConversationPage(offset: Int, limit: Int, accessToken: String) async throws -> [ConversationRecord]
    func fetchMessages(
        conversationID: String,
        accessToken: String,
        limit: Int
    ) async throws -> [ConversationMessageRecord]
    func fetchConversationToolHistory(
        conversationID: String,
        assistantMessageIDs: [UUID],
        accessToken: String
    ) async throws -> ConversationToolHistory
    func updateConversationTitle(
        id: String,
        title: String,
        accessToken: String
    ) async throws
    func setConversationPinned(
        id: String,
        pinned: Bool,
        accessToken: String
    ) async throws
    func setConversationStarred(
        id: String,
        starred: Bool,
        accessToken: String
    ) async throws
    func setConversationProject(
        id: String,
        projectID: String?,
        accessToken: String
    ) async throws
    func deleteConversation(id: String, accessToken: String) async throws
}

extension SupabaseDataServing {
    func fetchConversationPage(offset: Int, limit: Int, accessToken: String) async throws -> [ConversationRecord] {
        let records = try await fetchConversations(accessToken: accessToken)
        return Array(records.dropFirst(max(0, offset)).prefix(max(0, limit)))
    }

    func fetchMessages(
        conversationID: String,
        accessToken: String
    ) async throws -> [ConversationMessageRecord] {
        try await fetchMessages(
            conversationID: conversationID,
            accessToken: accessToken,
            limit: 140
        )
    }
}

enum SupabaseDataError: LocalizedError, Equatable, Sendable {
    case invalidAccessToken
    case invalidIdentifier
    case invalidResponse
    case server(status: Int, code: String?, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidAccessToken:
            return "登录会话无效，请重新登录"
        case .invalidIdentifier:
            return "会话标识无效"
        case .invalidResponse:
            return "数据服务返回了无效响应"
        case let .server(_, _, message):
            return message
        }
    }
}

struct SupabaseDataClient: SupabaseDataServing {
    private static let productionBaseURL = URL(string: "https://mychat-nm6x.onrender.com")!
    private static let historyBatchSize = 50
    private static let historyPageSize = 1_000
    private let configurationClient: any MobileConfigurationServing
    private let session: URLSession

    init(
        configurationClient: any MobileConfigurationServing = MobileConfigurationClient(),
        session: URLSession = .shared
    ) {
        self.configurationClient = configurationClient
        self.session = session
    }

    func fetchConversations(accessToken: String) async throws -> [ConversationRecord] {
        try await fetchConversationPage(offset: 0, limit: 100, accessToken: accessToken)
    }

    func fetchConversationPage(offset: Int, limit: Int, accessToken: String) async throws -> [ConversationRecord] {
        let context = try await requestContext(accessToken: accessToken)
        let endpoint = try endpoint(
            baseURL: context.configuration.supabaseURL,
            table: "conversations",
            queryItems: [
                URLQueryItem(
                    name: "select",
                    value: "id,title,updated_at,project_id,starred,pinned,memory_enabled"
                ),
                URLQueryItem(name: "order", value: "pinned.desc,updated_at.desc,id.asc"),
                URLQueryItem(name: "offset", value: String(max(0, offset))),
                URLQueryItem(name: "limit", value: String(min(200, max(1, limit)))),
            ]
        )
        let data = try await perform(
            method: "GET",
            endpoint: endpoint,
            context: context
        )
        return try decode([ConversationRecord].self, from: data)
    }

    func fetchMessages(
        conversationID: String,
        accessToken: String,
        limit: Int = 140
    ) async throws -> [ConversationMessageRecord] {
        let normalizedID = try validIdentifier(conversationID)
        let context = try await requestContext(accessToken: accessToken)
        let safeLimit = min(max(limit, 1), 1_000)
        let endpoint = try endpoint(
            baseURL: context.configuration.supabaseURL,
            table: "messages",
            queryItems: [
                URLQueryItem(
                    name: "select",
                    value: "id,role,content,images,thinking,created_at,seq"
                ),
                URLQueryItem(name: "conversation_id", value: "eq.\(normalizedID)"),
                URLQueryItem(name: "order", value: "seq.desc"),
                URLQueryItem(name: "limit", value: String(safeLimit)),
            ]
        )
        let data = try await perform(
            method: "GET",
            endpoint: endpoint,
            context: context
        )
        let decoded = try decode(
            LossyDecodableArray<ConversationMessageRecord>.self,
            from: data
        )
        guard !decoded.elements.isEmpty || decoded.skippedCount == 0 else {
            throw SupabaseDataError.invalidResponse
        }
        return decoded.elements.reversed()
    }

    func fetchConversationToolHistory(
        conversationID: String,
        assistantMessageIDs: [UUID],
        accessToken: String
    ) async throws -> ConversationToolHistory {
        let conversationID = try validIdentifier(conversationID)
        let messageIDs = Array(Set(assistantMessageIDs.map { $0.uuidString.lowercased() })).sorted()
        guard !messageIDs.isEmpty else { return ConversationToolHistory() }
        let context = try await requestContext(accessToken: accessToken)
        var latestJobByMessageID: [String: String] = [:]

        for start in stride(from: 0, to: messageIDs.count, by: Self.historyBatchSize) {
            try Task.checkCancellation()
            let batch = Array(messageIDs[start..<min(start + Self.historyBatchSize, messageIDs.count)])
            let allowed = Set(batch)
            var offset = 0
            while true {
                let url = try endpoint(
                    baseURL: context.configuration.supabaseURL,
                    table: "jobs",
                    queryItems: [
                        URLQueryItem(name: "select", value: "id,subject"),
                        URLQueryItem(name: "type", value: "eq.chat.generation"),
                        URLQueryItem(name: "subject->>conversationId", value: "eq.\(conversationID)"),
                        URLQueryItem(name: "subject->>assistantMessageId", value: "in.(\(batch.joined(separator: ",")))"),
                        URLQueryItem(name: "order", value: "created_at.desc,id.desc"),
                        URLQueryItem(name: "limit", value: String(Self.historyPageSize)),
                        URLQueryItem(name: "offset", value: String(offset))
                    ]
                )
                let data = try await perform(method: "GET", endpoint: url, context: context)
                let rows = try decode([HistoricalChatJobRow].self, from: data)
                for row in rows {
                    guard row.subject.conversationId?.lowercased() == conversationID,
                          let messageID = row.subject.assistantMessageId?.lowercased(),
                          allowed.contains(messageID), UUID(uuidString: row.id) != nil,
                          latestJobByMessageID[messageID] == nil else { continue }
                    latestJobByMessageID[messageID] = row.id.lowercased()
                }
                guard rows.count == Self.historyPageSize else { break }
                offset += rows.count
                try Task.checkCancellation()
            }
        }

        let messageByJobID = Dictionary(uniqueKeysWithValues: latestJobByMessageID.compactMap { messageID, jobID in
            UUID(uuidString: messageID).map { (jobID, $0) }
        })
        let jobIDs = messageByJobID.keys.sorted()
        var history = ConversationToolHistory()
        for start in stride(from: 0, to: jobIDs.count, by: Self.historyBatchSize) {
            try Task.checkCancellation()
            let batch = Array(jobIDs[start..<min(start + Self.historyBatchSize, jobIDs.count)])
            var offset = 0
            while true {
                let url = try endpoint(
                    baseURL: context.configuration.supabaseURL,
                    table: "job_events",
                    queryItems: [
                        URLQueryItem(name: "select", value: "job_id,seq,kind,payload"),
                        URLQueryItem(name: "job_id", value: "in.(\(batch.joined(separator: ",")))"),
                        URLQueryItem(name: "kind", value: "in.(\"tool.search\",\"tool.memory\",\"tool.requested\",\"tool.completed\",\"connector.app\")"),
                        URLQueryItem(name: "order", value: "job_id.asc,seq.asc"),
                        URLQueryItem(name: "limit", value: String(Self.historyPageSize)),
                        URLQueryItem(name: "offset", value: String(offset))
                    ]
                )
                let data = try await perform(method: "GET", endpoint: url, context: context)
                let rows = try decode([HistoricalChatJobEventRow].self, from: data)
                for row in rows {
                    guard let messageID = messageByJobID[row.jobID.lowercased()] else { continue }
                    restore(row, for: messageID, into: &history)
                }
                guard rows.count == Self.historyPageSize else { break }
                offset += rows.count
                try Task.checkCancellation()
            }
        }
        return history
    }

    private func restore(
        _ row: HistoricalChatJobEventRow,
        for messageID: UUID,
        into history: inout ConversationToolHistory
    ) {
        guard let payload = row.payload.objectValue else { return }
        switch row.kind {
        case "tool.search":
            if let search = decodeEventValue(payload["search"], as: ChatToolSearch.self) {
                history.searches[messageID, default: []].append(search)
            }
        case "tool.memory":
            if let change = decodeEventValue(payload["memory"], as: ChatMemoryEvent.self) {
                history.memoryChanges[messageID, default: []].append(change)
            }
        case "tool.requested", "tool.completed":
            guard let callID = payload["toolCallId"]?.stringValue,
                  let name = payload["toolName"]?.stringValue else { return }
            var activities = history.toolActivities[messageID, default: []]
            if let index = activities.firstIndex(where: { $0.toolCallID == callID }) {
                activities[index].isComplete = activities[index].isComplete || row.kind == "tool.completed"
            } else {
                activities.append(ChatToolActivity(toolCallID: callID, toolName: name,
                                                   isComplete: row.kind == "tool.completed"))
            }
            history.toolActivities[messageID] = activities
        case "connector.app":
            if let app = decodeEventValue(payload["connectorApp"], as: ChatConnectorAppPayload.self) {
                history.connectorApps[messageID, default: []].append(ChatConnectorAppEvent(
                    id: "\(row.jobID.lowercased()):\(row.sequence)", payload: app
                ))
            }
        default: break
        }
    }

    private func decodeEventValue<Value: Decodable>(_ value: JSONValue?, as type: Value.Type) -> Value? {
        guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func updateConversationTitle(
        id: String,
        title: String,
        accessToken: String
    ) async throws {
        let patch = ConversationTitlePatch(
            title: title,
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )
        try await patchConversation(
            id: id,
            accessToken: accessToken,
            patch: patch
        )
    }

    func setConversationPinned(
        id: String,
        pinned: Bool,
        accessToken: String
    ) async throws {
        try await patchConversation(
            id: id,
            accessToken: accessToken,
            patch: ConversationPinnedPatch(pinned: pinned)
        )
    }

    func setConversationStarred(
        id: String,
        starred: Bool,
        accessToken: String
    ) async throws {
        try await patchConversation(
            id: id,
            accessToken: accessToken,
            patch: ConversationStarredPatch(starred: starred)
        )
    }

    func setConversationProject(
        id: String,
        projectID: String?,
        accessToken: String
    ) async throws {
        let normalizedProjectID: String?
        if let projectID {
            normalizedProjectID = try validIdentifier(projectID)
        } else {
            normalizedProjectID = nil
        }
        try await patchConversation(
            id: id,
            accessToken: accessToken,
            patch: ConversationProjectPatch(projectID: normalizedProjectID)
        )
    }

    func deleteConversation(id: String, accessToken: String) async throws {
        let normalizedID = try validIdentifier(id)
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: \.isNewline) else {
            throw SupabaseDataError.invalidAccessToken
        }
        let endpoint = Self.productionBaseURL
            .appendingPathComponent("api/conversations")
            .appendingPathComponent(normalizedID)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("mychat-ios/1.0", forHTTPHeaderField: "X-Client-Info")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseDataError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let payload = try? JSONDecoder().decode(ConversationDeleteErrorPayload.self, from: data)
            throw SupabaseDataError.server(
                status: http.statusCode,
                code: nil,
                message: payload?.error ?? "会话删除失败，请稍后重试"
            )
        }
    }

    private func patchConversation<P: Encodable & Sendable>(
        id: String,
        accessToken: String,
        patch: P
    ) async throws {
        let normalizedID = try validIdentifier(id)
        let context = try await requestContext(accessToken: accessToken)
        let endpoint = try endpoint(
            baseURL: context.configuration.supabaseURL,
            table: "conversations",
            queryItems: [URLQueryItem(name: "id", value: "eq.\(normalizedID)")]
        )
        let body: Data
        do {
            body = try JSONEncoder().encode(patch)
        } catch {
            throw SupabaseDataError.invalidResponse
        }
        _ = try await perform(
            method: "PATCH",
            endpoint: endpoint,
            context: context,
            body: body,
            prefer: "return=minimal"
        )
    }

    private func requestContext(accessToken: String) async throws -> RequestContext {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw SupabaseDataError.invalidAccessToken
        }
        return RequestContext(
            configuration: try await configurationClient.fetchConfiguration(),
            accessToken: token
        )
    }

    private func endpoint(
        baseURL: URL,
        table: String,
        queryItems: [URLQueryItem]
    ) throws -> URL {
        let base = baseURL
            .appendingPathComponent("rest")
            .appendingPathComponent("v1")
            .appendingPathComponent(table)
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw SupabaseDataError.invalidResponse
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw SupabaseDataError.invalidResponse
        }
        return url
    }

    private func perform(
        method: String,
        endpoint: URL,
        context: RequestContext,
        body: Data? = nil,
        prefer: String? = nil
    ) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            context.configuration.supabaseAnonKey,
            forHTTPHeaderField: "apikey"
        )
        request.setValue(
            "Bearer \(context.accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("mychat-ios/1.0", forHTTPHeaderField: "X-Client-Info")
        if let prefer {
            request.setValue(prefer, forHTTPHeaderField: "Prefer")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseDataError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw serverError(status: http.statusCode, data: data)
        }
        return data
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw SupabaseDataError.invalidResponse
        }
    }

    private func validIdentifier(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let identifier = UUID(uuidString: normalized) else {
            throw SupabaseDataError.invalidIdentifier
        }
        return identifier.uuidString.lowercased()
    }

    private func serverError(status: Int, data: Data) -> SupabaseDataError {
        let payload = try? JSONDecoder().decode(PostgRESTErrorPayload.self, from: data)
        let fallback: String
        switch status {
        case 401:
            fallback = "登录会话已失效，请重新登录"
        case 403:
            fallback = "没有权限访问此会话"
        case 404:
            fallback = "会话不存在"
        default:
            fallback = "会话数据暂时不可用，请稍后再试"
        }
        return .server(
            status: status,
            code: payload?.code,
            message: payload?.message ?? fallback
        )
    }
}

private struct RequestContext: Sendable {
    let configuration: MobileConfiguration
    let accessToken: String
}

private struct ConversationTitlePatch: Encodable, Sendable {
    let title: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case title
        case updatedAt = "updated_at"
    }
}

private struct ConversationPinnedPatch: Encodable, Sendable {
    let pinned: Bool
}

private struct ConversationStarredPatch: Encodable, Sendable {
    let starred: Bool
}

private struct ConversationProjectPatch: Encodable, Sendable {
    let projectID: String?

    enum CodingKeys: String, CodingKey {
        case projectID = "project_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(projectID, forKey: .projectID)
    }
}

private struct PostgRESTErrorPayload: Decodable {
    let code: String?
    let message: String?
}

private struct ConversationDeleteErrorPayload: Decodable {
    let error: String?
}

private struct HistoricalChatJobRow: Decodable {
    let id: String
    let subject: Subject

    struct Subject: Decodable {
        let conversationId: String?
        let assistantMessageId: String?
    }
}

private struct HistoricalChatJobEventRow: Decodable {
    let jobID: String
    let sequence: Int
    let kind: String
    let payload: JSONValue

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case sequence = "seq"
        case kind, payload
    }
}

private struct LossyDecodableArray<Element: Decodable>: Decodable {
    let elements: [Element]
    let skippedCount: Int

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        var skippedCount = 0

        while !container.isAtEnd {
            do {
                elements.append(try container.decode(Element.self))
            } catch {
                _ = try container.decode(JSONValue.self)
                skippedCount += 1
            }
        }

        self.elements = elements
        self.skippedCount = skippedCount
    }
}
