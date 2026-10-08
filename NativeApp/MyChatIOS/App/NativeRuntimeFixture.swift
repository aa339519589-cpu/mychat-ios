#if DEBUG
import Foundation
import CryptoKit
import UIKit

/// Deterministic, network-isolated runtime testing. Never used in Release.
enum NativeRuntimeFixture {
    static let userID = "10000000-0000-4000-8000-000000000064"
    static let conversationID = "20000000-0000-4000-8000-000000000064"
    static let projectID = "30000000-0000-4000-8000-000000000064"

    @MainActor static func makeModel(dataClient: (any SupabaseDataServing)? = nil,
        workspaceClient: (any WorkspaceDataServing)? = nil,
        chatClient: any ChatAPIServing = ChatAPIClient(), stream: any ChatEventStreaming = JobEventStream()) -> AppModel {
        if ProcessInfo.processInfo.arguments.contains("--ui-test-mode") {
            UserDefaults.standard.removeObject(forKey: "mychat.account-settings-cache.v1." + userID)
            if let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                try? FileManager.default.removeItem(at: base.appendingPathComponent("MyChatConversationCache/" + userID + ".json"))
            }
        }
        URLProtocol.registerClass(NativeAuditURLProtocol.self)
        return AppModel(authenticationClient: SupabaseAuthClient(sessionStore: AuditSessionStore()),
            dataClient: dataClient ?? SupabaseDataClient(),
            workspaceClient: workspaceClient ?? WorkspaceDataClient(),
            chatClient: chatClient, jobEventStream: stream)
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
        let path = url.path
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
        case "/api/models":
            if ProcessInfo.processInfo.arguments.contains("--ui-test-claude-models") {
                let routes = [("anthropic/claude-fable-5-1", "Claude Fable 5.1"),
                    ("anthropic/claude-opus-5-5", "Claude Opus 5.5"),
                    ("anthropic/claude-sonnet-5-5", "Claude Sonnet 5.5"),
                    ("anthropic/claude-sonnet-5", "Claude Sonnet 5"),
                    ("anthropic/claude-haiku-5.5", "Claude Haiku 5.5"),
                    ("anthropic/claude-haiku-4.5", "Claude Haiku 4.5")]
                let models: [[String: Any]] = routes.map { id, name in
                    ["id": id, "name": name, "provider": "Anthropic", "access": "quota", "outputKind": "chat",
                     "promptPrice": 0, "completionPrice": 0, "contextLength": 100000,
                     "vision": true, "tools": true, "flagship": false,
                     "reasoningEfforts": ["none", "low", "medium", "high", "xhigh", "max"],
                     "defaultReasoningEffort": "medium", "reasoningMandatory": false]
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
        case "/api/endpoints": return (200, ["endpoints": []])
        case "/rest/v1/code_sessions":
            guard ProcessInfo.processInfo.arguments.contains("--ui-test-code-display") else { return (200, []) }
            let id = "80000000-0000-4000-8000-000000000064"
            let provisionalRepository = "__mychat_new__/" + id
            return (200, [
                ["id": id, "repo": provisionalRepository, "title": provisionalRepository, "created_at": date, "updated_at": date],
                ["id": "80000000-0000-4000-8000-000000000065", "repo": provisionalRepository, "title": "继续当前任务", "created_at": date, "updated_at": date],
                ["id": "80000000-0000-4000-8000-000000000066", "repo": "mychat/test-app", "title": "修复登录边界", "created_at": date, "updated_at": date],
            ])
        case "/api/code/tasks":
            guard ProcessInfo.processInfo.arguments.contains("--ui-test-code-display") else {
                return (503, ["error": "隔离测试未配置任务恢复"])
            }
            return (200, ["task": NSNull(), "admission": NSNull()])
        case "/api/connectors": return (200, ["connectors": []])
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
            if ProcessInfo.processInfo.arguments.contains("--ui-test-artifacts") {
                return (200, [[
                    "id": "70000000-0000-4000-8000-000000000064",
                    "title": "动画咖啡杯",
                    "raw": "<html><body><h1>Artifact preview</h1><p>Fixture artifact.</p></body></html>",
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
            if path.hasPrefix("/api/conversations/"), method == "DELETE" {
                deletedConversations.insert(url.lastPathComponent); return (200, ["ok": true])
            }
            if path.hasPrefix("/rest/v1/") { return (200, []) }
            if path == "/auth/v1/user" { return (200, ["id": NativeRuntimeFixture.userID, "email": "runtime-audit@example.invalid"]) }
            return (503, ["error": "隔离测试未配置这个请求路径：\(path)"])
        }
    }
}
#endif
