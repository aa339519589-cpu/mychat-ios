#if DEBUG
import Foundation
import CryptoKit
import UIKit

/// Deterministic, network-isolated runtime testing. Never used in Release.
enum NativeRuntimeFixture {
    static let userID = "10000000-0000-4000-8000-000000000064"
    static let conversationID = "20000000-0000-4000-8000-000000000064"
    static let projectID = "30000000-0000-4000-8000-000000000064"
    // Opt-in UI stress fixture only; a large style payload keeps the DOM small.
    static let largeArtifactHTML =
        "<html><head><style>" +
        String(repeating: "/* Artifact swipe fixture payload */", count: 4096) +
        "</style></head><body><main><h1>Artifact preview</h1><p>Large return fixture.</p></main></body></html>"

    // Exercise the production inline-SVG renderer as well as the HTML renderer.
    static let largeArtifactSVG =
        "<inline-artifact><svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 300 200\"><title>SVG return fixture</title>" +
        "<!--" + String(repeating: "SVG return fixture payload ", count: 4096) + "-->" +
        "<circle id=\"fixture-sun\" cx=\"150\" cy=\"100\" r=\"32\" fill=\"orange\"><animate attributeName=\"r\" values=\"32;36;32\" dur=\"2s\" repeatCount=\"indefinite\"/></circle></svg></inline-artifact>"

    @MainActor static func makeModel(dataClient: (any SupabaseDataServing)? = nil,
        workspaceClient: (any WorkspaceDataServing)? = nil,
        chatClient: (any ChatAPIServing)? = nil, stream: (any ChatEventStreaming)? = nil,
        planSession: URLSession? = nil,
        planCredentialStore: (any ChatGPTPlanCredentialStoring)? = nil) -> AppModel {
        if ProcessInfo.processInfo.arguments.contains("--ui-test-mode") {
            UserDefaults.standard.removeObject(forKey: "mychat.account-settings-cache.v1." + userID)
            if let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                try? FileManager.default.removeItem(at: base.appendingPathComponent("MyChatConversationCache/" + userID + ".json"))
            }
        }
        URLProtocol.registerClass(NativeAuditURLProtocol.self)
        // Every fixture-owned client uses a session whose protocol list is fixed
        // before its first request. Global URLProtocol registration alone cannot
        // isolate URLSession.shared or an already-running shared config fetch.
        let network = makeSession()
        let configuration = MobileConfigurationClient(session: network)
        let planNetwork = planSession ?? network
        return AppModel(
            catalogClient: ModelCatalogClient(session: network),
            authenticationClient: SupabaseAuthClient(configurationClient: configuration,
                sessionStore: AuditSessionStore(), networkSession: network),
            dataClient: dataClient ?? SupabaseDataClient(configurationClient: configuration, session: network),
            workspaceClient: workspaceClient ?? WorkspaceDataClient(configurationClient: configuration, session: network),
            accountSettingsClient: AccountSettingsClient(configurationClient: configuration, session: network),
            chatClient: chatClient ?? ChatAPIClient(session: network),
            codeClient: CodeAPIClient(session: network),
            jobEventStream: stream ?? JobEventStream(session: network),
            chatGPTPlanProvider: ChatGPTPlanProvider(session: planNetwork,
                credentialStore: planCredentialStore ?? NativeAuditPlanCredentialStore()),
            chatGPTPlanHistoryClient: ChatGPTPlanHistoryClient(session: planNetwork)
        )
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeAuditURLProtocol.self]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }

    static var imageSource: String {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128)).image { context in
            UIColor(red: 0.53, green: 0.74, blue: 0.77, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
            UIColor.white.withAlphaComponent(0.7).setFill()
            UIBezierPath(ovalIn: CGRect(x: 35, y: 35, width: 58, height: 58)).fill()
        }
        return "data:image/png;base64," + image.pngData()!.base64EncodedString()
    }

    static let referenceArticle = """
    # 慢下来的艺术
    
    我们这个时代,好像人人都在赶路。早上赶地铁,中午赶外卖,晚上赶进度条。手机里的消息永远回不完,待办清单刚划掉一项,又冒出三项。于是"忙"成了一种体面的状态,仿佛不忙就是被世界落下了。
    
    可是,真的是这样吗?
    
    ## 一杯茶的时间
    
    前阵子,我试着做了一件很小的事:每天下午泡一杯茶,什么也不做,只是看着热气升起来。第一天,我坐立不安,总想去摸手机。第二天,开始留意到茶叶在水里慢慢舒展的样子。一周之后,这十分钟竟成了一天里最清醒的时刻。
    
    慢下来,并不是偷懒,而是把注意力从"下一件事"拉回"这一件事"。很多时候,我们不是没有时间,而是从未真正待在当下。
    
    ## 慢,才看得见
    
    走路时看见路边新开的小花,吃饭时尝出食物本来的味道,和朋友聊天时认真听完对方的一句话。这些细小的体验,都需要一点"慢"才能抵达。
    
    速度能让我们更快到达目的地,却也常常让我们错过沿途的风景。人生不是一场比赛,没有人会因为你跑得最快,就多给你一份幸福。
    
    ## 给自己留一点空白
    
    把注意力放回此刻,先把这一件事认真做好。
    """

    static var session: AuthSession {
        AuthSession(accessToken: "isolated-runtime-test", refreshToken: "isolated-refresh",
            tokenType: "bearer", expiresAt: Date().addingTimeInterval(3600),
            user: AuthUser(id: userID, email: "runtime-audit@example.invalid", isAnonymous: false))
    }
}

/// Opt-in network diagnostic; real credentials never leave Keychain/server
/// storage, and only timings/status/character counts are printed or saved.
@MainActor enum NativeLiveChatProbe {
    static func run(appModel: AppModel? = nil) async {
        URLProtocol.unregisterClass(NativeAuditURLProtocol.self)
        NSLog("LIVE_NATIVE_STAGE started")
        var metrics: [String: Any] = [:]
        let start = ProcessInfo.processInfo.systemUptime
        func mark(_ stage: String) { metrics[stage] = Int((ProcessInfo.processInfo.systemUptime - start) * 1000) }
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]),
               let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                try? data.write(to: directory.appendingPathComponent("live-standalone-probe.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                print("LIVE_NATIVE_RESULT " + (String(data: data, encoding: .utf8) ?? "{}"))
                NSLog("LIVE_NATIVE_RESULT %@", String(data: data, encoding: .utf8) ?? "{}")
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = []
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 150
        let network = URLSession(configuration: configuration)
        let deadline = Task {
            try? await Task.sleep(for: .seconds(150))
            if !Task.isCancelled { network.getAllTasks { tasks in tasks.forEach { $0.cancel() } } }
        }
        defer { deadline.cancel(); network.getAllTasks { tasks in tasks.forEach { $0.cancel() } } }
        do {
            let store = KeychainAuthSessionStore()
            guard var account = try store.load() else {
                metrics["error"] = "No stored account"
                return
            }
            if account.expires(within: 0) {
                let auth = SupabaseAuthClient(configurationClient: MobileConfigurationClient(session: network),
                    sessionStore: store, networkSession: network)
                account = try await auth.refreshSession()
            }
            mark("authenticationReadyMs")
            NSLog("LIVE_NATIVE_STAGE authenticated")
            let arguments = ProcessInfo.processInfo.arguments
            func argument(_ flag: String) -> String? {
                guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
                return arguments[index + 1]
            }
            let kind = argument("--live-kind") ?? ProcessInfo.processInfo.environment["MYCHAT_LIVE_PROBE_KIND"] ?? "text"
            let model = argument("--live-model") ?? ProcessInfo.processInfo.environment["MYCHAT_LIVE_MODEL_ID"] ?? "anthropic/claude-sonnet-5.5"
            metrics["kind"] = kind; metrics["model"] = model
            if kind == "display", let appModel {
                appModel.acceptAuthentication(account)
                await appModel.reloadModels()
                guard let selected = appModel.models.first(where: { $0.id == model }) else {
                    metrics["error"] = "Requested real model unavailable"
                    return
                }
                appModel.selectModel(selected)
                appModel.beginNewChat()
                appModel.draft = "请解释为什么月亮会有不同的形状，给出生活中的例子。"
                appModel.sendDraft()
                guard let conversation = appModel.activeConversationID else { return }
                for _ in 0..<1_200 {
                    try Task.checkCancellation()
                    if appModel.messages.contains(where: { $0.role == .assistant && !$0.content.isEmpty }), !appModel.isCurrentConversationGenerating { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                let record = ChatGenerationDiagnostics.records.values.filter { $0.conversationID == conversation }.max { $0.monotonicStart < $1.monotonicStart }
                metrics["generationID"] = record?.generationID.uuidString
                metrics["stages"] = record?.milliseconds
                metrics["characters"] = appModel.messages.last(where: { $0.role == .assistant })?.content.count
                return
            }
            let prompt = ProcessInfo.processInfo.environment["MYCHAT_LIVE_PROMPT"]
                ?? (kind == "health" ? "只列出你能看到的本次健康数据类别名称，不要复述任何个人数值、时间或健康判断。如果没有提供数据，请明确说没有。"
                    : kind == "photo" ? "描述图片里的颜色和形状。" : kind == "web" ? "请联网查询苹果官网现在有哪些 iPhone，给出来源链接。" : "请解释为什么月亮会有不同的形状，给出一个生活中的例子。")
            var message = ChatMessage(id: UUID(), role: .user, content: prompt, thinking: nil, createdAt: Date())
            if kind == "photo" {
                let picture = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256)).image { context in
                    UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
                    UIColor.red.setFill(); UIBezierPath(ovalIn: CGRect(x: 48, y: 48, width: 160, height: 160)).fill()
                }
                message.sourceImages = ["data:image/jpeg;base64," + (picture.jpegData(compressionQuality: 0.85)?.base64EncodedString() ?? "")]
            }
            var tools = ChatToolSelection()
            tools.searchMode = kind == "web" ? .web : .off
            var preparedCommand = ChatAppendCommand(conversationID: UUID(), userMessage: message,
                modelID: model, tools: tools, createConversation: true,
                conversationMemoryEnabled: false, title: "链路诊断 · " + kind)
            if kind == "health" {
                guard let context = await HealthConnector.modelContext(ownerID: account.user.id, refresh: true)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !context.isEmpty else {
                    metrics["error"] = "No enabled, readable Health connection"; return
                }
                preparedCommand.healthContext = context
                metrics["healthAudit"] = HealthConnector.readAudit[account.user.id]
                metrics["healthContextChars"] = context.utf16.count
                metrics["healthContextSHA256"] = SHA256.hash(data: Data(context.utf8)).map { String(format: "%02x", $0) }.joined()
            }
            let command = preparedCommand
            metrics["generationID"] = command.generationID.uuidString
            mark("requestStartedMs")
            NSLog("LIVE_NATIVE_STAGE request %@", command.generationID.uuidString)
            let connection = try await ChatAPIClient(session: network).openAppendTurn(command, accessToken: account.accessToken)
            mark("admittedMs")
            NSLog("LIVE_NATIVE_STAGE admitted %@", String(metrics["admittedMs"] as? Int ?? -1))
            Task {
                do {
                    let bootstrap = try await MobileConfigurationClient().fetchConfiguration()
                    var url = URLComponents(url: bootstrap.supabaseURL.appendingPathComponent("rest/v1/jobs"), resolvingAgainstBaseURL: false)!
                    url.queryItems = [URLQueryItem(name: "id", value: "eq." + command.generationID.uuidString.lowercased()),
                        URLQueryItem(name: "select", value: "id,status,progress,result,error_code,event_sequence,started_at,terminal_at")]
                    var request = URLRequest(url: url.url!)
                    request.setValue(bootstrap.supabaseAnonKey, forHTTPHeaderField: "apikey")
                    request.setValue("Bearer " + account.accessToken, forHTTPHeaderField: "Authorization")
                    let (data, response) = try await URLSession.shared.data(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    let error = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    NSLog("LIVE_NATIVE_REST status=%d code=%@ message=%@", status,
                        error?["code"] as? String ?? "", error?["message"] as? String ?? "")
                } catch { NSLog("LIVE_NATIVE_REST transport=%@", String((error as NSError).code)) }
            }
            let events = connection.events ?? JobEventStream(session: network).events(admission: connection.admission, accessToken: account.accessToken)
            var count = 0
            var searches = 0
            for try await event in events {
                if metrics["firstEventMs"] == nil { mark("firstEventMs") }
                switch event.payload {
                case let .textDelta(text) where !text.isEmpty:
                    if count == 0 { mark("firstTextMs"); NSLog("LIVE_NATIVE_FIRST_TEXT %@", String(metrics["firstTextMs"] as? Int ?? -1)) }
                    count += text.count
                case .toolSearch: searches += 1
                case let .terminal(terminal):
                    mark("terminalMs")
                    metrics["status"] = terminal.status.rawValue
                    metrics["errorCode"] = terminal.errorCode
                default: break
                }
            }
            metrics["characters"] = count; metrics["searchEvents"] = searches
        } catch {
            let failure = error as NSError
            metrics["errorDomain"] = failure.domain; metrics["errorCode"] = failure.code
            metrics["error"] = error.localizedDescription
        }
    }
}

/// Fixture credentials never consult or mutate the simulator's Keychain.
final class NativeAuditPlanCredentialStore: ChatGPTPlanCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credential: ChatGPTPlanCredential?
    private var hostID: String?
    private var reads = 0

    init(credential: ChatGPTPlanCredential? = nil) { self.credential = credential }

    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }

    func loadCredential() throws -> ChatGPTPlanCredential? {
        lock.lock(); defer { lock.unlock() }
        reads += 1
        return credential
    }

    func save(_ credential: ChatGPTPlanCredential) throws {
        lock.lock(); defer { lock.unlock() }
        self.credential = credential
    }

    func deleteCredential() throws {
        lock.lock(); defer { lock.unlock() }
        credential = nil
    }

    func loadOrCreateHostID() throws -> String {
        lock.lock(); defer { lock.unlock() }
        if let hostID { return hostID }
        let value = "urn:uuid:10000000-0000-4000-8000-000000000099"
        hostID = value
        return value
    }

    func deleteHostID() throws {
        lock.lock(); defer { lock.unlock() }
        hostID = nil
    }
}

private final class AuditSessionStore: AuthSessionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: AuthSession? = NativeRuntimeFixture.session
    func load() throws -> AuthSession? { lock.lock(); defer { lock.unlock() }; return value }
    func save(_ session: AuthSession) throws { lock.lock(); defer { lock.unlock() }; value = session }
    func clear() throws { lock.lock(); defer { lock.unlock() }; value = nil }
}

final class NativeAuditURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var memoryEnabled = true
    private static var sensitiveEnabled = false
    private static var systemPrompt = ""
    private static var deletedConversations: Set<String> = []
    private static var deletedProjects: Set<String> = []
    private static var codeCancellationCount = 0
    private static var codeCancellationStatusQueryCount = 0
    private static let lateCodeJobA = "88000000-0000-4000-8000-000000000064"
    private static let lateCodeJobB = "88000000-0000-4000-8000-000000000067"
    private static let lateCodeTask = "88000000-0000-4000-8000-000000000065"
    private static var lateCodeStreams: [String: NativeAuditURLProtocol] = [:]
    private static var lateCodeStreamCounts: [String: Int] = [:]
    private static var lateCodeCancellation: NativeAuditURLProtocol?
    private static var lateCodeEndedA = false
    private static var lateCodeReplyScheduled = false
    private static var lateCodeReplyDelivered = false
    private static var staleRecoveryEndedA = false
    private static var staleRecoveryHeldRequest: NativeAuditURLProtocol?
    private static var staleRecoveryHeldOnce = false
    private static var staleRecoveryStreams: [String: NativeAuditURLProtocol] = [:]
    static var historicalTestContent: String?
    private static var addedMemories: [[String: Any]] = []
    private static var savedArtifacts: [[String: Any]] = []
    static func containsSavedArtifact(messageID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return savedArtifacts.contains { $0["message_id"] as? String == messageID }
    }
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        // Capture every request at the protocol boundary, but only answer the
        // fixture's declared origins. Unknown requests fail here; they never
        // fall through to a real network or receive a fabricated success.
        guard url.scheme == "https", url.port == nil || url.port == 443,
              ["isolated.mychat.invalid", "mychat-nm6x.onrender.com"].contains(url.host ?? "") else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL,
                userInfo: [NSLocalizedDescriptionKey: "Offline fixture rejected an unconfigured origin"]))
            return
        }
        if handleStaleCodeRecovery(url) { return }
        if handleLateCodeCancellation(url) { return }
        let path = url.path
        if ProcessInfo.processInfo.arguments.contains("--ui-test-code-terminal-replay"),
           path.hasPrefix("/api/v1/jobs/"), path.hasSuffix("/events") {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let fromSequence = components?.queryItems?.first(where: { $0.name == "from_seq" })?.value
            guard fromSequence == "0" else {
                let errorResponse = HTTPURLResponse(url: url, statusCode: 400, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: errorResponse, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(#"{"error":"fixture requires from_seq=0"}"#.utf8))
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            let jobID = "88000000-0000-4000-8000-000000000074"
            let taskID = "88000000-0000-4000-8000-000000000075"
            func frame(_ sequence: Int, _ kind: String, _ payload: [String: Any]) -> Data {
                let envelope: [String: Any] = ["jobId": jobID, "seq": sequence, "kind": kind, "payload": payload]
                let json = try! JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
                let text = String(data: json, encoding: .utf8)!
                return Data("id: \(sequence)\nevent: \(kind)\ndata: \(text)\n\n".utf8)
            }
            let textEvent = frame(1, "text.delta", ["text": "终态任务回放正文"])
            let planEvent = frame(2, "agent.plan", ["plan": [
                "kind": "write_file", "path": "README.md", "newContent": "replayed"
            ]])
            let terminalEvent = frame(3, "job.terminal", ["status": "completed", "result": [
                "mode": "publish_pr", "taskId": taskID, "repo": "mychat/test-app"
            ]])
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream", "Cache-Control": "no-store"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: textEvent)
            client?.urlProtocol(self, didLoad: textEvent) // replayed sequence is ignored by the client cursor
            client?.urlProtocol(self, didLoad: planEvent)
            Thread.sleep(forTimeInterval: 2.0)
            guard !stopped else { return }
            client?.urlProtocol(self, didLoad: terminalEvent)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-test-code-cancel-lost-sse"),
           path.hasPrefix("/api/v1/jobs/"), path.hasSuffix("/events") {
            // Hold the durable event stream open. The cancellation test proves
            // task recovery can settle the UI even without a terminal SSE.
            return
        }
        let body = Self.body(request)
        Self.lock.lock()
        let (status, payload) = Self.response(path, request.httpMethod ?? "GET", body, url)
        Self.lock.unlock()
        guard !stopped else { return }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json", "Cache-Control": "no-store"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { stopped = true }

    private func codeFixtureJSON(status: Int, payload: [String: Any]) -> Bool {
        guard !stopped, let url = request.url, let receiver = client else { return false }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json", "Cache-Control": "no-store"])!
        receiver.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        receiver.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        receiver.urlProtocolDidFinishLoading(self)
        return true
    }

    private func codeFixtureFrame(_ sequence: Int, kind: String, payload: [String: Any]) {
        guard !stopped, let url = request.url else { return }
        let envelope: [String: Any] = ["jobId": url.pathComponents.dropLast().last ?? "",
            "seq": sequence, "kind": kind, "payload": payload]
        let json = try! JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        let text = String(data: json, encoding: .utf8)!
        client?.urlProtocol(self, didLoad: Data("id: \(sequence)\nevent: \(kind)\ndata: \(text)\n\n".utf8))
    }

    private func handleStaleCodeRecovery(_ url: URL) -> Bool {
        guard ProcessInfo.processInfo.arguments.contains("--ui-test-code-stale-recovery") else { return false }
        let jobID = url.pathComponents.dropLast().last ?? ""
        if url.path == "/api/code/tasks", request.httpMethod == "GET" {
            Self.lock.lock()
            let endedA = Self.staleRecoveryEndedA
            if endedA && !Self.staleRecoveryHeldOnce {
                Self.staleRecoveryHeldOnce = true
                Self.staleRecoveryHeldRequest = self
                Self.lock.unlock()
                return true
            }
            Self.lock.unlock()
            _ = codeFixtureJSON(status: 200, payload: Self.staleRecoveryPayload(successor: endedA))
            return true
        }
        guard url.path.hasPrefix("/api/v1/jobs/") else { return false }
        if url.path.hasSuffix("/events") {
            Self.lock.lock()
            Self.staleRecoveryStreams[jobID] = self
            let held = jobID == Self.lateCodeJobB ? Self.staleRecoveryHeldRequest : nil
            if held != nil { Self.staleRecoveryHeldRequest = nil }
            Self.lock.unlock()
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream", "Cache-Control": "no-store"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            codeFixtureFrame(1, kind: "text.delta", payload: ["text": jobID == Self.lateCodeJobB ? "新任务已接管" : "任务正在运行"])
            if let held {
                DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                    guard held.codeFixtureJSON(status: 200,
                        payload: Self.staleRecoveryPayload(successor: false, completed: true)) else { return }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                        self.codeFixtureFrame(2, kind: "text.delta", payload: ["text": "；旧恢复响应已交付"])
                    }
                }
            }
            return true
        }
        guard url.path.hasSuffix("/cancel"), request.httpMethod == "POST", jobID == Self.lateCodeJobA else { return false }
        Self.lock.lock()
        Self.staleRecoveryEndedA = true
        let stream = Self.staleRecoveryStreams[jobID]
        Self.lock.unlock()
        _ = codeFixtureJSON(status: 202, payload: ["jobId": jobID, "accepted": true,
            "replayed": false, "status": "cancelling", "eventSeq": 1])
        stream?.codeFixtureFrame(2, kind: "job.terminal", payload: ["status": "completed", "content": "旧任务已结束"])
        if let stream { stream.client?.urlProtocolDidFinishLoading(stream) }
        return true
    }

    private static func staleRecoveryPayload(successor: Bool, completed: Bool = false) -> [String: Any] {
        let jobID = successor ? lateCodeJobB : lateCodeJobA
        let responseID = successor ? "88000000-0000-4000-8000-000000000068" : "88000000-0000-4000-8000-000000000066"
        let status = completed ? "completed" : "running"
        let evidenceID = successor ? "current-recovery-evidence" : "previous-recovery-evidence"
        let task: [String: Any] = ["id": lateCodeTask, "status": status,
            "branch": successor ? "feature/current-task" : "main", "error": NSNull(), "pullRequestUrl": NSNull(),
            "toolCalls": [], "artifacts": [["id": evidenceID, "kind": "summary",
                "title": successor ? "当前任务记录" : "旧任务记录", "content": "隔离测试持久记录"]]]
        let admission: Any
        if completed {
            admission = NSNull()
        } else {
            admission = ["schemaVersion": 1, "jobId": jobID,
                "taskId": lateCodeTask, "responseId": responseID, "status": status, "created": false,
                "streamUrl": "/api/v1/jobs/\(jobID)/events", "trialRemaining": NSNull(), "trialLimit": NSNull()] as [String: Any]
        }
        return ["sessionId": "80000000-0000-4000-8000-000000000064", "task": task,
            "admission": admission, "operationAdmission": NSNull()]
    }

    private func handleLateCodeCancellation(_ url: URL) -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-test-code-late-cancel"),
              url.path.hasPrefix("/api/v1/jobs/") else { return false }
        let jobID = url.pathComponents.dropLast().last ?? ""
        if url.path.hasSuffix("/events") {
            Self.lock.lock()
            Self.lateCodeStreams[jobID] = self
            Self.lateCodeStreamCounts[jobID, default: 0] += 1
            let count = Self.lateCodeStreamCounts[jobID, default: 0]
            let resumed = jobID == Self.lateCodeJobB && count > 1
            if Self.lateCodeEndedA,
               jobID == Self.lateCodeJobB || arguments.contains("--ui-test-code-cancel-resubscribe") {
                Self.scheduleLateCodeReply()
            }
            Self.lock.unlock()
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream", "Cache-Control": "no-store"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let cursorValue = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "from_seq" })?.value
            let cursor = max(0, Int(cursorValue ?? "0") ?? 0)
            if cursor < 1 {
                codeFixtureFrame(1, kind: "text.delta", payload: ["text": "任务正在运行"])
            }
            if resumed {
                // Replay immutable events before publishing the next sequence after reconnect.
                if cursor < 2 {
                    codeFixtureFrame(2, kind: "text.delta", payload: ["text": "；取消响应已交付"])
                }
                if cursor < 3 {
                    codeFixtureFrame(3, kind: "text.delta", payload: ["text": "后继任务已正常恢复"])
                }
            }
            return true
        }
        guard url.path.hasSuffix("/cancel"), request.httpMethod == "POST", jobID == Self.lateCodeJobA else {
            return false
        }
        Self.lock.lock()
        Self.lateCodeCancellation = self
        Self.lateCodeEndedA = true
        let stream = Self.lateCodeStreams[jobID]
        Self.lock.unlock()
        if !arguments.contains("--ui-test-code-cancel-resubscribe") {
            stream?.codeFixtureFrame(2, kind: "job.terminal", payload: ["status": "completed", "content": "首个任务已完成"])
        }
        if let stream { stream.client?.urlProtocolDidFinishLoading(stream) }
        // The HTTP response remains held until recovery has reached the selected owner.
        return true
    }

    // Called with lock held. No sleeping while holding the fixture's request lock.
    private static func scheduleLateCodeReply() {
        guard !lateCodeReplyScheduled, lateCodeCancellation != nil else { return }
        lateCodeReplyScheduled = true
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            lock.lock()
            let pending = lateCodeCancellation
            lateCodeCancellation = nil
            let arguments = ProcessInfo.processInfo.arguments
            let successor = arguments.contains("--ui-test-code-cancel-successor")
            let resumed = arguments.contains("--ui-test-code-cancel-resubscribe")
            let stream = successor ? lateCodeStreams[lateCodeJobB] : (resumed ? lateCodeStreams[lateCodeJobA] : nil)
            lock.unlock()
            let delivered: Bool
            if arguments.contains("--ui-test-code-late-cancel-fails") {
                delivered = pending?.codeFixtureJSON(status: 503, payload: ["error": "隔离测试：迟到取消失败"]) ?? false
            } else {
                delivered = pending?.codeFixtureJSON(status: 202, payload: ["jobId": lateCodeJobA,
                    "accepted": true, "replayed": false, "status": "cancelling", "eventSeq": 1]) ?? false
            }
            guard delivered else { return }
            lock.lock(); lateCodeReplyDelivered = true; lock.unlock()
            NSLog("CODE_LATE_CANCEL_RESPONSE_DELIVERED")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                stream?.codeFixtureFrame(2, kind: "text.delta", payload: ["text": "；取消响应已交付"])
                if successor, let stream {
                    // A normal disconnect after the stale reply must not enter A's cancellation path.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                        stream.client?.urlProtocolDidFinishLoading(stream)
                    }
                }
            }
        }
    }

    // Called with lock held by response(). B deliberately shares A's task ID.
    private static func lateCodeRecovery() -> [String: Any] {
        let arguments = ProcessInfo.processInfo.arguments
        let successor = lateCodeEndedA && arguments.contains("--ui-test-code-cancel-successor")
        let sameJob = arguments.contains("--ui-test-code-cancel-resubscribe")
        let finished = lateCodeEndedA && !successor && !sameJob
        if finished { scheduleLateCodeReply() }
        let jobID = successor ? lateCodeJobB : lateCodeJobA
        let responseID = successor ? "88000000-0000-4000-8000-000000000068" : "88000000-0000-4000-8000-000000000066"
        let cancelling = sameJob && lateCodeReplyDelivered && !arguments.contains("--ui-test-code-late-cancel-fails")
        let status = finished ? "completed" : (cancelling ? "cancelling" : "running")
        let task: [String: Any] = ["id": lateCodeTask, "status": status, "branch": "main",
            "error": NSNull(), "pullRequestUrl": NSNull(), "toolCalls": [], "artifacts": []]
        let admission: Any
        if finished {
            admission = NSNull()
        } else {
            admission = ["schemaVersion": 1, "jobId": jobID,
                "taskId": lateCodeTask, "responseId": responseID, "status": status, "created": false,
                "streamUrl": "/api/v1/jobs/\(jobID)/events", "trialRemaining": NSNull(), "trialLimit": NSNull()] as [String: Any]
        }
        return ["sessionId": "80000000-0000-4000-8000-000000000064", "task": task,
            "admission": admission, "operationAdmission": NSNull()]
    }

    private static func body(_ request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable, data.count < 256 * 1024 {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func response(_ path: String, _ method: String, _ body: [String: Any], _ url: URL) -> (Int, Any) {
        let date = "2026-10-03T06:00:00Z"
        switch path {
        case "/api/mobile/config":
            return (200, ["supabaseUrl": "https://isolated.mychat.invalid", "supabaseAnonKey": "isolated-anon"])
        case "/api/code/capabilities":
            var capabilities: [String: Any] = [
                "schemaVersion": 1, "cloudOnly": true, "durableQueue": true,
                "execution": ["backend": "isolated", "location": "local_test", "configured": false,
                              "verified": false, "reason": "Isolated test fixture; no Cloud verification"]
            ]
            if ProcessInfo.processInfo.arguments.contains("--ui-test-code-diff") {
                capabilities["workspaceDiff"] = ["schemaVersion": 1, "formats": ["cas-change-summary", "unified"],
                    "requiresSnapshotBinding": true, "maxFileBytes": 262144, "maxPatchBytes": 1048576]
            }
            return (200, capabilities)
        case "/api/code/branches":
            return (200, ["branches": [["name": "main"], ["name": "feature/fixture"]], "defaultBranch": "main"])
        case "/api/github/status":
            let connected = ProcessInfo.processInfo.arguments.contains("--ui-test-connected-github")
            let login: Any = connected ? "fixture-user" : NSNull()
            return (200, ["connected": connected, "login": login])
        case "/api/github/repos":
            guard ProcessInfo.processInfo.arguments.contains("--ui-test-connected-github") else {
                return (401, ["error": "GitHub fixture is not connected"])
            }
            return (200, ["repos": [[
                "name": "mychat-ios",
                "full_name": "aa339519589-cpu/mychat-ios",
                "private": true,
                "description": "Isolated repository fixture"
            ]]])
        case "/api/models":
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--ui-test-claude-models") || arguments.contains("--ui-test-long-model-names") {
                let routes = [("anthropic/claude-fable-5-1", "Claude Fable 5.1"),
                    ("anthropic/claude-opus-5-5", "Claude Opus 5.5"),
                    ("anthropic/claude-sonnet-5-5", "Claude Sonnet 5.5"),
                    ("anthropic/claude-sonnet-5", "Claude Sonnet 5"),
                    ("anthropic/claude-haiku-5.5", "Claude Haiku 5.5"),
                    ("anthropic/claude-haiku-4.5", "Claude Haiku 4.5")]
                var models: [[String: Any]] = routes.map { id, name in
                    ["id": id, "name": name, "provider": "Anthropic", "access": "quota", "outputKind": "chat",
                     "promptPrice": 0, "completionPrice": 0, "contextLength": 100000,
                     "vision": true, "tools": true, "flagship": false,
                     "reasoningEfforts": ["none", "low", "medium", "high", "xhigh", "max"],
                     "defaultReasoningEffort": "medium", "reasoningMandatory": false]
                }
                if arguments.contains("--ui-test-long-model-names") {
                    let longModels: [(String, String, String)] = [
                        ("fixture-long-english", "Experimental Multilingual Reasoning Model for Very Long Context and Advanced Tool Use",
                         "Provider with a deliberately long English description to verify the model row layout"),
                        ("fixture-long-chinese", "面向复杂知识工作和超长上下文的多语言研究与逻辑推理模型",
                         "用于验证中文模型说明换行与勾选列对齐的服务提供方")
                    ]
                    models.append(contentsOf: longModels.map { id, name, provider in
                        ["id": id, "name": name, "provider": provider, "access": "quota", "outputKind": "chat",
                         "promptPrice": 0, "completionPrice": 0, "contextLength": 100000,
                         "vision": true, "tools": false, "flagship": false,
                         "reasoningEfforts": ["none", "low", "medium"], "defaultReasoningEffort": "medium",
                         "reasoningMandatory": false]
                    })
                }
                return (200, ["schemaVersion": 1, "configured": true, "owner": false, "trialLimit": 0, "models": models])
            }
            return (200, ["schemaVersion": 1, "configured": true, "owner": false, "trialLimit": 0,
                "models": [["id": "audit-model", "name": "测试模型", "provider": "custom", "access": "quota",
                    "outputKind": "chat", "promptPrice": 0, "completionPrice": 0, "contextLength": 100000,
                    "vision": true, "tools": true, "flagship": false,
                    "reasoningEfforts": ["none", "low", "medium", "high"], "reasoningMandatory": false]]])
        case "/api/profile/memory":
            if let enabled = body["enabled"] as? Bool { memoryEnabled = enabled }
            if let enabled = body["sensitiveEnabled"] as? Bool { sensitiveEnabled = enabled }
            return (200, ["enabled": memoryEnabled, "sensitiveEnabled": sensitiveEnabled])
        case "/api/memories":
            if method == "POST" {
                let row: [String: Any] = ["id": UUID().uuidString.lowercased(), "content": body["content"] ?? "", "topic": body["topic"] ?? "General", "sensitive": false, "created_at": date, "updated_at": date]
                addedMemories.append(row); return (201, ["memory": row])
            }
            return (200, ["memories": [["id": "40000000-0000-4000-8000-000000000064", "content": "这是隔离测试记忆", "topic": "测试", "sensitive": false, "created_at": date, "updated_at": date]] + addedMemories])
        case "/api/profile/system-prompt":
            if let prompt = body["prompt"] as? String { systemPrompt = prompt }
            return (200, ["prompt": systemPrompt])
        case "/api/endpoints":
            guard ProcessInfo.processInfo.arguments.contains("--ui-test-connected-model") else {
                return (200, ["endpoints": []])
            }
            return (200, ["endpoints": [[
                "id": "90000000-0000-4000-8000-000000000064", "name": "My endpoint",
                "baseUrl": "https://endpoint.example.invalid/v1", "model": "audit-connected-model",
                "outputKind": "chat", "authType": "bearer", "needsReconnect": false,
                "createdAt": date, "updatedAt": date
            ]]])
        case "/rest/v1/code_sessions":
            guard ProcessInfo.processInfo.arguments.contains("--ui-test-code-display") else { return (200, []) }
            let id = "80000000-0000-4000-8000-000000000064"
            let provisionalRepository = "__mychat_new__/" + id
            return (200, [
                ["id": id, "repo": provisionalRepository, "title": provisionalRepository, "created_at": date, "updated_at": date],
                ["id": "80000000-0000-4000-8000-000000000065", "repo": provisionalRepository, "title": "继续当前任务", "created_at": date, "updated_at": date],
                ["id": "80000000-0000-4000-8000-000000000066", "repo": "mychat/test-app", "title": "修复登录边界", "created_at": date, "updated_at": date],
            ])
        case "/rest/v1/code_messages":
            if ProcessInfo.processInfo.arguments.contains("--ui-test-code-late-cancel")
                || ProcessInfo.processInfo.arguments.contains("--ui-test-code-stale-recovery") {
                return (200, ["88000000-0000-4000-8000-000000000066", "88000000-0000-4000-8000-000000000068"].map { id in
                    ["id": id, "session_id": "80000000-0000-4000-8000-000000000064", "role": "assistant",
                     "content": "隔离任务记录", "meta": NSNull(), "created_at": date] as [String: Any]
                })
            }
            guard ProcessInfo.processInfo.arguments.contains("--ui-test-code-terminal-replay") else { return (200, []) }
            return (200, [[
                "id": "88000000-0000-4000-8000-000000000076",
                "session_id": "80000000-0000-4000-8000-000000000066",
                "role": "assistant", "content": "旧内容", "meta": NSNull(), "created_at": date,
            ]])
        case "/api/code/tasks":
            guard ProcessInfo.processInfo.arguments.contains("--ui-test-code-display") else {
                return (503, ["error": "隔离测试未配置任务恢复"])
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-test-code-late-cancel") {
                return (200, lateCodeRecovery())
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-test-code-diff")
                || ProcessInfo.processInfo.arguments.contains("--ui-test-code-diff-legacy") {
                return (200, ["task": ["id": "88000000-0000-4000-8000-000000000075", "status": "completed", "branch": "main",
                    "error": NSNull(), "pullRequestUrl": NSNull(), "toolCalls": [],
                    "artifacts": [["id": "legacy-summary", "kind": "summary", "title": "更改摘要", "content": "已修改两个文件"]]],
                    "admission": NSNull(), "operationAdmission": NSNull()])
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-test-code-terminal-replay") {
                let jobID = "88000000-0000-4000-8000-000000000074"
                let taskID = "88000000-0000-4000-8000-000000000075"
                let sessionID = "80000000-0000-4000-8000-000000000066"
                let task: [String: Any] = [
                    "id": taskID, "status": "completed", "branch": "main",
                    "error": NSNull(), "pullRequestUrl": NSNull(), "toolCalls": [], "artifacts": []
                ]
                let admission: [String: Any] = [
                    "schemaVersion": 1, "jobId": jobID, "taskId": taskID,
                    "responseId": "88000000-0000-4000-8000-000000000076",
                    "status": "completed", "created": false,
                    "streamUrl": "/api/v1/jobs/\(jobID)/events",
                    "trialRemaining": NSNull(), "trialLimit": NSNull()
                ]
                return (200, ["sessionId": sessionID, "task": task, "admission": admission,
                              "operationAdmission": NSNull()])
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-test-code-cancel-lost-sse") {
                let jobID = "88000000-0000-4000-8000-000000000064"
                let taskID = "88000000-0000-4000-8000-000000000065"
                let sessionID = "80000000-0000-4000-8000-000000000064"
                if codeCancellationCount >= 2 { codeCancellationStatusQueryCount += 1 }
                let cancelled = codeCancellationCount >= 2 && codeCancellationStatusQueryCount >= 2
                let status = cancelled ? "cancelled" : (codeCancellationCount >= 2 ? "cancelling" : "running")
                let task: [String: Any] = [
                    "id": taskID, "status": status, "branch": "main",
                    "error": NSNull(), "pullRequestUrl": NSNull(), "toolCalls": [], "artifacts": []
                ]
                let admission: Any
                if cancelled {
                    admission = NSNull()
                } else {
                    admission = [
                        "schemaVersion": 1, "jobId": jobID, "taskId": taskID,
                        "responseId": "88000000-0000-4000-8000-000000000066",
                        "status": status, "created": false,
                        "streamUrl": "/api/v1/jobs/\(jobID)/events",
                        "trialRemaining": NSNull(), "trialLimit": NSNull()
                    ] as [String: Any]
                }
                return (200, ["sessionId": sessionID, "task": task, "admission": admission,
                              "operationAdmission": NSNull()])
            }
            return (200, ["task": NSNull(), "admission": NSNull()])
        case "/api/connectors":
            if method == "POST" {
                let accessToken = body["accessToken"] as? String
                let connector: [String: Any] = [
                    "id": "90000000-0000-4000-8000-000000000066",
                    "name": body["name"] as? String ?? "Fixture connector",
                    "serverUrl": body["serverUrl"] as? String ?? "https://connector.example.invalid/mcp",
                    "enabled": true,
                    "hasAccessToken": accessToken != nil,
                    "authType": accessToken == nil ? "none" : "bearer",
                    "toolCount": 0,
                    "tools": [],
                    "createdAt": date,
                    "updatedAt": date
                ]
                return (201, ["connector": connector])
            }
            return (200, ["connectors": []])
        case "/api/connectors/directory": return (200, ["entries": [["id": "sample", "name": "Sample service", "description": "An isolated directory entry", "serverUrl": "https://connector.example.invalid/mcp", "authType": "oauth"]], "nextCursor": NSNull()])
        case "/api/tts": return (503, ["error": "隔离测试：模拟语音提供方失败"])
        case "/rest/v1/conversations":
            if ProcessInfo.processInfo.arguments.contains("--ui-test-all-chats") {
                return (200, (0..<10).map { index in
                    ["id": index == 0 ? NativeRuntimeFixture.conversationID : String(format: "20000000-0000-4000-8000-%012d", index),
                     "title": index == 0 ? "隔离测试对话" : "History fixture \(index)", "updated_at": date,
                     "starred": false, "pinned": false, "memory_enabled": true] as [String: Any]
                })
            }
            return (200, deletedConversations.contains(NativeRuntimeFixture.conversationID) ? [] : [[
                "id": NativeRuntimeFixture.conversationID, "title": "隔离测试对话", "updated_at": date,
                "starred": false, "pinned": false, "memory_enabled": true]])
        case "/rest/v1/messages":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard query.contains(where: { $0.name == "conversation_id" && $0.value?.contains(NativeRuntimeFixture.conversationID) == true }) else { return (200, []) }
            if let content = historicalTestContent {
                return (200, [["id": "77700000-0000-4000-8000-000000000064", "role": "assistant", "content": content, "seq": 2, "created_at": date]])
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-test-english-font-reference") {
                let reply = "Yes, I can! I'm happy to chat in English. Feel free to ask me anything, or tell me what you'd like help with, and we can continue in English or switch to Chinese whenever you like."
                let summary = "This person is simply asking if I can speak English."
                return (200, [
                    ["id": "40000000-0000-4000-8000-000000000063", "role": "user",
                     "content": "Hello, can you speak English?", "seq": 1, "created_at": date],
                    ["id": "40000000-0000-4000-8000-000000000064", "role": "assistant", "content": reply,
                     "thinking": ChatReasoningSummaryStorage.encode(summary) ?? "", "seq": 2, "created_at": date]
                ].reversed().map { $0 })
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-test-summary-reference") {
                let summary = "核对研究资料包并规划后续步骤。\n\n第二段摘要仍然保留，展开后可以继续阅读。"
                let reply = "<document>\ntitle: 摘要样式测试\nfilename: summary.md\nsummary: 这是文档描述。\n\n# 测试正文\n\n文档内容保持独立。\n</document>\n\n保留摘要下方的回复正文。"
                return (200, [
                    ["id": "40000000-0000-4000-8000-000000000063", "role": "user", "content": "整理资料并生成文件。", "seq": 1, "created_at": date],
                    ["id": "40000000-0000-4000-8000-000000000064", "role": "assistant", "content": reply,
                     "thinking": ChatReasoningSummaryStorage.encode(summary) ?? "", "seq": 2, "created_at": date]
                ].reversed().map { $0 })
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-test-document-reference") {
                var reply = "<document>\ntitle: 文章 慢下来\nfilename: 文章 慢下来.md\nsummary: 撰写一篇主题自选的文章。\n\n" + NativeRuntimeFixture.referenceArticle + "\n</document>\n\n我写了一篇关于\"慢下来\"的短文,放在上面的文件里了。想换主题或风格(比如更幽默、更正式),告诉我就行。"
                if ProcessInfo.processInfo.arguments.contains("--ui-test-multiple-documents") {
                    reply += "\n\n<document>\ntitle: 阅读笔记\nfilename: notes.md\nsummary: 整理文章中的要点。\n\n# 阅读笔记\n\n每天留一点时间，把注意力放回此刻。\n</document>"
                }
                return (200, [
                    ["id": "40000000-0000-4000-8000-000000000063", "role": "user", "content": "随便用文件写一篇文章给我。", "seq": 1, "created_at": date],
                    ["id": "40000000-0000-4000-8000-000000000064", "role": "assistant", "content": reply, "seq": 2, "created_at": date]
                ].reversed().map { $0 })
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-test-uploaded-file-reference") {
                let doc = ChatDocument(id: "fixture-original", title: "How the Ideas Came Together", filename: "reasoning-throughs.pdf", content: "# How the Ideas Came Together\n\nThis is the original sample PDF used to validate file attachment preview and recovery.", isMarkdown: true)
                let bytes = try! Data(contentsOf: doc.downloadURL())
                let preview = try! ChatFilePreview.save(data: bytes, name: "reasoning-throughs.pdf", contentType: "application/pdf")
                let metadata = try! JSONSerialization.jsonObject(with: JSONEncoder().encode([preview]))
                return (200, [["id": "40000000-0000-4000-8000-000000000063", "role": "user", "content": "", "file_previews": metadata, "seq": 1, "created_at": date]])
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-test-claude-layout") {
                let reply = """
                # Swift Demo

                ## Overview

                Here's a quick look at Swift essentials:

                - **Type Safety:** Swift catches errors at compile time, not runtime
                - **Optionals:** Safely handle values that may or may not exist
                - **Closures:** Pass functions around like any other value

                | Feature | Benefit |
                | --- | --- |
                | Type inference | Less boilerplate |
                | Memory safety | No buffer overflows |
                | Modern syntax | Readable, concise |

                ```swift
                let numbers = [1, 2, 3, 4, 5]
                let doubled = numbers.map { $0 * 2 }
                print(doubled) // [2, 4, 6, 8, 10]
                ```
                """
                return (200, [
                    ["id": "40000000-0000-4000-8000-000000000063", "conversation_id": NativeRuntimeFixture.conversationID,
                     "role": "user", "content": "Show a short Markdown demo with a heading, 3 bullets, a small table and Swift code.", "seq": 1, "created_at": date],
                    ["id": "40000000-0000-4000-8000-000000000064", "conversation_id": NativeRuntimeFixture.conversationID,
                     "role": "assistant", "content": reply, "seq": 2, "created_at": date]
                ].reversed().map { $0 })
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-test-reference-chat") {
                return (200, [
                    ["id": "40000000-0000-4000-8000-000000000063", "conversation_id": NativeRuntimeFixture.conversationID,
                     "role": "user", "content": "你好", "seq": 1, "created_at": date],
                    ["id": "40000000-0000-4000-8000-000000000064", "conversation_id": NativeRuntimeFixture.conversationID,
                     "role": "assistant", "content": "你好！有什么我可以帮你的吗？", "seq": 2, "created_at": date]
                ].reversed().map { $0 })
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-test-long-chat") {
                let rows: [[String: Any]] = (1...1_000).map { index in
                    let role = index.isMultiple(of: 2) ? "assistant" : "user"
                    let content = role == "assistant"
                        ? "长聊天第 \(index) 条回复：这是用于滚动压力测试的合成历史消息。\n\n## 要点\n- 保留前文上下文\n- 支持 Markdown 排版\n\n| 项目 | 内容 |\n| --- | --- |\n| 序号 | \(index) |\n\n[测试来源](https://example.invalid/reference/\(index))\n\n```json\n{\"seq\": \(index)}\n```"
                        : "长聊天第 \(index) 条用户消息：这是用于滚动压力测试的合成历史消息。"
                    return [
                        "id": String(format: "50000000-0000-4000-8000-%012x", index),
                        "role": role,
                        "content": content,
                        "seq": index,
                        "created_at": date,
                    ]
                }
                return (200, rows.reversed().map { $0 })
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-test-images") {
                let image = NativeRuntimeFixture.imageSource
                let multiImages = Array(repeating: image, count: ProcessInfo.processInfo.arguments.contains("--ui-test-wide-images") ? 5 : 2)
                return (200, [
                    ["id": "50000000-0000-4000-8000-000000000064", "role": "user", "content": "纯文字靠右", "seq": 1, "created_at": date],
                    ["id": "50000000-0000-4000-8000-000000000065", "role": "user", "content": "", "images": ["refs": [image]], "seq": 2, "created_at": date],
                    ["id": "50000000-0000-4000-8000-000000000066", "role": "user", "content": "图片加文字靠右", "images": ["refs": multiImages], "seq": 3, "created_at": date],
                    ["id": "60000000-0000-4000-8000-000000000064", "role": "assistant", "content": "中文回复靠左。\n\nEnglish typography stays unchanged.", "seq": 4, "created_at": date]
                ].reversed().map { $0 })
            }
            return (200, [["id": "50000000-0000-4000-8000-000000000064", "role": "user", "content": "中文用户消息靠右", "seq": 1, "created_at": date],
                ["id": "60000000-0000-4000-8000-000000000064", "role": "assistant", "seq": 2,
                 "content": "中文回复使用苹方。\n\nEnglish typography stays unchanged.\n\n```json\n{\"audit\":true}\n```", "created_at": date]].reversed().map { $0 })
        case "/rest/v1/projects":
            if method == "GET", ProcessInfo.processInfo.arguments.contains("--ui-test-no-projects") { return (200, []) }
            if method == "DELETE" { deletedProjects.insert(NativeRuntimeFixture.projectID); return (200, []) }
            return (200, deletedProjects.isEmpty ? [["id": NativeRuntimeFixture.projectID, "name": "隔离测试项目", "instructions": "测试", "created_at": date]] : [])
        case "/rest/v1/artifacts":
            if method == "POST" {
                let row: [String: Any] = [
                    "id": body["id"] as? String ?? UUID().uuidString.lowercased(),
                    "user_id": body["user_id"] as? String ?? NativeRuntimeFixture.userID,
                    "conversation_id": body["conversation_id"] as? String ?? NativeRuntimeFixture.conversationID,
                    "message_id": body["message_id"] as? String ?? UUID().uuidString.lowercased(),
                    "title": body["title"] as? String ?? "Untitled artifact",
                    "raw": body["raw"] as? String ?? "",
                    "created_at": date,
                    "updated_at": date,
                ]
                if let index = savedArtifacts.firstIndex(where: { $0["message_id"] as? String == row["message_id"] as? String }) {
                    savedArtifacts[index] = row
                } else {
                    savedArtifacts.insert(row, at: 0)
                }
                return (201, [row])
            }
            if ProcessInfo.processInfo.arguments.contains("--ui-test-document-library") {
                return (200, [["id": "70000000-0000-4000-8000-000000000065",
                    "title": "两个文件", "raw": "<document>\ntitle: 第一篇文章\nfilename: first.md\nsummary: 撰写第一篇文章。\n# 第一篇正文\n\n第一份完整内容。</document>\n<document>\ntitle: 第二篇文章\nfilename: second.md\n# 第二篇正文\n\n第二份完整内容。</document>",
                    "conversation_id": NativeRuntimeFixture.conversationID,
                    "message_id": "60000000-0000-4000-8000-000000000065",
                    "project_id": NSNull(), "created_at": date, "updated_at": date]])
            }
            let largeArtifactFixture = ProcessInfo.processInfo.arguments.contains("--ui-test-artifacts-large")
            let svgArtifactFixture = ProcessInfo.processInfo.arguments.contains("--ui-test-artifacts-svg-large")
            if ProcessInfo.processInfo.arguments.contains("--ui-test-artifacts") || largeArtifactFixture || svgArtifactFixture {
                return (200, [[
                    "id": "70000000-0000-4000-8000-000000000064",
                    "title": "动画咖啡杯",
                    "raw": svgArtifactFixture
                        ? NativeRuntimeFixture.largeArtifactSVG
                        : largeArtifactFixture
                        ? NativeRuntimeFixture.largeArtifactHTML
                        : "<html><body><h1>Artifact preview</h1><p>Fixture artifact.</p></body></html>",
                    "conversation_id": NativeRuntimeFixture.conversationID,
                    "message_id": "60000000-0000-4000-8000-000000000064",
                    "project_id": NSNull(),
                    "created_at": date,
                    "updated_at": date,
                ]])
            }
            return (200, savedArtifacts)
        case "/rest/v1/profiles": return (200, [])
        default:
            if path == "/api/agent/tasks/88000000-0000-4000-8000-000000000075/workspace"
                || path == "/api/agent/tasks/88000000-0000-4000-8000-000000000075/workspace/diff" {
                guard method == "GET", ProcessInfo.processInfo.arguments.contains("--ui-test-code-diff") else {
                    return (404, ["error": "Fixture diff capability is unavailable"])
                }
                let snapshotID = "99000000-0000-4000-8000-000000000075"
                let digest = String(repeating: "a", count: 64), head = String(repeating: "b", count: 40)
                if !path.hasSuffix("/diff") {
                    return (200, ["status": "durable", "repo": "mychat/test-app", "branch": "main",
                        "snapshotId": snapshotID, "manifestDigest": digest, "commit": head, "version": 7])
                }
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if query.isEmpty {
                    return (200, ["diff": "旧版更改摘要，不能当作 patch", "diffFormat": "cas-change-summary",
                        "snapshotId": snapshotID, "manifestDigest": digest, "head": head, "hasChanges": true,
                        "changedFiles": [["path": "README.md", "status": "modified"], ["path": "image.bin", "status": "added"]],
                        "summary": ["added": 1, "modified": 1, "deleted": 0]])
                }
                let keys = ["format", "path", "snapshotId", "manifestDigest", "head", "version"]
                guard query.count == keys.count, Set(query.map(\.name)) == Set(keys),
                      query.first(where: { $0.name == "format" })?.value == "unified",
                      query.first(where: { $0.name == "snapshotId" })?.value == snapshotID,
                      query.first(where: { $0.name == "manifestDigest" })?.value == digest,
                      query.first(where: { $0.name == "head" })?.value == head,
                      query.first(where: { $0.name == "version" })?.value == "7",
                      let selected = query.first(where: { $0.name == "path" })?.value,
                      ["README.md", "image.bin"].contains(selected) else {
                    return (400, ["error": "Fixture requires an exact immutable diff selection"])
                }
                if ProcessInfo.processInfo.arguments.contains("--ui-test-code-diff-stale") {
                    return (409, ["error": "工作区已更新，请刷新后再查看差异"])
                }
                var payload: [String: Any] = ["schemaVersion": 1, "path": selected,
                    "scope": ["userId": NativeRuntimeFixture.userID, "taskId": "88000000-0000-4000-8000-000000000075",
                        "repository": "mychat/test-app", "snapshotId": snapshotID, "manifestDigest": digest, "head": head, "version": 7]]
                if selected == "image.bin" {
                    payload["status"] = "omitted"; payload["format"] = "none"; payload["reason"] = "binary"
                } else {
                    payload["status"] = "ready"; payload["format"] = "unified"
                    payload["patch"] = "diff --git a/README.md b/README.md\n--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n-before\n+after\n"
                }
                return (200, payload)
            }
            if path.hasPrefix("/api/v1/jobs/"), path.hasSuffix("/cancel"), method == "POST",
               ProcessInfo.processInfo.arguments.contains("--ui-test-code-cancel-lost-sse") {
                Thread.sleep(forTimeInterval: 0.4)
                codeCancellationCount += 1
                if ProcessInfo.processInfo.arguments.contains("--ui-test-code-cancel-first-fails"),
                   codeCancellationCount == 1 {
                    return (503, ["error": "隔离测试：模拟取消服务失败"])
                }
                let jobID = url.pathComponents.dropLast().last ?? ""
                return (202, ["jobId": jobID, "accepted": true, "replayed": false,
                              "status": "cancelling", "eventSeq": 1])
            }
            if path.hasPrefix("/api/conversations/"), method == "DELETE" {
                deletedConversations.insert(url.lastPathComponent); return (200, ["ok": true])
            }
            let emptyReadTables = ["jobs", "job_events", "project_files", "project_memories",
                "code_messages", "code_memories", "agent_tasks"]
            if method == "GET", emptyReadTables.contains(where: { path == "/rest/v1/" + $0 }) {
                return (200, [])
            }
            if path == "/auth/v1/user" { return (200, ["id": NativeRuntimeFixture.userID, "email": "runtime-audit@example.invalid"]) }
            return (503, ["error": "隔离测试未配置这个请求路径：\(path)"])
        }
    }
}
#endif
