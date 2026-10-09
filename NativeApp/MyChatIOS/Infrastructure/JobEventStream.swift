import Foundation

protocol ChatEventStreaming {
    @MainActor func privateEvents(request: PrivateChatStreamRequest, accessToken: String) -> AsyncThrowingStream<ChatJobEvent, Error>
    @MainActor func events(admission: ChatAdmission, accessToken: String, fromSequence: Int) -> AsyncThrowingStream<ChatJobEvent, Error>
}

@MainActor extension ChatEventStreaming {
    func privateEvents(request: PrivateChatStreamRequest, accessToken: String) -> AsyncThrowingStream<ChatJobEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: ChatTransportError.invalidRequest("私密聊天流暂时不可用")) }
    }

    func events(admission: CodeAdmission, accessToken: String) -> AsyncThrowingStream<ChatJobEvent, Error> {
        events(admission: ChatAdmission(schemaVersion: admission.schemaVersion, jobID: admission.jobID,
            generationID: admission.jobID, userMessageID: admission.taskID,
            assistantMessageID: admission.responseID ?? admission.taskID, status: admission.status,
            created: admission.created, streamURL: admission.streamURL,
            trialRemaining: admission.trialRemaining, trialLimit: admission.trialLimit), accessToken: accessToken)
    }

    func events(admission: ChatAdmission, accessToken: String) -> AsyncThrowingStream<ChatJobEvent, Error> {
        events(admission: admission, accessToken: accessToken, fromSequence: 0)
    }
}

struct JobEventStream: ChatEventStreaming {
    private static let productionOrigin = URL(string: "https://mychat-nm6x.onrender.com")!

    private let session: URLSession
    private let allowedOrigin: URL
    private let maximumDuration: TimeInterval

    init(
        session: URLSession = .shared,
        allowedOrigin: URL = Self.productionOrigin,
        maximumDuration: TimeInterval = 20 * 60
    ) {
        self.session = session
        self.allowedOrigin = allowedOrigin
        self.maximumDuration = maximumDuration
    }

    /// Opens the durable GET stream. Unknown event kinds still advance the
    /// sequence cursor; duplicate replay is ignored and any forward gap fails.
    func events(
        admission: ChatAdmission,
        accessToken: String,
        fromSequence: Int = 0
    ) -> AsyncThrowingStream<ChatJobEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await consume(
                        admission: admission,
                        accessToken: accessToken,
                        fromSequence: fromSequence,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Continue the admission POST immediately, with durable GET replay only
    /// when that connection closes. No second authentication round trip.
    func admittedEvents(bytes: URLSession.AsyncBytes, admission: ChatAdmission,
                        accessToken: String) -> AsyncThrowingStream<ChatJobEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                defer { bytes.task.cancel() }
                do {
                    let state = StreamState(sequence: 0)
                    do {
                        if try await consumeBytes(bytes, admission: admission, state: state, continuation: continuation) {
                            continuation.finish(); return
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch let error as ChatTransportError where !error.isRetryable { throw error }
                    catch { try Task.checkCancellation() }
                    try await consume(admission: admission, accessToken: accessToken,
                        fromSequence: state.sequence, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError { continuation.finish() }
                catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in bytes.task.cancel(); task.cancel() }
        }
    }

    @MainActor func events(
        admission: CodeAdmission,
        accessToken: String,
        fromSequence: Int = 0
    ) -> AsyncThrowingStream<ChatJobEvent, Error> {
        let responseID = admission.responseID ?? admission.taskID
        return events(
            admission: ChatAdmission(
                schemaVersion: admission.schemaVersion,
                jobID: admission.jobID,
                generationID: admission.jobID,
                userMessageID: admission.taskID,
                assistantMessageID: responseID,
                status: admission.status,
                created: admission.created,
                streamURL: admission.streamURL,
                trialRemaining: admission.trialRemaining,
                trialLimit: admission.trialLimit
            ),
            accessToken: accessToken,
            fromSequence: fromSequence
        )
    }

    /// Privacy conversations are one-shot POST SSE responses rather than
    /// durable jobs. They deliberately do not reconnect: a retry would create
    /// a second model turn and violate the one-request privacy contract.
    func privateEvents(
        request: PrivateChatStreamRequest,
        accessToken: String
    ) -> AsyncThrowingStream<ChatJobEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await consumePrivate(
                        request: request,
                        accessToken: accessToken,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func consume(
        admission: ChatAdmission,
        accessToken: String,
        fromSequence: Int,
        continuation: AsyncThrowingStream<ChatJobEvent, Error>.Continuation
    ) async throws {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: { $0.isNewline }) else {
            throw ChatTransportError.missingAccessToken
        }
        guard fromSequence >= 0 else {
            throw ChatTransportError.invalidRequest("fromSequence 不能小于 0")
        }
        guard isAllowed(admission.streamURL) else {
            throw ChatTransportError.unsafeStreamURL
        }

        let state = StreamState(sequence: fromSequence)
        let deadline = Date().addingTimeInterval(maximumDuration)
        var retryNanoseconds: UInt64 = 250_000_000

        while !Task.isCancelled, Date() < deadline {
            do {
                let terminal = try await consumeConnection(
                    admission: admission,
                    accessToken: token,
                    state: state,
                    continuation: continuation
                )
                if terminal { return }
                retryNanoseconds = 250_000_000
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ChatTransportError {
                guard error.isRetryable else { throw error }
            } catch {
                // URLSession transport failures are retried from the last
                // accepted sequence; protocol/decoding failures use explicit
                // ChatTransportError cases and fail above.
            }

            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: retryNanoseconds)
            retryNanoseconds = min(5_000_000_000, retryNanoseconds * 2)
        }
        try Task.checkCancellation()
        throw ChatTransportError.streamTimedOut
    }

    private func consumePrivate(
        request privateRequest: PrivateChatStreamRequest,
        accessToken: String,
        continuation: AsyncThrowingStream<ChatJobEvent, Error>.Continuation
    ) async throws {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: { $0.isNewline }) else {
            throw ChatTransportError.missingAccessToken
        }
        guard isAllowed(privateRequest.endpoint) else {
            throw ChatTransportError.unsafeStreamURL
        }

        var request = URLRequest(url: privateRequest.endpoint)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = maximumDuration
        request.httpBody = privateRequest.body
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("mychat-ios/1.0", forHTTPHeaderField: "X-Client-Info")

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ChatTransportError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw serverError(status: http.statusCode, data: try await boundedData(from: bytes))
        }
        guard http.value(forHTTPHeaderField: "Content-Type")?
            .lowercased().contains("text/event-stream") == true
        else {
            throw ChatTransportError.invalidResponse
        }

        let state = StreamState(sequence: 0)
        var parser = SSEByteParser()
        for try await byte in bytes {
            guard let frame = try parser.consume(byte: byte) else { continue }
            try Task.checkCancellation()
            if try process(
                frame: frame,
                expectedJobID: privateRequest.jobID,
                state: state,
                continuation: continuation
            ) {
                return
            }
        }
        if let frame = try parser.finish(), try process(
            frame: frame,
            expectedJobID: privateRequest.jobID,
            state: state,
            continuation: continuation
        ) {
            return
        }
        throw ChatTransportError.invalidResponse
    }

    private func consumeConnection(
        admission: ChatAdmission,
        accessToken: String,
        state: StreamState,
        continuation: AsyncThrowingStream<ChatJobEvent, Error>.Continuation
    ) async throws -> Bool {
        var request = URLRequest(url: try streamURL(admission.streamURL, fromSequence: state.sequence))
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = maximumDuration
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("mychat-ios/1.0", forHTTPHeaderField: "X-Client-Info")
        if state.sequence > 0 {
            request.setValue(String(state.sequence), forHTTPHeaderField: "Last-Event-ID")
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ChatTransportError.invalidResponse
        }
        guard http.statusCode == 200 else {
            let body = try await boundedData(from: bytes)
            throw serverError(status: http.statusCode, data: body)
        }
        guard http.value(forHTTPHeaderField: "Content-Type")?
            .lowercased().contains("text/event-stream") == true
        else {
            throw ChatTransportError.invalidResponse
        }

        return try await consumeBytes(bytes, admission: admission, state: state, continuation: continuation)
    }

    private func consumeBytes(_ bytes: URLSession.AsyncBytes, admission: ChatAdmission,
                              state: StreamState,
                              continuation: AsyncThrowingStream<ChatJobEvent, Error>.Continuation) async throws -> Bool {
        var parser = SSEByteParser()
        for try await byte in bytes {
            guard let frame = try parser.consume(byte: byte) else { continue }
            try Task.checkCancellation()
            if try process(
                frame: frame,
                expectedJobID: admission.jobID,
                state: state,
                continuation: continuation
            ) {
                return true
            }
        }
        if let frame = try parser.finish(), try process(
            frame: frame,
            expectedJobID: admission.jobID,
            state: state,
            continuation: continuation
        ) {
            return true
        }
        return false
    }

    private func process(
        frame: SSEFrame,
        expectedJobID: UUID,
        state: StreamState,
        continuation: AsyncThrowingStream<ChatJobEvent, Error>.Continuation
    ) throws -> Bool {
        if frame.event == "done" || frame.data.isEmpty { return false }
        guard let data = frame.data.data(using: .utf8) else {
            throw fail(.malformedEnvelope(frame.event ?? "unknown"), frame: frame)
        }
        guard let header = try? JSONDecoder().decode(EventHeader.self, from: data) else {
            if let failure = try? JSONDecoder().decode(StreamFailure.self, from: data) {
                throw ChatTransportError.server(
                    status: 503,
                    code: failure.code,
                    message: failure.message ?? failure.code,
                    retryable: failure.retryable,
                    requestID: nil
                )
            }
            throw fail(.malformedEnvelope(frame.event ?? "unknown"), frame: frame, data: data)
        }
        guard let jobID = UUID(uuidString: header.jobId), jobID == expectedJobID else {
            throw ChatTransportError.mismatchedJob
        }
        if let eventName = frame.event, !eventName.isEmpty, eventName != header.kind {
            throw fail(
                .eventKindMismatch(event: eventName, envelope: header.kind),
                frame: frame,
                data: data,
                header: header
            )
        }
        if let identifier = frame.id {
            guard let eventSequence = Int(identifier), eventSequence == header.seq else {
                throw fail(
                    .eventSequenceMismatch(identifier: identifier, envelope: header.seq),
                    frame: frame,
                    data: data,
                    header: header
                )
            }
        }
        if header.seq <= state.sequence {
            return false
        }
        let expectedSequence = state.sequence + 1
        guard header.seq == expectedSequence else {
            throw ChatTransportError.sequenceGap(expected: expectedSequence, actual: header.seq)
        }
        state.sequence = header.seq
        if !state.recordedFirstEnvelope {
            state.recordedFirstEnvelope = true
            let receivedAt = ProcessInfo.processInfo.systemUptime
            Task { @MainActor in ChatGenerationDiagnostics.mark(jobID, stage: .firstEvent, receivedAt: receivedAt) }
        }

        switch header.kind {
        case "text.delta":
            let payload: TextPayload = try payload(from: data, kind: header.kind)
            state.content += payload.text
            continuation.yield(ChatJobEvent(
                jobID: jobID,
                sequence: header.seq,
                payload: .textDelta(payload.text)
            ))
        case "thinking.delta":
            let payload: ThinkingPayload = try payload(from: data, kind: header.kind)
            state.thinking += payload.thinking
            continuation.yield(ChatJobEvent(
                jobID: jobID,
                sequence: header.seq,
                payload: .thinkingDelta(payload.thinking)
            ))
        case "reasoning.summary.delta":
            let payload: ReasoningSummaryPayload = try payload(from: data, kind: header.kind)
            state.reasoningSummary += payload.reasoningSummary
            continuation.yield(ChatJobEvent(jobID: jobID, sequence: header.seq,
                payload: .reasoningSummaryDelta(payload.reasoningSummary)))
        case "tool.search":
            let payload: ToolSearchPayload = try payload(from: data, kind: header.kind)
            continuation.yield(ChatJobEvent(
                jobID: jobID,
                sequence: header.seq,
                payload: .toolSearch(payload.search)
            ))
        case "tool.memory":
            let payload: MemoryChangePayload = try payload(from: data, kind: header.kind)
            continuation.yield(ChatJobEvent(
                jobID: jobID,
                sequence: header.seq,
                payload: .memoryChange(payload.memory)
            ))
        case "connector.app":
            let payload: ConnectorAppEventPayload = try payload(from: data, kind: header.kind)
            continuation.yield(ChatJobEvent(
                jobID: jobID,
                sequence: header.seq,
                payload: .connectorApp(ChatConnectorAppEvent(
                    id: "\(jobID.uuidString.lowercased()):\(header.seq)",
                    payload: payload.connectorApp
                ))
            ))
        case "tool.requested", "tool.completed":
            let payload: ToolActivityPayload = try payload(from: data, kind: header.kind)
            continuation.yield(ChatJobEvent(
                jobID: jobID,
                sequence: header.seq,
                payload: .toolActivity(ChatToolActivity(
                    toolCallID: payload.toolCallId,
                    toolName: payload.toolName,
                    isComplete: header.kind == "tool.completed"
                ))
            ))
        case "agent.step":
            let payload: AgentStepPayload = try payload(from: data, kind: header.kind)
            continuation.yield(ChatJobEvent(
                jobID: jobID,
                sequence: header.seq,
                payload: .agentStep(payload.step)
            ))
        case "agent.plan":
            let payload: AgentPlanPayload = try payload(from: data, kind: header.kind)
            continuation.yield(ChatJobEvent(
                jobID: jobID,
                sequence: header.seq,
                payload: .agentPlan(payload.plan)
            ))
        case "model.output_completed":
            continuation.yield(ChatJobEvent(
                jobID: jobID,
                sequence: header.seq,
                payload: .modelOutputCompleted
            ))
        case "job.snapshot":
            let payload: SnapshotPayload = try payload(from: data, kind: header.kind)
            if let content = payload.content { state.content = content }
            if let thinking = payload.thinking { state.thinking = thinking }
            if let summary = payload.reasoningSummary { state.reasoningSummary = summary }
            if let media = payload.media { state.media = media }
            let snapshot = ChatJobSnapshot(
                content: state.content,
                thinking: ChatReasoningSummaryStorage.encode(state.reasoningSummary) ?? state.thinking,
                media: state.media
            )
            continuation.yield(ChatJobEvent(
                jobID: jobID,
                sequence: header.seq,
                payload: .snapshot(snapshot)
            ))
        case "job.terminal":
            let inspection = JSONInspection(data: data)
            guard let statusValue = inspection.statusValue else {
                let error: ChatTransportError = inspection.statusType == nil
                    ? .terminalStatusMissing
                    : .terminalStatusType(inspection.statusType ?? "unknown")
                throw fail(error, frame: frame, data: data, header: header)
            }
            guard let status = ChatTerminalStatus(rawValue: statusValue) else {
                throw fail(
                    .terminalStatusValue(statusValue),
                    frame: frame,
                    data: data,
                    header: header
                )
            }
            let payload: TerminalPayload
            do {
                payload = try JSONDecoder().decode(Envelope<TerminalPayload>.self, from: data).payload
            } catch {
                throw fail(.malformedEnvelope(header.kind), frame: frame, data: data, header: header)
            }
            let terminal = ChatTerminalSnapshot(
                status: status,
                content: payload.result?.content ?? state.content,
                thinking: payload.result?.reasoningSummary.flatMap(ChatReasoningSummaryStorage.encode)
                    ?? payload.result?.thinking ?? state.thinking,
                sequence: header.seq,
                errorCode: payload.errorCode,
                media: payload.result?.media ?? state.media,
                tokenUsage: payload.result?.tokenUsage,
                codeReceipt: payload.result?.codeReceipt
            )
            state.content = terminal.content
            state.thinking = terminal.thinking
            state.media = terminal.media
            continuation.yield(ChatJobEvent(
                jobID: jobID,
                sequence: header.seq,
                payload: .terminal(terminal)
            ))
            return true
        case "job.retry_scheduled":
            state.resetOutput()
        case "job.leased":
            let attempt = (try? JSONDecoder().decode(Envelope<LeasePayload>.self, from: data))?.payload.attempt
            if let attempt, attempt > 1 { state.resetOutput() }
        default:
            break
        }
        return false
    }

    private func payload<Value: Decodable>(from data: Data, kind: String) throws -> Value {
        do {
            return try JSONDecoder().decode(Envelope<Value>.self, from: data).payload
        } catch {
            throw ChatTransportError.malformedEnvelope(kind)
        }
    }

    private func fail(
        _ error: ChatTransportError,
        frame: SSEFrame,
        data: Data? = nil,
        header: EventHeader? = nil
    ) -> ChatTransportError {
        let diagnostic = SSEDiagnostic(
            error: error.errorDescription ?? "SSE 协议错误",
            frame: frame,
            header: header,
            inspection: data.map(JSONInspection.init(data:))
        )
        diagnostic.persist()
        return error
    }

    private func streamURL(_ url: URL, fromSequence: Int) throws -> URL {
        guard isAllowed(url), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ChatTransportError.unsafeStreamURL
        }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "from_seq" }
        items.append(URLQueryItem(name: "from_seq", value: String(fromSequence)))
        components.queryItems = items
        guard let result = components.url, isAllowed(result) else {
            throw ChatTransportError.unsafeStreamURL
        }
        return result
    }

    private func isAllowed(_ url: URL) -> Bool {
        url.scheme?.lowercased() == allowedOrigin.scheme?.lowercased()
            && url.host?.lowercased() == allowedOrigin.host?.lowercased()
            && effectivePort(url) == effectivePort(allowedOrigin)
            && url.user == nil
            && url.password == nil
    }

    private func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    private func boundedData(from bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            if data.count >= 64 * 1_024 { break }
            data.append(byte)
        }
        return data
    }

    private func serverError(status: Int, data: Data) -> ChatTransportError {
        if let envelope = try? JSONDecoder().decode(StreamAPIErrorEnvelope.self, from: data) {
            return .server(
                status: status,
                code: envelope.error.code,
                message: envelope.error.message,
                retryable: envelope.error.retryable,
                requestID: envelope.requestID
            )
        }
        let flat = try? JSONDecoder().decode(StreamFlatError.self, from: data)
        return .server(
            status: status,
            code: nil,
            message: flat?.error ?? "聊天事件流暂时不可用",
            retryable: status == 429 || status >= 500,
            requestID: nil
        )
    }
}

private final class StreamState {
    var recordedFirstEnvelope = false
    var sequence: Int
    var content = ""
    var thinking = ""
    var reasoningSummary = ""
    var media: [ChatGeneratedMedia] = []

    init(sequence: Int) {
        self.sequence = sequence
    }

    func resetOutput() {
        content = ""
        thinking = ""
        media = []
    }
}

struct SSEFrame {
    let id: String?
    let event: String?
    let data: String
}

/// Decode complete UTF-8 lines ourselves: AsyncBytes.lines can omit the
/// empty SSE delimiter, leaving the final event pending until another event.
struct SSEByteParser {
    private var bytes: [UInt8] = []
    private var parser = SSEParser()
    private var firstLine = true
    private var previousWasCR = false

    mutating func consume(byte: UInt8) throws -> SSEFrame? {
        if previousWasCR, byte == 10 { previousWasCR = false; return nil }
        previousWasCR = byte == 13
        if byte == 10 || byte == 13 { return try consumeBufferedLine() }
        guard bytes.count < 16 * 1_024 * 1_024 else {
            throw ChatTransportError.malformedEnvelope("SSE 单行内容超过限制")
        }
        bytes.append(byte)
        return nil
    }
    mutating func finish() throws -> SSEFrame? {
        if !bytes.isEmpty, let frame = try consumeBufferedLine() { return frame }
        return parser.finish()
    }
    private mutating func consumeBufferedLine() throws -> SSEFrame? {
        guard var line = String(bytes: bytes, encoding: .utf8) else {
            throw ChatTransportError.malformedEnvelope("SSE UTF-8")
        }
        bytes.removeAll(keepingCapacity: true)
        if firstLine { firstLine = false; if line.first == "\u{FEFF}" { line.removeFirst() } }
        return parser.consume(line: line)
    }
}

private struct SSEParser {
    private var id: String?
    private var event: String?
    private var dataLines: [String] = []

    mutating func consume(line rawLine: String) -> SSEFrame? {
        let line = rawLine.last == "\r" ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty {
            return emit()
        }
        if line.hasPrefix(":") { return nil }

        let field: String
        var value: String
        if let separator = line.firstIndex(of: ":") {
            field = String(line[..<separator])
            value = String(line[line.index(after: separator)...])
            if value.first == " " { value.removeFirst() }
        } else {
            field = line
            value = ""
        }

        switch field {
        case "id":
            // Tolerate older replay records that lack an empty separator.
            let pending = dataLines.isEmpty ? nil : emit()
            if !value.contains("\0") { id = value }
            return pending
        case "event":
            event = value
        case "data":
            dataLines.append(value)
        default:
            break
        }
        return nil
    }

    mutating func finish() -> SSEFrame? {
        emit()
    }

    private mutating func emit() -> SSEFrame? {
        defer {
            id = nil
            event = nil
            dataLines.removeAll(keepingCapacity: true)
        }
        guard !dataLines.isEmpty else { return nil }
        return SSEFrame(id: id, event: event, data: dataLines.joined(separator: "\n"))
    }
}

private struct EventHeader: Decodable {
    let jobId: String
    let seq: Int
    let kind: String
}

private struct Envelope<Payload: Decodable>: Decodable {
    let payload: Payload
}

private struct TextPayload: Decodable {
    let text: String
}

private struct ThinkingPayload: Decodable {
    let thinking: String
}

private struct ReasoningSummaryPayload: Decodable {
    let reasoningSummary: String
}

private struct ToolSearchPayload: Decodable {
    let search: ChatToolSearch
}

private struct MemoryChangePayload: Decodable {
    let memory: ChatMemoryEvent
}

private struct ConnectorAppEventPayload: Decodable {
    let connectorApp: ChatConnectorAppPayload
}

private struct ToolActivityPayload: Decodable {
    let toolCallId: String
    let toolName: String
}

private struct AgentStepPayload: Decodable {
    let step: CodeAgentStep
}

private struct AgentPlanPayload: Decodable {
    let plan: CodePlanAction
}

private struct SnapshotPayload: Decodable {
    let content: String?
    let thinking: String?
    let reasoningSummary: String?
    let media: [ChatGeneratedMedia]?
}

private struct TerminalPayload: Decodable {
    struct Result: Decodable {
        let content: String?
        let thinking: String?
        let reasoningSummary: String?
        let media: [ChatGeneratedMedia]?
        let tokenUsage: ChatTokenUsage?
        let codeReceipt: CodeOperationReceipt?

        private enum CodingKeys: String, CodingKey {
            case content
            case thinking
            case reasoningSummary
            case media
            case tokenUsage
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // The Web consumer treats every result field independently: an
            // optional extension must not invalidate the authoritative status.
            content = try? container.decode(String.self, forKey: .content)
            thinking = try? container.decode(String.self, forKey: .thinking)
            reasoningSummary = try? container.decode(String.self, forKey: .reasoningSummary)
            media = try? container.decode([ChatGeneratedMedia].self, forKey: .media)
            tokenUsage = try? container.decode(ChatTokenUsage.self, forKey: .tokenUsage)
            codeReceipt = try? CodeOperationReceipt(from: decoder)
        }
    }

    let status: String
    let result: Result?
    let errorCode: String?

    private enum CodingKeys: String, CodingKey {
        case status
        case result
        case errorCode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        result = try? container.decode(Result.self, forKey: .result)
        errorCode = try? container.decode(String.self, forKey: .errorCode)
    }
}

private struct LeasePayload: Decodable {
    let attempt: Int?
}

private struct StreamFailure: Decodable {
    let code: String
    let message: String?
    let retryable: Bool
}

private struct StreamAPIErrorEnvelope: Decodable {
    struct Failure: Decodable {
        let code: String
        let message: String
        let retryable: Bool
    }

    let error: Failure
    let requestID: String?

    enum CodingKeys: String, CodingKey {
        case error
        case requestID = "request_id"
    }
}

private struct StreamFlatError: Decodable {
    let error: String
}

private struct JSONInspection {
    let headerKeys: [String]
    let headerTypes: [String: String]
    let payloadKeys: [String]
    let payloadTypes: [String: String]
    let resultKeys: [String]
    let resultTypes: [String: String]
    let statusType: String?
    let statusValue: String?

    init(data: Data) {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let payload = root?["payload"] as? [String: Any]
        let result = payload?["result"] as? [String: Any]
        let header = root?.filter { $0.key != "payload" } ?? [:]

        headerKeys = header.keys.sorted()
        headerTypes = Self.types(in: header)
        payloadKeys = payload?.keys.sorted() ?? []
        payloadTypes = Self.types(in: payload ?? [:])
        resultKeys = result?.keys.sorted() ?? []
        resultTypes = Self.types(in: result ?? [:])
        if let status = payload?["status"] {
            statusType = Self.jsonType(status)
            statusValue = status as? String
        } else {
            statusType = nil
            statusValue = nil
        }
    }

    private static func types(in object: [String: Any]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: object.map { ($0.key, jsonType($0.value)) })
    }

    private static func jsonType(_ value: Any) -> String {
        if value is NSNull { return "null" }
        if value is String { return "string" }
        if value is Bool { return "boolean" }
        if value is NSNumber { return "number" }
        if value is [Any] { return "array" }
        if value is [String: Any] { return "object" }
        return "unknown"
    }
}

private struct SSEDiagnostic: Codable {
    let capturedAt: String
    let error: String
    let sseEvent: String?
    let sseIdentifier: String?
    let headerKind: String?
    let headerSequence: Int?
    let headerKeys: [String]
    let headerTypes: [String: String]
    let payloadKeys: [String]
    let payloadTypes: [String: String]
    let resultKeys: [String]
    let resultTypes: [String: String]
    let statusType: String?
    let statusValue: String?

    init(error: String, frame: SSEFrame, header: EventHeader?, inspection: JSONInspection?) {
        capturedAt = ISO8601DateFormatter().string(from: Date())
        self.error = error
        sseEvent = frame.event
        sseIdentifier = frame.id
        headerKind = header?.kind
        headerSequence = header?.seq
        headerKeys = inspection?.headerKeys ?? []
        headerTypes = inspection?.headerTypes ?? [:]
        payloadKeys = inspection?.payloadKeys ?? []
        payloadTypes = inspection?.payloadTypes ?? [:]
        resultKeys = inspection?.resultKeys ?? []
        resultTypes = inspection?.resultTypes ?? [:]
        statusType = inspection?.statusType
        statusValue = inspection?.statusValue
    }

    func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return }
        let url = caches.appendingPathComponent("mychat-last-sse-diagnostic.json", isDirectory: false)
        try? data.write(to: url, options: .atomic)
#if DEBUG
        if let summary = String(data: data, encoding: .utf8) {
            print("MyChat SSE protocol diagnostic:\n\(summary)")
        }
#endif
    }
}
