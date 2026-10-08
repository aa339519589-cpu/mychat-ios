import Foundation

protocol AccountSettingsServing: Sendable {
    func fetchMemorySettings(accessToken: String) async throws -> MemorySettingsRecord
    func setMemoryEnabled(_ enabled: Bool, accessToken: String) async throws
    func setSensitiveMemoryEnabled(_ enabled: Bool, accessToken: String) async throws
    func fetchMemories(accessToken: String) async throws -> [MemoryRecord]
    func createMemory(content: String, topic: String, accessToken: String) async throws -> MemoryRecord
    func importMemories(_ entries: [MemoryImportEntry], accessToken: String) async throws -> MemoryImportResult
    func updateMemory(id: String, content: String, topic: String, accessToken: String) async throws
    func deleteMemory(id: String, accessToken: String) async throws
    func fetchSystemPrompt(accessToken: String) async throws -> String
    func saveSystemPrompt(_ prompt: String, accessToken: String) async throws -> String
    func fetchQuota(userID: String, accessToken: String) async throws -> AccountQuotaSnapshot
    func redeemInvitationCode(_ code: String, accessToken: String) async throws -> InvitationRedemption
    func deleteAllConversations(accessToken: String) async throws -> Int
    func deleteAllMemories(accessToken: String) async throws
    func fetchModelEndpoints(accessToken: String) async throws -> [CustomModelEndpoint]
    func discoverModels(
        baseURL: String,
        apiKey: String,
        authType: CustomEndpointAuthType,
        accessToken: String
    ) async throws -> CustomModelDiscovery
    func createModelEndpoint(
        _ draft: CustomEndpointDraft,
        accessToken: String
    ) async throws -> CustomModelEndpoint
    func deleteModelEndpoint(id: String, accessToken: String) async throws
    func fetchConnectors(accessToken: String) async throws -> [MCPConnectorRecord]
    func createConnector(name: String, serverURL: String, accessTokenValue: String?, accessToken: String) async throws -> MCPConnectorRecord
    func setConnectorEnabled(id: String, enabled: Bool, accessToken: String) async throws
    func refreshConnector(id: String, accessToken: String) async throws
    func deleteConnector(id: String, accessToken: String) async throws -> String?
    func fetchConnectorDirectory(search: String, cursor: String?, accessToken: String) async throws -> MCPDirectoryResponse
    func startConnectorAuthorization(connectorID: String?, name: String, serverURL: String, clientID: String?, clientSecret: String?, accessToken: String) async throws -> MCPOAuthStartResponse
    func fetchConnectorAppResource(connectorID: String, toolName: String, accessToken: String) async throws -> ChatConnectorAppResource
    func callConnectorAppTool(connectorID: String, toolName: String, arguments: [String: JSONValue], accessToken: String) async throws -> ChatConnectorAppResult
}

enum AccountSettingsError: LocalizedError, Equatable, Sendable {
    case invalidAccessToken
    case invalidInput(String)
    case invalidResponse
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidAccessToken:
            return "登录会话无效，请重新登录"
        case let .invalidInput(message):
            return message
        case .invalidResponse:
            return "账户服务返回了无效响应"
        case let .server(_, message):
            return message
        }
    }
}

struct AccountSettingsClient: AccountSettingsServing {
    private static let productionBaseURL = URL(string: "https://mychat-nm6x.onrender.com")!

    private let configurationClient: any MobileConfigurationServing
    private let session: URLSession
    private let baseURL: URL

    init(
        configurationClient: any MobileConfigurationServing = MobileConfigurationClient(),
        session: URLSession = .shared,
        baseURL: URL = Self.productionBaseURL
    ) {
        self.configurationClient = configurationClient
        self.session = session
        self.baseURL = baseURL
    }

    func fetchMemorySettings(accessToken: String) async throws -> MemorySettingsRecord {
        let data = try await backendRequest(
            method: "GET",
            path: ["api", "profile", "memory"],
            accessToken: accessToken
        )
        let response = try decode(MemorySettingResponse.self, from: data)
        return MemorySettingsRecord(
            enabled: response.enabled,
            sensitiveEnabled: response.sensitiveEnabled == true
        )
    }

    func setMemoryEnabled(_ enabled: Bool, accessToken: String) async throws {
        let data = try await backendRequest(
            method: "PUT",
            path: ["api", "profile", "memory"],
            accessToken: accessToken,
            body: try encode(MemorySettingRequest(enabled: enabled))
        )
        guard try decode(MemorySettingResponse.self, from: data).enabled == enabled else {
            throw AccountSettingsError.invalidResponse
        }
    }

    func setSensitiveMemoryEnabled(_ enabled: Bool, accessToken: String) async throws {
        let data = try await backendRequest(
            method: "PUT",
            path: ["api", "profile", "memory"],
            accessToken: accessToken,
            body: try encode(MemorySettingRequest(sensitiveEnabled: enabled))
        )
        guard try decode(MemorySettingResponse.self, from: data).sensitiveEnabled == enabled else {
            throw AccountSettingsError.invalidResponse
        }
    }

    func fetchMemories(accessToken: String) async throws -> [MemoryRecord] {
        let data = try await backendRequest(
            method: "GET",
            path: ["api", "memories"],
            accessToken: accessToken
        )
        return try decode(MemoriesResponse.self, from: data).memories
    }

    func createMemory(content: String, topic: String, accessToken: String) async throws -> MemoryRecord {
        let normalized = try validMemoryContent(content)
        let data = try await backendRequest(
            method: "POST",
            path: ["api", "memories"],
            accessToken: accessToken,
            body: try encode(MemoryContentRequest(content: normalized, topic: try validMemoryTopic(topic)))
        )
        return try decode(MemoryMutationResponse.self, from: data).memory
    }

    func importMemories(
        _ entries: [MemoryImportEntry],
        accessToken: String
    ) async throws -> MemoryImportResult {
        guard (1...100).contains(entries.count) else {
            throw AccountSettingsError.invalidInput("每次最多导入 100 条记忆")
        }
        let normalized = try entries.map { entry in
            MemoryImportEntry(
                content: try validMemoryContent(entry.content),
                topic: try validMemoryTopic(entry.topic)
            )
        }
        let data = try await backendRequest(
            method: "POST",
            path: ["api", "memories", "import"],
            accessToken: accessToken,
            body: try encode(MemoryImportRequest(memories: normalized))
        )
        let response = try decode(MemoryImportResponse.self, from: data)
        return MemoryImportResult(
            memories: response.memories,
            skippedDuplicates: response.skipped
        )
    }

    func updateMemory(id: String, content: String, topic: String, accessToken: String) async throws {
        let normalized = try validMemoryContent(content)
        let data = try await backendRequest(
            method: "PATCH",
            path: ["api", "memories", id],
            accessToken: accessToken,
            body: try encode(MemoryContentRequest(content: normalized, topic: try validMemoryTopic(topic)))
        )
        _ = try decode(MemoryMutationResponse.self, from: data).memory
    }

    func deleteMemory(id: String, accessToken: String) async throws {
        let data = try await backendRequest(
            method: "DELETE",
            path: ["api", "memories", id],
            accessToken: accessToken
        )
        guard try decode(MemoryDeleteResponse.self, from: data).ok else {
            throw AccountSettingsError.invalidResponse
        }
    }

    func fetchSystemPrompt(accessToken: String) async throws -> String {
        let data = try await backendRequest(
            method: "GET",
            path: ["api", "profile", "system-prompt"],
            accessToken: accessToken
        )
        return try decode(PromptResponse.self, from: data).prompt
    }

    func saveSystemPrompt(_ prompt: String, accessToken: String) async throws -> String {
        guard prompt.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count <= 20_000 else {
            throw AccountSettingsError.invalidInput("系统提示词最多 20,000 字")
        }
        let data = try await backendRequest(
            method: "PUT",
            path: ["api", "profile", "system-prompt"],
            accessToken: accessToken,
            body: try encode(PromptRequest(prompt: prompt))
        )
        return try decode(PromptResponse.self, from: data).prompt
    }

    func fetchQuota(userID: String, accessToken: String) async throws -> AccountQuotaSnapshot {
        guard let userID = UUID(uuidString: userID)?.uuidString.lowercased() else {
            throw AccountSettingsError.invalidInput("用户标识无效")
        }
        let configuration = try await configurationClient.fetchConfiguration()
        let endpoint = try restEndpoint(
            configuration.supabaseURL,
            table: "profiles",
            queryItems: [
                .init(name: "select", value: "tokens_5h,window_5h_start,tokens_7d,window_7d_start,balance"),
                .init(name: "user_id", value: "eq.\(userID)"),
                .init(name: "limit", value: "1"),
            ]
        )
        let data = try await supabaseRequest(
            method: "GET",
            endpoint: endpoint,
            configuration: configuration,
            accessToken: accessToken
        )
        let rows = try decode([QuotaRow].self, from: data)
        let now = ISO8601DateFormatter().string(from: Date())
        let row = rows.first
        return AccountQuotaSnapshot(
            tokens5h: row?.tokens5h ?? 0,
            window5hStart: row?.window5hStart ?? now,
            tokens7d: row?.tokens7d ?? 0,
            window7dStart: row?.window7dStart ?? now,
            balance: row?.balance ?? 0
        )
    }

    func redeemInvitationCode(_ code: String, accessToken: String) async throws -> InvitationRedemption {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (8...128).contains(normalized.count) else {
            throw AccountSettingsError.invalidInput("邀请码长度必须为 8 到 128 个字符")
        }
        let data = try await backendRequest(
            method: "POST",
            path: ["api", "redeem-code"],
            accessToken: accessToken,
            body: try encode(RedeemRequest(code: normalized))
        )
        let response = try decode(RedeemResponse.self, from: data)
        return InvitationRedemption(tokensAdded: response.tokensAdded, newBalance: response.newBalance)
    }

    func deleteAllConversations(accessToken: String) async throws -> Int {
        let data = try await backendRequest(
            method: "DELETE",
            path: ["api", "conversations"],
            accessToken: accessToken
        )
        return try decode(DeleteConversationsResponse.self, from: data).count
    }

    func deleteAllMemories(accessToken: String) async throws {
        let data = try await backendRequest(
            method: "DELETE",
            path: ["api", "memories"],
            accessToken: accessToken
        )
        guard try decode(MemoryDeleteAllResponse.self, from: data).deleted >= 0 else {
            throw AccountSettingsError.invalidResponse
        }
    }

    func fetchModelEndpoints(accessToken: String) async throws -> [CustomModelEndpoint] {
        let data = try await backendRequest(
            method: "GET",
            path: ["api", "endpoints"],
            accessToken: accessToken
        )
        return try decode(EndpointsResponse.self, from: data).endpoints
    }

    func discoverModels(
        baseURL: String,
        apiKey: String,
        authType: CustomEndpointAuthType,
        accessToken: String
    ) async throws -> CustomModelDiscovery {
        let normalizedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedURL.utf16.count <= 2_048, apiKey.utf16.count <= 4_096 else {
            throw AccountSettingsError.invalidInput("模型服务配置过长")
        }
        let data = try await backendRequest(
            method: "POST",
            path: ["api", "endpoints", "discover"],
            accessToken: accessToken,
            body: try encode(DiscoverRequest(
                baseURL: normalizedURL,
                apiKey: apiKey,
                authType: authType
            )),
            timeout: 45
        )
        let response = try decode(DiscoveryResponse.self, from: data)
        return CustomModelDiscovery(
            baseURL: response.baseURL,
            authType: response.authType,
            models: response.models
        )
    }

    func createModelEndpoint(
        _ draft: CustomEndpointDraft,
        accessToken: String
    ) async throws -> CustomModelEndpoint {
        let model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.utf16.count <= 512 else {
            throw AccountSettingsError.invalidInput("请选择有效模型")
        }
        let data = try await backendRequest(
            method: "POST",
            path: ["api", "endpoints"],
            accessToken: accessToken,
            body: try encode(CreateEndpointRequest(draft: draft)),
            timeout: 60
        )
        return try decode(EndpointMutationResponse.self, from: data).endpoint
    }

    func deleteModelEndpoint(id: String, accessToken: String) async throws {
        guard let id = UUID(uuidString: id)?.uuidString.lowercased() else {
            throw AccountSettingsError.invalidInput("端点标识无效")
        }
        _ = try await backendRequest(
            method: "DELETE",
            path: ["api", "endpoints", id],
            accessToken: accessToken
        )
    }

    func fetchConnectors(accessToken: String) async throws -> [MCPConnectorRecord] {
        let data = try await backendRequest(
            method: "GET",
            path: ["api", "connectors"],
            accessToken: accessToken
        )
        return try decode(ConnectorsResponse.self, from: data).connectors
    }

    func createConnector(
        name: String,
        serverURL: String,
        accessTokenValue: String?,
        accessToken: String
    ) async throws -> MCPConnectorRecord {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, normalizedName.count <= 80 else {
            throw AccountSettingsError.invalidInput("连接器名称必须为 1 到 80 个字符")
        }
        guard normalizedURL.utf16.count <= 2_048,
              let components = URLComponents(string: normalizedURL),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.fragment == nil else {
            throw AccountSettingsError.invalidInput("MCP 服务必须使用有效的 HTTPS 地址")
        }
        let token = accessTokenValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (token?.utf16.count ?? 0) <= 4_096,
              !(token?.contains(where: \.isNewline) ?? false),
              !(token?.contains("\0") ?? false) else {
            throw AccountSettingsError.invalidInput("访问令牌无效或过长")
        }
        let data = try await backendRequest(
            method: "POST",
            path: ["api", "connectors"],
            accessToken: accessToken,
            body: try encode(ConnectorCreateRequest(
                name: normalizedName,
                serverURL: normalizedURL,
                accessToken: token?.isEmpty == true ? nil : token
            )),
            timeout: 45
        )
        return try decode(ConnectorMutationResponse.self, from: data).connector
    }

    func setConnectorEnabled(id: String, enabled: Bool, accessToken: String) async throws {
        let connectorID = try validConnectorID(id)
        let data = try await backendRequest(
            method: "PATCH",
            path: ["api", "connectors", connectorID],
            accessToken: accessToken,
            body: try encode(ConnectorEnabledRequest(enabled: enabled))
        )
        let response = try decode(ConnectorEnabledResponse.self, from: data)
        guard response.id == connectorID, response.enabled == enabled else {
            throw AccountSettingsError.invalidResponse
        }
    }

    func refreshConnector(id: String, accessToken: String) async throws {
        let connectorID = try validConnectorID(id)
        let data = try await backendRequest(
            method: "POST",
            path: ["api", "connectors", connectorID, "refresh"],
            accessToken: accessToken,
            timeout: 45
        )
        guard try decode(ConnectorRefreshResponse.self, from: data).connected else {
            throw AccountSettingsError.invalidResponse
        }
    }

    func deleteConnector(id: String, accessToken: String) async throws -> String? {
        let connectorID = try validConnectorID(id)
        let data = try await backendRequest(
            method: "DELETE",
            path: ["api", "connectors", connectorID],
            accessToken: accessToken
        )
        let result = try decode(ConnectorDeleteResponse.self, from: data)
        guard result.ok else { throw AccountSettingsError.invalidResponse }
        return result.revocation
    }

    func fetchConnectorDirectory(search: String, cursor: String?, accessToken: String) async throws -> MCPDirectoryResponse {
        var query = [URLQueryItem(name: "search", value: search)]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let data = try await backendRequest(method: "GET", path: ["api", "connectors", "directory"],
                                           accessToken: accessToken, queryItems: query)
        return try decode(MCPDirectoryResponse.self, from: data)
    }

    func startConnectorAuthorization(connectorID: String?, name: String, serverURL: String,
                                     clientID: String?, clientSecret: String?, accessToken: String) async throws -> MCPOAuthStartResponse {
        var body = ["name": name.trimmingCharacters(in: .whitespacesAndNewlines),
                    "serverUrl": serverURL.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let connectorID { body["connectorId"] = try validConnectorID(connectorID) }
        if let clientID, !clientID.isEmpty { body["clientId"] = clientID }
        if let clientSecret, !clientSecret.isEmpty { body["clientSecret"] = clientSecret }
        let data = try await backendRequest(method: "POST", path: ["api", "connectors", "oauth", "start"],
                                           accessToken: accessToken, body: try encode(body), timeout: 60)
        let result = try decode(MCPOAuthStartResponse.self, from: data)
        guard result.authorizationUrl.scheme == "https", result.authorizationUrl.host != nil,
              result.authorizationUrl.user == nil, result.authorizationUrl.password == nil else {
            throw AccountSettingsError.invalidResponse
        }
        return result
    }

    func fetchConnectorAppResource(
        connectorID: String,
        toolName: String,
        accessToken: String
    ) async throws -> ChatConnectorAppResource {
        let connectorID = try validConnectorID(connectorID)
        let normalizedToolName = try validConnectorToolName(toolName)
        let data = try await backendRequest(
            method: "POST",
            path: ["api", "connectors", connectorID, "resource"],
            accessToken: accessToken,
            body: try encode(ConnectorAppRequest(toolName: normalizedToolName))
        )
        return try decode(ChatConnectorAppResource.self, from: data)
    }

    func callConnectorAppTool(
        connectorID: String,
        toolName: String,
        arguments: [String: JSONValue],
        accessToken: String
    ) async throws -> ChatConnectorAppResult {
        let connectorID = try validConnectorID(connectorID)
        let normalizedToolName = try validConnectorToolName(toolName)
        let data = try await backendRequest(
            method: "POST",
            path: ["api", "connectors", connectorID, "call"],
            accessToken: accessToken,
            body: try encode(ConnectorAppCallRequest(toolName: normalizedToolName, arguments: arguments)),
            timeout: 45
        )
        return try decode(ConnectorAppCallResponse.self, from: data).result
    }

    private func validConnectorID(_ value: String) throws -> String {
        guard let id = UUID(uuidString: value)?.uuidString.lowercased() else {
            throw AccountSettingsError.invalidInput("连接器标识无效")
        }
        return id
    }

    private func validConnectorToolName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf16.count <= 128,
              name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw AccountSettingsError.invalidInput("连接器工具名称无效")
        }
        return name
    }

    private func validMemoryContent(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf16.count <= 20_000 else {
            throw AccountSettingsError.invalidInput("记忆内容为空或过长")
        }
        return normalized
    }

    private func validMemoryTopic(_ value: String) throws -> String {
        let normalized = value
            .precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalized.isEmpty, normalized.count <= 80 else {
            throw AccountSettingsError.invalidInput("记忆主题为空或超过 80 个字符")
        }
        return normalized
    }

    private func backendRequest(
        method: String,
        path: [String],
        accessToken: String,
        body: Data? = nil,
        timeout: TimeInterval = 30,
        queryItems: [URLQueryItem] = []
    ) async throws -> Data {
        let token = try validatedAccessToken(accessToken)
        var endpoint = baseURL
        for component in path { endpoint.appendPathComponent(component) }
        guard endpoint.scheme == "https", endpoint.host != nil else {
            throw AccountSettingsError.invalidResponse
        }
        if !queryItems.isEmpty {
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
            components?.queryItems = queryItems
            guard let url = components?.url else { throw AccountSettingsError.invalidInput("查询无效") }
            endpoint = url
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("mychat-ios/1.0", forHTTPHeaderField: "X-Client-Info")
        return try await perform(request)
    }

    private func supabaseRequest(
        method: String,
        endpoint: URL,
        configuration: MobileConfiguration,
        accessToken: String,
        prefer: String? = nil
    ) async throws -> Data {
        let token = try validatedAccessToken(accessToken)
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(configuration.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("mychat-ios/1.0", forHTTPHeaderField: "X-Client-Info")
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AccountSettingsError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let payload = try? JSONDecoder().decode(FlatErrorResponse.self, from: data)
            throw AccountSettingsError.server(
                status: http.statusCode,
                message: payload?.error ?? fallbackMessage(for: http.statusCode)
            )
        }
        return data
    }

    private func restEndpoint(
        _ baseURL: URL,
        table: String,
        queryItems: [URLQueryItem]
    ) throws -> URL {
        let base = baseURL
            .appendingPathComponent("rest")
            .appendingPathComponent("v1")
            .appendingPathComponent(table)
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw AccountSettingsError.invalidResponse
        }
        components.queryItems = queryItems
        guard let endpoint = components.url else { throw AccountSettingsError.invalidResponse }
        return endpoint
    }

    private func validatedAccessToken(_ value: String) throws -> String {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: \.isNewline) else {
            throw AccountSettingsError.invalidAccessToken
        }
        return token
    }

    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        do { return try JSONEncoder().encode(value) }
        catch { throw AccountSettingsError.invalidResponse }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw AccountSettingsError.invalidResponse }
    }

    private func fallbackMessage(for status: Int) -> String {
        switch status {
        case 400: return "提交内容无效，请检查后重试"
        case 401: return "登录会话已失效，请重新登录"
        case 403: return "没有权限执行这项操作"
        case 404: return "请求的数据不存在"
        case 409: return "当前状态暂时不能执行这项操作"
        case 429: return "操作太频繁，请稍后再试"
        default: return "账户服务暂时不可用，请稍后再试"
        }
    }
}

private struct PromptRequest: Encodable { let prompt: String }
private struct PromptResponse: Decodable { let prompt: String }
struct MemorySettingRequest: Encodable {
    var enabled: Bool? = nil
    var sensitiveEnabled: Bool? = nil
}
private struct MemorySettingResponse: Decodable {
    let enabled: Bool
    let sensitiveEnabled: Bool?
}
private struct MemoryContentRequest: Encodable { let content: String; let topic: String }
private struct MemoryImportRequest: Encodable { let memories: [MemoryImportEntry] }
private struct MemoryImportResponse: Decodable {
    let memories: [MemoryRecord]
    let skipped: Int
}
private struct MemoriesResponse: Decodable { let memories: [MemoryRecord] }
private struct MemoryMutationResponse: Decodable { let memory: MemoryRecord }
private struct MemoryDeleteResponse: Decodable { let ok: Bool }
private struct MemoryDeleteAllResponse: Decodable { let deleted: Int }
private struct RedeemRequest: Encodable { let code: String }

private struct RedeemResponse: Decodable {
    let tokensAdded: Int64
    let newBalance: Int64
}

private struct DeleteConversationsResponse: Decodable {
    let ok: Bool
    let count: Int
}

private struct QuotaRow: Decodable {
    let tokens5h: Int64?
    let window5hStart: String?
    let tokens7d: Int64?
    let window7dStart: String?
    let balance: Int64?

    enum CodingKeys: String, CodingKey {
        case tokens5h = "tokens_5h"
        case window5hStart = "window_5h_start"
        case tokens7d = "tokens_7d"
        case window7dStart = "window_7d_start"
        case balance
    }
}

private struct EndpointsResponse: Decodable { let endpoints: [CustomModelEndpoint] }
private struct EndpointMutationResponse: Decodable { let endpoint: CustomModelEndpoint }
private struct ConnectorsResponse: Decodable { let connectors: [MCPConnectorRecord] }
private struct ConnectorMutationResponse: Decodable { let connector: MCPConnectorRecord }
private struct ConnectorCreateRequest: Encodable {
    let name: String
    let serverURL: String
    let accessToken: String?

    enum CodingKeys: String, CodingKey {
        case name
        case serverURL = "serverUrl"
        case accessToken
    }
}
private struct ConnectorEnabledRequest: Encodable { let enabled: Bool }
private struct ConnectorEnabledResponse: Decodable { let id: String; let enabled: Bool }
private struct ConnectorRefreshResponse: Decodable { let connected: Bool }
private struct ConnectorDeleteResponse: Decodable { let ok: Bool; let revocation: String? }
private struct ConnectorAppRequest: Encodable { let toolName: String }
private struct ConnectorAppCallRequest: Encodable {
    let toolName: String
    let arguments: [String: JSONValue]
}
private struct ConnectorAppCallResponse: Decodable { let result: ChatConnectorAppResult }

private struct DiscoverRequest: Encodable {
    let baseURL: String
    let apiKey: String
    let authType: CustomEndpointAuthType

    enum CodingKeys: String, CodingKey {
        case baseURL = "baseUrl"
        case apiKey
        case authType
    }
}

private struct DiscoveryResponse: Decodable {
    let baseURL: String
    let authType: CustomEndpointAuthType
    let models: [DiscoveredCustomModel]

    enum CodingKeys: String, CodingKey {
        case baseURL = "baseUrl"
        case authType
        case models
    }
}

private struct CreateEndpointRequest: Encodable {
    let baseURL: String
    let apiKey: String
    let model: String
    let displayName: String
    let outputKind: CustomEndpointOutputKind
    let authType: CustomEndpointAuthType

    init(draft: CustomEndpointDraft) {
        baseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        displayName = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        outputKind = draft.outputKind
        authType = draft.authType
    }

    enum CodingKeys: String, CodingKey {
        case baseURL = "baseUrl"
        case apiKey
        case model
        case displayName
        case outputKind
        case authType
    }
}

private struct FlatErrorResponse: Decodable { let error: String? }

/// Local, content-free diagnostics for the global Memory path.
/// The cache file contains operation names, result categories, HTTP statuses,
/// and row counts only; it never stores memory text, account IDs, or tokens.
enum MemoryOperationDiagnostics {
    private static let fileName = "mychat-memory-diagnostic.json"
    private static let maxRecords = 24

    static func record(
        action: String,
        succeeded: Bool,
        count: Int? = nil,
        enabled: Bool? = nil,
        error: Error? = nil
    ) {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return
        }
        let url = caches.appendingPathComponent(fileName)
        var records = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        var entry: [String: Any] = [
            "time": ISO8601DateFormatter().string(from: Date()),
            "action": action,
            "outcome": succeeded ? "success" : "failure",
        ]
        if let count { entry["count"] = count }
        if let enabled { entry["enabled"] = enabled }
        if let error {
            let details = failureDetails(error)
            for (key, value) in details { entry[key] = value }
        }
        records.append(entry)
        if records.count > maxRecords { records.removeFirst(records.count - maxRecords) }
        guard let data = try? JSONSerialization.data(withJSONObject: records, options: [.sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func failureDetails(_ error: Error) -> [String: Any] {
        if let error = error as? AccountSettingsError {
            switch error {
            case .invalidAccessToken:
                return ["failure": "invalid_access_token"]
            case .invalidInput:
                return ["failure": "invalid_input"]
            case .invalidResponse:
                return ["failure": "invalid_response"]
            case let .server(status, _):
                return ["failure": "http_error", "http_status": status]
            }
        }
        if let error = error as? AuthenticationError {
            if case let .server(status, _) = error {
                return ["failure": "auth_http_error", "http_status": status]
            }
            return ["failure": "authentication"]
        }
        if let error = error as? URLError {
            return ["failure": "network_error", "network_code": error.code.rawValue]
        }
        return ["failure": "other"]
    }
}
