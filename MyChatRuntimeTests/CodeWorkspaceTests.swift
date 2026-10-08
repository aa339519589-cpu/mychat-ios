import XCTest
@testable import MyChat

@MainActor final class CodeWorkspaceTests: XCTestCase {
    func testDraftSurvivesReloadAndIsIsolatedByOwnerAndSession() {
        let owner = "code-test-" + UUID().uuidString
        defer { CodeLocalState.clear(owner: owner, scope: "new") }
        let value = CodeDraftRecord(prompt: "修复真正的测试失败", repository: "owner/repo", branch: "feature/review", mode: "plan")
        CodeLocalState.save(value, owner: owner, scope: "new")
        XCTAssertEqual(CodeLocalState.draft(owner: owner, scope: "new"), value)
        XCTAssertEqual(CodeLocalState.draft(owner: owner + "-other", scope: "new"), CodeDraftRecord())
        XCTAssertEqual(CodeLocalState.draft(owner: owner, scope: "session-other"), CodeDraftRecord())
        CodeLocalState.clear(owner: owner, scope: "new")
        XCTAssertEqual(CodeLocalState.draft(owner: owner, scope: "new"), CodeDraftRecord())
    }

    func testDeepLinkRequiresAuthenticationAndNeverSubmits() {
        let model = AppModel()
        model.openCodeLink(URL(string: "mychat://code/new?q=fix&mode=plan")!)
        XCTAssertNil(model.pendingCodeLink)
        XCTAssertEqual(model.selectedDestination, .chats)
    }

    func testRecoveryDecodesDurableTaskEvidenceAndRelativeStream() throws {
        let payload = #"{"sessionId":"11111111-1111-1111-1111-111111111111","admission":{"schemaVersion":1,"jobId":"22222222-2222-2222-2222-222222222222","taskId":"33333333-3333-3333-3333-333333333333","responseId":"44444444-4444-4444-4444-444444444444","status":"completed","created":false,"streamUrl":"/api/v1/jobs/22222222-2222-2222-2222-222222222222/events?from_seq=0","eventSequence":12},"task":{"id":"33333333-3333-3333-3333-333333333333","status":"completed","branch":"main","mode":"plan","error":null,"pullRequestUrl":null,"toolCalls":[{"id":"tool-1","toolName":"shell.exec","status":"success","output":{"exitCode":0,"stdout":"test passed"},"error":null,"durationMs":40}],"artifacts":[{"id":"artifact-1","kind":"diff","title":"Changes","content":"+ actual change","url":null}]}}"#
        let recovery = try JSONDecoder().decode(CodeTaskRecovery.self, from: Data(payload.utf8))
        XCTAssertEqual(recovery.task?.toolCalls.first?.toolName, "shell.exec")
        XCTAssertEqual(recovery.task?.artifacts.first?.kind, "diff")
        XCTAssertEqual(recovery.admission?.status, "completed")
        XCTAssertNotNil(recovery.sessionId)
    }
}
