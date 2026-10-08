import XCTest

final class CodeWorkspaceUITests: XCTestCase {
    @MainActor func testCodeListsAndRecoveryHideInternalIdentifiersInBothAppearances() {
        for appearance in ["Light", "Dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-test-mode", "--ui-test-code-display", "--ui-test-claude-models", "-AppleInterfaceStyle", appearance]
            app.launch()
            let sidebar = app.buttons["打开侧边栏"].firstMatch
            XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
            sidebar.tap()
            app.buttons["编程"].firstMatch.tap()
            let row = app.buttons["code.session.80000000-0000-4000-8000-000000000064"]
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            assertNoInternalCodeMetadata(in: app)
            XCTAssertFalse(app.staticTexts["编程"].exists)
            XCTAssertTrue(app.staticTexts["mychat/test-app"].exists)
            XCTAssertTrue(app.staticTexts["修复登录边界"].exists)
            screenshot(app, name: "code-simplified-list-\(appearance)")
            row.tap()
            let title = app.staticTexts["code.session.title"]
            XCTAssertTrue(title.waitForExistence(timeout: 10))
            XCTAssertEqual(title.label, "新建会话")
            assertNoInternalCodeMetadata(in: app)
            screenshot(app, name: "code-simplified-detail-\(appearance)")
            app.buttons["打开编程操作"].tap()
            let resume = app.staticTexts["/resume"].firstMatch
            XCTAssertTrue(resume.waitForExistence(timeout: 10))
            resume.tap()
            XCTAssertTrue(app.staticTexts["恢复会话"].firstMatch.waitForExistence(timeout: 10))
            assertNoInternalCodeMetadata(in: app)
            XCTAssertTrue(app.staticTexts["继续当前任务"].exists)
            screenshot(app, name: "code-simplified-resume-\(appearance)")
            app.terminate()
        }
    }

    @MainActor private func assertNoInternalCodeMetadata(in app: XCUIApplication) {
        let internalText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "__mychat_")).firstMatch
        XCTAssertFalse(internalText.exists)
        XCTAssertFalse(app.staticTexts["80000000-0000-4000-8000-000000000064"].exists)
    }

    // Uses the network-isolated DEBUG fixture. This checks native draft and
    // navigation behavior, and makes no claim of real Cloud execution.
    @MainActor func testUnsentPlanDraftSurvivesTerminationInBothAppearances() {
        for appearance in ["Light", "Dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-test-mode", "-AppleInterfaceStyle", appearance]
            app.launch()
            openNewCode(in: app)
            let input = app.descendants(matching: .any).matching(identifier: "code.draft").firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 10))
            XCTAssertFalse(app.staticTexts["Cloud · 已验证"].exists,
                "The isolated fixture must not claim a verified Cloud environment")
            let send = app.buttons["code.send"]
            XCTAssertGreaterThanOrEqual(send.frame.width, 44)
            XCTAssertGreaterThanOrEqual(send.frame.height, 44)
            app.segmentedControls["code.mode"].buttons["Plan · 只读"].tap()
            screenshot(app, name: "code-plan-\(appearance)-small-screen")
            input.tap()
            let marker = "Draft-" + UUID().uuidString
            input.typeText(marker)
            screenshot(app, name: "code-draft-keyboard-\(appearance)-small-screen")
            app.terminate()
            app.launch()
            openNewCode(in: app)
            XCTAssertTrue(input.waitForExistence(timeout: 10))
            XCTAssertTrue((input.value as? String)?.contains(marker) == true)
            XCTAssertTrue(app.segmentedControls["code.mode"].buttons["Plan · 只读"].isSelected)
            screenshot(app, name: "code-restored-\(appearance)-small-screen")
            app.terminate()
        }
    }

    @MainActor private func screenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func openNewCode(in app: XCUIApplication) {
        let sidebar = app.buttons["打开侧边栏"].firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
        sidebar.tap()
        let code = app.buttons["编程"].firstMatch
        XCTAssertTrue(code.waitForExistence(timeout: 10))
        code.tap()
        let newSession = app.buttons["新建会话"].firstMatch
        XCTAssertTrue(newSession.waitForExistence(timeout: 10))
        newSession.tap()
    }
}
