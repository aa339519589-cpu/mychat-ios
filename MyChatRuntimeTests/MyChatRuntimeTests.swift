import XCTest
import SwiftUI
import Speech
import WebKit
import PDFKit
@testable import MyChat

@MainActor final class MyChatRuntimeTests: XCTestCase {
    override func setUp() { super.setUp(); URLProtocol.registerClass(NativeAuditURLProtocol.self) }

    func testStreamingArtifactKeepsCompleteTokensAndOriginalMessageOrder() {
        let prefix = #"<svg viewBox="0 0 300 200"><circle id="sun" cx="100" cy="100" r="20"/>"#
        let partial = prefix + #"<path d="M 0 0 L 20"#
        XCTAssertEqual(StreamingArtifactSource.renderableHTML(partial, streaming: true), prefix)
        XCTAssertEqual(StreamingArtifactSource.renderableHTML(prefix + "<!-- pending >", streaming: true), prefix)
        XCTAssertEqual(StreamingArtifactSource.renderableHTML("<style>svg { fill:", streaming: true), "")
        XCTAssertEqual(StreamingArtifactSource.renderableHTML(partial, streaming: false), partial)
        let source = "Before\n\n<inline-artifact>\(prefix)</svg></inline-artifact>\n\nAfter"
        let document = ChatPresentationCache.document(key: UUID().uuidString, source: source, streaming: false)
        XCTAssertEqual(document.blocks.count, 3)
        XCTAssertEqual(document.blocks.first, .paragraph("Before"))
        guard case .artifact = document.blocks[1] else { return XCTFail("Drawing moved out of its source position") }
        XCTAssertEqual(document.blocks.last, .paragraph("After"))
        let growing = ChatArtifactParser.parse("Before\n\n<inline-artifact>" + prefix)
        XCTAssertEqual(growing.blocks.first?.id, document.artifacts.first?.id)
    }

    func testStreamingArtifactPatchesSameCanvasWithoutDroppingDrawnNodes() async throws {
        let first = #"<svg viewBox="0 0 300 200"><circle id="sun" cx="100" cy="100" r="20"/>"#
        let coordinator = ArtifactSandboxView.Coordinator()
        let parent = ArtifactSandboxView(rawHTML: first, colorScheme: .light, isStreaming: true, inline: true, reduceMotion: true)
        let webView = parent.makeWebView(coordinator: coordinator)
        webView.frame = CGRect(x: 0, y: 0, width: 390, height: 260)
        defer { webView.stopLoading(); webView.navigationDelegate = nil }
        func evaluate(_ expression: String) async throws -> Bool {
            try await withCheckedThrowingContinuation { continuation in
                webView.evaluateJavaScript(expression, in: nil, in: .defaultClient) { result in
                    switch result {
                    case .success(let value): continuation.resume(returning: value as? Bool ?? false)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            }
        }
        func waitFor(_ expression: String) async throws {
            for _ in 0..<100 {
                if (try? await evaluate(expression)) == true { return }
                try await Task.sleep(for: .milliseconds(30))
            }
            XCTFail("Canvas never reached: \(expression)")
        }
        try await waitFor("document.getElementById('sun') !== null")
        _ = try await evaluate("window.originalSun = document.getElementById('sun'); true")
        coordinator.update(ArtifactSandboxView(rawHTML: first + #"<circle id="earth" cx="1"#,
            colorScheme: .light, isStreaming: true, inline: true, reduceMotion: true), in: webView)
        let complete = first + #"<circle id="earth" cx="180" cy="100" r="8"/></svg><script>document.body.remove()</script>"#
        coordinator.update(ArtifactSandboxView(rawHTML: complete,
            colorScheme: .dark, isStreaming: false, inline: true, reduceMotion: true), in: webView)
        try await waitFor("document.getElementById('earth') !== null")
        let result = try await evaluate("document.getElementById('sun') === window.originalSun && document.querySelectorAll('circle').length === 2 && document.querySelectorAll('script').length === 0 && document.body.style.padding === '0px'")
        XCTAssertTrue(result)
    }

    func testAppendingMathKeepsThePreviousVisibleHeight() async {
        var height: CGFloat = 96
        let parent = LaTeXMathWebView(source: "First $x$ and more text", mode: .inlineDocument, colorScheme: .light,
            fontSize: 18, paragraphTypography: .response, inlineHTML: "First $x$ and more text", renderedHeight: Binding(get: { height }, set: { height = $0 }))
        let coordinator = parent.makeCoordinator()
        coordinator.signature = "previous paragraph"
        coordinator.documentSignature = "light-inlineDocument-response-18.0"
        let web = WKWebView()
        parent.load(web, coordinator: coordinator)
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(height, 96, "Appending a chunk must not collapse the paragraph into a zero-height fallback")
        web.stopLoading()
    }

    func testNaturalMemoryInstructionWritesRealMemoryAPIAndRejectsOtherIDs() async throws {
        let transport = ControlledChatTransport()
        transport.privateReply = #"{"actions":[{"op":"create","topic":"Food","content":"喜欢苹果"}]}"#
        let model = NativeRuntimeFixture.makeModel(chatClient: transport, stream: transport)
        await model.restoreAuthenticationIfNeeded(); await model.reloadModels()
        try await model.interpretMemoryInstruction("记住我喜欢苹果", topic: nil)
        XCTAssertTrue(model.memories.contains { $0.topic == "Food" && $0.content == "喜欢苹果" })
        XCTAssertTrue(model.messages.isEmpty, "Memory editing must not append messages to the open chat")
        XCTAssertEqual(transport.commands.count, 0, "Memory editing must not enqueue a durable chat")
        transport.privateReply = #"{"actions":[{"op":"delete","id":"another-account-record"}]}"#
        do { try await model.interpretMemoryInstruction("删除", topic: "Food"); XCTFail("Unscoped ID was accepted") }
        catch { XCTAssertTrue(model.memories.contains { $0.topic == "Food" && $0.content == "喜欢苹果" }) }
    }

    func testHistoricalArtifactRecoverySavesMissingPackageWithoutOpeningChat() async throws {
        let source = "<inline-artifact><svg viewBox=\"0 0 100 100\"><circle r=\"20\"/></svg></inline-artifact>"
        NativeAuditURLProtocol.historicalTestContent = source
        defer { NativeAuditURLProtocol.historicalTestContent = nil }
        let model = NativeRuntimeFixture.makeModel()
        await model.restoreAuthenticationIfNeeded(); await model.reloadConversations(); await model.reloadWorkspaceData()
        await model.recoverHistoricalArtifacts()
        XCTAssertTrue(model.artifacts.contains { $0.messageID == "77700000-0000-4000-8000-000000000064" && $0.raw.contains("<svg") }, model.artifactsError ?? "No recovered artifact")
        XCTAssertTrue(model.messages.isEmpty)
        let count = model.artifacts.count
        await model.recoverHistoricalArtifacts()
        XCTAssertEqual(model.artifacts.count, count, "Repeated recovery must not duplicate a message's artifact")
    }

    func testChatGPTPlanRecoveryRecordRestoresOriginalTurnAndIsAccountScoped() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyChatPlanRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChatGPTPlanRecoveryStore(rootDirectory: root)
        let conversationID = UUID()
        let command = ChatAppendCommand(
            conversationID: conversationID,
            userMessage: ChatMessage(
                id: UUID(), role: .user, content: "恢复这条回答", thinking: nil,
                attachedFileNames: ["notes.txt"], createdAt: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            generationID: UUID(),
            assistantMessageID: UUID(),
            modelID: "\(ChatGPTPlanProvider.modelIDPrefix)gpt-6.1-sol",
            reasoningEffort: .high,
            tools: ChatToolSelection(
                searchMode: .web,
                historyRetrieval: true,
                renderEnabled: false,
                connectorAccessMode: .onDemand,
                connectorIDs: ["connector-a"]
            ),
            createConversation: false,
            title: "恢复测试",
            attachments: [ChatFileAttachment(
                name: "notes.txt", dataURL: "data:text/plain;base64,SGk=", isPDF: false,
                text: "附件正文", pageImages: nil
            )]
        )

        let saved = await store.save(command, userID: "user-a")
        XCTAssertTrue(saved)
        let restored = await store.loadAll(userID: "user-a")
        XCTAssertEqual(restored[conversationID], command)
        let otherUserRecords = await store.loadAll(userID: "user-b")
        XCTAssertTrue(otherUserRecords.isEmpty)

        await store.remove(userID: "user-a", conversationID: conversationID)
        let removedRecords = await store.loadAll(userID: "user-a")
        XCTAssertTrue(removedRecords.isEmpty)
    }

    func testPCMSpeechStartsBeforeEOFAndStopSwitchCompletionRetryAreSilent() async throws {
        PlaybackFixtureURLProtocol.audio = Data([0, 0, 255, 127, 0, 128, 0, 64])
        PlaybackFixtureURLProtocol.failNext = false
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlaybackFixtureURLProtocol.self]
        var sinks: [SilentPCMSink] = []
        let controller = SpeechPlaybackController(streamingConfiguration: config, sinkFactory: {
            let sink = SilentPCMSink(); sinks.append(sink); return sink
        })
        defer { controller.stop() }
        let first = UUID(), second = UUID()
        controller.toggle(messageID: first, text: "静音网络验收") { "fresh-fixture-token" }
        await waitForPlayback(controller, first, .playing)
        XCTAssertEqual(PlaybackFixtureURLProtocol.authorization, "Bearer fresh-fixture-token")
        XCTAssertLessThan(try XCTUnwrap(controller.firstAudioLatencyMilliseconds), 4000)
        XCTAssertEqual(sinks[0].samples.count, 4)
        controller.stop()
        XCTAssertTrue(sinks[0].stopped)
        XCTAssertEqual(controller.state(for: first), .idle)
        controller.toggle(messageID: first, text: "再次请求") { "fresh-fixture-token" }
        await waitForPlayback(controller, first, .playing)
        controller.toggle(messageID: second, text: "切换回复") { "fresh-fixture-token" }
        XCTAssertEqual(controller.state(for: first), .idle)
        await waitForPlayback(controller, second, .playing)
        sinks.last?.complete()
        await waitForPlayback(controller, second, .idle)
        PlaybackFixtureURLProtocol.failNext = true
        controller.toggle(messageID: first, text: "失败") { "fresh-fixture-token" }
        await waitForPlayback(controller, first, .failed)
        controller.toggle(messageID: first, text: "重试") { "fresh-fixture-token" }
        await waitForPlayback(controller, first, .playing)
    }

    func testPCMDecoderKeepsSampleBoundariesAndDeadlineIncludesAuthentication() async throws {
        var decoder = PCMFrameDecoder()
        XCTAssertTrue(decoder.decode(Data([0])).isEmpty)
        let values = decoder.decode(Data([128, 0, 0, 255, 127, 0]))
        XCTAssertEqual(values.count, 3)
        XCTAssertEqual(values[0], -1)
        XCTAssertEqual(values[1], 0)
        XCTAssertEqual(values[2], 32767.0 / 32768.0, accuracy: 0.000001)
        XCTAssertTrue(decoder.hasIncompleteSample)
        XCTAssertEqual(decoder.decode(Data([64]))[0], 0.5)
        XCTAssertFalse(decoder.hasIncompleteSample)
        let controller = SpeechPlaybackController(firstAudioDeadline: .milliseconds(50), sinkFactory: { SilentPCMSink() })
        let id = UUID()
        controller.toggle(messageID: id, text: "认证等待") { try await Task.sleep(for: .seconds(2)); return "late" }
        await waitForPlayback(controller, id, .failed, seconds: 1)
        XCTAssertNil(controller.firstAudioLatencyMilliseconds)
        controller.stop()
    }

    func testPackagedDocumentsPreserveContentAndExportRealPDFAndOriginalFiles() throws {
        let content = "# 慢下来的艺术\n\n留一点时间，把这一件事做好。"
        let parsed = ChatArtifactParser.parse("<document>title: 文章 慢下来\nfilename: 慢下来.pdf\n\n" + content + "</document>\n我写好了。")
        let block = try XCTUnwrap(parsed.blocks.first)
        XCTAssertEqual(block.kind, .document)
        let doc = try XCTUnwrap(ChatDocument.from(block))
        XCTAssertEqual(doc.title, "文章 慢下来")
        XCTAssertEqual(doc.content, content)
        XCTAssertEqual(parsed.displayText, "我写好了。")
        let url = try doc.downloadURL()
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(String(data: bytes.prefix(4), encoding: .utf8), "%PDF")
        XCTAssertGreaterThan(try XCTUnwrap(PDFDocument(data: bytes)).pageCount, 0)
        let original = Data("真实文件原件，不是重新拼出的文件。".utf8)
        let prepared = try AttachmentPreparation.prepareFile(data: original, name: "原件.md", mimeType: "text/markdown")
        let preview = try XCTUnwrap(prepared.preview)
        XCTAssertEqual(preview.byteCount, original.count)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(preview.fileURL)), original)
        let message = ChatMessage(id: UUID(), role: .user, content: "", thinking: nil, filePreviews: [preview], createdAt: Date())
        let restored = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(restored.filePreviews, [preview])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(restored.filePreviews?.first?.fileURL)), original)
        let package = "<document>title: 第一篇\nfilename: first.md\nsummary: 撰写文章。\n# 第一份</document>\n<document>title: 第二篇\nfilename: second.md\n# 第二份</document>"
        let documents = ChatDocument.documents(in: package, namespace: "record-one")
        XCTAssertEqual(documents.map(\.title), ["第一篇", "第二篇"])
        XCTAssertEqual(documents.first?.summary, "撰写文章。")
        XCTAssertEqual(Set(documents.map(\.id)).count, 2)
        XCTAssertNotEqual(documents.first?.id, ChatDocument.documents(in: package, namespace: "record-two").first?.id)
        XCTAssertEqual(try String(contentsOf: documents[1].downloadURL(), encoding: .utf8), "# 第二份")
    }

    func testChatAdmissionAutomaticallyWaitsForPreviousGenerationAndReplaysSameTurn() async throws {
        let conversationID = UUID()
        let userMessage = ChatMessage(id: UUID(), role: .user, content: "Max 请求", thinking: nil, createdAt: Date())
        let command = ChatAppendCommand(
            conversationID: conversationID,
            userMessage: userMessage,
            generationID: UUID(),
            assistantMessageID: UUID(),
            modelID: "custom/claude-sonnet-5-5",
            reasoningEffort: .max,
            createConversation: false,
            title: "Max admission test"
        )
        let accepted = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "jobId": UUID().uuidString.lowercased(),
            "generationId": command.generationID.uuidString.lowercased(),
            "userMessageId": command.userMessageID.uuidString.lowercased(),
            "assistantMessageId": command.assistantMessageID.uuidString.lowercased(),
            "status": "queued",
            "created": true,
            "streamUrl": "https://mychat.invalid/api/v1/jobs/fixture/events"
        ])
        let conflict = Data(#"{"error":{"code":"CONFLICT","message":"上一条回复正在完成保存，当前消息会自动发送","retryable":true,"details":{"conflictKind":"active_chat_generation"}}}"#.utf8)
        let recorder = ChatAdmissionRetryRecorder(responses: [
            (425, conflict, ["Retry-After": "0"]),
            (202, accepted, [:]),
        ])
        ChatAdmissionRetryFixtureURLProtocol.recorder = recorder
        defer { ChatAdmissionRetryFixtureURLProtocol.recorder = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatAdmissionRetryFixtureURLProtocol.self]
        let client = ChatAPIClient(
            session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://mychat.invalid")!
        )

        let admission = try await client.enqueueAppendTurn(command, accessToken: "fixture-token")

        XCTAssertEqual(admission.generationID, command.generationID)
        XCTAssertEqual(recorder.requestCount, 2)
        let bodies = try recorder.requestBodies.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
        XCTAssertEqual(bodies[0]["generationId"] as? String, bodies[1]["generationId"] as? String)
        XCTAssertEqual(bodies[0]["userMessageId"] as? String, bodies[1]["userMessageId"] as? String)
        XCTAssertEqual(bodies[0]["assistantMessageId"] as? String, bodies[1]["assistantMessageId"] as? String)
        XCTAssertEqual(bodies[0]["reasoningEffort"] as? String, "max")
    }

    func testChatAdmissionDoesNotRetryUnrelatedPreconditionFailure() async throws {
        let command = ChatAppendCommand(
            conversationID: UUID(),
            userMessage: ChatMessage(id: UUID(), role: .user, content: "hello", thinking: nil, createdAt: Date()),
            modelID: "custom/claude-sonnet-5-5",
            reasoningEffort: .high,
            createConversation: false,
            title: "Conflict test"
        )
        let conflict = Data(#"{"error":{"code":"CONFLICT","message":"Different conflict","retryable":true,"details":{"conflictKind":"other"}}}"#.utf8)
        let recorder = ChatAdmissionRetryRecorder(responses: [(425, conflict, ["Retry-After": "0"])])
        ChatAdmissionRetryFixtureURLProtocol.recorder = recorder
        defer { ChatAdmissionRetryFixtureURLProtocol.recorder = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatAdmissionRetryFixtureURLProtocol.self]
        let client = ChatAPIClient(
            session: URLSession(configuration: configuration),
            baseURL: URL(string: "https://mychat.invalid")!
        )

        do {
            _ = try await client.enqueueAppendTurn(command, accessToken: "fixture-token")
            XCTFail("Expected an unrelated conflict to surface immediately")
        } catch let error as ChatTransportError {
            guard case let .server(status, code, message, retryable, _) = error else {
                return XCTFail("Expected the original server conflict")
            }
            XCTAssertEqual(status, 425)
            XCTAssertEqual(code, "CONFLICT")
            XCTAssertEqual(message, "Different conflict")
            XCTAssertTrue(retryable)
        }
        XCTAssertEqual(recorder.requestCount, 1)
    }

    func testMemoryPreferenceRequestsMatchBackendSingleKeyContract() throws {
        let encoder = JSONEncoder()
        let memoryBody = try encoder.encode(MemorySettingRequest(enabled: false))
        let memoryJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: memoryBody) as? [String: Any])
        XCTAssertEqual(Set(memoryJSON.keys), Set(["enabled"]))
        XCTAssertEqual(memoryJSON["enabled"] as? Bool, false)

        let sensitiveBody = try encoder.encode(MemorySettingRequest(sensitiveEnabled: true))
        let sensitiveJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: sensitiveBody) as? [String: Any])
        XCTAssertEqual(Set(sensitiveJSON.keys), Set(["sensitiveEnabled"]))
        XCTAssertEqual(sensitiveJSON["sensitiveEnabled"] as? Bool, true)
    }

    func testUserMessageRenderingPreservesMarkdownLookingTextLiterally() {
        let original = "修正：~~80100 token~~，GPT 6.1 SOL，*UltraFast*，`原样`，$x_1$。"
        let markdown = MessageInlinePresentationCache.presentation(original).text
        let rendered = MessageInlinePresentationCache.userMessageText(original)

        XCTAssertTrue(markdown.runs.contains {
            $0.inlinePresentationIntent?.contains(.strikethrough) == true
        })
        XCTAssertEqual(String(rendered.characters), original)
        XCTAssertFalse(rendered.runs.contains {
            $0.inlinePresentationIntent?.contains(.strikethrough) == true
        })
    }

    func testCurrencyTextDoesNotEnterInlineMathWebViewAndMathHeightIsBounded() {
        let currency = "价格从 $3.75/百万 到 $4.90/百万，方案约 $200/月。"
        XCTAssertFalse(MessageInlinePresentationCache.presentation(currency).hasInlineMath)
        XCTAssertFalse(MessageInlinePresentationCache.presentation("$500 per month\nand $200 per month").hasInlineMath)
        XCTAssertTrue(MessageInlinePresentationCache.presentation("成本为 $x_1 + 2$。 ").hasInlineMath)
        let mixed = MessageInlinePresentationCache.presentation("月费 $20/月，计算式 $x_1$，年费 $200/月。")
        XCTAssertTrue(mixed.hasInlineMath)
        XCTAssertTrue(mixed.mathHTML.contains("literal-dollar"))
        XCTAssertEqual(InlineMathLayoutPolicy.height(for: 520), 520)
        XCTAssertNil(InlineMathLayoutPolicy.height(for: 521))
        XCTAssertNil(InlineMathLayoutPolicy.height(for: 20_000))
    }

    func testReasoningSummaryStorageIsTaggedAndDoesNotExposeUnmarkedThinking() {
        let summary = "先核对输入，再比较可用选项。"
        let stored = ChatReasoningSummaryStorage.encode(summary)
        XCTAssertEqual(ChatReasoningSummaryStorage.decode(stored), summary)
        XCTAssertNil(ChatReasoningSummaryStorage.decode("provider-private-thinking"))

        var accumulator = ChatStreamAccumulator()
        let event = ChatJobEvent(jobID: UUID(), sequence: 1, payload: .reasoningSummaryDelta(summary))
        accumulator.apply(event)
        XCTAssertEqual(ChatReasoningSummaryStorage.decode(accumulator.persistedThinking), summary)
        XCTAssertEqual(accumulator.thinking, "")
    }

    private func waitForPlayback(_ controller: SpeechPlaybackController, _ id: UUID,
                                 _ expected: SpeechPlaybackState, seconds: Double = 10) async {
        let deadline = Date().addingTimeInterval(seconds)
        while controller.state(for: id) != expected && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(controller.state(for: id), expected)
    }

    func testOAuthCallbackRejectsOtherAttemptsAndMalformedDeepLinks() throws {
        let started = MCPOAuthStartResponse(connectorId: "connector", attemptId: "attempt",
            authorizationUrl: URL(string: "https://auth.example.test")!, expiresIn: 600)
        try started.validateCallback(URL(string: "mychat://connectors/oauth?status=success&connectorId=connector&attemptId=attempt")!)
        for value in ["https://connectors/oauth?status=success&connectorId=connector&attemptId=attempt",
                      "mychat://connectors/oauth?status=success&connectorId=connector&attemptId=old",
                      "mychat://connectors/oauth?status=success&status=success&connectorId=connector&attemptId=attempt"] {
            XCTAssertThrowsError(try started.validateCallback(URL(string: value)!))
        }
    }

    func testChatGPTPlanDynamicAuthorizationUsesPKCEAndRequestsPlanScope() throws {
        let redirect = URL(string: "http://127.0.0.1:49152/auth/callback")!
        let url = try ChatGPTPlanProvider.authorizationURL(
            clientID: "dynamic_agent_client",
            hostID: "urn:uuid:fixture-host",
            redirectURI: redirect,
            state: "fixture-state",
            nonce: "fixture-nonce",
            codeChallenge: "fixture-challenge",
            prior: nil,
            isDynamicRegistration: true,
            requestConsent: false
        )
        let values = Dictionary(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map {
            ($0.name, $0.value ?? "")
        }, uniquingKeysWith: { first, _ in first })
        let scopes = Set((values["scope"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
        XCTAssertEqual(values["client_id"], "dynamic_agent_client")
        XCTAssertEqual(values["code_challenge_method"], "S256")
        XCTAssertEqual(values["code_challenge"], "fixture-challenge")
        XCTAssertEqual(values["ext_agent_host_id"], "urn:uuid:fixture-host")
        XCTAssertEqual(values["resource"], "https://api.openai.com/v1")
        XCTAssertTrue(scopes.contains("chatgpt.tokens.use.direct"))
    }

    func testChatGPTPlanModelDiscoveryFiltersToListedAccountModels() throws {
        let data = Data(#"{"models":[{"slug":"model-next","display_name":"Model Next","visibility":"list","capabilities":{"vision":true,"tools":true},"reasoning_efforts":["low","high"]},{"slug":"model-hidden","display_name":"Hidden","visibility":"hidden"}]}"#.utf8)
        let models = try ChatGPTPlanProvider.decodeModels(from: data)
        XCTAssertEqual(models.map(\.slug), ["model-next"])
        XCTAssertEqual(models.first?.displayName, "Model Next")
        XCTAssertTrue(models.first?.supportsVision == true)
        XCTAssertTrue(models.first?.supportsTools == true)
        XCTAssertEqual(models.first?.reasoningEfforts, ["low", "high"])

        let currentModels = try ChatGPTPlanProvider.decodeModels(from: Data(#"{"models":[{"slug":"gpt-5.6","display_name":"GPT-5.6","visibility":"list"},{"slug":"gpt-5.6-sol","display_name":"GPT-5.6 Sol","visibility":"list"},{"slug":"gpt-5.6-terra","display_name":"GPT-5.6 Terra","visibility":"list"},{"slug":"gpt-5.6-luna","display_name":"GPT-5.6 Luna","visibility":"list"},{"slug":"gpt-6.1-sol","display_name":"GPT-6.1 Sol","visibility":"list"},{"slug":"gpt-6-luna","display_name":"GPT-6 Luna","visibility":"list"},{"slug":"gpt-6-astra","display_name":"GPT-6 Astra","visibility":"list"}]}"#.utf8))
        XCTAssertEqual(currentModels.map(\.slug), [
            "gpt-5.6", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna",
            "gpt-6.1-sol", "gpt-6-luna", "gpt-6-astra",
        ])
        XCTAssertTrue(currentModels.allSatisfy(\.supportsVision))
        XCTAssertTrue(currentModels.allSatisfy(\.supportsTools))
        XCTAssertEqual(currentModels[0].reasoningEfforts, ["none", "low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(currentModels[1].reasoningEfforts, ["none", "low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(currentModels[2].reasoningEfforts, ["none", "low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(currentModels[3].reasoningEfforts, ["none", "low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(currentModels[4].reasoningEfforts, ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(currentModels[5].reasoningEfforts, ["none", "low", "medium", "high", "xhigh", "max"])
        XCTAssertTrue(currentModels.allSatisfy { $0.contextLength == 1_050_000 })
    }

    func testChatGPTSubscriptionCatalogStaysSeparateFromOpenAIAPICatalog() {
        let model = ChatGPTPlanModel(
            slug: "gpt-6.1-sol",
            displayName: "GPT-6.1 Sol",
            supportsVision: true,
            supportsTools: true,
            reasoningEfforts: ["low", "medium", "high", "xhigh", "max"],
            contextLength: 1_050_000
        )

        let item = AppModel.catalogItem(from: model)

        XCTAssertEqual(item.id, "chatgpt-plan:gpt-6.1-sol")
        XCTAssertEqual(item.provider, "ChatGPT 订阅")
        XCTAssertNotEqual(item.id, "openai/gpt-6.1-sol")
        XCTAssertNotEqual(item.provider, "OpenAI")
        XCTAssertEqual(item.reasoningEfforts, model.reasoningEfforts)
    }

    func testChatGPTPlanResponsesBodyIsUnstoredStreamingAndStateless() throws {
        let message = ChatMessage(id: UUID(), role: .user, content: "hello", thinking: nil, createdAt: Date())
        let payload = try ChatGPTPlanProvider.responsesBody(
            model: "model-from-account",
            messages: [message],
            attachments: [],
            systemPrompt: "MYCHAT_PLATFORM_PROMPT",
            reasoningEffort: "none",
            tools: []
        )
        XCTAssertEqual(payload["store"] as? Bool, false)
        XCTAssertEqual(payload["stream"] as? Bool, true)
        XCTAssertNil(payload["previous_response_id"])
        XCTAssertEqual(payload["model"] as? String, "model-from-account")
        XCTAssertTrue((payload["instructions"] as? String)?.hasPrefix("MYCHAT_PLATFORM_PROMPT") == true)
        XCTAssertTrue((payload["instructions"] as? String)?.contains("<document>") == true)

        let thinkingPayload = try ChatGPTPlanProvider.responsesBody(
            model: "model-from-account",
            messages: [message],
            attachments: [],
            systemPrompt: nil,
            reasoningEffort: "high",
            tools: []
        )
        XCTAssertEqual((thinkingPayload["reasoning"] as? [String: String])?["effort"], "high")
        XCTAssertEqual((thinkingPayload["reasoning"] as? [String: String])?["summary"], "auto")

        let functionTool = try JSONDecoder().decode(
            ChatGPTPlanToolDefinition.self,
            from: Data(#"{"type":"function","name":"web_search","description":"Search the web","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}"#.utf8)
        )
        let searchPayload = try ChatGPTPlanProvider.responsesBody(
            model: "model-from-account",
            messages: [message],
            attachments: [],
            systemPrompt: nil,
            reasoningEffort: "none",
            tools: [functionTool]
        )
        XCTAssertNil(searchPayload["tools"])
        XCTAssertNil(searchPayload["tool_choice"])
        let searchInput = try XCTUnwrap(searchPayload["input"] as? [[String: Any]])
        let additionalToolsIndex = try XCTUnwrap(searchInput.firstIndex {
            $0["type"] as? String == "additional_tools"
        })
        let latestUserMessageIndex = try XCTUnwrap(searchInput.lastIndex {
            $0["role"] as? String == "user"
        })
        XCTAssertLessThan(additionalToolsIndex, latestUserMessageIndex)
        let additionalTools = try XCTUnwrap(searchInput[additionalToolsIndex])
        XCTAssertEqual(additionalTools["role"] as? String, "developer")
        let declaredTools = try XCTUnwrap(additionalTools["tools"] as? [[String: Any]])
        XCTAssertEqual(declaredTools.first?["type"] as? String, "function")
        XCTAssertEqual(declaredTools.first?["name"] as? String, "web_search")
    }

    func testChatGPTPlanUnauthorizedStreamRefreshesOnceAndEOFIsFailure() async throws {
        let recorder = ChatGPTPlanRequestRecorder()
        ChatGPTPlanFixtureURLProtocol.recorder = recorder
        defer { ChatGPTPlanFixtureURLProtocol.recorder = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatGPTPlanFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let body = try JSONSerialization.data(withJSONObject: [
            "model": "model-from-account",
            "input": [["role": "user", "content": "hello"]],
            "store": false,
            "stream": true
        ])
        let refresh = PlanRefreshCounter()
        let stream = ChatGPTPlanProvider.stream(
            session: session,
            requestBody: body,
            accessToken: "stale-access-token",
            executeTool: { _, _ in #"{"result":"unused"}"# },
            refresh: { refresh.increment(); return "rotated-access-token" }
        )
        do {
            for try await _ in stream {}
            XCTFail("EOF without response.completed must fail")
        } catch let error as ChatGPTPlanError {
            guard case let .streamProtocol(message, _) = error else {
                return XCTFail("Expected a stream protocol error")
            }
            XCTAssertTrue(message.contains("response.completed"))
        }
        XCTAssertEqual(recorder.authorizationHeaders, ["Bearer stale-access-token", "Bearer rotated-access-token"])
        XCTAssertEqual(refresh.value, 1)
        XCTAssertEqual(recorder.requests.count, 2)
    }

    func testChatGPTPlanSurfacesSuccessfulJSONAdmissionErrorInsteadOfGenericInvalidResponse() async throws {
        let recorder = ChatGPTPlanRequestRecorder()
        recorder.streamContentType = "application/json"
        recorder.streamResponseBody = Data(#"{"detail":"direct usage is unavailable"}"#.utf8)
        ChatGPTPlanFixtureURLProtocol.recorder = recorder
        defer { ChatGPTPlanFixtureURLProtocol.recorder = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatGPTPlanFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let requestBody = Data(#"{"model":"model-from-account","input":[],"store":false,"stream":true}"#.utf8)
        let stream = ChatGPTPlanProvider.stream(
            session: session,
            requestBody: requestBody,
            accessToken: "access-token",
            executeTool: { _, _ in #"{"result":"unused"}"# },
            refresh: { "refreshed-access-token" }
        )

        do {
            for try await _ in stream {}
            XCTFail("Expected the server's JSON admission error")
        } catch let error as ChatGPTPlanError {
            guard case let .server(status, _, message, _) = error else {
                return XCTFail("Expected a structured server error")
            }
            XCTAssertEqual(status, 200)
            XCTAssertEqual(message, "direct usage is unavailable")
        }
    }

    func testChatGPTPlanStreamParsesCRLFSSEFramesAndDoneSentinel() async throws {
        let recorder = ChatGPTPlanRequestRecorder()
        let sseFrames: [String] = [
            "event: response.created\r\n",
            "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_fixture\"}}\r\n\r\n",
            "event: response.reasoning_summary_text.delta\r\n",
            "data: {\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"Checking the request. \"}\r\n\r\n",
            "event: response.output_text.delta\r\n",
            "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}\r\n\r\n",
            "data: [DONE]\r\n\r\n",
            "event: response.completed\r\n",
            "data: {\"type\":\"response.completed\",\"response\":{\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello\"}]}]}}\r\n\r\n",
        ]
        recorder.streamResponseBody = Data(sseFrames.joined().utf8)
        ChatGPTPlanFixtureURLProtocol.recorder = recorder
        defer { ChatGPTPlanFixtureURLProtocol.recorder = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatGPTPlanFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let requestBody = Data(#"{"model":"model-from-account","input":[],"store":false,"stream":true}"#.utf8)
        let stream = ChatGPTPlanProvider.stream(
            session: session,
            requestBody: requestBody,
            accessToken: "access-token",
            executeTool: { _, _ in #"{"result":"unused"}"# },
            refresh: { "refreshed-access-token" }
        )
        var deltas: [String] = []
        var reasoningSummaryDeltas: [String] = []
        var completion: String?
        var toolActivities: [String] = []
        for try await event in stream {
            switch event {
            case let .textDelta(delta): deltas.append(delta)
            case let .reasoningSummaryDelta(delta): reasoningSummaryDeltas.append(delta)
            case let .toolActivity(_, name, _): toolActivities.append(name)
            case .toolOutcome: break
            case let .completed(text): completion = text
            }
        }
        XCTAssertEqual(deltas, ["Hello"])
        XCTAssertEqual(reasoningSummaryDeltas, ["Checking the request. "])
        XCTAssertEqual(completion, "Hello")
        XCTAssertTrue(toolActivities.isEmpty)
    }

    func testChatGPTPlanRunsResponsesFunctionCallsAndFeedsToolOutputBack() async throws {
        let recorder = ChatGPTPlanRequestRecorder()
        let firstEvent = try JSONSerialization.data(withJSONObject: [
            "type": "response.completed",
            "response": ["output": [[
                "type": "function_call",
                "id": "fc_fixture",
                "call_id": "call_fixture",
                "name": "web_search",
                "arguments": #"{"query":"latest"}"#,
            ]]],
        ])
        let finalEvent = try JSONSerialization.data(withJSONObject: [
            "type": "response.completed",
            "response": ["output": [[
                "type": "message",
                "content": [["type": "output_text", "text": "Found two current sources." ]],
            ]]],
        ])
        recorder.scriptedResponses = [
            (200, Data("event: response.completed\ndata: \(String(decoding: firstEvent, as: UTF8.self))\n\n".utf8), "text/event-stream"),
            (200, Data("event: response.completed\ndata: \(String(decoding: finalEvent, as: UTF8.self))\n\n".utf8), "text/event-stream"),
        ]
        ChatGPTPlanFixtureURLProtocol.recorder = recorder
        defer { ChatGPTPlanFixtureURLProtocol.recorder = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatGPTPlanFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let requestBody = Data(#"{"model":"model-from-account","input":[{"type":"additional_tools","role":"developer","tools":[{"type":"function","name":"web_search","description":"Search","parameters":{"type":"object","properties":{}}}]},{"role":"user","content":"latest"}],"store":false,"stream":true}"#.utf8)
        let executed = PlanToolExecutionRecorder()
        let stream = ChatGPTPlanProvider.stream(
            session: session,
            requestBody: requestBody,
            accessToken: "access-token",
            executeTool: { name, arguments in
                executed.record(name: name, arguments: arguments)
                return #"{"result":"two sources","event":null}"#
            },
            refresh: { "refreshed-access-token" }
        )
        var finalText: String?
        var outcomes: [(String, String)] = []
        var activities: [(String, Bool)] = []
        for try await event in stream {
            switch event {
            case let .toolOutcome(id, outcome): outcomes.append((id, outcome))
            case let .toolActivity(id, _, isComplete): activities.append((id, isComplete))
            case let .completed(text): finalText = text
            case .textDelta, .reasoningSummaryDelta: break
            }
        }

        XCTAssertEqual(executed.values.count, 1)
        XCTAssertEqual(executed.values.first?.0, "web_search")
        XCTAssertEqual(executed.values.first?.1, #"{"query":"latest"}"#)
        XCTAssertEqual(activities.map { $0.0 }, ["call_fixture", "call_fixture"])
        XCTAssertEqual(activities.map { $0.1 }, [false, true])
        XCTAssertEqual(outcomes.first?.0, "call_fixture")
        XCTAssertEqual(finalText, "Found two current sources.")
        XCTAssertEqual(recorder.requests.count, 2)
        let followupData = try XCTUnwrap(recorder.requestBody(at: 1))
        let followup = try XCTUnwrap(JSONSerialization.jsonObject(with: followupData) as? [String: Any])
        let input = try XCTUnwrap(followup["input"] as? [[String: Any]])
        XCTAssertEqual(input[0]["type"] as? String, "additional_tools")
        XCTAssertEqual(input[0]["role"] as? String, "developer")
        XCTAssertEqual(input.suffix(2).compactMap { $0["type"] as? String }, ["function_call", "function_call_output"])
        XCTAssertEqual(input.last?["call_id"] as? String, "call_fixture")
        XCTAssertEqual(input.last?["output"] as? String, "two sources")
    }

    func testChatGPTPlanSSEDecoderHandlesTextCompletionAndIncompleteEvents() throws {
        let delta = try ChatGPTPlanProvider.decodeStreamEvent(
            name: nil,
            data: #"{"type":"response.output_text.delta","delta":"part"}"#
        )
        if case let .textDelta(value) = delta { XCTAssertEqual(value, "part") }
        else { XCTFail("Expected output text delta") }

        let completion = try ChatGPTPlanProvider.decodeStreamEvent(
            name: nil,
            data: #"{"type":"response.completed","response":{"output":[{"type":"message","content":[{"type":"output_text","text":"answer"}]}]}}"#
        )
        if case let .responseCompleted(value, calls, _) = completion {
            XCTAssertEqual(value, "answer")
            XCTAssertTrue(calls.isEmpty)
        } else { XCTFail("Expected response.completed") }

        XCTAssertNoThrow(try ChatGPTPlanProvider.decodeStreamEvent(name: nil, data: "[DONE]"))

        XCTAssertThrowsError(try ChatGPTPlanProvider.decodeStreamEvent(
            name: nil,
            data: #"{"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}"#
        )) { error in
            guard let planError = error as? ChatGPTPlanError,
                  case .server(status: 200, code: "max_output_tokens", _, _) = planError else {
                return XCTFail("Expected an incomplete-response error")
            }
        }
    }

    func testNewChatPreservesModelAndThinkingWhileClearingDraft() async {
        let model = NativeRuntimeFixture.makeModel()
        model.acceptAuthentication(NativeRuntimeFixture.session)
        await model.reloadModels()
        model.setReasoningEffort("high")
        let selected = model.selectedModelID
        model.draft = "未发送草稿"
        model.selectedDestination = .projects
        let revision = model.newChatRevision
        model.beginNewChat()
        XCTAssertEqual(model.draft, "")
        XCTAssertNil(model.activeConversationID)
        XCTAssertEqual(model.selectedDestination, .chats)
        XCTAssertEqual(model.newChatRevision, revision + 1)
        XCTAssertEqual(model.selectedModelID, selected)
        XCTAssertEqual(model.reasoningEffort, "high")
        XCTAssertNotNil(model.authSession)
    }

    func testFailedDeleteCannotResurrectAnotherSuccessfulDeleteOrStaleRefresh() async throws {
        let data = ControlledConversationStore()
        let model = NativeRuntimeFixture.makeModel(dataClient: data)
        model.acceptAuthentication(NativeRuntimeFixture.session)
        await model.reloadConversations()
        let rows = model.conversations
        XCTAssertEqual(rows.count, 2)
        let first = Task { try await model.deleteConversation(rows[0]) }
        let second = Task { try await model.deleteConversation(rows[1]) }
        guard await data.waitForPending(count: 2) else {
            first.cancel(); second.cancel(); XCTFail("Delete requests did not reach the store"); return
        }
        XCTAssertTrue(model.conversations.isEmpty)
        await data.finish(rows[1].id, error: nil)
        try await second.value
        await data.finish(rows[0].id, error: SupabaseDataError.server(status: 503, code: nil, message: "测试失败"))
        do { try await first.value; XCTFail("Server failure must remain a failure") } catch {}
        XCTAssertEqual(model.conversations.map(\.id), [rows[0].id])
        await model.reloadConversations()
        XCTAssertEqual(model.conversations.map(\.id), [rows[0].id])
    }

    func testNextDraftIsAcceptedBeforeDurableFinalizationAndSentExactlyOnce() async throws {
        let transport = ControlledChatTransport()
        let model = NativeRuntimeFixture.makeModel(chatClient: transport, stream: transport)
        model.acceptAuthentication(NativeRuntimeFixture.session)
        await model.reloadModels()
        model.beginNewChat()
        model.draft = "第一轮"
        model.sendDraft()
        try await waitUntil { transport.commands.count == 1 && transport.continuations.count == 1 }
        let first = transport.commands[0]
        transport.emit(.textDelta("第一轮完成"), for: first, sequence: 1)
        transport.emit(.modelOutputCompleted, for: first, sequence: 2)
        let completedAt = Date()
        model.draft = "第二轮"
        try await waitUntil { model.canSendCurrentDraft }
        XCTAssertLessThan(Date().timeIntervalSince(completedAt), 1)
        model.sendDraft()
        XCTAssertEqual(model.messages.last(where: { $0.role == .user })?.content, "第二轮")
        XCTAssertEqual(transport.commands.count, 1, "Do not submit while the previous server turn is finalizing")
        XCTAssertEqual(model.queuedCommands.count, 1)
        transport.complete(first, text: "第一轮完成", sequence: 3)
        try await waitUntil { transport.commands.count == 2 && transport.continuations.count == 2 }
        XCTAssertTrue(model.queuedCommands.isEmpty)
        XCTAssertEqual(transport.commands[1].userMessage.content, "第二轮")
        transport.complete(transport.commands[1], text: "第二轮完成", sequence: 1)
        try await waitUntil { !model.isCurrentConversationGenerating }
        XCTAssertEqual(transport.commands.count, 2)
        XCTAssertEqual(model.messages.filter { $0.role == .assistant }.map(\.content), ["第一轮完成", "第二轮完成"])
    }

    func testForegroundReattachesToActiveServerGenerationWithoutResubmittingTurn() async throws {
        let transport = ControlledChatTransport()
        let model = NativeRuntimeFixture.makeModel(chatClient: transport, stream: transport)
        await model.restoreAuthenticationIfNeeded()
        await model.reloadModels()
        model.beginNewChat()
        model.draft = "切回前台后继续这条回复"
        model.sendDraft()
        try await waitUntil { transport.commands.count == 1 && transport.streamStarts.count == 1 }

        let command = try XCTUnwrap(transport.commands.first)
        let checkpoint = 7
        transport.recovery = ChatGenerationRecovery(
            admission: ChatAdmission(
                schemaVersion: 1,
                jobID: command.generationID,
                generationID: command.generationID,
                userMessageID: command.userMessageID,
                assistantMessageID: command.assistantMessageID,
                status: "running",
                created: false,
                streamURL: URL(string: "https://isolated.mychat.invalid/events")!,
                trialRemaining: nil,
                trialLimit: nil
            ),
            sequence: checkpoint,
            content: "已生成的检查点",
            thinking: "",
            media: [],
            terminal: nil
        )

        await model.resumeAuthentication()
        try await waitUntil { transport.streamStarts.count == 2 }
        try await waitUntil { model.messages.last(where: { $0.role == .assistant })?.content == "已生成的检查点" }
        XCTAssertEqual(transport.commands.count, 1, "Foreground recovery must not enqueue a second model request")
        XCTAssertEqual(transport.streamStarts.map { $0.fromSequence }, [0, checkpoint])
        XCTAssertTrue(model.isCurrentConversationGenerating)
        XCTAssertEqual(model.messages.last(where: { $0.role == .assistant })?.content, "已生成的检查点")

        transport.complete(command, text: "已生成的检查点，继续完成。", sequence: checkpoint + 1)
        try await waitUntil { !model.isCurrentConversationGenerating }
        XCTAssertEqual(model.messages.last(where: { $0.role == .assistant })?.content, "已生成的检查点，继续完成。")
        XCTAssertEqual(transport.commands.count, 1)
    }

    func testForegroundStatusMissKeepsLiveGenerationStreamAttached() async throws {
        let transport = ControlledChatTransport()
        let model = NativeRuntimeFixture.makeModel(chatClient: transport, stream: transport)
        await model.restoreAuthenticationIfNeeded()
        await model.reloadModels()
        model.beginNewChat()
        model.draft = "状态查询短暂为空时仍保留原回复"
        model.sendDraft()
        try await waitUntil { transport.commands.count == 1 && transport.streamStarts.count == 1 }

        let command = try XCTUnwrap(transport.commands.first)
        await model.resumeAuthentication()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(transport.commands.count, 1, "恢复检查不能重复提交模型请求")
        XCTAssertEqual(transport.streamStarts.count, 1, "空状态查询时不能取消唯一的实时流")
        XCTAssertTrue(model.isCurrentConversationGenerating)

        transport.complete(command, text: "回复已正常完成", sequence: 1)
        try await waitUntil { !model.isCurrentConversationGenerating }
        XCTAssertEqual(model.messages.last(where: { $0.role == .assistant })?.content, "回复已正常完成")
        XCTAssertEqual(transport.commands.count, 1)
    }

    func testCompletedAssistantArtifactIsPersistedAndPublishedToLibrary() async throws {
        let transport = ControlledChatTransport()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [NativeAuditURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let workspace = WorkspaceDataClient(
            configurationClient: MobileConfigurationClient(session: session),
            session: session
        )
        let fixtureSession = NativeRuntimeFixture.session
        let isolatedUserSession = AuthSession(
            accessToken: fixtureSession.accessToken,
            refreshToken: fixtureSession.refreshToken,
            tokenType: fixtureSession.tokenType,
            expiresAt: fixtureSession.expiresAt,
            user: AuthUser(id: UUID().uuidString.lowercased(), email: "artifact-runtime-audit@example.invalid", isAnonymous: false)
        )
        let model = NativeRuntimeFixture.makeModel(
            workspaceClient: workspace,
            chatClient: transport,
            stream: transport
        )
        model.acceptAuthentication(isolatedUserSession)
        await model.reloadModels()
        model.beginNewChat()
        model.draft = "生成一个动画咖啡杯"
        model.sendDraft()
        try await waitUntil { transport.commands.count == 1 && transport.continuations.count == 1 }

        let command = transport.commands[0]
        let output = "<artifact><html><head><title>动画咖啡杯</title></head><body><main>作品</main></body></html></artifact>"
        transport.emit(.textDelta(output), for: command, sequence: 1)
        transport.complete(command, text: output, sequence: 2)

        let expectedMessageID = command.assistantMessageID.uuidString.lowercased()
        for _ in 0..<150 where !NativeAuditURLProtocol.containsSavedArtifact(messageID: expectedMessageID)
            || model.artifacts.first?.messageID != expectedMessageID {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(NativeAuditURLProtocol.containsSavedArtifact(messageID: expectedMessageID),
            "Artifact was not persisted by the server fixture: \(model.artifactsError ?? model.workspaceError ?? "no reported error")")
        XCTAssertEqual(model.artifacts.first?.title, "动画咖啡杯",
            "Artifact save error: \(model.artifactsError ?? "none"); workspace error: \(model.workspaceError ?? "none")")
        XCTAssertEqual(model.artifacts.first?.messageID, expectedMessageID)
        await model.reloadWorkspaceData()
        XCTAssertEqual(model.artifacts.first?.title, "动画咖啡杯")
        XCTAssertEqual(model.artifacts.first?.raw, "<html><head><title>动画咖啡杯</title></head><body><main>作品</main></body></html>")
        XCTAssertEqual(model.artifacts.first?.messageID, command.assistantMessageID.uuidString.lowercased())
    }

    func testDocumentStaysPendingUntilTerminalAndRegenerationRespondsImmediately() async throws {
        let transport = ControlledChatTransport()
        let model = NativeRuntimeFixture.makeModel(chatClient: transport, stream: transport)
        await model.restoreAuthenticationIfNeeded(); await model.reloadModels(); model.beginNewChat()
        model.draft = "写成文件"; model.sendDraft()
        try await waitUntil { transport.commands.count == 1 && transport.continuations.count == 1 }
        let command = transport.commands[0]
        let output = "<document>\ntitle: 完成后展示\nfilename: complete.md\nsummary: 撰写文章\n\n# 正文\n这是完整文章\n</document>"
        transport.emit(.textDelta(output), for: command, sequence: 1)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.isCurrentConversationGenerating)
        XCTAssertNil(model.pendingDocumentPreview, "A closed document tag must not open a preview before the reply finishes")
        XCTAssertFalse(model.messages.last!.completedReplyIsVisible)
        transport.complete(command, text: output, sequence: 2)
        try await waitUntil { !model.isCurrentConversationGenerating && model.pendingDocumentPreview != nil }
        let assistant = try XCTUnwrap(model.messages.last)
        model.pendingDocumentPreview = nil
        model.regenerate(assistant)
        XCTAssertTrue(model.isCurrentConversationGenerating, "Regenerate must update state before waiting for network admission")
        XCTAssertEqual(model.messages.last?.content, "", "Regenerate must immediately replace the old reply with the generating placeholder")
        try await waitUntil { transport.commands.count == 2 }
        transport.complete(transport.commands[1], text: "重新生成完成", sequence: 1)
    }

    func testFooterWaitsForCompletedNonemptyReply() async throws {
        let transport = ControlledChatTransport()
        let model = NativeRuntimeFixture.makeModel(chatClient: transport, stream: transport)
        await model.restoreAuthenticationIfNeeded(); await model.reloadModels(); model.beginNewChat()
        for text in ["正常回复", ""] {
            model.draft = "测试免责声明"; model.sendDraft()
            let index = transport.commands.count
            try await waitUntil { transport.commands.count > index && transport.continuations[transport.commands.last!.generationID] != nil }
            let command = transport.commands.last!
            let footer = AssistantFooterPresentation(model, messageID: command.assistantMessageID)
            XCTAssertFalse(footer.showsDisclaimer)
            if !text.isEmpty {
                transport.emit(.textDelta(text), for: command, sequence: 1)
                try await waitUntil { model.messages.last?.content == text }
                XCTAssertFalse(footer.showsDisclaimer)
            }
            transport.complete(command, text: text, sequence: 2)
            try await waitUntil { !model.isCurrentConversationGenerating && !footer.isGenerating }
            XCTAssertEqual(footer.showsDisclaimer, !text.isEmpty)
            let metrics = try XCTUnwrap(ChatGenerationDiagnostics.records[command.generationID])
            XCTAssertNotNil(metrics.milliseconds["admitted"])
            XCTAssertNotNil(metrics.milliseconds["firstEvent"])
            XCTAssertEqual(metrics.milliseconds["firstText"] != nil, !text.isEmpty)
        }
    }

    func testStopWaitingAndStreamingImmediatelyStopsAndIgnoresLateCallbacks() async throws {
        for partial in ["", "已输出的正文"] {
            let transport = ControlledChatTransport()
            let model = NativeRuntimeFixture.makeModel(chatClient: transport, stream: transport)
            await model.restoreAuthenticationIfNeeded(); await model.reloadModels(); model.beginNewChat()
            model.draft = "第一条"; model.sendDraft()
            try await waitUntil { transport.commands.count == 1 && transport.continuations.count == 1 }
            let old = transport.commands[0]
            if !partial.isEmpty {
                transport.emit(.textDelta(partial), for: old, sequence: 1)
                try await waitUntil { model.messages.last?.content == partial }
            }
            model.stopCurrentGeneration()
            XCTAssertFalse(model.isCurrentConversationGenerating)
            XCTAssertEqual(model.messages.last?.content, partial)
            XCTAssertEqual(model.messages.last?.localGenerationState, .stopped)
            try await waitUntil { ChatGenerationDiagnostics.records[old.generationID]?.milliseconds["cancelComplete"] != nil }
            XCTAssertEqual(transport.cancelCalls, [old.generationID])
            model.draft = "第二条"; model.sendDraft()
            try await waitUntil { transport.commands.count == 2 && transport.continuations[transport.commands[1].generationID] != nil }
            let next = transport.commands[1]
            transport.emit(.textDelta("旧任务的迟到文字"), for: old, sequence: 2)
            transport.complete(old, text: "旧任务迟到完成", sequence: 3)
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertTrue(model.isCurrentConversationGenerating)
            XCTAssertEqual(model.messages.last?.id, next.assistantMessageID)
            XCTAssertEqual(model.messages.last?.content, "")
            transport.complete(next, text: "新的正常回复", sequence: 1)
            try await waitUntil { !model.isCurrentConversationGenerating && model.messages.last?.content == "新的正常回复" }
        }
    }

    func testStopDuringAdmissionCancelsTheServerReceiptBeforeStartingTheNextTurn() async throws {
        let transport = ControlledChatTransport(); transport.holdAdmission = true
        let model = NativeRuntimeFixture.makeModel(chatClient: transport, stream: transport)
        await model.restoreAuthenticationIfNeeded(); await model.reloadModels(); model.beginNewChat()
        model.draft = "第一条"; model.sendDraft()
        try await waitUntil { transport.commands.count == 1 && transport.heldAdmissions.count == 1 }
        let old = transport.commands[0]
        model.stopCurrentGeneration()
        XCTAssertFalse(model.isCurrentConversationGenerating)
        model.draft = "第二条"; model.sendDraft()
        XCTAssertTrue(model.isCurrentConversationGenerating)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(transport.commands.count, 1)
        transport.holdAdmission = false
        transport.heldAdmissions.removeValue(forKey: old.generationID)?.resume()
        try await waitUntil { transport.cancelCalls == [old.generationID] && transport.commands.count == 2 }
        XCTAssertNil(transport.continuations[old.generationID], "A stopped admission must never open its output stream")
        let next = transport.commands[1]
        try await waitUntil { transport.continuations[next.generationID] != nil }
        XCTAssertEqual(model.messages.last?.id, next.assistantMessageID)
        transport.complete(next, text: "第二条完成", sequence: 1)
        try await waitUntil { !model.isCurrentConversationGenerating }
    }

    func testProcessEntriesPreserveThinkingSearchAndToolOrder() {
        let job = UUID()
        var entries: [ChatProcessEntry] = []
        let payloads: [ChatJobEventPayload] = [.thinkingDelta("先思考"),
            .toolSearch(ChatToolSearch(query: "第一个问题", results: [], kind: nil, images: nil)),
            .reasoningSummaryDelta("API 摘要"), .thinkingDelta("再思考"),
            .toolActivity(ChatToolActivity(toolCallID: "tool-1", toolName: "memory_search", isComplete: false)),
            .toolSearch(ChatToolSearch(query: "第二个问题", results: [], kind: nil, images: nil)),
            .toolActivity(ChatToolActivity(toolCallID: "tool-1", toolName: "memory_search", isComplete: true))]
        for (index, payload) in payloads.enumerated() {
            ChatProcessEntry.record(ChatJobEvent(jobID: job, sequence: index + 1, payload: payload), into: &entries)
        }
        XCTAssertEqual(entries.count, 6)
        XCTAssertEqual(entries[0].content, .thinking("先思考"))
        XCTAssertEqual(entries[2].content, .reasoningSummary("API 摘要"))
        XCTAssertEqual(entries[3].content, .thinking("再思考"))
        XCTAssertEqual(entries[4].content, .tool(ChatToolActivity(toolCallID: "tool-1", toolName: "memory_search", isComplete: true)))
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(1)
        while !predicate(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), "Expected state did not arrive within one second")
        if !predicate() { throw CancellationError() }
    }

    func testStoppedDictationIgnoresLateSpeechAuthorization() async {
        var speechCallback: ((SFSpeechRecognizerAuthorizationStatus) -> Void)?
        var microphoneRequested = false
        let controller = NativeDictationController(
            requestSpeechAuthorization: { speechCallback = $0 },
            requestMicrophonePermission: { _ in microphoneRequested = true })
        controller.start(onTranscript: { _ in XCTFail("No transcript after cancel") }, onError: { _ in XCTFail("No error after cancel") })
        XCTAssertTrue(controller.isStarting)
        controller.stop()
        speechCallback?(.authorized)
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(microphoneRequested)
        XCTAssertFalse(controller.isStarting)
        XCTAssertFalse(controller.isListening)
    }

    func testStoppedDictationIgnoresLateMicrophonePermission() async {
        var microphoneCallback: ((Bool) -> Void)?
        let controller = NativeDictationController(
            requestSpeechAuthorization: { $0(.authorized) },
            requestMicrophonePermission: { microphoneCallback = $0 })
        controller.start(onTranscript: { _ in XCTFail("No transcript after cancel") }, onError: { _ in XCTFail("No recording after cancel") })
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertNotNil(microphoneCallback)
        controller.stop()
        microphoneCallback?(true)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(controller.isListening)
        XCTAssertFalse(controller.isStarting)
    }

    func testSSEFramesFlushAtCRLFBoundaryAndKeepChineseBytes() throws {
        var parser = SSEByteParser()
        var frames: [SSEFrame] = []
        for byte in Data("event: thinking.delta\r\ndata: {\"thinking\":\"中文\"}\r\n\r\n".utf8) {
            if let frame = try parser.consume(byte: byte) { frames.append(frame) }
        }
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].event, "thinking.delta")
        XCTAssertEqual(frames[0].data, "{\"thinking\":\"中文\"}")
    }

    func testPresentationTextKeepsMeaningAndCleansProcessMarkup() {
        XCTAssertEqual(PresentationText.plain("## **搜索网页**\\n`完成`"), "搜索网页\n完成")
        XCTAssertEqual(PresentationText.plain("https://example.com:8443/a"), "https://example.com:8443/a")
    }
}

private actor ControlledConversationStore: SupabaseDataServing {
    let records = ["20000000-0000-4000-8000-000000000001", "20000000-0000-4000-8000-000000000002"].map {
        ConversationRecord(id: $0, title: $0, updatedAt: "2026-10-03", projectID: nil, starred: false, pinned: false)
    }
    var pending: [String: CheckedContinuation<Void, Error>] = [:]
    func fetchConversations(accessToken: String) async throws -> [ConversationRecord] { records }
    func fetchMessages(conversationID: String, accessToken: String, limit: Int) async throws -> [ConversationMessageRecord] { [] }
    func fetchConversationToolHistory(conversationID: String, assistantMessageIDs: [UUID], accessToken: String) async throws -> ConversationToolHistory { ConversationToolHistory() }
    func updateConversationTitle(id: String, title: String, accessToken: String) async throws {}
    func setConversationPinned(id: String, pinned: Bool, accessToken: String) async throws {}
    func setConversationStarred(id: String, starred: Bool, accessToken: String) async throws {}
    func setConversationProject(id: String, projectID: String?, accessToken: String) async throws {}
    func deleteConversation(id: String, accessToken: String) async throws {
        try await withCheckedThrowingContinuation { pending[id] = $0 }
    }
    func waitForPending(count: Int) async -> Bool {
        for _ in 0..<100 {
            if pending.count >= count { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
    func finish(_ id: String, error: Error?) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}

@MainActor private final class ControlledChatTransport: ChatAPIServing, ChatEventStreaming {
    var holdAdmission = false
    var heldAdmissions: [UUID: CheckedContinuation<Void, Never>] = [:]
    var cancelCalls: [UUID] = []
    var privateReply: String?
    var commands: [ChatAppendCommand] = []
    var recovery: ChatGenerationRecovery?
    var streamStarts: [(jobID: UUID, fromSequence: Int)] = []
    var continuations: [UUID: AsyncThrowingStream<ChatJobEvent, Error>.Continuation] = [:]
    func enqueueAppendTurn(_ command: ChatAppendCommand, accessToken: String) async throws -> ChatAdmission {
        commands.append(command)
        if holdAdmission { await withCheckedContinuation { heldAdmissions[command.generationID] = $0 } }
        return ChatAdmission(schemaVersion: 1, jobID: command.generationID, generationID: command.generationID,
            userMessageID: command.userMessageID, assistantMessageID: command.assistantMessageID,
            status: "queued", created: true, streamURL: URL(string: "https://isolated.mychat.invalid/events")!,
            trialRemaining: nil, trialLimit: nil)
    }
    func events(admission: ChatAdmission, accessToken: String, fromSequence: Int) -> AsyncThrowingStream<ChatJobEvent, Error> {
        streamStarts.append((admission.jobID, fromSequence))
        return AsyncThrowingStream { continuations[admission.jobID] = $0 }
    }
    func emit(_ payload: ChatJobEventPayload, for command: ChatAppendCommand, sequence: Int) {
        continuations[command.generationID]?.yield(ChatJobEvent(jobID: command.generationID, sequence: sequence, payload: payload))
    }
    func complete(_ command: ChatAppendCommand, text: String, sequence: Int) {
        emit(.terminal(ChatTerminalSnapshot(status: .completed, content: text, thinking: "", sequence: sequence,
            errorCode: nil, media: [], tokenUsage: nil, codeReceipt: nil)), for: command, sequence: sequence)
        continuations[command.generationID]?.finish()
    }
    func generateConversationTitle(conversationID: UUID, userText: String, assistantText: String, endpointID: UUID?, accessToken: String) async throws -> String { "隔离测试标题" }
    func conversationGeneration(conversationID: UUID, accessToken: String) async throws -> ChatGenerationRecovery? { recovery }
    func terminalSnapshot(conversationID: UUID, jobID: UUID, accessToken: String) async throws -> ChatTerminalSnapshot? { nil }
    func cancel(jobID: UUID, accessToken: String, reason: String?) async throws -> ChatCancelResponse {
        cancelCalls.append(jobID)
        return ChatCancelResponse(jobID: jobID, accepted: true, replayed: false, status: "cancelled", eventSequence: 1)
    }
    func privateStreamRequest(command: ChatAppendCommand, messages: [ChatMessage]) throws -> PrivateChatStreamRequest {
        guard privateReply != nil else { throw CancellationError() }
        return PrivateChatStreamRequest(endpoint: URL(string: "https://isolated.mychat.invalid/private")!, body: Data(), jobID: command.conversationID)
    }
    func privateEvents(request: PrivateChatStreamRequest, accessToken: String) -> AsyncThrowingStream<ChatJobEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let reply = privateReply else { continuation.finish(throwing: CancellationError()); return }
            continuation.yield(ChatJobEvent(jobID: request.jobID, sequence: 1, payload: .terminal(ChatTerminalSnapshot(status: .completed, content: reply, thinking: "", sequence: 1, errorCode: nil, media: [], tokenUsage: nil, codeReceipt: nil))))
            continuation.finish()
        }
    }
}

private final class PlanRefreshCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

private final class ChatGPTPlanRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedRequests: [URLRequest] = []
    private var capturedRequestBodies: [Data?] = []
    private var capturedAuthorizationHeaders: [String] = []
    var streamContentType = "text/event-stream"
    var streamResponseBody = Data()
    var scriptedResponses: [(Int, Data, String)] = []

    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return capturedRequests }
    func requestBody(at index: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard capturedRequestBodies.indices.contains(index) else { return nil }
        return capturedRequestBodies[index]
    }
    var authorizationHeaders: [String] {
        lock.lock(); defer { lock.unlock() }; return capturedAuthorizationHeaders
    }

    func response(for request: URLRequest) -> (Int, Data, String) {
        let body = Self.readBody(from: request)
        lock.lock()
        capturedRequests.append(request)
        capturedRequestBodies.append(body)
        capturedAuthorizationHeaders.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
        let requestNumber = capturedRequests.count
        let scripted = scriptedResponses.isEmpty ? nil : scriptedResponses.removeFirst()
        lock.unlock()

        if let scripted { return scripted }

        if requestNumber == 1 {
            return (401, Data(#"{"error":{"code":"token_expired","message":"expired"}}"#.utf8), "application/json")
        }
        return (200, streamResponseBody, streamContentType)
    }

    private static func readBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 8_192)
        defer { buffer.deallocate() }
        var data = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 8_192)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }
}

private final class ChatAdmissionRetryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var scriptedResponses: [(Int, Data, [String: String])]
    private var capturedRequestBodies: [Data] = []
    private var capturedRequestCount = 0

    init(responses: [(Int, Data, [String: String])]) {
        scriptedResponses = responses
    }

    var requestBodies: [Data] {
        lock.lock(); defer { lock.unlock() }
        return capturedRequestBodies
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return capturedRequestCount
    }

    func response(for request: URLRequest) -> (Int, Data, [String: String]) {
        lock.lock(); defer { lock.unlock() }
        capturedRequestCount += 1
        if let body = request.httpBody {
            capturedRequestBodies.append(body)
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 8_192)
            defer { buffer.deallocate() }
            var data = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(buffer, maxLength: 8_192)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            if !data.isEmpty { capturedRequestBodies.append(data) }
        }
        guard !scriptedResponses.isEmpty else { return (500, Data(), [:]) }
        return scriptedResponses.removeFirst()
    }
}

private final class ChatAdmissionRetryFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var recorder: ChatAdmissionRetryRecorder?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let recorder = Self.recorder else {
            client?.urlProtocol(self, didFailWithError: ChatTransportError.invalidResponse)
            return
        }
        let (status, data, headers) = recorder.response(for: request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"].merging(headers) { _, value in value }
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class PlanToolExecutionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(String, String)] = []
    var values: [(String, String)] { lock.lock(); defer { lock.unlock() }; return recorded }
    func record(name: String, arguments: String) {
        lock.lock(); recorded.append((name, arguments)); lock.unlock()
    }
}

private final class ChatGPTPlanFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var recorder: ChatGPTPlanRequestRecorder?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let recorder = Self.recorder else {
            client?.urlProtocol(self, didFailWithError: ChatGPTPlanError.invalidResponse)
            return
        }
        let (status, data, contentType) = recorder.response(for: request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class PlaybackFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    static var audio = Data()
    static var failNext = false
    static var authorization: String?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.authorization = request.value(forHTTPHeaderField: "Authorization")
        let failed = Self.failNext; Self.failNext = false
        let response = HTTPURLResponse(url: request.url!, statusCode: failed ? 503 : 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": failed ? "application/json" : "audio/pcm", "X-Audio-Sample-Rate": "24000"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !failed {
            for start in stride(from: 0, to: Self.audio.count, by: 8192) {
                client?.urlProtocol(self, didLoad: Self.audio.subdata(in: start..<min(start + 8192, Self.audio.count)))
            }
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@MainActor private final class SilentPCMSink: PCMPlaybackSink {
    var samples: [Float] = []
    var stopped = false
    var onStarted: (() -> Void)?
    var onDrain: (() -> Void)?
    var queuedSeconds: Double { Double(samples.count) / 24000 }
    var elapsedSeconds: Double { stopped ? 0 : 0.01 }
    private var completion: (() -> Void)?
    func append(_ samples: [Float]) throws { let first = self.samples.isEmpty; self.samples += samples; if first { onStarted?() } }
    func finish(_ completion: @escaping () -> Void) { self.completion = completion }
    func complete() { completion?(); completion = nil }
    func stop() { stopped = true; completion = nil }
}
