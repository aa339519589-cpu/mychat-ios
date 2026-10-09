import XCTest
import CoreText
import UIKit
import SwiftUI
@testable import MyChat

@MainActor final class CodeWorkspaceTests: XCTestCase {
    func testWorkspaceDiffRequiresAnExplicitSupportedCapability() throws {
        var payload: [String: Any] = ["schemaVersion": 1, "durableQueue": true,
            "execution": ["backend": "isolated", "location": "cloud", "configured": true, "verified": false]]
        func decode() throws -> CodeCapabilities {
            try JSONDecoder().decode(CodeCapabilities.self, from: JSONSerialization.data(withJSONObject: payload))
        }
        XCTAssertNil(try decode().supportedWorkspaceDiff, "Old capabilities keep Code working without advertising patch reads")
        payload["workspaceDiff"] = ["future": true]
        XCTAssertNil(try decode().supportedWorkspaceDiff)
        for (key, value) in [("schemaVersion", 2 as Any), ("formats", ["cas-change-summary"] as Any),
                             ("requiresSnapshotBinding", false as Any), ("maxFileBytes", 0 as Any),
                             ("maxPatchBytes", 1_048_577 as Any)] {
            var capability = diffCapabilityPayload
            capability[key] = value
            payload["workspaceDiff"] = capability
            XCTAssertNil(try decode().supportedWorkspaceDiff, key)
            XCTAssertTrue(try decode().execution.configured)
            XCTAssertFalse(try decode().execution.verified)
        }
        payload["workspaceDiff"] = diffCapabilityPayload
        XCTAssertNotNil(try decode().supportedWorkspaceDiff)
        payload["schemaVersion"] = 2
        XCTAssertNil(try decode().supportedWorkspaceDiff)
    }

    func testWorkspaceSummaryRemainsAFileListAndRequiresMatchingSnapshotPins() throws {
        let summary: [String: Any] = ["diff": "modified README.md", "hasChanges": true,
            "changedFiles": [["path": "README.md", "status": "modified"]],
            "summary": ["added": 0, "modified": 1, "deleted": 0],
            "snapshotId": diffBinding.snapshotID.uuidString, "head": diffBinding.head, "manifestDigest": diffBinding.manifestDigest]
        let data = try JSONSerialization.data(withJSONObject: summary)
        let changes = try JSONDecoder().decode(CodeWorkspaceChanges.self, from: data)
        XCTAssertNil(changes.diffFormat)
        XCTAssertTrue(changes.matches(diffBinding))
        XCTAssertThrowsError(try JSONDecoder().decode(CodeWorkspaceDiffResponse.self, from: data))
        var stale = summary
        stale["head"] = String(repeating: "c", count: 40)
        XCTAssertFalse(try JSONDecoder().decode(CodeWorkspaceChanges.self,
            from: JSONSerialization.data(withJSONObject: stale)).matches(diffBinding))
        var duplicate = summary
        duplicate["changedFiles"] = Array(repeating: ["path": "README.md", "status": "modified"], count: 2)
        XCTAssertFalse(try JSONDecoder().decode(CodeWorkspaceChanges.self,
            from: JSONSerialization.data(withJSONObject: duplicate)).isWellFormed)
    }

    func testWorkspaceStateCannotInventARepositoryOrImmutableSnapshot() throws {
        var wire: [String: Any] = ["status": "durable", "repo": diffBinding.repository,
            "snapshotId": diffBinding.snapshotID.uuidString, "manifestDigest": diffBinding.manifestDigest,
            "commit": diffBinding.head, "version": diffBinding.version]
        func binding() throws -> CodeWorkspaceDiffBinding? {
            try JSONDecoder().decode(CodeWorkspaceState.self, from: JSONSerialization.data(withJSONObject: wire))
                .binding(taskID: diffBinding.taskID, userID: diffBinding.userID)
        }
        XCTAssertEqual(try binding(), diffBinding)
        wire["repo"] = NSNull()
        XCTAssertNil(try binding())
        wire["repo"] = diffBinding.repository; wire["status"] = "not_hydrated"
        XCTAssertNil(try binding())
        wire["status"] = "durable"; wire["commit"] = "main"
        XCTAssertNil(try binding())
    }

    func testWorkspaceDiffRequestPinsEveryAuthorityFieldAndOnlyUsesGET() async throws {
        let session = diffSession()
        defer { session.invalidateAndCancel(); DiffRequestURLProtocol.reset() }
        let api = CodeAPIClient(session: session, baseURL: URL(string: "https://diff.invalid")!)
        let path = "docs/中文 & plus+.md"
        try DiffRequestURLProtocol.respond(diffResponse(path: path))
        let value = try await api.workspaceDiff(binding: diffBinding, path: path,
            capability: diffCapability, accessToken: "test-token")
        XCTAssertEqual(value.patch, diffPatch)
        let request = try XCTUnwrap(DiffRequestURLProtocol.requests.last)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(request.url?.path, "/api/agent/tasks/\(diffBinding.taskID.uuidString.lowercased())/workspace/diff")
        let query = try XCTUnwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.count, 6)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") }), [
            "format": "unified", "path": path, "snapshotId": diffBinding.snapshotID.uuidString.lowercased(),
            "manifestDigest": diffBinding.manifestDigest, "head": diffBinding.head, "version": "7"])
    }

    func testWorkspaceDiffRejectsUnsupportedCapabilitiesAndUnsafePathsBeforeTransport() async throws {
        let session = diffSession()
        defer { session.invalidateAndCancel(); DiffRequestURLProtocol.reset() }
        let api = CodeAPIClient(session: session, baseURL: URL(string: "https://diff.invalid")!)
        let unsupported = CodeWorkspaceDiffCapability(schemaVersion: 2, formats: ["unified"],
            requiresSnapshotBinding: true, maxFileBytes: 262144, maxPatchBytes: 1048576)
        do {
            _ = try await api.workspaceDiff(binding: diffBinding, path: "README.md", capability: unsupported, accessToken: "test-token")
            XCTFail("A capability must be explicitly supported before making a request")
        } catch { XCTAssertEqual(error as? CodeAPIError, .workspaceDiffUnavailable) }
        for path in ["../outside", "/etc/passwd", "a//b", "a/./b", "a\\b", "C:/file", "a\nb", Array(repeating: "a", count: 17).joined(separator: "/")] {
            do {
                _ = try await api.workspaceDiff(binding: diffBinding, path: path, capability: diffCapability, accessToken: "test-token")
                XCTFail(path)
            } catch { XCTAssertFalse(error is CancellationError) }
        }
        XCTAssertTrue(DiffRequestURLProtocol.requests.isEmpty)
    }

    func testWorkspaceDiffRejectsEveryCrossScopeResponseAndLegacyHTTP200Summary() async throws {
        let session = diffSession()
        defer { session.invalidateAndCancel(); DiffRequestURLProtocol.reset() }
        let api = CodeAPIClient(session: session, baseURL: URL(string: "https://diff.invalid")!)
        let replacements: [(String, Any)] = [
            ("userId", UUID().uuidString), ("taskId", UUID().uuidString), ("repository", "other/repo"),
            ("snapshotId", UUID().uuidString), ("manifestDigest", String(repeating: "c", count: 64)),
            ("head", String(repeating: "c", count: 40)), ("version", 8)]
        for (key, value) in replacements {
            var payload = diffResponse()
            var scope = try XCTUnwrap(payload["scope"] as? [String: Any]); scope[key] = value; payload["scope"] = scope
            try DiffRequestURLProtocol.respond(payload)
            do {
                _ = try await api.workspaceDiff(binding: diffBinding, path: "README.md", capability: diffCapability, accessToken: "test-token")
                XCTFail("Accepted wrong " + key)
            } catch { XCTAssertEqual(error as? CodeAPIError, .mismatchedResponse) }
        }
        for (key, value) in [("path", "other.md" as Any), ("schemaVersion", 2 as Any), ("format", "cas-change-summary" as Any)] {
            var payload = diffResponse(); payload[key] = value
            try DiffRequestURLProtocol.respond(payload)
            do {
                _ = try await api.workspaceDiff(binding: diffBinding, path: "README.md", capability: diffCapability, accessToken: "test-token")
                XCTFail("Accepted wrong " + key)
            } catch { XCTAssertEqual(error as? CodeAPIError, .mismatchedResponse) }
        }
        try DiffRequestURLProtocol.respond(["diff": "modified README.md", "hasChanges": true,
            "changedFiles": [["path": "README.md", "status": "modified"]], "summary": ["added": 0, "modified": 1, "deleted": 0]])
        do {
            _ = try await api.workspaceDiff(binding: diffBinding, path: "README.md", capability: diffCapability, accessToken: "test-token")
            XCTFail("An old service ignoring format must not produce a patch")
        } catch { XCTAssertEqual(error as? CodeAPIError, .invalidResponse) }
    }

    func testWorkspaceDiffOmissionsHaveNoPatchAndTextPatchHasAHardBound() throws {
        for reason in ["binary", "file_too_large", "symlink", "patch_too_large"] {
            var payload = diffResponse(); payload["status"] = "omitted"; payload["format"] = "none"
            payload["reason"] = reason; payload.removeValue(forKey: "patch")
            let result = try JSONDecoder().decode(CodeWorkspaceDiffResponse.self,
                from: JSONSerialization.data(withJSONObject: payload))
            XCTAssertTrue(result.isValid(for: diffBinding, path: "README.md", capability: diffCapability))
            XCTAssertNil(result.patch)
            payload["patch"] = diffPatch
            XCTAssertFalse(try JSONDecoder().decode(CodeWorkspaceDiffResponse.self,
                from: JSONSerialization.data(withJSONObject: payload)).isValid(for: diffBinding, path: "README.md", capability: diffCapability))
        }
        for patch in ["modified README.md", diffPatch + diffPatch, "diff --git " + String(repeating: "x", count: 1_048_576)] {
            var payload = diffResponse(); payload["patch"] = patch
            XCTAssertFalse(try JSONDecoder().decode(CodeWorkspaceDiffResponse.self,
                from: JSONSerialization.data(withJSONObject: payload)).isValid(for: diffBinding, path: "README.md", capability: diffCapability))
        }
    }

    func testWorkspaceDiffRejectsOversizedDownloadAndDoesNotFallbackOnStaleSnapshot() async throws {
        let session = diffSession()
        defer { session.invalidateAndCancel(); DiffRequestURLProtocol.reset() }
        let api = CodeAPIClient(session: session, baseURL: URL(string: "https://diff.invalid")!)
        DiffRequestURLProtocol.respondRaw(Data(), contentLength: "4194305")
        do {
            _ = try await api.workspaceDiff(binding: diffBinding, path: "README.md", capability: diffCapability, accessToken: "test-token")
            XCTFail("Reject a declared oversized body before consuming it")
        } catch { XCTAssertEqual(error as? CodeAPIError, .invalidResponse) }
        try DiffRequestURLProtocol.respond(["error": "Refresh the workspace snapshot"], status: 409)
        do {
            _ = try await api.workspaceDiff(binding: diffBinding, path: "README.md", capability: diffCapability, accessToken: "test-token")
            XCTFail("A stale pin cannot silently retry against a newer snapshot")
        } catch {
            XCTAssertEqual(error as? CodeAPIError, .server(status: 409, message: "Refresh the workspace snapshot", retryable: false))
        }
        XCTAssertEqual(DiffRequestURLProtocol.requests.count, 2)
        XCTAssertTrue(DiffRequestURLProtocol.requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testWorkspaceDiffRejectsRedirectWithoutContactingItsDestination() async throws {
        let session = diffSession()
        defer { session.invalidateAndCancel(); DiffRequestURLProtocol.reset() }
        let api = CodeAPIClient(session: session, baseURL: URL(string: "https://diff.invalid")!)
        DiffRequestURLProtocol.redirect(to: URL(string: "https://redirect.invalid/private")!)
        do {
            _ = try await api.workspaceDiff(binding: diffBinding, path: "README.md", capability: diffCapability, accessToken: "test-token")
            XCTFail("Authenticated workspace reads must not follow redirects")
        } catch { XCTAssertEqual(error as? CodeAPIError, .workspaceDiffRedirect) }
        XCTAssertEqual(DiffRequestURLProtocol.requests.count, 1)
        XCTAssertEqual(DiffRequestURLProtocol.requests.first?.url?.host, "diff.invalid")
    }

    func testWorkspaceDiffRedirectFixtureActuallyFollowsWithoutReadDelegate() async throws {
        let session = diffSession()
        defer { session.invalidateAndCancel(); DiffRequestURLProtocol.reset() }
        let target = URL(string: "https://redirect.invalid/private")!
        DiffRequestURLProtocol.redirect(to: target)
        let (_, response) = try await session.data(for: URLRequest(url: URL(string: "https://diff.invalid/control")!))
        XCTAssertEqual(response.url, target)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(DiffRequestURLProtocol.requests.count, 2,
            "The synthetic redirect must really reach its target when the production rejection delegate is absent")
    }

    func testWorkspaceDiffBoundsActualBodyWithoutContentLength() async throws {
        let session = diffSession()
        defer { session.invalidateAndCancel(); DiffRequestURLProtocol.reset() }
        let api = CodeAPIClient(session: session, baseURL: URL(string: "https://diff.invalid")!)
        DiffRequestURLProtocol.respondRaw(Data(repeating: 32, count: 4 * 1024 * 1024 + 1), contentLength: nil)
        do {
            _ = try await api.workspaceDiff(binding: diffBinding, path: "README.md", capability: diffCapability, accessToken: "test-token")
            XCTFail("A missing size header must not bypass the streamed byte limit")
        } catch { XCTAssertEqual(error as? CodeAPIError, .invalidResponse) }
        XCTAssertEqual(DiffRequestURLProtocol.requests.count, 1)
    }

    private var diffBinding: CodeWorkspaceDiffBinding {
        CodeWorkspaceDiffBinding(userID: UUID(uuidString: "10000000-0000-4000-8000-000000000064")!,
            taskID: UUID(uuidString: "88000000-0000-4000-8000-000000000075")!, repository: "mychat/test-app",
            snapshotID: UUID(uuidString: "99000000-0000-4000-8000-000000000075")!,
            manifestDigest: String(repeating: "a", count: 64), head: String(repeating: "b", count: 40), version: 7)
    }
    private var diffCapability: CodeWorkspaceDiffCapability {
        CodeWorkspaceDiffCapability(schemaVersion: 1, formats: ["unified"], requiresSnapshotBinding: true,
            maxFileBytes: 262144, maxPatchBytes: 1048576)
    }
    private var diffCapabilityPayload: [String: Any] {
        ["schemaVersion": 1, "formats": ["cas-change-summary", "unified"], "requiresSnapshotBinding": true,
            "maxFileBytes": 262144, "maxPatchBytes": 1048576]
    }
    private var diffPatch: String { "diff --git a/README.md b/README.md\n--- a/README.md\n+++ b/README.md\n@@ -1 +1 @@\n-before\n+after\n" }
    private func diffResponse(path: String = "README.md") -> [String: Any] {
        ["schemaVersion": 1, "status": "ready", "format": "unified", "path": path, "patch": diffPatch,
            "scope": ["userId": diffBinding.userID.uuidString.lowercased(), "taskId": diffBinding.taskID.uuidString.lowercased(),
                "repository": diffBinding.repository, "snapshotId": diffBinding.snapshotID.uuidString.lowercased(),
                "manifestDigest": diffBinding.manifestDigest, "head": diffBinding.head, "version": diffBinding.version]]
    }
    private func diffSession() -> URLSession {
        DiffRequestURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiffRequestURLProtocol.self]
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

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

    func testRecoveryTracksPublicationJobInsteadOfCompletedCodingTask() throws {
        for status in ["queued", "running", "cancelling", "completed", "cancelled", "failed"] {
            let recovery = try recoveryStatusFixture(taskStatus: "completed",
                admissionStatus: "completed", operationStatus: status)
            XCTAssertEqual(recovery.trackingStatus, status,
                "The publication job owns the active/terminal state even though its coding task completed")
        }
    }

    func testRecoveryTracksCodingJobBeforeLaggingTaskSnapshot() throws {
        let running = try recoveryStatusFixture(taskStatus: "completed",
            admissionStatus: "running", operationStatus: nil)
        XCTAssertEqual(running.trackingStatus, "running")
        let cancelled = try recoveryStatusFixture(taskStatus: "running",
            admissionStatus: "cancelled", operationStatus: nil)
        XCTAssertEqual(cancelled.trackingStatus, "cancelled")
    }

    func testRecoveryFallsBackToTaskStatusOnlyWithoutJobAdmissions() throws {
        let terminal = try recoveryStatusFixture(taskStatus: "cancelled",
            admissionStatus: nil, operationStatus: nil)
        XCTAssertEqual(terminal.trackingStatus, "cancelled")
        let empty = try JSONDecoder().decode(CodeTaskRecovery.self,
            from: Data(#"{"admission":null,"task":null,"operationAdmission":null}"#.utf8))
        XCTAssertNil(empty.trackingStatus)
    }

    private func recoveryStatusFixture(taskStatus: String, admissionStatus: String?,
                                       operationStatus: String?) throws -> CodeTaskRecovery {
        let taskID = "33333333-3333-3333-3333-333333333333"
        func admission(_ status: String?, jobID: String) -> Any {
            guard let status else { return NSNull() }
            return ["schemaVersion": 1, "jobId": jobID, "taskId": taskID,
                "status": status, "created": false,
                "streamUrl": "/api/v1/jobs/\(jobID)/events?from_seq=0"] as [String: Any]
        }
        let task: [String: Any] = ["id": taskID, "status": taskStatus, "branch": "main",
            "toolCalls": [], "artifacts": []]
        let payload: [String: Any] = ["task": task,
            "admission": admission(admissionStatus, jobID: "22222222-2222-2222-2222-222222222222"),
            "operationAdmission": admission(operationStatus, jobID: "55555555-5555-5555-5555-555555555555")]
        return try JSONDecoder().decode(CodeTaskRecovery.self,
            from: JSONSerialization.data(withJSONObject: payload))
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

private final class DiffRequestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var captured: [URLRequest] = []
    nonisolated(unsafe) private static var payload = Data()
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var length: String?
    nonisolated(unsafe) private static var redirectURL: URL?
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    static func reset() {
        lock.lock(); defer { lock.unlock() }
        captured = []; payload = Data(); status = 200; length = nil; redirectURL = nil
    }
    static func respond(_ value: [String: Any], status code: Int = 200) throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        lock.lock(); defer { lock.unlock() }
        payload = data; status = code; length = nil; redirectURL = nil
    }
    static func respondRaw(_ value: Data, contentLength: String?) {
        lock.lock(); defer { lock.unlock() }
        payload = value; status = 200; length = contentLength; redirectURL = nil
    }
    static func redirect(to url: URL) {
        lock.lock(); defer { lock.unlock() }
        payload = Data(); status = 302; length = nil; redirectURL = url
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.captured.append(request)
        let body = Self.payload, code = Self.status, length = Self.length, redirect = Self.redirectURL
        Self.lock.unlock()
        var headers = ["Content-Type": "application/json", "Cache-Control": "private, no-store"]
        if let length { headers["Content-Length"] = length }
        if let redirect, redirect != request.url { headers["Location"] = redirect.absoluteString }
        let response = HTTPURLResponse(url: request.url!, statusCode: redirect == request.url ? 200 : code,
            httpVersion: "HTTP/1.1", headerFields: headers)!
        if let redirect, redirect != request.url {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirect), redirectResponse: response)
            // A rejected redirect still has an original HTTP response/body.
            // Omitting these callbacks made the old assertion pass only after a 30s timeout.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
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
