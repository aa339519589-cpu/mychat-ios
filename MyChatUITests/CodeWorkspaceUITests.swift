import XCTest

final class CodeWorkspaceUITests: XCTestCase {
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
