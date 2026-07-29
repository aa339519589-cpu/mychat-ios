import Foundation

enum APIError: LocalizedError {
    case message(String)
    case response(
        message: String,
        statusCode: Int,
        code: String?,
        retryable: Bool,
        retryAfter: TimeInterval?,
        requestID: String?
    )

    var errorDescription: String? {
        switch self {
        case let .message(value):
            return value
        case let .response(message, _, _, _, _, _):
            return message
        }
    }

    var statusCode: Int? {
        if case let .response(_, statusCode, _, _, _, _) = self { return statusCode }
        return nil
    }

    var isRetryable: Bool {
        if case let .response(_, _, _, retryable, _, _) = self { return retryable }
        return false
    }

    var retryAfter: TimeInterval? {
        if case let .response(_, _, _, _, retryAfter, _) = self { return retryAfter }
        return nil
    }
}

actor APIClient {
    private let baseURL: URL
    private let decoder: JSONDecoder
    private let encoder = JSONEncoder()
    private var bootstrap: MobileBootstrap?
    private var session: AuthSession?

    init(baseURL: URL = AppConfig.apiBaseURL) {
        self.baseURL = baseURL
        self.session = KeychainStore.load()
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let standard = ISO8601DateFormatter()
            if let date = standard.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid ISO-8601 date"
            )
        }
    }

    func restoreSession() async -> Bool {
        guard session != nil else { return false }
        do {
            let config = try await loadBootstrap()
            var request = URLRequest(url: config.supabaseUrl.appending(path: "auth/v1/user"))
            request.setValue(config.supabaseAnonKey, forHTTPHeaderField: "apikey")
            request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            if http.statusCode == 401 {
                _ = try await refreshSession()
                return true
            }
            return 200..<300 ~= http.statusCode
        } catch {
            return false
        }
    }

    func signIn(email: String, password: String) async throws {
        let config = try await loadBootstrap()
        var components = URLComponents(
            url: config.supabaseUrl.appending(path: "auth/v1/token"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "grant_type", value: "password")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(["email": email, "password": password])
        try saveSession(try await send(request))
    }

    func signOut() {
        session = nil
        KeychainStore.clear()
    }

    func conversations() async throws -> [Conversation] {
        let config = try await loadBootstrap()
        let url = try restURL(config, path: "conversations", query: [
            "select": "id,title,updated_at",
            "order": "updated_at.desc",
            "limit": "100",
        ])
        let request = try await authorizedRequest(url, config: config)
        return try await send(request)
    }

    func messages(conversationID: UUID) async throws -> [ChatMessage] {
        let config = try await loadBootstrap()
        let url = try restURL(config, path: "messages", query: [
            "select": "id,role,content,thinking,created_at",
            "conversation_id": "eq.\(conversationID.uuidString)",
            "order": "created_at.asc",
            "limit": "300",
        ])
        let request = try await authorizedRequest(url, config: config)
        return try await send(request)
    }

    func models() async throws -> [ModelChoice] {
        let config = try await loadBootstrap()
        let url = try restURL(config, path: "endpoints", query: [
            "select": "id,name,model,output_kind",
            "output_kind": "eq.chat",
            "order": "updated_at.desc",
        ])
        let request = try await authorizedRequest(url, config: config)
        let endpoints: [EndpointRow]
        do {
            endpoints = try await send(request)
        } catch {
            return ModelChoice.platform
        }
        return ModelChoice.platform + endpoints.map {
            ModelChoice(
                id: "endpoint-\($0.id.uuidString)",
                name: $0.name.isEmpty ? $0.model : $0.name,
                detail: $0.model,
                selection: .endpoint(id: $0.id)
            )
        }
    }

    func enqueue(
        text: String,
        conversationID: UUID,
        history: [ChatMessage],
        model: ModelChoice,
        createConversation: Bool,
        conversationTitle: String,
        userMessageID: UUID,
        assistantMessageID: UUID,
        generationID: UUID
    ) async throws -> ChatEnqueueResponse {
        let submittedAt = Date()
        let userMessage = ChatMessage(
            id: userMessageID,
            role: "user",
            content: text,
            createdAt: submittedAt
        )
        let messages = history + [userMessage]
        let fallbackTitle = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let title = String((conversationTitle.isEmpty ? fallbackTitle : conversationTitle).prefix(200))
        let serverHasConversation = try? await conversationExists(conversationID)
        let authoritativeCreate = serverHasConversation.map { !$0 } ?? createConversation

        var body: [String: Any] = [
            "conversationId": conversationID.uuidString,
            "userMessageId": userMessageID.uuidString,
            "assistantMessageId": assistantMessageID.uuidString,
            "generationId": generationID.uuidString,
            "messages": messages.map { message -> [String: Any] in
                var value: [String: Any] = [
                    "id": message.id.uuidString,
                    "role": message.role,
                    "content": message.content,
                ]
                // The authoritative timestamp for the newly submitted user turn
                // stays server-owned. Historical timestamps are context only.
                if message.id != userMessageID, let createdAt = message.createdAt {
                    value["ts"] = ISO8601DateFormatter().string(from: createdAt)
                }
                return value
            },
            "searchMode": "off",
            "deepResearch": false,
            "historyRetrieval": false,
            "turn": [
                "schemaVersion": 1,
                "createConversation": authoritativeCreate,
                "title": title.isEmpty ? "新对话" : title,
                "projectId": NSNull(),
            ],
        ]
        switch model.selection {
        case let .platform(tier):
            body["tier"] = tier
        case let .endpoint(id):
            body["endpointId"] = id.uuidString
        }

        // One command, one set of durable IDs, one byte-identical body. A retry
        // can never create a second turn for the same tap.
        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        var retryAttempt = 0

        while true {
            try Task.checkCancellation()
            do {
                return try await postEnqueue(bodyData, generationID: generationID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }

                // The POST may have reached the server even when its acknowledgement
                // was lost. Read the durable job before deciding to send again.
                if let accepted = try? await reconcileEnqueue(generationID: generationID) {
                    return accepted
                }

                guard let delay = enqueueRetryDelay(for: error, attempt: retryAttempt) else {
                    throw error
                }
                retryAttempt += 1
                try await Task.sleep(nanoseconds: delay)
            }
        }
    }

    private func postEnqueue(_ bodyData: Data, generationID: UUID) async throws -> ChatEnqueueResponse {
        var request = URLRequest(url: baseURL.appending(path: "api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = 50
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("chat:\(generationID.uuidString)", forHTTPHeaderField: "Idempotency-Key")
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData
        return try await send(request)
    }

    private func reconcileEnqueue(generationID: UUID) async throws -> ChatEnqueueResponse? {
        var request = URLRequest(
            url: baseURL.appending(path: "api/v1/jobs/\(generationID.uuidString)")
        )
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.message("作业状态响应无效")
        }
        if http.statusCode == 404 { return nil }
        guard 200..<300 ~= http.statusCode else {
            throw responseError(data, response: http)
        }
        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let job = root["job"] as? [String: Any],
            let id = job["id"] as? String,
            id.caseInsensitiveCompare(generationID.uuidString) == .orderedSame,
            let status = job["status"] as? String
        else {
            throw APIError.message("作业状态格式无法识别")
        }
        return ChatEnqueueResponse(
            jobId: generationID,
            streamUrl: "/api/v1/jobs/\(generationID.uuidString)/events?from_seq=0",
            status: status
        )
    }

    private func conversationExists(_ conversationID: UUID) async throws -> Bool {
        let config = try await loadBootstrap()
        let url = try restURL(config, path: "conversations", query: [
            "select": "id",
            "id": "eq.\(conversationID.uuidString)",
            "limit": "1",
        ])
        let request = try await authorizedRequest(url, config: config)
        struct ExistingConversation: Decodable { let id: UUID }
        let rows: [ExistingConversation] = try await send(request)
        return !rows.isEmpty
    }

    func eventStream(_ accepted: ChatEnqueueResponse) -> AsyncThrowingStream<JobEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await consumeEvents(accepted, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func consumeEvents(
        _ accepted: ChatEnqueueResponse,
        continuation: AsyncThrowingStream<JobEvent, Error>.Continuation
    ) async throws {
        var sequence = 0
        var retryNanoseconds: UInt64 = 250_000_000
        let deadline = Date().addingTimeInterval(20 * 60)

        while !Task.isCancelled && Date() < deadline {
            do {
                let terminal = try await consumeConnection(
                    path: accepted.streamUrl,
                    fromSequence: &sequence,
                    continuation: continuation
                )
                if terminal { return }
                retryNanoseconds = 250_000_000
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Date() >= deadline { throw error }
            }
            try await Task.sleep(nanoseconds: retryNanoseconds)
            retryNanoseconds = min(5_000_000_000, retryNanoseconds * 2)
        }
        if !Task.isCancelled { throw APIError.message("回复连接超时") }
    }

    private func consumeConnection(
        path: String,
        fromSequence sequence: inout Int,
        continuation: AsyncThrowingStream<JobEvent, Error>.Continuation
    ) async throws -> Bool {
        guard var components = URLComponents(
            url: URL(string: path, relativeTo: baseURL)?.absoluteURL ?? baseURL,
            resolvingAgainstBaseURL: false
        ) else { throw APIError.message("流式地址无效") }
        var query = components.queryItems ?? []
        query.removeAll { $0.name == "from_seq" }
        query.append(URLQueryItem(name: "from_seq", value: String(sequence)))
        components.queryItems = query
        guard let url = components.url else { throw APIError.message("流式地址无效") }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if sequence > 0 { request.setValue(String(sequence), forHTTPHeaderField: "Last-Event-ID") }
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.message("流式响应无效")
        }
        guard 200..<300 ~= http.statusCode else {
            throw APIError.message("流式连接失败（\(http.statusCode)）")
        }

        var dataLines: [String] = []
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if line.isEmpty {
                guard let event = try decodeEvent(dataLines) else {
                    dataLines.removeAll(keepingCapacity: true)
                    continue
                }
                dataLines.removeAll(keepingCapacity: true)
                guard event.seq > sequence else { continue }
                if event.seq != sequence + 1 { throw APIError.message("回复事件出现缺口，正在重连") }
                sequence = event.seq
                continuation.yield(event)
                if event.kind == "job.terminal" { return true }
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        return false
    }

    private func decodeEvent(_ lines: [String]) throws -> JobEvent? {
        guard !lines.isEmpty else { return nil }
        let raw = lines.joined(separator: "\n")
        guard raw != "[DONE]", let data = raw.data(using: .utf8) else { return nil }
        return try decoder.decode(JobEvent.self, from: data)
    }

    private func loadBootstrap() async throws -> MobileBootstrap {
        if let bootstrap { return bootstrap }
        let request = URLRequest(url: baseURL.appending(path: "api/mobile/config"))
        let value: MobileBootstrap = try await send(request)
        bootstrap = value
        return value
    }

    private func accessToken() async throws -> String {
        guard let current = session else { throw APIError.message("请先登录") }
        if let expiresAt = current.expiresAt, expiresAt <= Date().timeIntervalSince1970 + 60 {
            return try await refreshSession().accessToken
        }
        return current.accessToken
    }

    private func refreshSession() async throws -> AuthSession {
        guard let current = session else { throw APIError.message("登录已过期") }
        let config = try await loadBootstrap()
        var components = URLComponents(
            url: config.supabaseUrl.appending(path: "auth/v1/token"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(["refresh_token": current.refreshToken])
        let refreshed: AuthSession = try await send(request)
        try saveSession(refreshed)
        return refreshed
    }

    private func saveSession(_ value: AuthSession) throws {
        session = value
        try KeychainStore.save(value)
    }

    private func restURL(
        _ config: MobileBootstrap,
        path: String,
        query: [String: String]
    ) throws -> URL {
        var components = URLComponents(
            url: config.supabaseUrl.appending(path: "rest/v1/\(path)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = query.map(URLQueryItem.init(name:value:))
        guard let url = components.url else { throw APIError.message("请求地址无效") }
        return url
    }

    private func authorizedRequest(_ url: URL, config: MobileBootstrap) async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        return request
    }

    private func responseError(_ data: Data, response: HTTPURLResponse) -> APIError {
        let status = response.statusCode
        var message = "请求失败（\(status)）"
        var code: String?
        var requestID: String?
        var retryable = status == 408 || status == 425 || status == 429 || status >= 500

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? String {
                message = error
            } else if let value = object["msg"] as? String {
                message = value
            } else if let value = object["message"] as? String {
                message = value
            } else if let value = object["error_description"] as? String {
                message = value
            } else if let error = object["error"] as? [String: Any] {
                if let value = error["message"] as? String { message = value }
                if let value = error["code"] as? String { code = value }
                if let value = error["retryable"] as? Bool { retryable = value }
                if let value = error["request_id"] as? String { requestID = value }
            }
            if requestID == nil, let value = object["request_id"] as? String { requestID = value }
        }

        let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
            .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return APIError.response(
            message: message,
            statusCode: status,
            code: code,
            retryable: retryable,
            retryAfter: retryAfter,
            requestID: requestID
        )
    }

    private func enqueueRetryDelay(for error: Error, attempt: Int) -> UInt64? {
        let fallbackSeconds: [TimeInterval] = [1, 2, 5, 10, 20, 30]
        guard attempt < fallbackSeconds.count else { return nil }
        let fallback = fallbackSeconds[attempt]

        if let apiError = error as? APIError, apiError.isRetryable {
            let seconds = min(60, max(0.5, apiError.retryAfter ?? fallback))
            return UInt64(seconds * 1_000_000_000)
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                 .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable,
                 .internationalRoamingOff, .dataNotAllowed:
                return UInt64(fallback * 1_000_000_000)
            default:
                return nil
            }
        }
        return nil
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.message("网络响应无效")
        }
        guard 200..<300 ~= http.statusCode else {
            throw responseError(data, response: http)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.message("服务器响应格式无法识别")
        }
    }
}
