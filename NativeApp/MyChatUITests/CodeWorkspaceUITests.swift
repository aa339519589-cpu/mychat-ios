import XCTest

final class CodeWorkspaceUITests: XCTestCase {
    @MainActor func testChineseCaptionInputAndRecommendedLabelAtNormalAndLargeType() {
        for category in ["UICTContentSizeCategoryL", "UICTContentSizeCategoryAccessibilityXXXL"] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-test-mode", "--ui-test-document-reference", "--ui-test-open-conversation",
                "--ui-test-code-display", "--ui-test-claude-models", "-UIPreferredContentSizeCategoryName", category]
            app.launch()
            let thought = app.buttons["document.thinking"].firstMatch
            XCTAssertTrue(thought.waitForExistence(timeout: 15))
            if !thought.isHittable { app.scrollViews.firstMatch.swipeDown() }
            screenshot(app, name: "font-thought-" + category)
            let input = app.textViews["composer.input"].firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 10))
            input.tap(); input.typeText("推荐，当前对话，输入文字")
            screenshot(app, name: "font-composer-" + category)
            app.buttons["选择模型"].firstMatch.tap()
            let effort = app.buttons["model.effort"]
            XCTAssertTrue(effort.waitForExistence(timeout: 10))
            if !effort.isHittable { app.scrollViews.firstMatch.swipeUp() }
            effort.tap()
            XCTAssertTrue(app.staticTexts["推荐"].firstMatch.waitForExistence(timeout: 10))
            screenshot(app, name: "font-recommended-" + category)
            app.buttons["返回"].firstMatch.tap()
            let close = app.buttons["关闭"].firstMatch
            XCTAssertTrue(close.waitForExistence(timeout: 10)); close.tap()
            app.buttons["打开侧边栏"].firstMatch.tap()
            app.buttons["编程"].firstMatch.tap()
            let row = app.buttons["code.session.80000000-0000-4000-8000-000000000064"]
            XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
            app.buttons["打开编程操作"].tap()
            XCTAssertTrue(app.staticTexts["新建对话"].firstMatch.waitForExistence(timeout: 10))
            screenshot(app, name: "font-code-commands-" + category)
            app.terminate()
        }
    }

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
            XCTAssertFalse(app.segmentedControls["code.session.mode"].exists)
            XCTAssertFalse(app.staticTexts["Plan · 只读"].exists)
            XCTAssertFalse(app.staticTexts["Execute"].exists)
            assertNoInternalCodeMetadata(in: app)
            let plus = app.buttons["打开编程操作"]
            let input = app.descendants(matching: .any).matching(identifier: "code.session.draft").firstMatch
            let send = app.buttons["code.session.send"]
            XCTAssertTrue(plus.exists && input.exists && send.exists)
            XCTAssertEqual(plus.frame.midY, send.frame.midY, accuracy: 2)
            XCTAssertEqual(input.frame.midY, send.frame.midY, accuracy: 3)
            XCTAssertGreaterThan(app.frame.maxX - send.frame.maxX, 10)
            screenshot(app, name: "code-simplified-detail-\(appearance)")
            app.buttons["打开编程操作"].tap()
            XCTAssertFalse(app.staticTexts["上下文"].exists)
            let resume = app.staticTexts["历史会话"].firstMatch
            XCTAssertTrue(resume.waitForExistence(timeout: 10))
            resume.tap()
            XCTAssertTrue(app.staticTexts["恢复会话"].firstMatch.waitForExistence(timeout: 10))
            assertNoInternalCodeMetadata(in: app)
            XCTAssertTrue(app.staticTexts["继续当前任务"].exists)
            screenshot(app, name: "code-simplified-resume-\(appearance)")
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.52))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.52))
            start.press(forDuration: 0.05, thenDragTo: end)
            let originalTitle = app.staticTexts.matching(
                NSPredicate(format: "identifier == %@ AND label == %@", "code.session.title", "新建会话")
            ).firstMatch
            XCTAssertTrue(originalTitle.waitForExistence(timeout: 5))
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
    @MainActor func testUnsentCloudDraftSurvivesTerminationInBothAppearances() {
        for appearance in ["Light", "Dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-test-mode", "-AppleInterfaceStyle", appearance]
            app.launch()
            openNewCode(in: app)
            let input = app.descendants(matching: .any).matching(identifier: "code.draft").firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 10))
            let status = app.descendants(matching: .any)
                .matching(identifier: "code.execution-status").firstMatch
            XCTAssertTrue(status.waitForExistence(timeout: 10))
            XCTAssertEqual(status.label, "执行状态：云端不可用",
                "The isolated fixture must not claim a verified Cloud environment")
            let send = app.buttons["code.send"]
            XCTAssertGreaterThanOrEqual(send.frame.width, 44)
            XCTAssertGreaterThanOrEqual(send.frame.height, 44)
            XCTAssertFalse(app.segmentedControls["code.mode"].exists)
            screenshot(app, name: "code-cloud-\(appearance)-small-screen")
            input.tap()
            let marker = "Draft-" + UUID().uuidString
            input.typeText(marker)
            screenshot(app, name: "code-draft-keyboard-\(appearance)-small-screen")
            app.terminate()
            app.launch()
            openNewCode(in: app)
            XCTAssertTrue(input.waitForExistence(timeout: 10))
            XCTAssertTrue((input.value as? String)?.contains(marker) == true)
            XCTAssertFalse(app.staticTexts["Plan · 只读"].exists)
            screenshot(app, name: "code-restored-\(appearance)-small-screen")
            app.terminate()
        }
    }

    @MainActor func testCodeDetailAndNewSessionRequireExplicitBackNavigation() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-mode", "--ui-test-code-display", "--ui-test-claude-models"]
        app.launch()

        let sidebar = app.buttons["打开侧边栏"].firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
        sidebar.tap()
        app.buttons["编程"].firstMatch.tap()
        let row = app.buttons["code.session.80000000-0000-4000-8000-000000000064"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        let title = app.staticTexts["code.session.title"]
        let send = app.buttons["code.session.send"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertTrue(send.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["停止 Code 任务"].exists)
        XCTAssertFalse(app.buttons["编程会话操作"].exists)
        XCTAssertGreaterThanOrEqual(send.frame.width, 44)
        XCTAssertGreaterThanOrEqual(send.frame.height, 44)

        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: 1, dy: app.frame.height * 0.5))
        let end = origin.withOffset(CGVector(dx: app.frame.width * 0.78, dy: app.frame.height * 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Code detail must stay until the explicit back button is tapped")
        app.buttons["code.session.back"].tap()

        let newSession = app.buttons["新建会话"].firstMatch
        XCTAssertTrue(newSession.waitForExistence(timeout: 10))
        newSession.tap()
        let draft = app.descendants(matching: .any).matching(identifier: "code.draft").firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        let newBack = app.buttons["code.new.back"]
        XCTAssertTrue(newBack.exists)
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(draft.waitForExistence(timeout: 5), "New Code session must not be dismissed by an edge swipe")
        newBack.tap()
        app.terminate()
    }

    @MainActor func testGitHubRepositorySelectionRestoresWithoutManualWebConnection() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-mode", "--ui-test-connected-github"]
        app.launch()
        openNewCode(in: app)

        let repositoryName = "aa339519589-cpu/mychat-ios"
        let selector = app.buttons["code.repository-selector"]
        XCTAssertTrue(selector.waitForExistence(timeout: 10))
        let connectedLabel = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "选择仓库"),
            object: selector
        )
        XCTAssertEqual(XCTWaiter.wait(for: [connectedLabel], timeout: 10), .completed)
        selector.tap()

        let repository = app.buttons["code.github.repository." + repositoryName]
        XCTAssertTrue(repository.waitForExistence(timeout: 10))
        repository.tap()
        let selectedLabel = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", repositoryName),
            object: selector
        )
        XCTAssertEqual(XCTWaiter.wait(for: [selectedLabel], timeout: 10), .completed)
        app.buttons["code.new.back"].tap()

        openNewCode(in: app)
        let restored = app.buttons["code.repository-selector"]
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        let restoredLabel = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", repositoryName),
            object: restored
        )
        XCTAssertEqual(XCTWaiter.wait(for: [restoredLabel], timeout: 10), .completed)
        XCTAssertFalse(app.staticTexts["请先在 MyChat 网页版连接 GitHub，然后刷新此页面。"].exists)
        app.terminate()
    }

    @MainActor func testUnconnectedCodeShowsNativeGitHubEntryWithoutWebInstructions() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-mode"]
        app.launch()
        openNewCode(in: app)

        let connect = app.buttons["code.repository-selector"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        let disconnectedLabel = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "连接 GitHub"),
            object: connect
        )
        XCTAssertEqual(XCTWaiter.wait(for: [disconnectedLabel], timeout: 10), .completed)
        XCTAssertTrue(connect.isEnabled)
        XCTAssertFalse(app.staticTexts["请先在 MyChat 网页版连接 GitHub，然后刷新此页面。"].exists)
        let status = app.descendants(matching: .any)
            .matching(identifier: "code.execution-status").firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.label, "执行状态：云端不可用")
        app.terminate()
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

