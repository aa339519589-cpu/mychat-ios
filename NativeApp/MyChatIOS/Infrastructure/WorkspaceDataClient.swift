import Foundation

protocol WorkspaceDataServing: Sendable {
    func fetchProjects(accessToken: String) async throws -> [ProjectRecord]
    func createProject(
        userID: String,
        name: String,
        instructions: String,
        accessToken: String
    ) async throws -> ProjectRecord
    func updateProject(
        id: String,
        name: String,
        instructions: String,
        accessToken: String
    ) async throws
    func deleteProject(id: String, accessToken: String) async throws

    func fetchProjectFiles(projectID: String, accessToken: String) async throws -> [ProjectFileRecord]
    func createProjectFile(
        userID: String,
        projectID: String,
        name: String,
        content: String,
        accessToken: String
    ) async throws -> ProjectFileRecord
    func deleteProjectFile(id: String, accessToken: String) async throws

    func fetchProjectMemories(
        projectID: String,
        accessToken: String
    ) async throws -> [ProjectMemoryRecord]
    func createProjectMemory(
        userID: String,
        projectID: String,
        content: String,
        accessToken: String
    ) async throws -> ProjectMemoryRecord
    func updateProjectMemory(id: String, content: String, accessToken: String) async throws
    func deleteProjectMemory(id: String, accessToken: String) async throws

    func fetchArtifacts(accessToken: String) async throws -> [ArtifactRecord]
    func upsertArtifact(
        userID: String,
        conversationID: String,
        messageID: String,
        projectID: String?,
        title: String,
        raw: String,
        accessToken: String
    ) async throws -> ArtifactRecord
    func deleteArtifact(id: String, accessToken: String) async throws

    func fetchCodeSessions(accessToken: String) async throws -> [CodeSessionRecord]
    func createCodeSession(
        userID: String,
        repository: String?,
        title: String,
        accessToken: String
    ) async throws -> CodeSessionRecord
    func deleteCodeSession(id: String, accessToken: String) async throws
    func fetchCodeMessages(
        sessionID: String,
        accessToken: String
    ) async throws -> [CodeMessageRecord]
    func createCodeMessage(
        userID: String,
        sessionID: String,
        role: String,
        content: String,
        metadata: JSONValue?,
        accessToken: String
    ) async throws -> CodeMessageRecord
    func fetchCodeMemories(
        repository: String,
        accessToken: String
    ) async throws -> [CodeMemoryRecord]
    func createCodeMemory(
        userID: String,
        repository: String,
        content: String,
        accessToken: String
    ) async throws -> CodeMemoryRecord
    func deleteCodeMemory(id: String, accessToken: String) async throws
    func fetchCodeTasks(
        repository: String,
        accessToken: String
    ) async throws -> [CodeTaskRecord]
}

enum WorkspaceDataError: LocalizedError, Equatable, Sendable {
    case invalidAccessToken
    case invalidIdentifier
    case invalidInput(String)
    case invalidResponse
    case server(status: Int, code: String?, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidAccessToken:
            return "登录会话无效，请重新登录"
        case .invalidIdentifier:
            return "数据标识无效"
        case let .invalidInput(message):
            return message
        case .invalidResponse:
            return "工作区数据服务返回了无效响应"
        case let .server(_, _, message):
            return message
        }
    }
}

struct WorkspaceDataClient: WorkspaceDataServing {
    private let configurationClient: any MobileConfigurationServing
    private let session: URLSession

    init(
        configurationClient: any MobileConfigurationServing = MobileConfigurationClient(),
        session: URLSession = .shared
    ) {
        self.configurationClient = configurationClient
        self.session = session
    }

    func fetchProjects(accessToken: String) async throws -> [ProjectRecord] {
        try await fetchRows(
            table: "projects",
            queryItems: [
                .init(name: "select", value: "id,name,instructions,created_at,updated_at"),
                .init(name: "order", value: "updated_at.desc"),
            ],
            accessToken: accessToken
        )
    }

    func createProject(
        userID: String,
        name: String,
        instructions: String,
        accessToken: String
    ) async throws -> ProjectRecord {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, normalizedName.utf16.count <= 200 else {
            throw WorkspaceDataError.invalidInput("项目名称必须为 1 到 200 个字符")
        }
        let row = ProjectInsert(
            id: UUID().uuidString.lowercased(),
            userID: try validIdentifier(userID),
            name: normalizedName,
            instructions: String(instructions.prefix(12_000))
        )
        return try await insertReturning(
            table: "projects",
            row: row,
            accessToken: accessToken
        )
    }

    func updateProject(
        id: String,
        name: String,
        instructions: String,
        accessToken: String
    ) async throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, normalizedName.utf16.count <= 200 else {
            throw WorkspaceDataError.invalidInput("项目名称必须为 1 到 200 个字符")
        }
        try await patch(
            table: "projects",
            id: id,
            body: ProjectUpdate(
                name: normalizedName,
                instructions: String(instructions.prefix(12_000)),
                updatedAt: timestamp()
            ),
            accessToken: accessToken
        )
    }

    func deleteProject(id: String, accessToken: String) async throws {
        try await delete(table: "projects", id: id, accessToken: accessToken)
    }

    func fetchProjectFiles(
        projectID: String,
        accessToken: String
    ) async throws -> [ProjectFileRecord] {
        let projectID = try validIdentifier(projectID)
        return try await fetchRows(
            table: "project_files",
            queryItems: [
                .init(name: "select", value: "id,project_id,name,content,created_at"),
                .init(name: "project_id", value: "eq.\(projectID)"),
                .init(name: "order", value: "created_at.asc"),
                .init(name: "limit", value: "100"),
            ],
            accessToken: accessToken
        )
    }

    func createProjectFile(
        userID: String,
        projectID: String,
        name: String,
        content: String,
        accessToken: String
    ) async throws -> ProjectFileRecord {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, normalizedName.utf16.count <= 255 else {
            throw WorkspaceDataError.invalidInput("资料名称必须为 1 到 255 个字符")
        }
        guard content.utf8.count <= 2_000_000 else {
            throw WorkspaceDataError.invalidInput("项目资料正文过大")
        }
        return try await insertReturning(
            table: "project_files",
            row: ProjectFileInsert(
                id: UUID().uuidString.lowercased(),
                projectID: try validIdentifier(projectID),
                userID: try validIdentifier(userID),
                name: normalizedName,
                content: content
            ),
            accessToken: accessToken
        )
    }

    func deleteProjectFile(id: String, accessToken: String) async throws {
        try await delete(table: "project_files", id: id, accessToken: accessToken)
    }

    func fetchProjectMemories(
        projectID: String,
        accessToken: String
    ) async throws -> [ProjectMemoryRecord] {
        let projectID = try validIdentifier(projectID)
        return try await fetchRows(
            table: "project_memories",
            queryItems: [
                .init(name: "select", value: "id,project_id,content,created_at,updated_at"),
                .init(name: "project_id", value: "eq.\(projectID)"),
                .init(name: "order", value: "created_at.asc"),
                .init(name: "limit", value: "200"),
            ],
            accessToken: accessToken
        )
    }

    func createProjectMemory(
        userID: String,
        projectID: String,
        content: String,
        accessToken: String
    ) async throws -> ProjectMemoryRecord {
        let content = try validMemoryContent(content)
        return try await insertReturning(
            table: "project_memories",
            row: ProjectMemoryInsert(
                id: UUID().uuidString.lowercased(),
                userID: try validIdentifier(userID),
                projectID: try validIdentifier(projectID),
                content: content
            ),
            accessToken: accessToken
        )
    }

    func updateProjectMemory(
        id: String,
        content: String,
        accessToken: String
    ) async throws {
        try await patch(
            table: "project_memories",
            id: id,
            body: ProjectMemoryUpdate(content: try validMemoryContent(content), updatedAt: timestamp()),
            accessToken: accessToken
        )
    }

    func deleteProjectMemory(id: String, accessToken: String) async throws {
        try await delete(table: "project_memories", id: id, accessToken: accessToken)
    }

    func fetchArtifacts(accessToken: String) async throws -> [ArtifactRecord] {
        try await fetchRows(
            table: "artifacts",
            queryItems: [
                .init(
                    name: "select",
                    value: "id,title,raw,conversation_id,message_id,project_id,created_at,updated_at"
                ),
                .init(name: "order", value: "created_at.desc"),
                .init(name: "limit", value: "100"),
            ],
            accessToken: accessToken
        )
    }

    func upsertArtifact(
        userID: String,
        conversationID: String,
        messageID: String,
        projectID: String?,
        title: String,
        raw: String,
        accessToken: String
    ) async throws -> ArtifactRecord {
        guard !raw.isEmpty, raw.utf8.count <= 2_000_000 else {
            throw WorkspaceDataError.invalidInput("可视化内容为空或过大")
        }
        let context = try await requestContext(accessToken: accessToken)
        let endpoint = try endpoint(
            baseURL: context.configuration.supabaseURL,
            table: "artifacts",
            queryItems: [.init(name: "on_conflict", value: "message_id")]
        )
        let row = ArtifactUpsert(
            id: UUID().uuidString.lowercased(),
            userID: try validIdentifier(userID),
            conversationID: try validIdentifier(conversationID),
            messageID: try validIdentifier(messageID),
            projectID: try projectID.map(validIdentifier),
            title: String(title.prefix(200)),
            raw: raw
        )
        let data = try await perform(
            method: "POST",
            endpoint: endpoint,
            context: context,
            body: try encode(row),
            prefer: "resolution=merge-duplicates,return=representation"
        )
        return try decodeSingle(ArtifactRecord.self, from: data)
    }

    func deleteArtifact(id: String, accessToken: String) async throws {
        try await delete(table: "artifacts", id: id, accessToken: accessToken)
    }

    func fetchCodeSessions(accessToken: String) async throws -> [CodeSessionRecord] {
        try await fetchRows(
            table: "code_sessions",
            queryItems: [
                .init(name: "select", value: "id,repo,title,created_at,updated_at"),
                .init(name: "order", value: "updated_at.desc"),
                .init(name: "limit", value: "50"),
            ],
            accessToken: accessToken
        )
    }

    func createCodeSession(
        userID: String,
        repository: String?,
        title: String,
        accessToken: String
    ) async throws -> CodeSessionRecord {
        let id = UUID().uuidString.lowercased()
        let suppliedRepository = repository?.trimmingCharacters(in: .whitespacesAndNewlines)
        let repository = suppliedRepository.flatMap { $0.isEmpty ? nil : $0 }
            ?? "__mychat_new__/\(id)"
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidRepository(repository) else {
            throw WorkspaceDataError.invalidInput("GitHub 仓库标识无效")
        }
        guard !title.isEmpty, title.utf16.count <= 200 else {
            throw WorkspaceDataError.invalidInput("编程会话标题无效")
        }
        return try await insertReturning(
            table: "code_sessions",
            row: CodeSessionInsert(
                id: id,
                userID: try validIdentifier(userID),
                repository: repository,
                title: title
            ),
            accessToken: accessToken
        )
    }

    func deleteCodeSession(id: String, accessToken: String) async throws {
        try await delete(table: "code_sessions", id: id, accessToken: accessToken)
    }

    func fetchCodeMessages(
        sessionID: String,
        accessToken: String
    ) async throws -> [CodeMessageRecord] {
        let sessionID = try validIdentifier(sessionID)
        return try await fetchRows(
            table: "code_messages",
            queryItems: [
                .init(name: "select", value: "id,session_id,role,content,meta,created_at"),
                .init(name: "session_id", value: "eq.\(sessionID)"),
                .init(name: "order", value: "created_at.asc"),
                .init(name: "limit", value: "200"),
            ],
            accessToken: accessToken
        )
    }

    func createCodeMessage(
        userID: String,
        sessionID: String,
        role: String,
        content: String,
        metadata: JSONValue?,
        accessToken: String
    ) async throws -> CodeMessageRecord {
        guard role == "user" || role == "assistant" else {
            throw WorkspaceDataError.invalidInput("编程消息角色无效")
        }
        guard content.utf16.count <= 100_000 else {
            throw WorkspaceDataError.invalidInput("编程消息过长")
        }
        return try await insertReturning(
            table: "code_messages",
            row: CodeMessageInsert(
                id: UUID().uuidString.lowercased(),
                sessionID: try validIdentifier(sessionID),
                userID: try validIdentifier(userID),
                role: role,
                content: content,
                metadata: metadata
            ),
            accessToken: accessToken
        )
    }

    func fetchCodeMemories(
        repository: String,
        accessToken: String
    ) async throws -> [CodeMemoryRecord] {
        guard isValidRepository(repository) else {
            throw WorkspaceDataError.invalidInput("GitHub 仓库标识无效")
        }
        return try await fetchRows(
            table: "code_memories",
            queryItems: [
                .init(name: "select", value: "id,repo,content,created_at"),
                .init(name: "repo", value: "eq.\(repository)"),
                .init(name: "order", value: "created_at.asc"),
                .init(name: "limit", value: "200"),
            ],
            accessToken: accessToken
        )
    }

    func createCodeMemory(
        userID: String,
        repository: String,
        content: String,
        accessToken: String
    ) async throws -> CodeMemoryRecord {
        guard isValidRepository(repository) else {
            throw WorkspaceDataError.invalidInput("GitHub 仓库标识无效")
        }
        return try await insertReturning(
            table: "code_memories",
            row: CodeMemoryInsert(
                id: UUID().uuidString.lowercased(),
                userID: try validIdentifier(userID),
                repository: repository,
                content: try validMemoryContent(content)
            ),
            accessToken: accessToken
        )
    }

    func deleteCodeMemory(id: String, accessToken: String) async throws {
        try await delete(table: "code_memories", id: id, accessToken: accessToken)
    }

    func fetchCodeTasks(
        repository: String,
        accessToken: String
    ) async throws -> [CodeTaskRecord] {
        guard isValidRepository(repository) else {
            throw WorkspaceDataError.invalidInput("GitHub 仓库标识无效")
        }
        return try await fetchRows(
            table: "agent_tasks",
            queryItems: [
                .init(name: "select", value: "id,goal,repo,status,error,created_at,updated_at"),
                .init(name: "repo", value: "eq.\(repository)"),
                .init(name: "order", value: "created_at.desc"),
                .init(name: "limit", value: "50"),
            ],
            accessToken: accessToken
        )
    }

    private func fetchRows<Value: Decodable>(
        table: String,
        queryItems: [URLQueryItem],
        accessToken: String
    ) async throws -> [Value] {
        let context = try await requestContext(accessToken: accessToken)
        let endpoint = try endpoint(
            baseURL: context.configuration.supabaseURL,
            table: table,
            queryItems: queryItems
        )
        let data = try await perform(method: "GET", endpoint: endpoint, context: context)
        return try decode([Value].self, from: data)
    }

    private func insertReturning<Row: Encodable, Value: Decodable>(
        table: String,
        row: Row,
        accessToken: String
    ) async throws -> Value {
        let context = try await requestContext(accessToken: accessToken)
        let endpoint = try endpoint(
            baseURL: context.configuration.supabaseURL,
            table: table,
            queryItems: []
        )
        let data = try await perform(
            method: "POST",
            endpoint: endpoint,
            context: context,
            body: try encode(row),
            prefer: "return=representation"
        )
        return try decodeSingle(Value.self, from: data)
    }

    private func patch<Body: Encodable>(
        table: String,
        id: String,
        body: Body,
        accessToken: String
    ) async throws {
        let context = try await requestContext(accessToken: accessToken)
        let endpoint = try endpoint(
            baseURL: context.configuration.supabaseURL,
            table: table,
            queryItems: [.init(name: "id", value: "eq.\(try validIdentifier(id))")]
        )
        _ = try await perform(
            method: "PATCH",
            endpoint: endpoint,
            context: context,
            body: try encode(body),
            prefer: "return=minimal"
        )
    }

    private func delete(table: String, id: String, accessToken: String) async throws {
        let context = try await requestContext(accessToken: accessToken)
        let endpoint = try endpoint(
            baseURL: context.configuration.supabaseURL,
            table: table,
            queryItems: [.init(name: "id", value: "eq.\(try validIdentifier(id))")]
        )
        _ = try await perform(
            method: "DELETE",
            endpoint: endpoint,
            context: context,
            prefer: "return=minimal"
        )
    }

    private func requestContext(accessToken: String) async throws -> WorkspaceRequestContext {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: \.isNewline) else {
            throw WorkspaceDataError.invalidAccessToken
        }
        return WorkspaceRequestContext(
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
            throw WorkspaceDataError.invalidResponse
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw WorkspaceDataError.invalidResponse }
        return url
    }

    private func perform(
        method: String,
        endpoint: URL,
        context: WorkspaceRequestContext,
        body: Data? = nil,
        prefer: String? = nil
    ) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(context.configuration.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(context.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("mychat-ios/1.0", forHTTPHeaderField: "X-Client-Info")
        if let prefer { request.setValue(prefer, forHTTPHeaderField: "Prefer") }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw WorkspaceDataError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw serverError(status: http.statusCode, data: data)
        }
        return data
    }

    private func validIdentifier(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = UUID(uuidString: value) else { throw WorkspaceDataError.invalidIdentifier }
        return id.uuidString.lowercased()
    }

    private func validMemoryContent(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf16.count <= 20_000 else {
            throw WorkspaceDataError.invalidInput("记忆内容为空或过长")
        }
        return value
    }

    private func isValidRepository(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-"))
        return parts.allSatisfy {
            !$0.isEmpty
                && $0 != "."
                && $0 != ".."
                && $0.unicodeScalars.allSatisfy(allowed.contains)
        }
    }

    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        do { return try JSONEncoder().encode(value) }
        catch { throw WorkspaceDataError.invalidResponse }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw WorkspaceDataError.invalidResponse }
    }

    private func decodeSingle<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let values: [Value] = try decode([Value].self, from: data)
        guard let value = values.first else { throw WorkspaceDataError.invalidResponse }
        return value
    }

    private func serverError(status: Int, data: Data) -> WorkspaceDataError {
        let payload = try? JSONDecoder().decode(WorkspacePostgRESTError.self, from: data)
        let fallback: String
        switch status {
        case 401: fallback = "登录会话已失效，请重新登录"
        case 403: fallback = "没有权限访问这项数据"
        case 404: fallback = "请求的数据不存在"
        case 409: fallback = "数据已经发生变化，请刷新后重试"
        default: fallback = "工作区数据暂时不可用，请稍后再试"
        }
        return .server(status: status, code: payload?.code, message: payload?.message ?? fallback)
    }

    private func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

private struct WorkspaceRequestContext: Sendable {
    let configuration: MobileConfiguration
    let accessToken: String
}

private struct WorkspacePostgRESTError: Decodable {
    let code: String?
    let message: String?
}

private struct ProjectInsert: Encodable {
    let id: String
    let userID: String
    let name: String
    let instructions: String
    enum CodingKeys: String, CodingKey { case id, name, instructions; case userID = "user_id" }
}

private struct ProjectUpdate: Encodable {
    let name: String
    let instructions: String
    let updatedAt: String
    enum CodingKeys: String, CodingKey { case name, instructions; case updatedAt = "updated_at" }
}

private struct ProjectFileInsert: Encodable {
    let id: String
    let projectID: String
    let userID: String
    let name: String
    let content: String
    enum CodingKeys: String, CodingKey {
        case id, name, content
        case projectID = "project_id"
        case userID = "user_id"
    }
}

private struct ProjectMemoryInsert: Encodable {
    let id: String
    let userID: String
    let projectID: String
    let content: String
    enum CodingKeys: String, CodingKey {
        case id, content
        case userID = "user_id"
        case projectID = "project_id"
    }
}

private struct ProjectMemoryUpdate: Encodable {
    let content: String
    let updatedAt: String
    enum CodingKeys: String, CodingKey { case content; case updatedAt = "updated_at" }
}

private struct ArtifactUpsert: Encodable {
    let id: String
    let userID: String
    let conversationID: String
    let messageID: String
    let projectID: String?
    let title: String
    let raw: String
    enum CodingKeys: String, CodingKey {
        case id, title, raw
        case userID = "user_id"
        case conversationID = "conversation_id"
        case messageID = "message_id"
        case projectID = "project_id"
    }
}

private struct CodeSessionInsert: Encodable {
    let id: String
    let userID: String
    let repository: String
    let title: String
    enum CodingKeys: String, CodingKey {
        case id, title
        case userID = "user_id"
        case repository = "repo"
    }
}

private struct CodeMessageInsert: Encodable {
    let id: String
    let sessionID: String
    let userID: String
    let role: String
    let content: String
    let metadata: JSONValue?
    enum CodingKeys: String, CodingKey {
        case id, role, content
        case sessionID = "session_id"
        case userID = "user_id"
        case metadata = "meta"
    }
}

private struct CodeMemoryInsert: Encodable {
    let id: String
    let userID: String
    let repository: String
    let content: String
    enum CodingKeys: String, CodingKey {
        case id, content
        case userID = "user_id"
        case repository = "repo"
    }
}
