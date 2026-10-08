import XCTest
import CoreText
import UIKit
import SwiftUI
@testable import MyChat

@MainActor final class CodeWorkspaceTests: XCTestCase {
    func testChineseFallbackTracksSmallFontsAndDynamicType() throws {
        let sample = "推荐编程当前对话" as CFString
        for size: CGFloat in [12, 12.5, 14, 17, 25] {
            let base = MyChatSystemFont.appUIFont(size: size)
            let fallback = CTFontCreateForString(base, sample, CFRange(location: 0, length: 8))
            XCTAssertEqual(CTFontGetSize(fallback), size, accuracy: 0.01)
            let descriptors = try XCTUnwrap(base.fontDescriptor.fontAttributes[.cascadeList] as? [UIFontDescriptor])
            for descriptor in descriptors {
                XCTAssertEqual((descriptor.fontAttributes[.size] as? NSNumber)?.doubleValue ?? 0, Double(size), accuracy: 0.01)
            }
        }
        for category in [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            let traits = UITraitCollection(preferredContentSizeCategory: category)
            let font = MyChatSystemFont.scaledUIFont(MyChatSystemFont.appUIFont(size: 12.5),
                relativeTo: .caption1, compatibleWith: traits)
            let descriptors = try XCTUnwrap(font.fontDescriptor.fontAttributes[.cascadeList] as? [UIFontDescriptor])
            for descriptor in descriptors {
                XCTAssertEqual((descriptor.fontAttributes[.size] as? NSNumber)?.doubleValue ?? 0, Double(font.pointSize), accuracy: 0.01)
            }
            let reference = MyChatSystemFont.scaledUIFont(MyChatSystemFont.hanUIFont(size: 12.5),
                relativeTo: .caption1, compatibleWith: traits)
            func render(_ font: UIFont) throws -> UIImage {
                let renderer = ImageRenderer(content: Text("推荐").font(Font(font)).foregroundStyle(.black).lineLimit(1).fixedSize())
                renderer.scale = 3
                return try XCTUnwrap(renderer.uiImage)
            }
            let actual = try render(font)
            let expected = try render(reference)
            // A same-size direct Han run is the full-glyph reference. This
            // catches the bridge bug that CoreText size assertions miss.
            let actualInk = try glyphInkBounds(actual)
            let expectedInk = try glyphInkBounds(expected)
            XCTAssertEqual(actualInk.width, expectedInk.width, accuracy: 1)
            XCTAssertEqual(actualInk.height, expectedInk.height, accuracy: 1)
            let canvas = VStack(alignment: .leading, spacing: 14) {
                Text("推荐 · 当前对话 · 打开新对话").font(Font(font)).lineLimit(1)
                Text("一篇关于夜晚、咖啡与安静阅读的温柔短文。").font(Font(font)).lineLimit(1)
                TextField("回复 MyChat", text: .constant("推荐编程输入框")).font(Font(font))
            }.foregroundStyle(.black).padding(20).frame(width: 390, alignment: .leading).background(.white)
            let renderer = ImageRenderer(content: canvas); renderer.scale = 3
            if let image = renderer.uiImage {
                let attachment = XCTAttachment(image: image)
                attachment.name = "font-cascade-fixed-" + category.rawValue
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    private func glyphInkBounds(_ image: UIImage) throws -> CGRect {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 127 {
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        XCTAssertGreaterThanOrEqual(maxX, minX)
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
    func testCodeDisplayHidesInternalIdentifiersWithoutChangingStoredValues() {
        let id = "11111111-1111-1111-1111-111111111111"
        let internalRepository = "__mychat_new__/" + id
        let internalSession = CodeSessionRecord(id: id, repository: internalRepository,
            title: internalRepository, createdAt: nil, updatedAt: nil)
        XCTAssertEqual(internalSession.displayTitle, "新建会话")
        XCTAssertNil(internalSession.displayRepository)
        XCTAssertEqual(internalSession.repository, internalRepository)
        XCTAssertEqual(internalSession.title, internalRepository)
        for title in ["", "   ", id, "__mychat_new__"] {
            XCTAssertNil(CodeDisplay.title(title, sessionID: id))
        }
        for repo in ["", "owner/", "/repo", "../repo", "owner/repo/extra", "owner/repo\nprivate"] {
            XCTAssertNil(CodeDisplay.repository(repo))
        }
        XCTAssertEqual(CodeDisplay.repository(" aa339519589-cpu/mychat-ios "), "aa339519589-cpu/mychat-ios")
        XCTAssertEqual(CodeDisplay.title(" 修复登录边界 ", sessionID: id), "修复登录边界")
    }

    func testDraftSurvivesReloadAndIsIsolatedByOwnerAndSession() {
        let owner = "code-test-" + UUID().uuidString
        defer { CodeLocalState.clear(owner: owner, scope: "new") }
        let value = CodeDraftRecord(prompt: "修复真正的测试失败", repository: "owner/repo", branch: "feature/review")
        CodeLocalState.save(value, owner: owner, scope: "new")
        XCTAssertEqual(CodeLocalState.draft(owner: owner, scope: "new"), value)
        XCTAssertEqual(CodeLocalState.draft(owner: owner + "-other", scope: "new"), CodeDraftRecord())
        XCTAssertEqual(CodeLocalState.draft(owner: owner, scope: "session-other"), CodeDraftRecord())
        CodeLocalState.clear(owner: owner, scope: "new")
        XCTAssertEqual(CodeLocalState.draft(owner: owner, scope: "new"), CodeDraftRecord())
    }

    func testDeepLinkRequiresAuthenticationAndNeverSubmits() {
        let model = AppModel()
        model.openCodeLink(URL(string: "mychat://code/new?q=fix")!)
        XCTAssertNil(model.pendingCodeLink)
        XCTAssertEqual(model.selectedDestination, .chats)
    }

    func testRecoveryDecodesDurableTaskEvidenceAndRelativeStream() throws {
        let payload = #"{"sessionId":"11111111-1111-1111-1111-111111111111","admission":{"schemaVersion":1,"jobId":"22222222-2222-2222-2222-222222222222","taskId":"33333333-3333-3333-3333-333333333333","responseId":"44444444-4444-4444-4444-444444444444","status":"completed","created":false,"streamUrl":"/api/v1/jobs/22222222-2222-2222-2222-222222222222/events?from_seq=0","eventSequence":12},"task":{"id":"33333333-3333-3333-3333-333333333333","status":"completed","branch":"main","error":null,"pullRequestUrl":null,"toolCalls":[{"id":"tool-1","toolName":"shell.exec","status":"success","output":{"exitCode":0,"stdout":"test passed"},"error":null,"durationMs":40}],"artifacts":[{"id":"artifact-1","kind":"diff","title":"Changes","content":"+ actual change","url":null}]}}"#
        let recovery = try JSONDecoder().decode(CodeTaskRecovery.self, from: Data(payload.utf8))
        XCTAssertEqual(recovery.task?.toolCalls.first?.toolName, "shell.exec")
        XCTAssertEqual(recovery.task?.artifacts.first?.kind, "diff")
        XCTAssertEqual(recovery.admission?.status, "completed")
        XCTAssertNotNil(recovery.sessionId)
    }

    func testFactoryModelAndReasoningDefaultsAreHaikuMediumAndToolsAreEnabled() async throws {
        let keys = factoryPreferenceKeys
        let previous = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { restoreFactoryPreferences(previous) }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        let model = AppModel(catalogClient: FactoryCatalogFixture())
        XCTAssertEqual(model.selectedModelID, "anthropic/claude-haiku-5.5")
        XCTAssertEqual(model.reasoningEffort, "medium")
        XCTAssertTrue(model.webSearchEnabled)
        XCTAssertTrue(model.renderEnabled)
        XCTAssertTrue(model.historyRetrievalEnabled)
        XCTAssertTrue(model.memoryEnabled)
        await model.reloadModels()
        XCTAssertEqual(model.selectedModel?.id, ModelCatalogItem.defaultChatModelID)
        XCTAssertEqual(model.codeRequestReasoningEffort, "medium")
        model.beginNewChat()
        XCTAssertEqual(model.selectedModelID, ModelCatalogItem.defaultChatModelID)
        XCTAssertEqual(model.reasoningEffort, "medium")
        XCTAssertTrue(model.activeConversationMemoryEnabled)
    }

    func testExplicitModelOffPreferencesAndImageRouteSurviveReload() async throws {
        let previous = factoryPreferenceKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { restoreFactoryPreferences(previous) }
        UserDefaults.standard.set("anthropic/claude-sonnet-5.5", forKey: "mychat.selected-model.v1")
        UserDefaults.standard.set("none", forKey: "mychat.reasoning-effort.anthropic/claude-sonnet-5.5")
        UserDefaults.standard.set(false, forKey: "mychat.web-search-enabled.v1")
        UserDefaults.standard.set(false, forKey: "mychat.render-enabled.v1")
        let model = AppModel(catalogClient: FactoryCatalogFixture())
        await model.reloadModels()
        XCTAssertEqual(model.selectedModelID, "anthropic/claude-sonnet-5.5")
        XCTAssertEqual(model.reasoningEffort, "none")
        XCTAssertEqual(model.codeRequestReasoningEffort, "none")
        XCTAssertFalse(model.webSearchEnabled)
        XCTAssertFalse(model.renderEnabled)
        model.beginNewChat()
        XCTAssertEqual(model.selectedModelID, "anthropic/claude-sonnet-5.5")
        XCTAssertEqual(model.reasoningEffort, "none")
        let image = try XCTUnwrap(model.models.first { $0.outputKind == .image })
        model.selectModel(image)
        await model.reloadModels()
        XCTAssertEqual(model.selectedModelID, "configured-image-model")
        XCTAssertEqual(model.selectedModel?.outputKind, .image)
        XCTAssertEqual(model.reasoningEffort, "none", "Unsupported reasoning is never sent to an image route")
    }

    func testImplicitOldCatalogFallbackDoesNotBecomeAnExplicitStartupPreference() async throws {
        let previous = factoryPreferenceKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { restoreFactoryPreferences(previous) }
        factoryPreferenceKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        let payload = try await FactoryCatalogFixture().fetchCatalog(accessToken: nil)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload.models[0])) as? [String: Any])
        old["id"] = "anthropic/claude-fable-5.1"; old["name"] = "Claude Fable 5.1"
        let fable = try JSONDecoder().decode(ModelCatalogItem.self, from: JSONSerialization.data(withJSONObject: old))
        let model = AppModel(catalogClient: FactoryCatalogSequence(old: [fable], current: payload.models))
        await model.reloadModels()
        XCTAssertEqual(model.selectedModelID, fable.id)
        XCTAssertNil(UserDefaults.standard.string(forKey: "mychat.selected-model.v1"))
        await model.reloadModels()
        XCTAssertEqual(model.selectedModelID, ModelCatalogItem.defaultChatModelID)
        XCTAssertEqual(model.reasoningEffort, "medium")
    }

    func testCodeDraftIgnoresRetiredModeAndCapabilitiesRequireNoModeChoices() throws {
        let legacy = Data(#"{"prompt":"keep draft","repository":"owner/repo","branch":"feature","mode":"legacy"}"#.utf8)
        let draft = try JSONDecoder().decode(CodeDraftRecord.self, from: legacy)
        XCTAssertEqual(draft.prompt, "keep draft")
        XCTAssertEqual(draft.repository, "owner/repo")
        XCTAssertEqual(draft.branch, "feature")
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
        XCTAssertNil(encoded["mode"])
        let wire = Data(#"{"schemaVersion":1,"cloudOnly":true,"durableQueue":true,"execution":{"backend":"isolated","location":"cloud","configured":true,"verified":false,"reason":null}}"#.utf8)
        let capabilities = try JSONDecoder().decode(CodeCapabilities.self, from: wire)
        XCTAssertEqual(capabilities.cloudOnly, true)
        XCTAssertEqual(capabilities.execution.location, "cloud")
    }

    func testChatAndCodeWireRequestsCarryFactoryDefaultsAndExplicitOverrides() async throws {
        FactoryRequestURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FactoryRequestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); FactoryRequestURLProtocol.reset() }
        let base = URL(string: "https://defaults.invalid")!
        let chat = ChatAPIClient(session: session, baseURL: base)
        let code = CodeAPIClient(session: session, baseURL: base)
        let message = ChatMessage(id: UUID(), role: .user, content: "default parameters", thinking: nil, createdAt: Date())
        let defaultChat = ChatAppendCommand(conversationID: UUID(), userMessage: message,
            createConversation: true, title: "default")
        _ = try await chat.enqueueAppendTurn(defaultChat, accessToken: "fixture-only-token")
        let defaultCode = CodeChatCommand(repository: "owner/repo", messages: [.init(role: "user", content: "default")],
            taskID: UUID(), responseID: UUID(), sessionID: UUID())
        _ = try await code.enqueue(defaultCode, accessToken: "fixture-only-token")
        XCTAssertEqual(defaultCode.mode, "code")
        let overrideChat = ChatAppendCommand(conversationID: UUID(), userMessage: message,
            modelID: "anthropic/claude-sonnet-5.5", reasoningEffort: ChatReasoningEffort.none,
            tools: ChatToolSelection(searchMode: .off, historyRetrieval: false, renderEnabled: false),
            createConversation: true, conversationMemoryEnabled: false, title: "override")
        _ = try await chat.enqueueAppendTurn(overrideChat, accessToken: "fixture-only-token")
        let overrideCode = CodeChatCommand(repository: "owner/repo", modelID: "anthropic/claude-sonnet-5.5",
            reasoningEffort: "none", messages: [.init(role: "user", content: "override")],
            taskID: UUID(), responseID: UUID(), sessionID: UUID())
        _ = try await code.enqueue(overrideCode, accessToken: "fixture-only-token")
        let bodies = FactoryRequestURLProtocol.bodies
        XCTAssertEqual(bodies.count, 4)
        for body in bodies.prefix(2) {
            XCTAssertEqual(body["modelId"] as? String, "anthropic/claude-haiku-5.5")
            XCTAssertEqual(body["reasoningEffort"] as? String, "medium")
        }
        XCTAssertEqual(bodies[0]["searchMode"] as? String, "web")
        XCTAssertEqual(bodies[0]["historyRetrieval"] as? Bool, true)
        XCTAssertEqual(bodies[0]["renderEnabled"] as? Bool, true)
        XCTAssertEqual((bodies[0]["turn"] as? [String: Any])?["memoryEnabled"] as? Bool, true)
        XCTAssertEqual(bodies[0]["generateImage"] as? Bool, false, "Enabling image tools does not replace the chat model")
        XCTAssertEqual(bodies[1]["mode"] as? String, "code")
        for body in bodies.suffix(2) {
            XCTAssertEqual(body["modelId"] as? String, "anthropic/claude-sonnet-5.5")
            XCTAssertEqual(body["reasoningEffort"] as? String, "none")
        }
        XCTAssertEqual(bodies[2]["searchMode"] as? String, "off")
        XCTAssertEqual(bodies[2]["renderEnabled"] as? Bool, false)
        XCTAssertEqual(bodies[2]["historyRetrieval"] as? Bool, false)
        XCTAssertEqual((bodies[2]["turn"] as? [String: Any])?["memoryEnabled"] as? Bool, false)
    }

    private var factoryPreferenceKeys: [String] {
        ["mychat.selected-model.v1", "mychat.web-search-enabled.v1", "mychat.render-enabled.v1",
         "mychat.reasoning-effort.anthropic/claude-haiku-5.5",
         "mychat.reasoning-effort.anthropic/claude-sonnet-5.5",
         "mychat.reasoning-effort.configured-image-model"]
    }

    private func restoreFactoryPreferences(_ values: [(String, Any?)]) {
        for (key, value) in values {
            if let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }
}

private struct FactoryCatalogFixture: ModelCatalogServing {
    func fetchCatalog(accessToken: String?) async throws -> ModelCatalogPayload {
        let rows: [[String: Any]] = [
            ["id": "anthropic/claude-sonnet-5.5", "name": "Claude Sonnet 5.5", "provider": "Anthropic", "outputKind": "chat"],
            ["id": "anthropic/claude-haiku-5.5", "name": "Claude Haiku 5.5", "provider": "Anthropic", "outputKind": "chat"],
            ["id": "configured-image-model", "name": "Configured image model", "provider": "Image provider", "outputKind": "image"],
        ].map { row in
            row.merging(["access": "quota", "promptPrice": 0, "completionPrice": 0, "contextLength": 100000,
                "vision": true, "tools": true, "flagship": false,
                "reasoningEfforts": row["outputKind"] as? String == "chat" ? ["none", "low", "medium", "high"] : [],
                "defaultReasoningEffort": "none", "reasoningMandatory": false]) { original, _ in original }
        }
        let payload: [String: Any] = ["schemaVersion": 1, "configured": true, "owner": true, "trialLimit": 3, "models": rows]
        return try JSONDecoder().decode(ModelCatalogPayload.self, from: JSONSerialization.data(withJSONObject: payload))
    }
}

private actor FactoryCatalogSequence: ModelCatalogServing {
    let old: [ModelCatalogItem]
    let current: [ModelCatalogItem]
    private var fetched = false
    init(old: [ModelCatalogItem], current: [ModelCatalogItem]) { self.old = old; self.current = current }
    func fetchCatalog(accessToken: String?) async throws -> ModelCatalogPayload {
        let rows = fetched ? current : old
        fetched = true
        return ModelCatalogPayload(schemaVersion: 1, configured: true, owner: true, trialLimit: 3,
            trialRemaining: nil, models: rows, error: nil)
    }
}

private final class FactoryRequestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var captured: [[String: Any]] = []
    static var bodies: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return captured }
    static func reset() { lock.lock(); defer { lock.unlock() }; captured = [] }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "defaults.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let capacity = bytes.count
            var body = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: capacity)
                if count <= 0 { break }
                body.append(contentsOf: bytes.prefix(count))
            }
            data = body
        }
        let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        Self.lock.lock(); Self.captured.append(body); Self.lock.unlock()
        let job = UUID().uuidString.lowercased()
        var accepted: [String: Any] = ["schemaVersion": 1, "jobId": job, "status": "queued", "created": true,
            "streamUrl": "/api/v1/jobs/\(job)/events?from_seq=0"]
        if request.url?.path == "/api/code/chat" {
            accepted["taskId"] = body["taskId"] ?? UUID().uuidString.lowercased()
            accepted["responseId"] = body["responseId"]
        } else {
            for key in ["generationId", "userMessageId", "assistantMessageId"] { accepted[key] = body[key] }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: accepted)) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
