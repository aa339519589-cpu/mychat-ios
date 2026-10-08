import Foundation

struct ChatTurnConnection {
    let admission: ChatAdmission
    let events: AsyncThrowingStream<ChatJobEvent, Error>?
}

protocol ChatAPIServing {
    func openAppendTurn(_ command: ChatAppendCommand, accessToken: String) async throws -> ChatTurnConnection

    func generateConversationTitle(
        conversationID: UUID,
        userText: String,
        assistantText: String,
        endpointID: UUID?,
        accessToken: String
    ) async throws -> String

    func enqueueAppendTurn(
        _ command: ChatAppendCommand,
        accessToken: String
    ) async throws -> ChatAdmission

    func cancel(
        jobID: UUID,
        accessToken: String,
        reason: String?
    ) async throws -> ChatCancelResponse

    func admissionStatus(command: ChatAppendCommand, accessToken: String) async throws -> ChatAdmissionJobStatus?

    func terminalSnapshot(
        conversationID: UUID,
        jobID: UUID,
        accessToken: String
    ) async throws -> ChatTerminalSnapshot?

    func conversationGeneration(
        conversationID: UUID,
        accessToken: String
    ) async throws -> ChatGenerationRecovery?

    @MainActor func privateStreamRequest(
        command: ChatAppendCommand,
        messages: [ChatMessage]
    ) throws -> PrivateChatStreamRequest
}

extension ChatAPIServing {
    func admissionStatus(command: ChatAppendCommand, accessToken: String) async throws -> ChatAdmissionJobStatus? { nil }

    func openAppendTurn(_ command: ChatAppendCommand, accessToken: String) async throws -> ChatTurnConnection {
        ChatTurnConnection(admission: try await enqueueAppendTurn(command, accessToken: accessToken), events: nil)
    }

    func conversationGeneration(
        conversationID: UUID,
        accessToken: String
    ) async throws -> ChatGenerationRecovery? { nil }
}

struct ChatAdmissionJobStatus: Equatable, Sendable {
    let jobID: UUID
    let status: String
    var isTerminal: Bool { ChatTerminalStatus(rawValue: status) != nil }
}

struct ChatAPIClient: ChatAPIServing {
    private static let productionBaseURL = URL(string: "https://mychat-nm6x.onrender.com")!
    private static let activeGenerationRetryWindow: TimeInterval = 10 * 60

    private let session: URLSession
    private let baseURL: URL

    init(
        session: URLSession = .shared,
        baseURL: URL = Self.productionBaseURL
    ) {
        self.session = session
        self.baseURL = baseURL
    }

    func generateConversationTitle(
        conversationID: UUID,
        userText: String,
        assistantText: String,
        endpointID: UUID?,
        accessToken: String
    ) async throws -> String {
        try validateBaseURL()
        let token = try validatedAccessToken(accessToken)
        var body: [String: JSONValue] = [
            "conversationId": .string(conversationID.uuidString.lowercased()),
            "userText": .string(Self.titleSource(userText)),
            "assistantText": .string(Self.titleSource(assistantText))
        ]
        if let endpointID { body["endpointId"] = .string(endpointID.uuidString.lowercased()) }
        var request = authorizedRequest(url: baseURL.appendingPathComponent("api/chat/title"), accessToken: token)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatTransportError.invalidResponse }
        guard http.statusCode == 202 else { throw serverError(status: http.statusCode, data: data) }
        let admission = try JSONDecoder().decode([String: JSONValue].self, from: data)
        guard let rawJobID = admission["jobId"]?.stringValue, let jobID = UUID(uuidString: rawJobID) else {
            throw ChatTransportError.invalidResponse
        }
        // Title jobs have their own result, separate from the chat stream.
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            try Task.checkCancellation()
            var poll = authorizedRequest(
                url: baseURL.appendingPathComponent("api/v1/jobs").appendingPathComponent(jobID.uuidString.lowercased()),
                accessToken: token
            )
            poll.httpMethod = "GET"
            poll.timeoutInterval = 10
            let (snapshotData, snapshotResponse) = try await session.data(for: poll)
            guard let snapshotHTTP = snapshotResponse as? HTTPURLResponse else { throw ChatTransportError.invalidResponse }
            guard snapshotHTTP.statusCode == 200 else {
                throw serverError(status: snapshotHTTP.statusCode, data: snapshotData)
            }
            let snapshot = try JSONDecoder().decode([String: JSONValue].self, from: snapshotData)
            guard let job = snapshot["job"]?.objectValue,
                  job["id"]?.stringValue?.lowercased() == jobID.uuidString.lowercased() else {
                throw ChatTransportError.mismatchedJob
            }
            switch job["status"]?.stringValue {
            case "completed":
                guard let title = job["result"]?.objectValue?["title"]?.stringValue,
                      !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ChatTransportError.invalidResponse
                }
                return String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            case "failed", "cancelled":
                throw ChatTransportError.invalidRequest("自动命名暂时不可用")
            default:
                try await Task.sleep(for: .seconds(1))
            }
        }
        throw ChatTransportError.invalidRequest("自动命名超时")
    }

    private static func titleSource(_ text: String) -> String {
        var result = ""
        for character in text {
            let next = String(character)
            guard result.utf16.count + next.utf16.count <= 2_000 else { break }
            result += next
        }
        return result.isEmpty ? "附件对话" : result
    }

    func openAppendTurn(_ command: ChatAppendCommand, accessToken: String) async throws -> ChatTurnConnection {
        try validateBaseURL()
        try validate(command)
        let token = try validatedAccessToken(accessToken)
        var request = authorizedRequest(url: baseURL.appendingPathComponent("api/chat"), accessToken: token)
        request.httpMethod = "POST"
        request.timeoutInterval = 20 * 60
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.httpBody = try JSONEncoder().encode(AppendRequestBody(command: command))
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatTransportError.invalidResponse }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--live-api-probe") {
            NSLog("LIVE_NATIVE_HEADERS type=%@ encoding=%@ cache=%@", http.value(forHTTPHeaderField: "Content-Type") ?? "",
                http.value(forHTTPHeaderField: "Content-Encoding") ?? "none", http.value(forHTTPHeaderField: "Cache-Control") ?? "")
        }
        #endif
        if http.statusCode == 200 {
            guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true,
                  let rawID = http.value(forHTTPHeaderField: "X-MyChat-Job-Id"),
                  let jobID = UUID(uuidString: rawID), jobID == command.generationID,
                  let streamPath = http.value(forHTTPHeaderField: "X-MyChat-Stream-Url") else {
                bytes.task.cancel()
                throw ChatTransportError.mismatchedAdmission
            }
            let streamURL: URL
            do { streamURL = try resolvedStreamURL(streamPath) }
            catch { bytes.task.cancel(); throw error }
            let admission = ChatAdmission(schemaVersion: 1, jobID: jobID,
                generationID: command.generationID, userMessageID: command.userMessageID,
                assistantMessageID: command.assistantMessageID,
                status: http.value(forHTTPHeaderField: "X-MyChat-Job-Status") ?? "queued",
                created: http.value(forHTTPHeaderField: "X-MyChat-Job-Created") == "1",
                streamURL: streamURL,
                trialRemaining: http.value(forHTTPHeaderField: "X-MyChat-Trial-Remaining").flatMap(Int.init),
                trialLimit: http.value(forHTTPHeaderField: "X-MyChat-Trial-Limit").flatMap(Int.init))
            return ChatTurnConnection(admission: admission,
                events: JobEventStream(session: session, allowedOrigin: baseURL).admittedEvents(
                    bytes: bytes, admission: admission, accessToken: token))
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1024 * 1024 else { bytes.task.cancel(); throw ChatTransportError.invalidResponse }
            data.append(byte)
        }
        if http.statusCode == 202 {
            return ChatTurnConnection(admission: try decodeAdmission(data, command: command), events: nil)
        }
        // Reuse exactly the same generation and message IDs on a lock retry.
        if http.statusCode == 425, Self.isActiveGenerationConflict(data) {
            return ChatTurnConnection(admission: try await enqueueAppendTurn(command, accessToken: token), events: nil)
        }
        throw serverError(status: http.statusCode, data: data)
    }

    func enqueueAppendTurn(
        _ command: ChatAppendCommand,
        accessToken: String
    ) async throws -> ChatAdmission {
        try validateBaseURL()
        try validate(command)
        let token = try validatedAccessToken(accessToken)
        let endpoint = baseURL.appendingPathComponent("api/chat")
        var request = authorizedRequest(url: endpoint, accessToken: token)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.httpBody = try JSONEncoder().encode(AppendRequestBody(command: command))

        let retryDeadline = Date().addingTimeInterval(Self.activeGenerationRetryWindow)
        let data: Data
        while true {
            try Task.checkCancellation()
            let (responseData, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ChatTransportError.invalidResponse
            }
            if http.statusCode == 202 {
                data = responseData
                break
            }
            guard http.statusCode == 425,
                  Self.isActiveGenerationConflict(responseData),
                  Date() < retryDeadline else {
                throw serverError(status: http.statusCode, data: responseData)
            }

            // The API promises to accept this exact turn once the previous
            // generation releases its conversation lock. Keep the same
            // idempotency IDs and wait for that lock instead of surfacing a
            // false send failure to the user.
            let remaining = retryDeadline.timeIntervalSinceNow
            let requestedDelay = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "1") ?? 1
            let delay = min(max(requestedDelay.isFinite ? requestedDelay : 1, 0.05), min(5, remaining))
            try await Task.sleep(for: .seconds(delay))
        }

        return try decodeAdmission(data, command: command)
    }

    private func decodeAdmission(_ data: Data, command: ChatAppendCommand) throws -> ChatAdmission {
        let wire: AdmissionWire
        do {
            wire = try JSONDecoder().decode(AdmissionWire.self, from: data)
        } catch {
            throw ChatTransportError.invalidResponse
        }
        guard
            wire.schemaVersion == 1,
            let jobID = UUID(uuidString: wire.jobId),
            let generationID = UUID(uuidString: wire.generationId),
            let userMessageID = UUID(uuidString: wire.userMessageId),
            let assistantMessageID = UUID(uuidString: wire.assistantMessageId),
            generationID == command.generationID,
            userMessageID == command.userMessageID,
            assistantMessageID == command.assistantMessageID
        else {
            throw ChatTransportError.mismatchedAdmission
        }
        let streamURL = try resolvedStreamURL(wire.streamUrl)
        return ChatAdmission(
            schemaVersion: wire.schemaVersion,
            jobID: jobID,
            generationID: generationID,
            userMessageID: userMessageID,
            assistantMessageID: assistantMessageID,
            status: wire.status,
            created: wire.created,
            streamURL: streamURL,
            trialRemaining: wire.trialRemaining,
            trialLimit: wire.trialLimit
        )
    }

    func cancel(
        jobID: UUID,
        accessToken: String,
        reason: String? = nil
    ) async throws -> ChatCancelResponse {
        try validateBaseURL()
        let token = try validatedAccessToken(accessToken)
        if let reason, reason.utf16.count > 500 {
            throw ChatTransportError.invalidRequest("取消原因最多 500 字符")
        }
        let endpoint = baseURL
            .appendingPathComponent("api/v1/jobs")
            .appendingPathComponent(jobID.uuidString.lowercased())
            .appendingPathComponent("cancel")
        var request = authorizedRequest(url: endpoint, accessToken: token)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(CancelBody(reason: reason))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ChatTransportError.invalidResponse
        }
        guard http.statusCode == 200 || http.statusCode == 202 else {
            throw serverError(status: http.statusCode, data: data)
        }
        let wire: CancelWire
        do {
            wire = try JSONDecoder().decode(CancelWire.self, from: data)
        } catch {
            throw ChatTransportError.invalidResponse
        }
        guard let returnedJobID = UUID(uuidString: wire.jobId), returnedJobID == jobID else {
            throw ChatTransportError.mismatchedJob
        }
        return ChatCancelResponse(
            jobID: returnedJobID,
            accepted: wire.accepted,
            replayed: wire.replayed,
            status: wire.status,
            eventSequence: wire.eventSeq
        )
    }

    func admissionStatus(command: ChatAppendCommand, accessToken: String) async throws -> ChatAdmissionJobStatus? {
        try validateBaseURL()
        let token = try validatedAccessToken(accessToken)
        let endpoint = baseURL.appendingPathComponent("api/v1/jobs")
            .appendingPathComponent(command.generationID.uuidString.lowercased())
        var request = authorizedRequest(url: endpoint, accessToken: token)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatTransportError.invalidResponse }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw serverError(status: http.statusCode, data: data) }
        let envelope = try JSONDecoder().decode(GenerationStatusEnvelopeWire.self, from: data)
        guard envelope.degraded != true, let job = envelope.job,
              UUID(uuidString: job.id) == command.generationID,
              job.type == "chat.generation",
              job.queue == (command.outputKind == .chat ? "chat" : "media"),
              job.eventSequence >= 0,
              job.subject["conversationId"]?.stringValue.flatMap(UUID.init(uuidString:)) == command.conversationID,
              job.subject["userMessageId"]?.stringValue.flatMap(UUID.init(uuidString:)) == command.userMessageID,
              job.subject["assistantMessageId"]?.stringValue.flatMap(UUID.init(uuidString:)) == command.assistantMessageID
        else { throw ChatTransportError.mismatchedJob }
        // The authenticated endpoint filters by principal as well as this exact
        // ID. AppModel separately checks the mounted owner and account generation
        // again after this await; a latest-conversation job is not a substitute.
        return ChatAdmissionJobStatus(jobID: command.generationID, status: job.status)
    }

    func terminalSnapshot(
        conversationID: UUID,
        jobID: UUID,
        accessToken: String
    ) async throws -> ChatTerminalSnapshot? {
        try validateBaseURL()
        let token = try validatedAccessToken(accessToken)
        let endpoint = baseURL
            .appendingPathComponent("api/v1/conversations")
            .appendingPathComponent(conversationID.uuidString.lowercased())
            .appendingPathComponent("generation")
        var request = authorizedRequest(url: endpoint, accessToken: token)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ChatTransportError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw serverError(status: http.statusCode, data: data)
        }

        let envelope: GenerationStatusEnvelopeWire
        do {
            envelope = try JSONDecoder().decode(GenerationStatusEnvelopeWire.self, from: data)
        } catch {
            throw ChatTransportError.invalidResponse
        }
        guard
            let job = envelope.job,
            UUID(uuidString: job.id) == jobID,
            let status = ChatTerminalStatus(rawValue: job.status)
        else { return nil }

        return ChatTerminalSnapshot(
            status: status,
            content: job.result?.content ?? "",
            thinking: job.result?.thinking ?? "",
            sequence: job.eventSequence,
            errorCode: job.errorCode,
            media: job.result?.media ?? [],
            tokenUsage: job.result?.tokenUsage,
            codeReceipt: job.result?.codeReceipt
        )
    }

    func conversationGeneration(
        conversationID: UUID,
        accessToken: String
    ) async throws -> ChatGenerationRecovery? {
        try validateBaseURL()
        let token = try validatedAccessToken(accessToken)
        let endpoint = baseURL
            .appendingPathComponent("api/v1/conversations")
            .appendingPathComponent(conversationID.uuidString.lowercased())
            .appendingPathComponent("generation")
        var request = authorizedRequest(url: endpoint, accessToken: token)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ChatTransportError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw serverError(status: http.statusCode, data: data)
        }

        let envelope: GenerationStatusEnvelopeWire
        do {
            envelope = try JSONDecoder().decode(GenerationStatusEnvelopeWire.self, from: data)
        } catch {
            throw ChatTransportError.invalidResponse
        }
        if envelope.degraded == true {
            throw ChatTransportError.server(
                status: 503,
                code: "GENERATION_STATUS_UNAVAILABLE",
                message: "暂时无法恢复这条回复，请稍后重试",
                retryable: true,
                requestID: nil
            )
        }
        guard let job = envelope.job else { return nil }
        guard job.type == "chat.generation", job.queue == "chat",
              job.eventSequence >= 0,
              let rawConversationID = job.subject["conversationId"]?.stringValue,
              UUID(uuidString: rawConversationID) == conversationID,
              let userMessageID = job.subject["userMessageId"]?.stringValue.flatMap(UUID.init(uuidString:)),
              let assistantMessageID = job.subject["assistantMessageId"]?.stringValue.flatMap(UUID.init(uuidString:)),
              let jobID = UUID(uuidString: job.id),
              let streamValue = envelope.streamUrl else {
            throw ChatTransportError.invalidResponse
        }
        let streamURL = try resolvedStreamURL(streamValue)
        let admission = ChatAdmission(
            schemaVersion: 1,
            jobID: jobID,
            generationID: jobID,
            userMessageID: userMessageID,
            assistantMessageID: assistantMessageID,
            status: job.status,
            created: false,
            streamURL: streamURL,
            trialRemaining: nil,
            trialLimit: nil
        )

        let status = ChatTerminalStatus(rawValue: job.status)
        let terminal = status.map {
            ChatTerminalSnapshot(
                status: $0,
                content: job.result?.content ?? job.progress?.content ?? "",
                thinking: job.result?.thinking ?? job.progress?.thinking ?? "",
                sequence: job.eventSequence,
                errorCode: job.errorCode,
                media: job.result?.media ?? job.progress?.media ?? [],
                tokenUsage: job.result?.tokenUsage,
                codeReceipt: job.result?.codeReceipt
            )
        }
        return ChatGenerationRecovery(
            admission: admission,
            sequence: job.eventSequence,
            content: terminal?.content ?? job.progress?.content ?? job.result?.content ?? "",
            thinking: terminal?.thinking ?? job.progress?.thinking ?? job.result?.thinking ?? "",
            media: terminal?.media ?? job.progress?.media ?? job.result?.media ?? [],
            terminal: terminal
        )
    }

    func privateStreamRequest(
        command: ChatAppendCommand,
        messages: [ChatMessage]
    ) throws -> PrivateChatStreamRequest {
        try validateBaseURL()
        try validate(command)
        guard command.endpointID == nil else {
            throw ChatTransportError.invalidRequest("隐私聊天仅支持 MyChat 平台模型")
        }
        guard !messages.isEmpty else {
            throw ChatTransportError.invalidRequest("隐私聊天至少需要一条消息")
        }
        let endpoint = baseURL.appendingPathComponent("api/chat/private")
        guard sameOrigin(endpoint, baseURL), endpoint.scheme?.lowercased() == "https" else {
            throw ChatTransportError.unsafeStreamURL
        }
        return PrivateChatStreamRequest(
            endpoint: endpoint,
            body: try JSONEncoder().encode(PrivateRequestBody(command: command, messages: messages)),
            jobID: command.conversationID
        )
    }

    private func validate(_ command: ChatAppendCommand) throws {
        guard command.userMessage.role == .user else {
            throw ChatTransportError.invalidRequest("聊天准入只能上传最近一条用户消息")
        }
        guard command.userMessage.content.utf16.count <= 100_000 else {
            throw ChatTransportError.invalidRequest("单条消息过长")
        }
        if command.endpointID == nil {
            let modelID = command.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                !modelID.isEmpty,
                modelID.utf16.count <= 160,
                modelID.contains("/"),
                !modelID.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
            else {
                throw ChatTransportError.invalidRequest("模型标识无效")
            }
        }
        guard (1...200).contains(command.title.utf16.count) else {
            throw ChatTransportError.invalidRequest("会话标题必须为 1 到 200 字符")
        }
    }

    private func validatedAccessToken(_ value: String) throws -> String {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: { $0.isNewline }) else {
            throw ChatTransportError.missingAccessToken
        }
        return token
    }

    private func validateBaseURL() throws {
        guard
            baseURL.scheme?.lowercased() == "https",
            baseURL.host != nil,
            baseURL.user == nil,
            baseURL.password == nil
        else {
            throw ChatTransportError.invalidRequest("聊天服务地址无效")
        }
    }

    private func authorizedRequest(url: URL, accessToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("mychat-ios/1.0", forHTTPHeaderField: "X-Client-Info")
        return request
    }

    private func resolvedStreamURL(_ value: String) throws -> URL {
        guard let resolved = URL(string: value, relativeTo: baseURL)?.absoluteURL else {
            throw ChatTransportError.unsafeStreamURL
        }
        guard sameOrigin(resolved, baseURL), resolved.scheme?.lowercased() == "https" else {
            throw ChatTransportError.unsafeStreamURL
        }
        return resolved
    }

    private func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    private func serverError(status: Int, data: Data) -> ChatTransportError {
        if let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) {
            return .server(
                status: status,
                code: envelope.error.code,
                message: envelope.error.message,
                retryable: envelope.error.retryable,
                requestID: envelope.requestID
            )
        }
        let flat = try? JSONDecoder().decode(FlatError.self, from: data)
        return .server(
            status: status,
            code: nil,
            message: flat?.error ?? "聊天服务暂时不可用",
            retryable: status == 429 || status >= 500,
            requestID: nil
        )
    }

    private static func isActiveGenerationConflict(_ data: Data) -> Bool {
        guard let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) else { return false }
        return envelope.error.code == "CONFLICT"
            && envelope.error.retryable
            && envelope.error.details?["conflictKind"]?.stringValue == "active_chat_generation"
    }
}

private struct AppendRequestBody: Encodable {
    let healthContext: String?
    let modelId: String?
    let endpointId: String?
    let reasoningEffort: ChatReasoningEffort?
    let messages: [UserMessageBody]
    let searchMode: ChatSearchMode
    let historyRetrieval: Bool
    let connectorAccessMode: ChatConnectorAccessMode
    let connectorIds: [String]?
    let renderEnabled: Bool
    let renderProfile = "native-v1"
    let attachments: [ChatFileAttachment]?
    let conversationId: String
    let userMessageId: String
    let generationId: String
    let assistantMessageId: String
    let generateImage: Bool
    let generateVideo: Bool
    let turn: AppendTurnBody

    init(command: ChatAppendCommand) {
        healthContext = command.healthContext
        modelId = command.endpointID == nil
            ? command.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        endpointId = command.endpointID?.uuidString.lowercased()
        reasoningEffort = command.reasoningEffort
        messages = [UserMessageBody(message: command.userMessage)]
        searchMode = command.tools.searchMode
        historyRetrieval = command.tools.historyRetrieval
        connectorAccessMode = command.tools.connectorAccessMode
        connectorIds = command.tools.connectorIDs?.map { $0.lowercased() }.sorted()
        renderEnabled = command.tools.renderEnabled
        attachments = command.attachments.isEmpty ? nil : command.attachments
        conversationId = command.conversationID.uuidString.lowercased()
        userMessageId = command.userMessageID.uuidString.lowercased()
        generationId = command.generationID.uuidString.lowercased()
        assistantMessageId = command.assistantMessageID.uuidString.lowercased()
        generateImage = command.outputKind == .image
        generateVideo = command.outputKind == .video
        turn = AppendTurnBody(command: command)
    }
}

private struct PrivateRequestBody: Encodable {
    let modelId: String
    let reasoningEffort: ChatReasoningEffort?
    let messages: [PrivateMessageBody]
    let searchMode: ChatSearchMode
    let historyRetrieval = false
    let renderEnabled: Bool
    let renderProfile = "native-v1"
    /// Ephemeral SSE identity only. The private endpoint never stores it.
    let conversationId: String

    init(command: ChatAppendCommand, messages: [ChatMessage]) {
        modelId = command.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        reasoningEffort = command.reasoningEffort
        self.messages = messages.map(PrivateMessageBody.init)
        searchMode = command.tools.searchMode
        renderEnabled = command.tools.renderEnabled
        conversationId = command.conversationID.uuidString.lowercased()
    }
}

private struct PrivateMessageBody: Encodable {
    let role: String
    let content: String
    let images: [String]?
    let ts: String

    init(message: ChatMessage) {
        role = message.role.rawValue
        content = message.content
        images = message.sourceImages?.isEmpty == false ? message.sourceImages : nil
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        ts = formatter.string(from: message.createdAt)
    }
}

private struct UserMessageBody: Encodable {
    let id: String
    let role = "user"
    let content: String
    let images: [String]?
    let ts: String

    init(message: ChatMessage) {
        id = message.id.uuidString.lowercased()
        content = message.content
        images = message.sourceImages?.isEmpty == false ? message.sourceImages : nil
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        ts = formatter.string(from: message.createdAt)
    }
}

private struct AppendTurnBody: Encodable {
    let schemaVersion = 1
    let createConversation: Bool
    let title: String
    let projectID: UUID?
    let memoryEnabled: Bool
    let regeneration: ChatRegeneration?

    init(command: ChatAppendCommand) {
        createConversation = command.createConversation
        title = command.title
        projectID = command.projectID
        memoryEnabled = command.conversationMemoryEnabled
        regeneration = command.regeneration
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case createConversation
        case title
        case projectId
        case memoryEnabled
        case operation
        case expectedTailMessageId
        case targetAssistantMessageId
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let regeneration {
            try container.encode(2, forKey: .schemaVersion)
            try container.encode(regeneration.operation, forKey: .operation)
            try container.encode(regeneration.expectedTailMessageID.uuidString.lowercased(), forKey: .expectedTailMessageId)
            if let target = regeneration.targetAssistantMessageID {
                try container.encode(target.uuidString.lowercased(), forKey: .targetAssistantMessageId)
            }
            return
        }
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(createConversation, forKey: .createConversation)
        try container.encode(title, forKey: .title)
        try container.encode(memoryEnabled, forKey: .memoryEnabled)
        if let projectID {
            try container.encode(projectID.uuidString.lowercased(), forKey: .projectId)
        } else {
            try container.encodeNil(forKey: .projectId)
        }
    }
}

private struct AdmissionWire: Decodable {
    let schemaVersion: Int
    let jobId: String
    let generationId: String
    let userMessageId: String
    let assistantMessageId: String
    let status: String
    let created: Bool
    let streamUrl: String
    let trialRemaining: Int?
    let trialLimit: Int?
}

private struct CancelBody: Encodable {
    let reason: String?
}

private struct CancelWire: Decodable {
    let jobId: String
    let accepted: Bool
    let replayed: Bool
    let status: String
    let eventSeq: Int?
}

private struct GenerationStatusEnvelopeWire: Decodable {
    let job: GenerationJobWire?
    let streamUrl: String?
    let degraded: Bool?
}

private struct GenerationJobWire: Decodable {
    let id: String
    let type: String
    let queue: String
    let subject: [String: JSONValue]
    let status: String
    let progress: GenerationResultWire?
    let result: GenerationResultWire?
    let errorCode: String?
    let eventSequence: Int

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case queue
        case subject
        case status
        case progress
        case result
        case errorCode
        case eventSequence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        queue = try container.decode(String.self, forKey: .queue)
        subject = try container.decode([String: JSONValue].self, forKey: .subject)
        status = try container.decode(String.self, forKey: .status)
        progress = try? container.decode(GenerationResultWire.self, forKey: .progress)
        result = try? container.decode(GenerationResultWire.self, forKey: .result)
        errorCode = try? container.decode(String.self, forKey: .errorCode)
        eventSequence = try container.decode(Int.self, forKey: .eventSequence)
    }
}

private struct GenerationResultWire: Decodable {
    let content: String?
    let thinking: String?
    let media: [ChatGeneratedMedia]?
    let tokenUsage: ChatTokenUsage?
    let codeReceipt: CodeOperationReceipt?

    private enum CodingKeys: String, CodingKey {
        case content
        case thinking
        case media
        case tokenUsage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = try? container.decode(String.self, forKey: .content)
        thinking = try? container.decode(String.self, forKey: .thinking)
        media = try? container.decode([ChatGeneratedMedia].self, forKey: .media)
        tokenUsage = try? container.decode(ChatTokenUsage.self, forKey: .tokenUsage)
        codeReceipt = try? CodeOperationReceipt(from: decoder)
    }
}

private struct APIErrorEnvelope: Decodable {
    struct Failure: Decodable {
        let code: String
        let message: String
        let retryable: Bool
        let details: [String: JSONValue]?
    }

    let error: Failure
    let requestID: String?

    enum CodingKeys: String, CodingKey {
        case error
        case requestID = "request_id"
    }
}

private struct FlatError: Decodable {
    let error: String
}

struct CloudTTSClient {
    private let session: URLSession
    private let baseURL: URL

    init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://mychat-nm6x.onrender.com")!
    ) {
        self.session = session
        self.baseURL = baseURL
    }

    func streamingRequest(text: String, accessToken: String) throws -> URLRequest {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudTTSError.invalidRequest
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/tts"))
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/pcm", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONEncoder().encode(CloudTTSRequest(text: text))
        return request
    }
}

private struct CloudTTSRequest: Encodable {
    let text: String
    let format = "pcm"
    enum CodingKeys: String, CodingKey { case text, format }
}
private enum CloudTTSError: Error { case invalidRequest }
