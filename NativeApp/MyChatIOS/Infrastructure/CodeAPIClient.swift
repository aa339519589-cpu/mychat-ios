import Foundation

protocol CodeAPIServing: Sendable {
    func githubAuthorizationURL(accessToken: String) async throws -> URL
    func fetchGitHubStatus(accessToken: String) async throws -> GitHubConnectionStatus
    func fetchRepositories(accessToken: String) async throws -> [GitHubRepositoryRecord]
    func enqueue(_ command: CodeChatCommand, accessToken: String) async throws -> CodeAdmission
    func apply(_ command: CodeApplyCommand, accessToken: String) async throws -> CodeApplyResponse
    func capabilities(accessToken: String) async throws -> CodeCapabilities
    func workspace(taskID: UUID, accessToken: String) async throws -> CodeWorkspaceState
    func workspaceChanges(taskID: UUID, accessToken: String) async throws -> CodeWorkspaceChanges
    func workspaceDiff(binding: CodeWorkspaceDiffBinding, path: String,
                       capability: CodeWorkspaceDiffCapability, accessToken: String) async throws -> CodeWorkspaceDiffResponse
    func recovery(sessionID: String, accessToken: String) async throws -> CodeTaskRecovery
    func taskRecovery(taskID: UUID, accessToken: String) async throws -> CodeTaskRecovery
    func reject(_ request: CodeConfirmationRequest, accessToken: String) async throws
    func branches(repository: String, accessToken: String) async throws -> CodeBranches
}

extension CodeAPIServing {
    func capabilities(accessToken: String) async throws -> CodeCapabilities { throw CodeAPIError.invalidResponse }
    func workspace(taskID: UUID, accessToken: String) async throws -> CodeWorkspaceState { throw CodeAPIError.workspaceDiffUnavailable }
    func workspaceChanges(taskID: UUID, accessToken: String) async throws -> CodeWorkspaceChanges { throw CodeAPIError.workspaceDiffUnavailable }
    func workspaceDiff(binding: CodeWorkspaceDiffBinding, path: String,
                       capability: CodeWorkspaceDiffCapability, accessToken: String) async throws -> CodeWorkspaceDiffResponse {
        throw CodeAPIError.workspaceDiffUnavailable
    }
    func recovery(sessionID: String, accessToken: String) async throws -> CodeTaskRecovery { throw CodeAPIError.invalidResponse }
    func taskRecovery(taskID: UUID, accessToken: String) async throws -> CodeTaskRecovery { throw CodeAPIError.invalidResponse }
    func reject(_ request: CodeConfirmationRequest, accessToken: String) async throws { throw CodeAPIError.invalidResponse }
    func branches(repository: String, accessToken: String) async throws -> CodeBranches { throw CodeAPIError.invalidResponse }
}

enum CodeAPIError: LocalizedError, Equatable, Sendable {
    case invalidAccessToken
    case invalidRequest(String)
    case invalidResponse
    case unsafeURL
    case mismatchedResponse
    case workspaceDiffUnavailable
    case server(status: Int, message: String, retryable: Bool)

    var errorDescription: String? {
        switch self {
        case .invalidAccessToken:
            return "登录会话无效，请重新登录"
        case let .invalidRequest(message):
            return message
        case .invalidResponse:
            return "编程服务返回了无效响应"
        case .unsafeURL:
            return "编程服务返回了不安全的事件流地址"
        case .mismatchedResponse:
            return "编程服务响应与本次任务不一致"
        case .workspaceDiffUnavailable:
            return "当前服务暂不支持查看文件差异"
        case let .server(_, message, _):
            return message
        }
    }
}

struct CodeAPIClient: CodeAPIServing {
    private static let productionBaseURL = URL(string: "https://mychat-nm6x.onrender.com")!

    private let session: URLSession
    private let baseURL: URL

    init(
        session: URLSession = .shared,
        baseURL: URL = Self.productionBaseURL
    ) {
        self.session = session
        self.baseURL = baseURL
    }

    func githubAuthorizationURL(accessToken: String) async throws -> URL {
        let endpoint = baseURL.appendingPathComponent("api/mobile/github/oauth/start")
        var request = try authorizedRequest(url: endpoint, accessToken: accessToken)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await perform(request: request)
        guard (200..<300).contains(response.statusCode) else {
            throw serverError(status: response.statusCode, data: data)
        }
        let wire: GitHubMobileAuthorizationWire
        do { wire = try JSONDecoder().decode(GitHubMobileAuthorizationWire.self, from: data) }
        catch { throw CodeAPIError.invalidResponse }
        guard wire.schemaVersion == 1,
              wire.callbackScheme == "mychat",
              let url = URL(string: wire.authorizationUrl),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "github.com",
              effectivePort(url) == 443,
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              url.path == "/login/oauth/authorize",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            throw CodeAPIError.invalidResponse
        }
        let values = Dictionary(grouping: queryItems, by: \.name)
        guard values["client_id"]?.count == 1,
              values["state"]?.first?.value?.isEmpty == false,
              values["redirect_uri"]?.count == 1,
              let redirectValue = values["redirect_uri"]?.first?.value,
              let redirectURL = URL(string: redirectValue),
              sameOrigin(redirectURL, baseURL),
              redirectURL.path == "/api/auth/github/callback",
              !queryItems.contains(where: { $0.name.localizedCaseInsensitiveContains("token") }) else {
            throw CodeAPIError.invalidResponse
        }
        return url
    }

    func capabilities(accessToken: String) async throws -> CodeCapabilities {
        try await get("api/code/capabilities", accessToken: accessToken)
    }

    func workspace(taskID: UUID, accessToken: String) async throws -> CodeWorkspaceState {
        try await workspaceRead(baseURL.appendingPathComponent("api/agent/tasks/\(taskID.uuidString.lowercased())/workspace"),
                                accessToken: accessToken)
    }

    func workspaceChanges(taskID: UUID, accessToken: String) async throws -> CodeWorkspaceChanges {
        let changes: CodeWorkspaceChanges = try await workspaceRead(
            baseURL.appendingPathComponent("api/agent/tasks/\(taskID.uuidString.lowercased())/workspace/diff"),
            accessToken: accessToken)
        guard changes.isWellFormed else { throw CodeAPIError.invalidResponse }
        return changes
    }

    func workspaceDiff(binding: CodeWorkspaceDiffBinding, path: String,
                       capability: CodeWorkspaceDiffCapability, accessToken: String) async throws -> CodeWorkspaceDiffResponse {
        guard capability.isSupported else { throw CodeAPIError.workspaceDiffUnavailable }
        guard binding.isValid, CodeWorkspacePath.isValid(path) else {
            throw CodeAPIError.invalidRequest("文件差异的快照信息无效")
        }
        let endpoint = baseURL.appendingPathComponent("api/agent/tasks/\(binding.taskID.uuidString.lowercased())/workspace/diff")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw CodeAPIError.unsafeURL
        }
        components.queryItems = [
            URLQueryItem(name: "format", value: "unified"), URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "snapshotId", value: binding.snapshotID.uuidString.lowercased()),
            URLQueryItem(name: "manifestDigest", value: binding.manifestDigest),
            URLQueryItem(name: "head", value: binding.head), URLQueryItem(name: "version", value: String(binding.version))
        ]
        guard let url = components.url else { throw CodeAPIError.unsafeURL }
        let value: CodeWorkspaceDiffResponse = try await workspaceRead(url, accessToken: accessToken)
        guard value.isValid(for: binding, path: path, capability: capability) else {
            throw CodeAPIError.mismatchedResponse
        }
        return value
    }

    /// These reads never follow a redirect, store cookies, or accumulate an unbounded response.
    private func workspaceRead<T: Decodable>(_ url: URL, accessToken: String) async throws -> T {
        var request = try authorizedRequest(url: url, accessToken: accessToken)
        request.httpShouldHandleCookies = false
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (bytes, response) = try await session.bytes(for: request, delegate: CodeWorkspaceReadDelegate())
        guard let response = response as? HTTPURLResponse, response.url == url else {
            bytes.task.cancel()
            throw CodeAPIError.unsafeURL
        }
        let limit = 4 * 1_024 * 1_024
        guard response.expectedContentLength <= Int64(limit) else {
            bytes.task.cancel()
            throw CodeAPIError.invalidResponse
        }
        let data: Data
        do {
            data = try await withTaskCancellationHandler {
                var collected = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard collected.count < limit else { throw CodeAPIError.invalidResponse }
                    collected.append(byte)
                }
                return collected
            } onCancel: { bytes.task.cancel() }
        } catch {
            bytes.task.cancel()
            throw error
        }
        guard (200..<300).contains(response.statusCode) else { throw serverError(status: response.statusCode, data: data) }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw CodeAPIError.invalidResponse }
    }

    func recovery(sessionID: String, accessToken: String) async throws -> CodeTaskRecovery {
        guard UUID(uuidString: sessionID) != nil else { throw CodeAPIError.invalidRequest("会话标识无效") }
        let value: CodeTaskRecovery = try await get("api/code/tasks?sessionId=\(sessionID)", accessToken: accessToken)
        return CodeTaskRecovery(admission: try value.admission.map(normalized), sessionId: value.sessionId,
            task: value.task, operationAdmission: try value.operationAdmission.map(normalized))
    }

    private func normalized(_ admission: CodeAdmission) throws -> CodeAdmission {
        guard admission.schemaVersion == 1 else { throw CodeAPIError.invalidResponse }
        return CodeAdmission(schemaVersion: admission.schemaVersion,
            jobID: admission.jobID, taskID: admission.taskID, responseID: admission.responseID,
            status: admission.status, created: admission.created,
            streamURL: try resolvedURL(admission.streamURL.relativeString),
            trialRemaining: admission.trialRemaining, trialLimit: admission.trialLimit)
    }

    func taskRecovery(taskID: UUID, accessToken: String) async throws -> CodeTaskRecovery {
        try await get("api/code/tasks/\(taskID.uuidString.lowercased())", accessToken: accessToken)
    }

    func branches(repository: String, accessToken: String) async throws -> CodeBranches {
        guard isRepository(repository, sessionID: UUID()),
              let query = repository.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw CodeAPIError.invalidRequest("仓库标识无效")
        }
        return try await get("api/code/branches?repo=\(query)", accessToken: accessToken)
    }

    func reject(_ confirmation: CodeConfirmationRequest, accessToken: String) async throws {
        let url = baseURL.appendingPathComponent("api/agent/tasks/\(confirmation.taskID.uuidString.lowercased())/confirm")
        var request = try authorizedRequest(url: url, accessToken: accessToken)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["action": "reject",
            "operation": confirmation.operation, "confirmationId": confirmation.confirmationID.uuidString.lowercased(),
            "confirmationToken": confirmation.confirmationToken])
        let (data, response) = try await perform(request: request)
        guard (200..<300).contains(response.statusCode) else { throw serverError(status: response.statusCode, data: data) }
    }

    private func get<T: Decodable>(_ path: String, accessToken: String) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { throw CodeAPIError.unsafeURL }
        let (data, response) = try await perform(request: authorizedRequest(url: url, accessToken: accessToken))
        guard (200..<300).contains(response.statusCode) else { throw serverError(status: response.statusCode, data: data) }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw CodeAPIError.invalidResponse }
    }

    func fetchGitHubStatus(accessToken: String) async throws -> GitHubConnectionStatus {
        let endpoint = baseURL.appendingPathComponent("api/github/status")
        let (data, response) = try await perform(
            request: authorizedRequest(url: endpoint, accessToken: accessToken)
        )
        guard (200..<300).contains(response.statusCode) else {
            throw serverError(status: response.statusCode, data: data)
        }
        do { return try JSONDecoder().decode(GitHubConnectionStatus.self, from: data) }
        catch { throw CodeAPIError.invalidResponse }
    }

    func fetchRepositories(accessToken: String) async throws -> [GitHubRepositoryRecord] {
        let endpoint = baseURL.appendingPathComponent("api/github/repos")
        let (data, response) = try await perform(
            request: authorizedRequest(url: endpoint, accessToken: accessToken)
        )
        guard (200..<300).contains(response.statusCode) else {
            throw serverError(status: response.statusCode, data: data)
        }
        do { return try JSONDecoder().decode(GitHubRepositoryPayload.self, from: data).repos }
        catch { throw CodeAPIError.invalidResponse }
    }

    func enqueue(
        _ command: CodeChatCommand,
        accessToken: String
    ) async throws -> CodeAdmission {
        try validate(command)
        let endpoint = baseURL.appendingPathComponent("api/code/chat")
        var request = try authorizedRequest(url: endpoint, accessToken: accessToken)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.httpBody = try JSONEncoder().encode(CodeChatBody(command: command))
        let (data, response) = try await perform(request: request)
        guard response.statusCode == 202 else {
            throw serverError(status: response.statusCode, data: data)
        }
        let wire: CodeAdmissionWire
        do { wire = try JSONDecoder().decode(CodeAdmissionWire.self, from: data) }
        catch { throw CodeAPIError.invalidResponse }
        let admission = try admission(from: wire)
        guard admission.responseID == command.responseID,
              admission.taskID == (command.taskID ?? admission.taskID) else {
            throw CodeAPIError.mismatchedResponse
        }
        return admission
    }

    func apply(
        _ command: CodeApplyCommand,
        accessToken: String
    ) async throws -> CodeApplyResponse {
        if (command.confirmationID == nil) != (command.confirmationToken == nil) {
            throw CodeAPIError.invalidRequest("确认凭据不完整")
        }
        let endpoint = baseURL.appendingPathComponent("api/code/apply")
        var request = try authorizedRequest(url: endpoint, accessToken: accessToken)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.httpBody = try JSONEncoder().encode(CodeApplyBody(command: command))
        let (data, response) = try await perform(request: request)
        if response.statusCode == 409,
           let confirmation = try? JSONDecoder().decode(CodeConfirmationRequest.self, from: data) {
            guard confirmation.taskID == command.taskID else {
                throw CodeAPIError.mismatchedResponse
            }
            return .confirmation(confirmation)
        }
        guard response.statusCode == 202 else {
            throw serverError(status: response.statusCode, data: data)
        }
        let wire: CodeAdmissionWire
        do { wire = try JSONDecoder().decode(CodeAdmissionWire.self, from: data) }
        catch { throw CodeAPIError.invalidResponse }
        let value = try admission(from: wire)
        guard value.taskID == command.taskID else { throw CodeAPIError.mismatchedResponse }
        return .accepted(value)
    }

    private func validate(_ command: CodeChatCommand) throws {
        guard command.branch.map({ !$0.isEmpty && $0.utf8.count <= 255 && !$0.hasPrefix("-") && !$0.contains("..") && !$0.contains(where: { $0.isWhitespace || $0.isNewline }) }) ?? true else {
            throw CodeAPIError.invalidRequest("目标分支无效")
        }
        guard isRepository(command.repository, sessionID: command.sessionID) else {
            throw CodeAPIError.invalidRequest("GitHub 仓库标识无效")
        }
        let modelID = command.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty, modelID.utf16.count <= 200,
              !modelID.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw CodeAPIError.invalidRequest("模型标识无效")
        }
        guard !command.messages.isEmpty, command.messages.count <= 20 else {
            throw CodeAPIError.invalidRequest("编程消息上下文无效")
        }
        let total = command.messages.reduce(0) { $0 + $1.content.utf8.count }
        guard total <= 2_000_000,
              command.messages.allSatisfy({
                  ($0.role == "user" || $0.role == "assistant")
                      && $0.content.utf16.count <= 100_000
              }) else {
            throw CodeAPIError.invalidRequest("编程消息上下文过大")
        }
    }

    private func authorizedRequest(url: URL, accessToken: String) throws -> URLRequest {
        guard sameOrigin(url, baseURL), baseURL.scheme?.lowercased() == "https" else {
            throw CodeAPIError.unsafeURL
        }
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: \.isNewline) else {
            throw CodeAPIError.invalidAccessToken
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("mychat-ios/1.0", forHTTPHeaderField: "X-Client-Info")
        return request
    }

    private func perform(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw CodeAPIError.invalidResponse
        }
        guard data.count <= 4 * 1_024 * 1_024 else {
            throw CodeAPIError.invalidResponse
        }
        return (data, response)
    }

    private func admission(from wire: CodeAdmissionWire) throws -> CodeAdmission {
        guard wire.schemaVersion == 1,
              let jobID = UUID(uuidString: wire.jobId),
              let taskID = UUID(uuidString: wire.taskId) else {
            throw CodeAPIError.invalidResponse
        }
        let responseID = wire.responseId.flatMap(UUID.init(uuidString:))
        guard wire.responseId == nil || responseID != nil else {
            throw CodeAPIError.invalidResponse
        }
        return CodeAdmission(
            schemaVersion: wire.schemaVersion,
            jobID: jobID,
            taskID: taskID,
            responseID: responseID,
            status: wire.status,
            created: wire.created,
            streamURL: try resolvedURL(wire.streamUrl),
            trialRemaining: wire.trialRemaining,
            trialLimit: wire.trialLimit
        )
    }

    private func resolvedURL(_ value: String) throws -> URL {
        guard let url = URL(string: value, relativeTo: baseURL)?.absoluteURL,
              sameOrigin(url, baseURL),
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil else {
            throw CodeAPIError.unsafeURL
        }
        return url
    }

    private func isRepository(_ repository: String, sessionID: UUID) -> Bool {
        if repository == "__mychat_new__/\(sessionID.uuidString.lowercased())" { return true }
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-"))
        return parts.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
                && $0.unicodeScalars.allSatisfy(allowed.contains)
        }
    }

    private func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        if url.scheme?.lowercased() == "https" { return 443 }
        if url.scheme?.lowercased() == "http" { return 80 }
        return nil
    }

    private func serverError(status: Int, data: Data) -> CodeAPIError {
        if let envelope = try? JSONDecoder().decode(CodeErrorEnvelope.self, from: data) {
            return .server(
                status: status,
                message: envelope.error.message,
                retryable: envelope.error.retryable
            )
        }
        let flat = try? JSONDecoder().decode(CodeFlatError.self, from: data)
        return .server(
            status: status,
            message: flat?.error ?? "编程服务暂时不可用",
            retryable: status == 429 || status >= 500
        )
    }
}

private final class CodeWorkspaceReadDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct CodeChatBody: Encodable {
    let branch: String?
    let mode: String
    let repo: String
    let modelId: String
    let endpointId: String?
    let reasoningEffort: String?
    let messages: [CodeContextMessage]
    let taskId: String?
    let responseId: String
    let sessionId: String

    init(command: CodeChatCommand) {
        branch = command.branch
        mode = command.mode
        repo = command.repository
        modelId = command.modelID
        endpointId = command.endpointID?.uuidString.lowercased()
        reasoningEffort = command.reasoningEffort
        messages = command.messages
        taskId = command.taskID?.uuidString.lowercased()
        responseId = command.responseID.uuidString.lowercased()
        sessionId = command.sessionID.uuidString.lowercased()
    }
}

private struct CodeApplyBody: Encodable {
    let repo: String?
    let actions: [CodePlanAction]
    let message: String
    let taskId: String
    let mode: String
    let confirmationId: String?
    let confirmationToken: String?

    init(command: CodeApplyCommand) {
        repo = command.repository
        actions = command.actions
        message = command.message
        taskId = command.taskID.uuidString.lowercased()
        mode = command.mode.rawValue
        confirmationId = command.confirmationID?.uuidString.lowercased()
        confirmationToken = command.confirmationToken
    }
}

private struct CodeAdmissionWire: Decodable {
    let schemaVersion: Int
    let jobId: String
    let taskId: String
    let responseId: String?
    let status: String
    let created: Bool
    let streamUrl: String
    let trialRemaining: Int?
    let trialLimit: Int?
}

private struct GitHubMobileAuthorizationWire: Decodable {
    let schemaVersion: Int
    let authorizationUrl: String
    let callbackScheme: String
}

private struct CodeErrorEnvelope: Decodable {
    struct Failure: Decodable {
        let message: String
        let retryable: Bool
    }

    let error: Failure
}

private struct CodeFlatError: Decodable {
    let error: String
}
