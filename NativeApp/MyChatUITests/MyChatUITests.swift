import XCTest

final class MyChatUITests: XCTestCase {
    @MainActor func testHorizontalPhotosKeepGestureOwnershipAndReachTheLastImage() {
        let app = launch(extra: ["--ui-test-images", "--ui-test-wide-images", "--ui-test-open-conversation"])
        let prefix = "message.image.50000000-0000-4000-8000-000000000066."
        let first = app.buttons[prefix + "0"], last = app.buttons[prefix + "4"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        let initialX = first.frame.minX
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let y = first.frame.midY
        let left = initialX + 25
        origin.withOffset(CGVector(dx: app.frame.width - 35, dy: y)).press(forDuration: 0.03,
            thenDragTo: origin.withOffset(CGVector(dx: left, dy: y)))
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        XCTAssertTrue(last.isHittable)
        XCTAssertFalse(app.buttons["sidebar.accountSettings"].isHittable)
        origin.withOffset(CGVector(dx: left, dy: y)).press(forDuration: 0.03,
            thenDragTo: origin.withOffset(CGVector(dx: app.frame.width - 35, dy: y)))
        XCTAssertFalse(app.buttons["sidebar.accountSettings"].isHittable,
            "Dragging photos right must not be stolen by the full-screen drawer recognizer")
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertEqual(first.frame.minX, initialX, accuracy: 2)
        saveScreenshot(app, "five-photos-horizontal-gesture")
    }

    @MainActor func testLargeTextComposerGrowsWithinScreenAndRetainsDraftOnRotation() {
        let app = launch(extra: ["--ui-test-seed-draft", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"])
        let input = app.textViews["composer.input"]
        let surface = app.descendants(matching: .any).matching(identifier: "composer.surface").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let draft = input.value as? String
        XCTAssertTrue(draft?.contains("你好明确") == true)
        XCTAssertGreaterThan(input.frame.height, 60)
        XCTAssertGreaterThanOrEqual(surface.frame.minY, app.buttons["header.sidebar"].frame.maxY)
        XCTAssertLessThanOrEqual(surface.frame.maxY, app.keyboards.firstMatch.frame.minY)
        XCTAssertTrue(app.buttons["composer.send"].isHittable)
        saveScreenshot(app, "large-text-long-draft")
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width > app.frame.height && surface.frame.maxX <= app.frame.maxX + 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 5), .completed)
        XCTAssertEqual(input.value as? String, draft)
        XCTAssertTrue(app.buttons["composer.send"].isHittable)
        XCTAssertGreaterThanOrEqual(surface.frame.minY, app.buttons["header.sidebar"].frame.maxY,
            "Landscape must keep the composer below navigation, including at large font sizes")
        XCTAssertLessThanOrEqual(surface.frame.maxY, app.keyboards.firstMatch.frame.minY)
        saveScreenshot(app, "rotation-contract")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertEqual(input.value as? String, draft)
    }

    @MainActor func testComposerTouchTargetsAndHapticPreferencePersist() {
        let app = launch()
        let input = app.textViews["composer.input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let composerControls: [(String, String)] = [
            ("composer.add", "添加内容和工具"),
            ("composer.model-picker", "选择模型"),
            ("语音转文字", "语音转文字")
        ]
        for (identifier, expectedLabel) in composerControls {
            let button = app.buttons[identifier].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing composer control: \(identifier)")
            XCTAssertTrue(button.label.contains(expectedLabel), "Unexpected accessibility label: \(button.label)")
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }
        input.tap(); input.typeText("hello")
        let send = app.buttons["composer.send"].firstMatch
        XCTAssertGreaterThanOrEqual(send.frame.width, 44)
        XCTAssertGreaterThanOrEqual(send.frame.height, 44)
        app.buttons["header.sidebar"].tap()
        app.buttons["sidebar.accountSettings"].tap()
        app.buttons["功能"].firstMatch.tap()
        let toggle = app.switches["settings.haptics"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if toggle.value as? String == "1" { toggle.tap() }
        XCTAssertEqual(toggle.value as? String, "0")
        app.terminate(); app.launch()
        app.buttons["header.sidebar"].tap()
        app.buttons["sidebar.accountSettings"].tap()
        app.buttons["功能"].firstMatch.tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0", "Haptic preference must persist across relaunch")
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, "1")
    }

    @MainActor func testManualReadingPositionSurvivesNewChatAndReturn() {
        let app = launch(extra: ["--ui-test-long-chat", "--layout-audit"])
        app.buttons["header.sidebar"].tap()
        app.buttons["隔离测试对话"].firstMatch.tap()
        let tail = app.descendants(matching: .any).matching(identifier: "message.row.50000000-0000-4000-8000-0000000003E8").firstMatch
        XCTAssertTrue(tail.waitForExistence(timeout: 30))
        let origin = app.coordinate(withNormalizedOffset: .zero)
        for _ in 0..<2 {
            origin.withOffset(CGVector(dx: app.frame.midX, dy: 220)).press(forDuration: 0.02,
                thenDragTo: origin.withOffset(CGVector(dx: app.frame.midX, dy: 520)))
        }
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "message.row.")).allElementsBoundByIndex
        guard let anchor = rows.first(where: { $0.frame.minY > 140 && $0.frame.maxY < 600 && $0.isHittable }) else {
            XCTFail("No visible reading anchor after scrolling into history"); return
        }
        let identifier = anchor.identifier, before = anchor.frame.minY
        app.buttons["header.new-chat"].tap()
        app.buttons["header.sidebar"].tap()
        app.buttons["隔离测试对话"].firstMatch.tap()
        let restored = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        expectation(for: NSPredicate { _, _ in abs(restored.frame.minY - before) < 3 }, evaluatedWith: restored)
        waitForExpectations(timeout: 8)
        XCTAssertTrue(app.buttons["chat.jump-to-latest"].exists)
        saveScreenshot(app, "reading-position-restored")
    }

    @MainActor func testPaperPanelSlowFastAndRepeatedSwipes() {
        let app = launch(extra: ["--drawer-motion-audit"])
        let account = app.buttons["sidebar.accountSettings"]
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let y = app.frame.height * 0.48
        app.buttons["header.sidebar"].tap()
        origin.withOffset(CGVector(dx: app.frame.width - 20, dy: y)).tap()
        for velocity in [90.0, 1_800.0, 600.0, 600.0] {
            origin.withOffset(CGVector(dx: 45, dy: y)).press(forDuration: 0.04,
                thenDragTo: origin.withOffset(CGVector(dx: 265, dy: y)),
                withVelocity: XCUIGestureVelocity(rawValue: velocity), thenHoldForDuration: 0.08)
            XCTAssertTrue(account.waitForExistence(timeout: 3))
            XCTAssertTrue(account.isHittable)
            saveScreenshot(app, "paper-open-\(Int(velocity))")
            origin.withOffset(CGVector(dx: app.frame.width - 24, dy: y)).press(forDuration: 0.04,
                thenDragTo: origin.withOffset(CGVector(dx: app.frame.width - 244, dy: y)),
                withVelocity: XCUIGestureVelocity(rawValue: velocity), thenHoldForDuration: 0.08)
            XCTAssertTrue(app.buttons["header.sidebar"].isHittable)
            XCTAssertFalse(account.isHittable)
        }
        saveScreenshot(app, "paper-closed-after-repeat")
    }

    @MainActor private func waitForHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let hittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: element
        )
        return XCTWaiter.wait(for: [hittable], timeout: timeout) == .completed
    }

    @MainActor private func isEmptyTextField(_ field: XCUIElement, placeholder: String) -> Bool {
        guard let value = field.value as? String else { return true }
        return value.isEmpty || value == placeholder
    }

    @MainActor private func openConnectorSettings(in app: XCUIApplication) {
        app.buttons["header.sidebar"].tap()
        let accountSettings = app.buttons["sidebar.accountSettings"].firstMatch
        XCTAssertTrue(accountSettings.waitForExistence(timeout: 5))
        accountSettings.tap()
        let connectors = app.buttons["连接器"].firstMatch
        XCTAssertTrue(connectors.waitForExistence(timeout: 5))
        connectors.tap()
        XCTAssertTrue(app.buttons["添加连接器"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor private func waitForKeyboardDismissal(in app: XCUIApplication) {
        let keyboardDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !app.keyboards.firstMatch.exists },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardDismissed], timeout: 5), .completed)
    }

    @MainActor private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-mode"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["打开侧边栏"].firstMatch.waitForExistence(timeout: 15))
        return app
    }

    @MainActor func testShortGentleSwipesOpenAndCloseDrawerFromAnywhere() {
        let app = launch(extra: ["--drawer-motion-audit"])
        let account = app.buttons["sidebar.accountSettings"]
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let y = app.frame.height * 0.48
        // Dismiss startup keyboard and establish a closed drawer first.
        app.buttons["header.sidebar"].tap()
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        origin.withOffset(CGVector(dx: app.frame.width - 24, dy: y)).tap()
        XCTAssertFalse(account.isHittable)

        for fraction in [0.15, 0.5, 0.85] {
            let x = app.frame.width * fraction
            let opening = origin.withOffset(CGVector(dx: x, dy: y))
            opening.press(forDuration: 0.03,
                thenDragTo: origin.withOffset(CGVector(dx: x + 40, dy: y)),
                withVelocity: .slow, thenHoldForDuration: 0.08)
            expectation(for: NSPredicate(format: "exists == true AND hittable == true"), evaluatedWith: account)
            waitForExpectations(timeout: 5)

            let closing = origin.withOffset(CGVector(dx: app.frame.width - 24, dy: y))
            closing.press(forDuration: 0.03,
                thenDragTo: origin.withOffset(CGVector(dx: app.frame.width - 64, dy: y)),
                withVelocity: .slow, thenHoldForDuration: 0.08)
            expectation(for: NSPredicate(format: "hittable == false"), evaluatedWith: account)
            waitForExpectations(timeout: 5)
            XCTAssertTrue(app.buttons["header.sidebar"].isHittable)
        }
        saveScreenshot(app, "short-gentle-swipe-closed")
    }

    @MainActor func testProjectPickerRemovesNoneAndShowsReferenceEmptyState() {
        let app = launch(extra: ["--ui-test-no-projects"])
        app.buttons["plus"].tap()
        let projects = app.buttons["tools.projects.row"]
        XCTAssertTrue(projects.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["无"].exists)
        projects.tap()
        XCTAssertTrue(app.staticTexts["暂无项目"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["tools.projects.search"].exists)
        XCTAssertTrue(app.buttons["tools.projects.create"].isHittable)
        XCTAssertFalse(app.buttons["无"].exists)
        saveScreenshot(app, "projects-empty-reference")
        app.buttons["tools.projects.create"].tap()
        XCTAssertTrue(app.textFields["项目名称"].waitForExistence(timeout: 5))
        app.buttons["关闭"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["暂无项目"].waitForExistence(timeout: 5))
    }

    @MainActor func testVerticalChatScrollMovesContentWithoutOpeningDrawer() {
        let app = launch(extra: ["--ui-test-long-chat"])
        app.buttons["header.sidebar"].tap()
        let conversation = app.buttons["隔离测试对话"].firstMatch
        XCTAssertTrue(conversation.waitForExistence(timeout: 5))
        conversation.tap()
        let tail = app.descendants(matching: .any)
            .matching(identifier: "message.row.50000000-0000-4000-8000-0000000003E8").firstMatch
        XCTAssertTrue(tail.waitForExistence(timeout: 30))
        XCTAssertFalse(app.keyboards.firstMatch.exists)

        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "message.row."))
            .allElementsBoundByIndex
        guard let anchor = rows.first(where: {
            $0.isHittable && $0.frame.minY > 180 && $0.frame.maxY < app.frame.height - 150
        }) else {
            XCTFail("Expected a visible conversation row before vertical scrolling")
            return
        }
        let before = anchor.frame.minY
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let x = app.frame.midX
        origin.withOffset(CGVector(dx: x, dy: app.frame.height * 0.58)).press(forDuration: 0.03,
            thenDragTo: origin.withOffset(CGVector(dx: x, dy: app.frame.height * 0.34)),
            withVelocity: .slow, thenHoldForDuration: 0.08)

        let transcriptMoved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !anchor.isHittable || abs(anchor.frame.minY - before) > 40
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [transcriptMoved], timeout: 5), .completed,
            "A vertical-intent gesture must still scroll the transcript")
        XCTAssertFalse(app.buttons["sidebar.accountSettings"].isHittable,
            "Vertical transcript scrolling must not reveal the drawer")
        XCTAssertTrue(app.buttons["header.sidebar"].isHittable)
    }

    @MainActor func testVerticalSwipeWithSidewaysDriftDoesNotOpenDrawer() {
        let app = launch()
        let account = app.buttons["sidebar.accountSettings"]
        let origin = app.coordinate(withNormalizedOffset: .zero)
        app.buttons["header.sidebar"].tap()
        origin.withOffset(CGVector(dx: app.frame.width - 24, dy: app.frame.height * 0.48)).tap()
        XCTAssertFalse(account.isHittable)
        for dx in [-22.0, 22.0] {
            let start = origin.withOffset(CGVector(dx: app.frame.width * 0.5, dy: app.frame.height * 0.55))
            start.press(forDuration: 0.03,
                thenDragTo: origin.withOffset(CGVector(dx: app.frame.width * 0.5 + dx, dy: app.frame.height * 0.55 - 110)),
                withVelocity: .slow, thenHoldForDuration: 0.08)
            XCTAssertFalse(account.isHittable, "Vertical intent must remain page scrolling")
            XCTAssertTrue(app.buttons["header.sidebar"].isHittable)
        }
    }

    @MainActor func testDefaultConnectorsContainsAppleButNoGmail() {
        let app = launch()
        app.buttons["plus"].tap()
        app.buttons["连接器"].firstMatch.tap()
        XCTAssertTrue(app.buttons["connectors.default.health"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["connectors.default.gmail"].exists)
        XCTAssertFalse(app.staticTexts["Gmail"].exists)
    }

    @MainActor func testConnectorDirectoryPushesAndPreservesEachPriorScreen() {
        let app = launch()
        openConnectorSettings(in: app)

        let addMenu = app.buttons["添加连接器"].firstMatch
        XCTAssertTrue(addMenu.waitForExistence(timeout: 5))
        addMenu.tap()
        app.buttons["浏览连接器"].firstMatch.tap()

        let directorySearch = app.textFields["connector.directory.search"].firstMatch
        let sample = app.buttons["connector.catalog.sample"].firstMatch
        XCTAssertTrue(directorySearch.waitForExistence(timeout: 8))
        XCTAssertTrue(sample.waitForExistence(timeout: 8))
        sample.tap()

        let name = app.textFields["connector.name"].firstMatch
        let serverURL = app.textFields["connector.server-url"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Sample service")
        XCTAssertEqual(serverURL.value as? String, "https://connector.example.invalid/mcp")
        XCTAssertTrue(app.navigationBars["连接服务"].exists)

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(directorySearch.waitForExistence(timeout: 5),
            "Popping the editor must reveal the same directory screen")
        XCTAssertTrue(sample.exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(addMenu.waitForExistence(timeout: 5))

        addMenu.tap()
        app.buttons["添加自定义连接器"].firstMatch.tap()
        let editorName = app.textFields["connector.name"].firstMatch
        XCTAssertTrue(editorName.waitForExistence(timeout: 5))
        editorName.tap()
        editorName.typeText("Unsaved draft")
        app.buttons["connector.directory"].tap()
        XCTAssertTrue(directorySearch.waitForExistence(timeout: 5))
        sample.tap()
        XCTAssertEqual(editorName.value as? String, "Sample service",
            "Selecting a common service must update the editor that remains beneath the directory")

        app.buttons["connector.directory"].tap()
        XCTAssertTrue(directorySearch.waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(editorName.waitForExistence(timeout: 5))
        XCTAssertEqual(editorName.value as? String, "Sample service",
            "Returning from the nested directory must preserve the editor state")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(addMenu.waitForExistence(timeout: 5),
            "Canceling the editor must return to connector settings")
    }

    @MainActor func testConnectorEditorSaveCancelAndRepeatedOpenResetState() {
        let app = launch()
        openConnectorSettings(in: app)
        let addMenu = app.buttons["添加连接器"].firstMatch
        XCTAssertTrue(addMenu.waitForExistence(timeout: 5))

        addMenu.tap()
        app.buttons["添加自定义连接器"].firstMatch.tap()
        let name = app.textFields["connector.name"].firstMatch
        let serverURL = app.textFields["connector.server-url"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Fixture saved connector")
        serverURL.tap()
        serverURL.typeText("https://fixture.example.invalid/mcp")
        app.buttons["无"].tap()
        let connect = app.buttons["connector.connect"]
        XCTAssertTrue(connect.isEnabled)
        connect.tap()

        XCTAssertTrue(app.staticTexts["Fixture saved connector"].waitForExistence(timeout: 10),
            "A successful isolated save must return to the connector list")
        XCTAssertTrue(addMenu.waitForExistence(timeout: 5))

        addMenu.tap()
        app.buttons["添加自定义连接器"].firstMatch.tap()
        let reopenedName = app.textFields["connector.name"].firstMatch
        XCTAssertTrue(reopenedName.waitForExistence(timeout: 5))
        XCTAssertTrue(isEmptyTextField(reopenedName, placeholder: "名称"),
            "Reopening a saved editor must start a fresh custom connector")
        reopenedName.tap()
        reopenedName.typeText("Canceled draft")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(addMenu.waitForExistence(timeout: 5),
            "Back/cancel must pop the editor without dismissing the Settings navigation flow")

        addMenu.tap()
        app.buttons["添加自定义连接器"].firstMatch.tap()
        XCTAssertTrue(reopenedName.waitForExistence(timeout: 5))
        XCTAssertTrue(isEmptyTextField(reopenedName, placeholder: "名称"),
            "Reopening after cancel must not restore a discarded draft")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(addMenu.waitForExistence(timeout: 5))
    }

    /// Reproduces transcript/composer geometry: the newest row must clear the
    /// floating composer at rest, and the transcript must still reach its true
    /// bottom with the keyboard up.
    @MainActor func testTranscriptClearsComposerAndScrollsWithKeyboard() {
        let app = launch(extra: ["--ui-test-long-chat", "-AppleInterfaceStyle", "Dark", "--layout-audit"])
        app.buttons["打开侧边栏"].firstMatch.tap()
        app.buttons["隔离测试对话"].firstMatch.tap()

        let tail = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "长聊天第 1000 条回复")
        ).firstMatch
        XCTAssertTrue(tail.waitForExistence(timeout: 30), "The newest message in a 1,000-message transcript did not render")
        saveScreenshot(app, "geometry-bottom-rest")

        let input = app.descendants(matching: .any).matching(identifier: "composer.input").firstMatch
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        saveScreenshot(app, "geometry-bottom-keyboard-open")

        let transcript = app.scrollViews.firstMatch
        let surface = app.descendants(matching: .any).matching(identifier: "composer.surface").firstMatch
        func dragVisibleTranscript(down: Bool) {
            // The full-height scroll view extends behind the keyboard. Drag
            // only through the exposed chat, never through keyboard keys.
            let top = app.buttons["打开侧边栏"].firstMatch.frame.maxY + 40
            let bottom = surface.frame.minY - 28
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let upper = origin.withOffset(CGVector(dx: app.frame.midX, dy: top))
            let lower = origin.withOffset(CGVector(dx: app.frame.midX, dy: bottom))
            if down { upper.press(forDuration: 0.02, thenDragTo: lower) }
            else { lower.press(forDuration: 0.02, thenDragTo: upper) }
        }
        for _ in 0..<8 {
            dragVisibleTranscript(down: false)
        }
        saveScreenshot(app, "geometry-bottom-keyboard-after-swipes")

        let tailFrame = tail.frame
        let clearance = surface.frame.minY - tailFrame.maxY
        XCTAssertGreaterThanOrEqual(clearance, 0,
            "The newest row must sit fully above the composer surface (clearance \(clearance))")

        dragVisibleTranscript(down: true)
        // The first downward gesture can dismiss the keyboard without leaving
        // the latest row; the next gesture actually navigates into history.
        dragVisibleTranscript(down: true)
        let latest = app.buttons["跳到最新消息"]
        XCTAssertTrue(latest.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(latest.frame.maxY, surface.frame.minY,
            "The latest-message action must remain above the floating composer")
        XCTAssertTrue(latest.isHittable)
        latest.tap()
        XCTAssertTrue(tail.waitForExistence(timeout: 5))
    }

    @MainActor func testSidebarDestinationsAndRepeatedOpenClose() {
        let app = launch()
        for destination in ["项目", "可视化", "编程", "聊天"] {
            app.buttons["打开侧边栏"].firstMatch.tap()
            let button = app.buttons[destination].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            XCTAssertTrue(button.isHittable)
            button.tap()
            XCTAssertTrue(app.buttons["打开侧边栏"].firstMatch.waitForExistence(timeout: 5))
        }
        for _ in 0..<5 {
            app.buttons["打开侧边栏"].firstMatch.tap()
            XCTAssertTrue(app.buttons["sidebar.newChat"].firstMatch.waitForExistence(timeout: 5))
            app.buttons["sidebar.newChat"].firstMatch.tap()
        }
        saveScreenshot(app, "sidebar-and-top-buttons")
    }

    @MainActor func testSidebarSelectionTraitTracksDestination() {
        let app = launch()
        let sidebar = app.buttons["打开侧边栏"].firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5))

        sidebar.tap()
        let projects = app.buttons["项目"].firstMatch
        XCTAssertTrue(projects.waitForExistence(timeout: 5))
        projects.tap()

        sidebar.tap()
        let selectedProjects = app.buttons["项目"].firstMatch
        XCTAssertTrue(selectedProjects.waitForExistence(timeout: 5))
        XCTAssertTrue(selectedProjects.isSelected)

        let code = app.buttons["编程"].firstMatch
        XCTAssertTrue(waitForHittable(code, timeout: 5))
        code.tap()
        sidebar.tap()
        let selectedCode = app.buttons["编程"].firstMatch
        XCTAssertTrue(selectedCode.waitForExistence(timeout: 5))
        XCTAssertTrue(selectedCode.isSelected)
        XCTAssertFalse(app.buttons["项目"].firstMatch.isSelected)
    }

    @MainActor func testArtifactLibraryOpensAndDismissesPreviewRepeatedly() {
        let app = launch(extra: ["--ui-test-artifacts"])
        app.buttons["打开侧边栏"].firstMatch.tap()
        app.buttons["可视化"].firstMatch.tap()

        let artifact = app.buttons["artifact-record-70000000-0000-4000-8000-000000000064"]
        XCTAssertTrue(artifact.waitForExistence(timeout: 10))
        let hittable = NSPredicate(format: "exists == true AND hittable == true")
        expectation(for: hittable, evaluatedWith: artifact)
        waitForExpectations(timeout: 5)
        if #available(iOS 26.0, *) {
            artifact.tap()
            let close = app.buttons["artifact-preview-close"]
            XCTAssertTrue(close.waitForExistence(timeout: 10))
            measure(metrics: [XCTHitchMetric(application: app)]) {
                close.tap()
                let deadline = ProcessInfo.processInfo.systemUptime + 3
                while close.exists && ProcessInfo.processInfo.systemUptime < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                }
                XCTAssertFalse(close.exists, "Artifact preview failed to dismiss")
                XCTAssertTrue(artifact.isHittable)
                artifact.tap()
                XCTAssertTrue(close.waitForExistence(timeout: 10))
            }
        } else {
            for _ in 0..<3 {
                artifact.tap()
                let close = app.buttons["artifact-preview-close"]
                XCTAssertTrue(close.waitForExistence(timeout: 10))
                XCTAssertTrue(close.isHittable)
                let start = ProcessInfo.processInfo.systemUptime
                close.tap()
                let deadline = start + 3
                while close.exists && ProcessInfo.processInfo.systemUptime < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.02))
                }
                let elapsedMS = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
                XCTContext.runActivity(named: "Artifact preview dismissal: \(elapsedMS) ms") { activity in
                    activity.add(XCTAttachment(string: "\(elapsedMS) ms"))
                }
                XCTAssertFalse(close.exists, "Artifact preview failed to dismiss")
                XCTAssertLessThan(Double(elapsedMS) / 1000, 2.5,
                    "Artifact preview dismissal exceeded the interaction budget")
                XCTAssertTrue(artifact.isHittable)
            }
        }
    }

    @MainActor func testArtifactPreviewEdgeSwipeCancelsAndReturnsRepeatedly() {
        verifyArtifactEdgeSwipe(fixture: "--ui-test-artifacts-large")
    }

    @MainActor func testSVGArtifactPreviewEdgeSwipeCancelsAndReturnsRepeatedly() {
        verifyArtifactEdgeSwipe(fixture: "--ui-test-artifacts-svg-large")
    }

    @MainActor private func verifyArtifactEdgeSwipe(fixture: String) {
        let app = launch(extra: [fixture, "--artifact-motion-audit"])
        app.buttons["打开侧边栏"].firstMatch.tap()
        app.buttons["可视化"].firstMatch.tap()

        let artifact = app.buttons["artifact-record-70000000-0000-4000-8000-000000000064"].firstMatch
        XCTAssertTrue(waitForHittable(artifact, timeout: 10))
        artifact.tap()

        let close = app.buttons["artifact-preview-close"].firstMatch
        let opened = waitForHittable(close, timeout: 10)
        recordArtifactPreviewState(app, phase: "opened", captureDetailFrames: true)
        XCTAssertTrue(opened, "The preview close control must become hittable before an edge gesture")
        guard opened else { return }
        if fixture == "--ui-test-artifacts-svg-large" {
            let native = app.descendants(matching: .any)
                .matching(identifier: "artifact-native-preview-inline-artifact").firstMatch
            XCTAssertTrue(native.waitForExistence(timeout: 10),
                "The SVG fixture must actually open the native inline-artifact preview")
        }
        let originalCloseMinX = close.frame.minX
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let width = app.frame.width
        let y = app.frame.height * 0.55

        func dragFromLeadingEdge(_ distance: CGFloat) {
            let start = origin.withOffset(CGVector(dx: 5, dy: y))
            start.press(forDuration: 0.03,
                thenDragTo: origin.withOffset(CGVector(dx: 5 + distance, dy: y)),
                withVelocity: .slow, thenHoldForDuration: 0.08)
        }

        // A short edge drag must settle back in place without dismissing the cover.
        dragFromLeadingEdge(34)
        let cancelled = waitForHittable(close, timeout: 5)
        XCTAssertTrue(cancelled,
            "A cancelled edge swipe must restore the artifact detail")
        let settleDeadline = ProcessInfo.processInfo.systemUptime + 2
        while abs(close.frame.minX - originalCloseMinX) > 2,
              ProcessInfo.processInfo.systemUptime < settleDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(close.frame.minX, originalCloseMinX, accuracy: 3,
            "A cancelled edge swipe must return the detail to its starting position")
        XCTAssertFalse(artifact.isHittable,
            "The artifact row must remain covered after a cancelled edge swipe")
        recordArtifactPreviewState(app, phase: "cancelled", captureDetailFrames: cancelled)

        // The same natural gesture must dismiss the detail and work again after re-entry.
        for cycle in 0..<2 {
            if !close.isHittable { artifact.tap() }
            XCTAssertTrue(waitForHittable(close, timeout: 10))
            dragFromLeadingEdge(width * 0.33)
            XCTContext.runActivity(named: "Artifact edge return geometry") { activity in
                let closeStillExists = close.exists
                let attachment = XCTAttachment(string: "screenWidth=\(width); requestedTravel=\(width * 0.33); originalCloseMinX=\(originalCloseMinX); closeExistsAfterDrag=\(closeStillExists)")
                attachment.lifetime = .keepAlways
                activity.add(attachment)
            }
            expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: close)
            waitForExpectations(timeout: 8)
            let listRestored = waitForHittable(artifact, timeout: 8)
            recordArtifactPreviewState(app, phase: "returned-\(cycle)", captureDetailFrames: false)
            XCTAssertTrue(listRestored,
                "The artifact list must be restored after the edge swipe")
        }
    }

    @MainActor private func recordArtifactPreviewState(_ app: XCUIApplication,
        phase: String, captureDetailFrames: Bool) {
        // Only known fixture/control geometry. Never dump the application tree,
        // arbitrary labels, source HTML, or a frame after its dismissal.
        let started = ProcessInfo.processInfo.systemUptime
        let close = app.buttons["artifact-preview-close"].firstMatch
        let row = app.buttons["artifact-record-70000000-0000-4000-8000-000000000064"].firstMatch
        let native = app.descendants(matching: .any)
            .matching(identifier: "artifact-native-preview-inline-artifact").firstMatch
        let closeExists = close.exists
        let rowExists = row.exists
        let nativeExists = native.exists
        let closeFrame = captureDetailFrames && closeExists ? String(describing: close.frame) : "not-sampled"
        let nativeFrame = captureDetailFrames && nativeExists ? String(describing: native.frame) : "not-sampled"
        let diagnostic = "ARTIFACT_PREVIEW_AX phase=\(phase) closeExists=\(closeExists) closeHittable=\(close.isHittable) closeFrame=\(closeFrame) nativeExists=\(nativeExists) nativeFrame=\(nativeFrame) rowExists=\(rowExists) rowHittable=\(row.isHittable) queryMs=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))"
        print(diagnostic)
        let attachment = XCTAttachment(string: diagnostic)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testArtifactLibraryKeepsEveryDocumentInPackage() {
        let app = launch(extra: ["--ui-test-document-library"])
        app.buttons["打开侧边栏"].firstMatch.tap()
        app.buttons["可视化"].firstMatch.tap()
        let artifact = app.buttons["artifact-record-70000000-0000-4000-8000-000000000065"]
        XCTAssertTrue(artifact.waitForExistence(timeout: 10))
        artifact.tap()
        for (title, heading) in [("第一篇文章", "第一篇正文"), ("第二篇文章", "第二篇正文")] {
            let document = app.buttons[title].firstMatch
            XCTAssertTrue(document.waitForExistence(timeout: 5))
            document.tap()
            XCTAssertTrue(app.staticTexts[heading].firstMatch.waitForExistence(timeout: 5))
            app.buttons["关闭文件预览"].tap()
            XCTAssertTrue(document.waitForExistence(timeout: 5))
        }
        XCTAssertTrue(app.buttons["全部下载"].exists)
        app.buttons["artifact-preview-close"].tap()
        XCTAssertTrue(artifact.waitForExistence(timeout: 5))
    }

    @MainActor func testLongTranscriptRendersTailAndSurvivesRepeatedScrolling() {
        let app = launch(extra: ["--ui-test-long-chat", "-AppleInterfaceStyle", "Dark"])
        app.buttons["打开侧边栏"].firstMatch.tap()
        app.buttons["隔离测试对话"].firstMatch.tap()

        let tail = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "长聊天第 1000 条回复")
        ).firstMatch
        let openStarted = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(tail.waitForExistence(timeout: 30), "The newest message in a 1,000-message transcript did not render")
        let openElapsed = ProcessInfo.processInfo.systemUptime - openStarted
        XCTContext.runActivity(named: "Open 1,000-message Markdown transcript: \(Int(openElapsed * 1000)) ms") { activity in
            activity.add(XCTAttachment(string: "\(Int(openElapsed * 1000)) ms from history tap through newest-row visibility"))
        }

        let transcript = app.scrollViews.firstMatch
        XCTAssertTrue(transcript.exists)
        let earlier = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "长聊天第 994 条回复")
        ).firstMatch
        for _ in 0..<6 {
            transcript.swipeDown()
            if earlier.waitForExistence(timeout: 2) { break }
        }
        XCTAssertTrue(earlier.exists, "Scrolling upward through the long transcript did not render earlier rows")
        saveScreenshot(app, "long-transcript-earlier-row")

        for _ in 0..<6 {
            transcript.swipeUp()
            if tail.waitForExistence(timeout: 2) { break }
        }
        XCTAssertTrue(tail.exists, "Returning to the transcript tail did not render the newest row")
        saveScreenshot(app, "long-transcript-tail-restored")

        let start = ProcessInfo.processInfo.systemUptime
        for _ in 0..<2 {
            transcript.swipeDown()
            transcript.swipeUp()
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTContext.runActivity(named: "Four XCTest-synchronized scroll actions: \(Int(elapsed * 1000)) ms") { activity in
            activity.add(XCTAttachment(string: "\(Int(elapsed * 1000)) ms; includes XCTest synchronization, not app-frame latency"))
        }

        transcript.swipeUp()
        let input = app.descendants(matching: .any).matching(identifier: "composer.input").firstMatch
        let bubble = app.descendants(matching: .any).matching(identifier: "composer.surface").firstMatch
        XCTAssertEqual(bubble.frame.height, 104, accuracy: 2)
        saveScreenshot(app, "long-transcript-bottom-before-keyboard")
        input.tap()
        input.typeText("long transcript keyboard")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(bubble.frame.height, 104, accuracy: 2)
        saveScreenshot(app, "long-transcript-bottom-with-keyboard")
        app.buttons["打开侧边栏"].firstMatch.tap()
        XCTAssertTrue(app.buttons["sidebar.newChat"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        app.buttons["隔离测试对话"].firstMatch.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        transcript.swipeUp()
        saveScreenshot(app, "long-transcript-bottom-after-keyboard")
    }

    @MainActor func testEdgeSwipeOnlyOpensSidebarAndDoesNotOpenHistory() {
        let app = launch()
        app.buttons["打开侧边栏"].firstMatch.tap()

        let history = app.buttons["隔离测试对话"].firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        XCTAssertTrue(history.isHittable)
        let historyY = history.frame.midY - app.frame.minY
        app.buttons["sidebar.newChat"].firstMatch.tap()

        let normalizedY = historyY / app.frame.height
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: normalizedY))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: normalizedY))
        start.press(forDuration: 0.05, thenDragTo: end)

        // The swipe's start height overlaps the history row once the drawer
        // moves, but it must only open the drawer. A separate tap still works.
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        XCTAssertTrue(history.isHittable)
        history.tap()
        XCTAssertFalse(history.isHittable)
    }

    @MainActor func testHistoryTextAlignmentCopyAndHeaderNewChat() {
        let app = launch()
        app.buttons["打开侧边栏"].firstMatch.tap()
        let history = app.buttons["隔离测试对话"].firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        history.tap()
        XCTAssertTrue(app.staticTexts["中文用户消息靠右"].firstMatch.waitForExistence(timeout: 5))
        saveScreenshot(app, "history-chinese-english-copy-block")
        let copy = app.buttons["复制"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        XCTAssertTrue(copy.isHittable)
        copy.tap()
        XCTAssertTrue(app.buttons["已复制"].firstMatch.waitForExistence(timeout: 2))
        let newChat = app.buttons["header.new-chat"]
        XCTAssertTrue(newChat.isHittable)
        newChat.tap()
        XCTAssertFalse(app.staticTexts["中文用户消息靠右"].firstMatch.exists)
        let composer = app.descendants(matching: .any).matching(identifier: "composer.input").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        composer.typeText("draft to clear")
        app.buttons["header.sidebar"].tap()
        app.buttons["sidebar.newChat"].tap()
        XCTAssertFalse((composer.value as? String ?? "").contains("draft to clear"))
        saveScreenshot(app, "new-chat-with-keyboard")
    }

    @MainActor func testDarkImageMessagesAndPreview() {
        let app = launch(extra: ["--ui-test-images", "-AppleInterfaceStyle", "Dark"])
        app.buttons["打开侧边栏"].firstMatch.tap()
        app.buttons["隔离测试对话"].firstMatch.tap()
        let images = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "message.image."))
        XCTAssertTrue(images.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(images.count, 3)
        for thumbnail in images.allElementsBoundByIndex {
            XCTAssertEqual(thumbnail.frame.width, thumbnail.frame.height, accuracy: 1)
            XCTAssertEqual(thumbnail.frame.width, 104, accuracy: 1)
            XCTAssertGreaterThanOrEqual(thumbnail.frame.minX, 16)
            XCTAssertLessThanOrEqual(thumbnail.frame.maxX, app.frame.maxX - 16 + 1)
        }
        XCTAssertEqual(images.allElementsBoundByIndex.map { $0.frame.minX }.min() ?? 0, app.frame.width - 16 - 216, accuracy: 1)
        let pair = images.allElementsBoundByIndex.suffix(2)
        XCTAssertEqual(pair.first!.frame.midY, pair.last!.frame.midY, accuracy: 1,
            "Multiple images occupy one horizontal row")
        XCTAssertTrue(app.staticTexts["图片加文字靠右"].firstMatch.exists)
        saveScreenshot(app, "dark-image-only-multi-image-text")
        images.firstMatch.tap()
        XCTAssertTrue(app.buttons["关闭图片预览"].waitForExistence(timeout: 5))
        app.buttons["关闭图片预览"].tap()
        XCTAssertTrue(images.firstMatch.waitForExistence(timeout: 5))
        let composer = app.descendants(matching: .any).matching(identifier: "composer.input").firstMatch
        composer.tap()
        composer.typeText("keyboard drawer")
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        app.buttons["打开侧边栏"].firstMatch.tap()
        XCTAssertTrue(app.buttons["sidebar.newChat"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        saveScreenshot(app, "dark-drawer-dismisses-keyboard")
    }

    @MainActor func testConnectorEntryIsChineseAndOpensDirectory() {
        let app = launch()
        app.buttons["打开侧边栏"].firstMatch.tap()
        app.buttons["账户设置"].firstMatch.tap()
        let connector = app.buttons["连接器"].firstMatch
        if !connector.isHittable { app.swipeUp() }
        XCTAssertTrue(connector.waitForExistence(timeout: 5))
        connector.tap()
        XCTAssertTrue(app.staticTexts["连接器"].firstMatch.waitForExistence(timeout: 5))
        saveScreenshot(app, "chinese-connector-settings")
        app.buttons["添加连接器"].tap()
        app.buttons["浏览连接器"].tap()
        let service = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sample service")).firstMatch
        XCTAssertTrue(service.waitForExistence(timeout: 5))
        service.tap()
        XCTAssertTrue(app.textFields["connector.name"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["connector.name"].value as? String, "Sample service")
        XCTAssertEqual(app.textFields["connector.server-url"].value as? String, "https://connector.example.invalid/mcp")
    }

    @MainActor func testMemoryFilesKeepEditingImportAndExportActions() {
        let app = launch()
        app.buttons["打开侧边栏"].firstMatch.tap(); app.buttons["账户设置"].firstMatch.tap()
        app.buttons["功能"].firstMatch.tap()
        let files = app.buttons["记忆文件"].firstMatch
        if !files.isHittable { app.swipeUp() }
        XCTAssertTrue(files.waitForExistence(timeout: 5)); files.tap()
        XCTAssertTrue(app.staticTexts["主题"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["memory.topic"].exists)
        let topic = app.buttons["memory.topic.测试"].firstMatch
        XCTAssertTrue(topic.waitForExistence(timeout: 5)); topic.tap()
        let content = app.staticTexts["这是隔离测试记忆"].firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["删除主题"].exists)
        saveScreenshot(app, "memory-topic-natural")
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["记忆操作"].tap()
        XCTAssertTrue(app.buttons["导入"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["导出"].exists)
    }

    @MainActor func testDefaultCodeModelsHaveNoEmptyCustomSection() {
        for appearance in ["Light", "Dark"] {
            let app = launch(extra: ["--ui-test-claude-models", "-AppleInterfaceStyle", appearance])
            openCodeModelPicker(in: app)
            XCTAssertTrue(app.staticTexts["Anthropic"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts["自定义模型"].exists)
            XCTAssertFalse(app.staticTexts["已连接模型"].exists)
            XCTAssertFalse(app.staticTexts["可在设置中添加自定义 API 与 URL"].exists)
            let sonnet = app.buttons["Sonnet 5.5，Anthropic"].firstMatch
            XCTAssertTrue(sonnet.waitForExistence(timeout: 5))
            saveScreenshot(app, "default-code-models-\(appearance)")
            sonnet.tap()
            let selected = app.buttons["code-model-selector"]
            XCTAssertTrue(selected.waitForExistence(timeout: 5))
            XCTAssertTrue(selected.label.contains("Sonnet 5.5"))
            app.terminate()
        }
    }

    @MainActor func testConnectedModelsRemainSelectableWithoutMislabelingDefaults() {
        let app = launch(extra: ["--ui-test-claude-models", "--ui-test-connected-model"])
        app.buttons["composer.model-picker"].firstMatch.tap()
        app.buttons["model.more"].tap()
        XCTAssertTrue(app.staticTexts["已连接模型"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["自定义模型"].exists)
        XCTAssertTrue(app.staticTexts["My endpoint"].exists)
        app.buttons["返回"].firstMatch.tap()
        app.buttons["关闭"].firstMatch.tap()
        openCodeModelPicker(in: app)
        XCTAssertTrue(app.staticTexts["Anthropic"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["自定义模型"].exists)
        let endpoint = app.buttons["My endpoint，Custom"].firstMatch
        let catalog = app.scrollViews["model.catalog"]
        for _ in 0..<4 {
            if endpoint.exists && endpoint.isHittable { break }
            catalog.swipeUp()
        }
        XCTAssertTrue(app.staticTexts["已连接模型"].exists)
        XCTAssertTrue(endpoint.isHittable)
        saveScreenshot(app, "connected-code-models")
        endpoint.tap()
        let selected = app.buttons["code-model-selector"]
        XCTAssertTrue(selected.waitForExistence(timeout: 5))
        XCTAssertTrue(selected.label.contains("My endpoint"),
            "Removing misleading labels must not remove saved endpoint selection")
    }

    @MainActor private func openCodeModelPicker(in app: XCUIApplication) {
        app.buttons["打开侧边栏"].firstMatch.tap()
        app.buttons["编程"].firstMatch.tap()
        let newSession = app.buttons["新建会话"].firstMatch
        XCTAssertTrue(newSession.waitForExistence(timeout: 5))
        newSession.tap()
        let picker = app.buttons["code-model-selector"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        XCTAssertTrue(app.staticTexts["选择模型"].waitForExistence(timeout: 5))
    }

    @MainActor func testClaudeModelNamesAndNativeEffortNavigation() {
        let app = launch(extra: ["-AppleInterfaceStyle", "Dark", "--ui-test-claude-models"])
        app.buttons["composer.model-picker"].firstMatch.tap()
        for name in ["Fable 5.1", "Opus 5.5", "Sonnet 5.5", "Haiku 5.5"] {
            XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5))
        }
        XCTAssertFalse(app.staticTexts["Claude Fable 5"].exists)
        saveScreenshot(app, "claude-model-main-dark")
        app.buttons["model.effort"].tap()
        XCTAssertTrue(app.buttons["effort.xhigh"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["effort.xhigh"].isHittable)
        app.buttons["effort.low"].tap()
        saveScreenshot(app, "claude-effort-dark")
        app.buttons["返回"].firstMatch.tap()
        XCTAssertTrue(app.buttons["model.effort"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["model.effort"].label.contains("低"))
        app.buttons["model.more"].tap()
        XCTAssertTrue(app.staticTexts["更多模型"].waitForExistence(timeout: 5))
        app.buttons["返回"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Sonnet 5.5"].exists)
    }

    @MainActor func testModelsEffortAndCompactAddMenu() {
        let app = launch(extra: ["-AppleInterfaceStyle", "Dark"])
        app.buttons["composer.model-picker"].firstMatch.tap()
        XCTAssertTrue(app.buttons["model.more"].waitForExistence(timeout: 5))
        app.buttons["model.effort"].tap()
        XCTAssertTrue(app.buttons["effort.low"].waitForExistence(timeout: 5)); app.buttons["effort.low"].tap()
        XCTAssertEqual(app.buttons["effort.low"].exists, true)
        saveScreenshot(app, "effort-dark")
        app.buttons["返回"].firstMatch.tap(); app.buttons["model.more"].tap()
        XCTAssertTrue(app.staticTexts["更多模型"].waitForExistence(timeout: 5))
        saveScreenshot(app, "more-models-dark")
        app.buttons["返回"].firstMatch.tap(); app.buttons["关闭"].firstMatch.tap()
        app.buttons["composer.add"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["添加到聊天"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["照片"].exists)
        let camera = app.buttons["拍照"].firstMatch
        XCTAssertEqual(camera.frame.width, camera.frame.height, accuracy: 1)
        let photo = app.buttons["添加最近照片"].firstMatch
        if photo.exists { XCTAssertEqual(photo.frame.width, photo.frame.height, accuracy: 1) }
        XCTAssertTrue(app.buttons["添加文件"].exists)
        XCTAssertTrue(app.buttons["tools.projects.row"].exists)
        XCTAssertTrue(app.buttons["连接器"].firstMatch.exists)
        XCTAssertFalse(app.switches["扩展思考"].exists)
        XCTAssertFalse(app.switches["自动网页搜索"].exists)
        saveScreenshot(app, "add-menu-dark")
    }

    @MainActor func testComposerButtonsAcceptSmallHorizontalTouchDrift() {
        let app = launch(extra: ["--ui-test-open-conversation"])
        let add = app.buttons["composer.add"].firstMatch
        let model = app.buttons["composer.model-picker"].firstMatch
        guard add.waitForExistence(timeout: 10), model.waitForExistence(timeout: 10) else {
            XCTFail("Expected stable composer controls in an existing conversation")
            return
        }
        waitForKeyboardDismissal(in: app)

        for (button, title) in [(add, "添加到聊天"), (model, "选择模型")] {
            let keyboard = app.keyboards.firstMatch
            guard waitForHittable(button, timeout: 10) else {
                XCTFail("Pre-gesture button is not hittable; frame=\(button.frame); keyboard=\(keyboard.exists ? String(describing: keyboard.frame) : "not present")")
                return
            }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let frame = button.frame
            origin.withOffset(CGVector(dx: frame.midX, dy: frame.midY)).press(forDuration: 0.08,
                thenDragTo: origin.withOffset(CGVector(dx: frame.midX + 15, dy: frame.midY)),
                withVelocity: .slow, thenHoldForDuration: 0.01)
            let sheetTitle = app.staticTexts[title].firstMatch
            guard sheetTitle.waitForExistence(timeout: 8) else {
                XCTFail("15 pt horizontal drift failed to open \(title); button frame=\(frame); keyboard=\(keyboard.exists ? String(describing: keyboard.frame) : "not present")")
                return
            }
            app.buttons["关闭"].firstMatch.tap()
            waitForKeyboardDismissal(in: app)
            XCTAssertTrue(waitForHittable(button, timeout: 8),
                "Composer control must be hittable after dismissal: \(title)")
        }
    }

    @MainActor func testComposerSheetsReopenAfterSelectingConversation() {
        let app = launch()
        app.buttons["header.sidebar"].tap()
        let conversation = app.buttons["隔离测试对话"].firstMatch
        XCTAssertTrue(conversation.waitForExistence(timeout: 5))
        conversation.tap()

        let add = app.buttons["composer.add"].firstMatch
        let model = app.buttons["composer.model-picker"].firstMatch
        XCTAssertTrue(waitForHittable(add, timeout: 10),
            "The composer must become interactive after a history row closes the drawer")
        XCTAssertTrue(waitForHittable(model, timeout: 5))
        XCTAssertFalse(app.buttons["sidebar.accountSettings"].isHittable)

        let routes: [(XCUIElement, String)] = [
            (model, "选择模型"),
            (add, "添加到聊天"),
            (model, "选择模型"),
            (add, "添加到聊天")
        ]
        func interactionState(_ phase: String, title: String) -> String {
            let keyboard = app.keyboards.firstMatch
            let keyboardFrame = keyboard.exists ? String(describing: keyboard.frame) : "absent"
            let addExists = add.exists, modelExists = model.exists
            let addFrame = addExists ? String(describing: add.frame) : "absent"
            let modelFrame = modelExists ? String(describing: model.frame) : "absent"
            return "COMPOSER_REOPEN_AX phase=\(phase) route=\(title) sheetTitleExists=\(app.staticTexts[title].firstMatch.exists) addExists=\(addExists) addEnabled=\(addExists && add.isEnabled) addHittable=\(addExists && add.isHittable) addFrame=\(addFrame) modelExists=\(modelExists) modelEnabled=\(modelExists && model.isEnabled) modelHittable=\(modelExists && model.isHittable) modelFrame=\(modelFrame) keyboardFrame=\(keyboardFrame)"
        }
        for (button, title) in routes {
            guard waitForHittable(button, timeout: 5) else {
                saveScreenshot(app, "composer-unavailable-before-" + title)
                let state = interactionState("before", title: title)
                let details = XCTAttachment(string: state)
                details.lifetime = .keepAlways
                self.add(details)
                print(state)
                XCTFail("Composer control unavailable before \(title); \(state)")
                return
            }
            button.tap()
            let sheetTitle = app.staticTexts[title].firstMatch
            XCTAssertTrue(sheetTitle.waitForExistence(timeout: 10))
            let close = app.buttons["关闭"].firstMatch
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            close.tap()
            let dismissedAndInteractive = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                !sheetTitle.exists && add.isHittable && model.isHittable
            }, object: nil)
            let settled = XCTWaiter.wait(for: [dismissedAndInteractive], timeout: 10)
            if settled != .completed {
                saveScreenshot(app, "composer-unavailable-after-" + title)
                let state = interactionState("after", title: title)
                let details = XCTAttachment(string: state)
                details.lifetime = .keepAlways
                self.add(details)
                print(state)
            }
            XCTAssertEqual(settled, .completed,
                "Dismissal must finish and both composer controls must return; \(interactionState("after", title: title))")
        }
    }

    @MainActor func testComposerSheetsOpenFromNewAndExistingChatsWithKeyboard() {
        for extra in [[], ["--ui-test-open-conversation"]] {
            let app = launch(extra: extra)
            let add = app.buttons["composer.add"].firstMatch
            let model = app.buttons["composer.model-picker"].firstMatch
            let input = app.descendants(matching: .any).matching(identifier: "composer.input").firstMatch
            XCTAssertTrue(add.waitForExistence(timeout: 10))
            XCTAssertTrue(model.waitForExistence(timeout: 10))
            XCTAssertTrue(add.isHittable)
            XCTAssertTrue(model.isHittable)

            model.tap()
            XCTAssertTrue(app.staticTexts["选择模型"].firstMatch.waitForExistence(timeout: 10))
            let close = app.buttons["关闭"].firstMatch
            XCTAssertTrue(close.isHittable)
            close.tap()

            XCTAssertTrue(add.waitForExistence(timeout: 5))
            add.tap()
            XCTAssertTrue(app.staticTexts["添加到聊天"].firstMatch.waitForExistence(timeout: 10))
            close.tap()

            input.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(add.isHittable)
            add.tap()
            XCTAssertTrue(app.staticTexts["添加到聊天"].firstMatch.waitForExistence(timeout: 10))
            waitForKeyboardDismissal(in: app)
            XCTAssertFalse(app.keyboards.firstMatch.exists)
            close.tap()

            input.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(model.isHittable)
            model.tap()
            XCTAssertTrue(app.staticTexts["选择模型"].firstMatch.waitForExistence(timeout: 10))
            waitForKeyboardDismissal(in: app)
            XCTAssertFalse(app.keyboards.firstMatch.exists)
            close.tap()
            app.terminate()
        }
    }

    @MainActor func testProfilePhotoMenuInstructionsSaveAndSupportedCapabilities() {
        let app = launch(extra: ["-AppleInterfaceStyle", "Dark"])
        app.buttons["打开侧边栏"].firstMatch.tap()
        app.buttons["账户设置"].firstMatch.tap()
        app.buttons["个人资料"].firstMatch.tap()
        let photoMenu = app.buttons.matching(identifier: "编辑头像").element(boundBy: 1)
        XCTAssertTrue(photoMenu.waitForExistence(timeout: 5))
        saveScreenshot(app, "profile-dark")
        photoMenu.tap()
        XCTAssertTrue(app.buttons["从照片图库选择"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["拍照"].exists)
        saveScreenshot(app, "profile-photo-menu-dark")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.7)).tap()
        let instructions = app.textFields["profile.instructions"]
        XCTAssertTrue(instructions.waitForExistence(timeout: 5))
        XCTAssertLessThan(instructions.frame.height, 60)
        instructions.tap()
        instructions.typeText("Keep replies concise.")
        app.buttons["保存自定义指令"].tap()
        XCTAssertTrue(app.staticTexts["已保存"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        let capabilities = app.buttons["功能"].firstMatch
        if !capabilities.isHittable { app.swipeUp() }
        capabilities.tap()
        XCTAssertTrue(app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "网页搜索")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "内联可视化")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["代码执行与文件创建"].exists)
        saveScreenshot(app, "capabilities-dark")
    }

    @MainActor func testHomeMascotAndPrivateHeaderPositions() {
        let app = launch(extra: ["-AppleInterfaceStyle", "Dark"])
        app.buttons["composer.model-picker"].tap()
        app.buttons["关闭"].firstMatch.tap()
        let logo = app.images["home.logo"]
        XCTAssertTrue(logo.waitForExistence(timeout: 5))
        let greeting = app.staticTexts["home.greeting"]
        XCTAssertEqual(logo.frame.midX, app.frame.midX, accuracy: 1)
        XCTAssertEqual(logo.frame.width, 52, accuracy: 1)
        XCTAssertEqual(logo.frame.height, 52, accuracy: 1)
        XCTAssertLessThan(logo.frame.midY, app.frame.height * 0.43,
            "The welcome logo and prompt must sit above the center")
        let logoBefore = logo.frame
        XCTAssertGreaterThan(greeting.frame.minY, logo.frame.maxY)
        let menuBefore = app.buttons["打开侧边栏"].firstMatch.frame
        let privateBefore = app.buttons["开始隐私聊天"].frame
        saveScreenshot(app, "home-new-mascot-dark")
        app.buttons["开始隐私聊天"].tap()
        let exit = app.buttons["退出隐私聊天"]
        XCTAssertTrue(exit.waitForExistence(timeout: 5))
        let privateLogo = app.descendants(matching: .any).matching(identifier: "home.private-logo").firstMatch
        XCTAssertTrue(privateLogo.exists)
        XCTAssertEqual(privateLogo.frame.midX, logoBefore.midX, accuracy: 0.5)
        XCTAssertEqual(privateLogo.frame.midY, logoBefore.midY, accuracy: 0.5,
            "The privacy marker must transition at the same center as the MyChat logo")
        XCTAssertEqual(exit.frame.minX, privateBefore.minX, accuracy: 1)
        XCTAssertEqual(exit.frame.minY, privateBefore.minY, accuracy: 1)
        XCTAssertEqual(app.buttons["打开侧边栏"].firstMatch.frame.minX, menuBefore.minX, accuracy: 1)
        XCTAssertEqual(app.buttons["打开侧边栏"].firstMatch.frame.minY, menuBefore.minY, accuracy: 1)
        saveScreenshot(app, "private-header-fixed-dark")
    }

    @MainActor func testAccountSettingsEntry() {
        let app = launch()
        app.buttons["打开侧边栏"].firstMatch.tap()
        let account = app.buttons["账户设置"].firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        account.tap()
        XCTAssertTrue(app.staticTexts["Settings"].firstMatch.waitForExistence(timeout: 5)
            || app.staticTexts["设置"].firstMatch.exists)
        saveScreenshot(app, "account-settings")
    }

    @MainActor func testPasswordAndPrivacyShareOneSettingsEntry() {
        let app = launch()
        app.buttons["打开侧边栏"].firstMatch.tap()
        app.buttons["sidebar.accountSettings"].tap()

        let combined = app.buttons["密码与隐私"].firstMatch
        XCTAssertTrue(combined.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["密码"].exists)
        XCTAssertFalse(app.buttons["隐私"].exists)
        combined.tap()

        XCTAssertTrue(app.buttons["密码"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["隐私"].firstMatch.exists)
    }

    @MainActor func testComposerKeyboardAndPrivacyTransitionsStayStable() {
        let app = launch(extra: ["-AppleInterfaceStyle", "Dark", "--layout-audit"])
        // Close the initial keyboard through a real modal, then start from the
        // same resting state as the user's recording.
        app.buttons["composer.model-picker"].tap()
        app.buttons["关闭"].firstMatch.tap()
        let input = app.textViews["composer.input"]
        let surface = app.descendants(matching: .any).matching(identifier: "composer.surface").firstMatch
        let logo = app.images["home.logo"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let restingLogo = logo.frame
        let restingSurface = surface.frame
        let menu = app.buttons["打开侧边栏"].firstMatch.frame
        let privacy = app.buttons["开始隐私聊天"].frame

        for cycle in 0..<3 {
            input.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            if cycle == 0 { input.typeText("hi") }
            XCTAssertEqual(input.value as? String, "hi")
            // Keyboard existence is reported at the start of UIKit's animation.
            // Check the real destination before measuring post-transition drift;
            // intermediate movement is required by the continuous interaction.
            let keyboardDestination = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                surface.frame.maxY <= app.keyboards.firstMatch.frame.minY - 4
                    && logo.frame.minY < restingLogo.minY - 100
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [keyboardDestination], timeout: 2), .completed,
                "resting logo=\(restingLogo); current logo=\(logo.frame); surface=\(surface.frame); keyboard=\(app.keyboards.firstMatch.frame)")
            XCTAssertLessThan(input.frame.height, 30, "A short draft must occupy one text line")
            XCTAssertEqual(surface.frame.height, 104, accuracy: 2)
            XCTAssertGreaterThanOrEqual(input.frame.minY, surface.frame.minY + 10,
                "Text must not be cropped through the top of the input bubble")
            XCTAssertLessThan(input.frame.maxY, surface.frame.maxY - 40)
            let openLogo = logo.frame
            let openSurface = surface.frame
            Thread.sleep(forTimeInterval: 0.8)
            XCTAssertEqual(logo.frame.minY, openLogo.minY, accuracy: 0.5)
            XCTAssertEqual(surface.frame.minY, openSurface.minY, accuracy: 0.5)
            saveScreenshot(app, "input-short-stable-\(cycle)")
            app.buttons["composer.model-picker"].tap()
            app.buttons["关闭"].firstMatch.tap()
            XCTAssertFalse(app.keyboards.firstMatch.exists)
            XCTAssertEqual(logo.frame.minY, restingLogo.minY, accuracy: 0.5)
            XCTAssertEqual(surface.frame.minY, restingSurface.minY, accuracy: 0.5)
            Thread.sleep(forTimeInterval: 0.8)
            XCTAssertEqual(logo.frame.minY, restingLogo.minY, accuracy: 0.5)
            XCTAssertEqual(surface.frame.minY, restingSurface.minY, accuracy: 0.5)
        }

        // Switching privacy must preserve both open and closed keyboard states.
        for keyboardOpen in [false, true] {
            if keyboardOpen { input.tap() }
            for _ in 0..<3 {
                let before = surface.frame
                app.buttons["开始隐私聊天"].tap()
                XCTAssertTrue(app.buttons["退出隐私聊天"].waitForExistence(timeout: 5))
                XCTAssertEqual(app.buttons["打开侧边栏"].firstMatch.frame.minY, menu.minY, accuracy: 0.5)
                XCTAssertEqual(app.buttons["退出隐私聊天"].frame.minX, privacy.minX, accuracy: 0.5)
                XCTAssertEqual(surface.frame.minY, before.minY, accuracy: 0.5)
                XCTAssertEqual(app.keyboards.firstMatch.exists, keyboardOpen)
                XCTAssertEqual(input.value as? String, "")
                app.buttons["退出隐私聊天"].tap()
                XCTAssertTrue(app.buttons["开始隐私聊天"].waitForExistence(timeout: 5))
                XCTAssertEqual(surface.frame.minY, before.minY, accuracy: 0.5)
                XCTAssertEqual(app.keyboards.firstMatch.exists, keyboardOpen)
            }
        }
    }

    @MainActor func testReferenceComposerHasOneBoundedSurfaceAndFollowsKeyboard() {
        for (name, appearance, opaque) in [("light", "Light", false), ("dark", "Dark", false), ("dark-opaque", "Dark", true)] {
            var arguments = ["--ui-test-reference-chat", "-AppleInterfaceStyle", appearance]
            if opaque { arguments.append("--ui-test-reduce-transparency") }
            let app = launch(extra: arguments)
            app.buttons["打开侧边栏"].firstMatch.tap()
            let history = app.buttons["隔离测试对话"].firstMatch
            XCTAssertTrue(history.waitForExistence(timeout: 5))
            history.tap()
            XCTAssertTrue(app.staticTexts["你好！有什么我可以帮你的吗？"].firstMatch.waitForExistence(timeout: 5))
            let surface = app.descendants(matching: .any).matching(identifier: "composer.surface").firstMatch
            let input = app.descendants(matching: .any).matching(identifier: "composer.input").firstMatch
            XCTAssertTrue(surface.exists)
            XCTAssertEqual(surface.frame.width, app.frame.width - 32, accuracy: 1)
            XCTAssertEqual(surface.frame.height, 104, accuracy: 2)
            XCTAssertEqual(app.frame.maxY - surface.frame.maxY, 34, accuracy: 2,
                "The composer must use the home-indicator inset once, without an extra bottom panel")
            saveScreenshot(app, "reference-chat-\(name)")

            input.tap()
            input.typeText("hello")
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(surface.frame.width, app.frame.width - 16, accuracy: 1)
            // XCTest excludes some input methods' candidate bar from the
            // Keyboard frame. Inspect the screenshots for the actual 8 pt join.
            let keyboardGap = app.keyboards.firstMatch.frame.minY - surface.frame.maxY
            XCTAssertGreaterThanOrEqual(keyboardGap, 0)
            XCTAssertLessThan(keyboardGap, 60,
                "The input bubble must stay directly above the keyboard and its candidate bar")
            saveScreenshot(app, "reference-keyboard-\(name)")

            input.typeText(String(repeating: "long draft ", count: 30))
            XCTAssertLessThan(surface.frame.height, 240,
                "Long drafts must scroll inside the composer instead of expanding it into a screen-sized box")
            app.buttons["打开侧边栏"].firstMatch.tap()
            XCTAssertTrue(app.buttons["sidebar.newChat"].firstMatch.waitForExistence(timeout: 5))
            XCTAssertFalse(app.keyboards.firstMatch.exists)
            let menuButtons = ["聊天", "项目", "编程", "可视化"].map { app.buttons[$0].firstMatch }
            for pair in zip(menuButtons, menuButtons.dropFirst()) {
                XCTAssertEqual(pair.1.frame.midY - pair.0.frame.midY, 50, accuracy: 1,
                    "Sidebar destinations must stay compact while preserving 44 pt touch targets")
            }
            saveScreenshot(app, "reference-sidebar-\(name)")
            app.terminate()
        }
    }

    @MainActor func testClaudeReferenceLayoutAndExistingActions() {
        for appearance in ["Light", "Dark"] {
            let app = launch(extra: ["--ui-test-claude-layout", "--ui-test-open-conversation", "-AppleInterfaceStyle", appearance])
            let code = app.buttons["展开代码"].firstMatch
            XCTAssertTrue(code.waitForExistence(timeout: 10))
            if !code.isHittable { app.scrollViews.firstMatch.swipeUp() }
            saveScreenshot(app, "claude-aligned-chat-\(appearance)")
            XCTAssertTrue(app.buttons["复制"].firstMatch.exists)
            XCTAssertTrue(app.buttons["重新回复"].firstMatch.exists)
            code.tap()
            XCTAssertTrue(app.staticTexts["Swift 代码"].firstMatch.waitForExistence(timeout: 5))
            saveScreenshot(app, "claude-aligned-code-\(appearance)")
            app.buttons["关闭"].firstMatch.tap()
            app.buttons["composer.model-picker"].firstMatch.tap()
            XCTAssertTrue(app.staticTexts["选择模型"].firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["测试模型"].firstMatch.exists,
                "The selected fixture model must remain available in the native model picker")
            saveScreenshot(app, "claude-aligned-models-\(appearance)")
            app.buttons["关闭"].firstMatch.tap()
            app.buttons["打开侧边栏"].firstMatch.tap()
            XCTAssertTrue(app.staticTexts["MyChat"].firstMatch.waitForExistence(timeout: 5))
            saveScreenshot(app, "claude-aligned-sidebar-\(appearance)")
            app.buttons["账户设置"].firstMatch.tap()
            XCTAssertTrue(app.staticTexts["设置"].firstMatch.waitForExistence(timeout: 5))
            saveScreenshot(app, "claude-aligned-settings-\(appearance)")
            app.buttons["关闭设置"].firstMatch.tap()
            if !app.buttons["可视化"].firstMatch.isHittable {
                app.buttons["打开侧边栏"].firstMatch.tap()
            }
            app.buttons["可视化"].firstMatch.tap()
            XCTAssertTrue(app.textFields["搜索"].firstMatch.waitForExistence(timeout: 5))
            saveScreenshot(app, "claude-aligned-artifacts-\(appearance)")
            app.terminate()
        }
    }

    @MainActor func testReasoningSummaryShowsProviderPreviewAndReopensInBothAppearances() {
        let opening = "核对研究资料包并规划后续步骤。"
        let preview = "第二段摘要仍然保留，展开后可以继续阅读。"
        for appearance in ["Light", "Dark"] {
            let app = launch(extra: ["--ui-test-summary-reference", "-AppleInterfaceStyle", appearance])
            app.buttons["header.sidebar"].firstMatch.tap()
            let conversation = app.buttons["隔离测试对话"].firstMatch
            XCTAssertTrue(waitForHittable(conversation, timeout: 10))
            conversation.tap()

            let row = app.buttons["document.thinking"].firstMatch
            XCTAssertTrue(waitForHittable(row, timeout: 10))
            XCTAssertEqual(row.value as? String, preview,
                "The collapsed row must show the latest public summary, not the first line or document description")
            XCTAssertGreaterThanOrEqual(row.frame.height, 40)
            XCTAssertLessThanOrEqual(row.frame.maxX, app.frame.maxX - 8)
            saveScreenshot(app, "reasoning-summary-preview-" + appearance)

            for cycle in 0..<3 {
                row.tap()
                XCTAssertTrue(app.staticTexts["思考摘要"].firstMatch.waitForExistence(timeout: 5))
                let sheet = app.descendants(matching: .any).matching(identifier: "document.thinking.sheet").firstMatch
                XCTAssertTrue(sheet.waitForExistence(timeout: 5))
                let body = sheet.descendants(matching: .any).matching(identifier: "document.thinking.content").firstMatch
                XCTAssertTrue(body.waitForExistence(timeout: 5))
                // MarkdownBody is one attributed Text. Scope this to the sheet
                // body so the obscured collapsed preview cannot satisfy it.
                let bodyLabels = ([body.label] + body.staticTexts.allElementsBoundByIndex.map(\.label)).joined(separator: "\n")
                let openingPresent = bodyLabels.contains(opening)
                let latestPresent = bodyLabels.contains(preview)
                let safeDiagnostic = "SUMMARY_EXPANDED_AX \(appearance)-\(cycle) sheet=document.thinking.sheet body=document.thinking.content elementType=\(body.elementType.rawValue) frame=\(body.frame) characters=\(bodyLabels.count) knownOpeningPresent=\(openingPresent) knownLatestPresent=\(latestPresent)"
                print(safeDiagnostic)
                XCTAssertTrue(openingPresent, "Opening paragraph missing from the expanded summary body")
                XCTAssertTrue(latestPresent, "Latest paragraph missing from the expanded summary body")
                let contents = XCTAttachment(string: safeDiagnostic)
                contents.lifetime = .keepAlways
                add(contents)
                saveScreenshot(app, "reasoning-summary-expanded-\(appearance)-\(cycle)")
                let close = app.buttons["关闭"].firstMatch
                XCTAssertTrue(waitForHittable(close, timeout: 5))
                close.tap()
                XCTAssertTrue(waitForHittable(row, timeout: 5))
                XCTAssertEqual(row.value as? String, preview)
            }
            app.terminate()
        }
    }

    @MainActor func testDocumentCardFilesListPreviewDownloadAndRepeatedDismissal() {
        for appearance in ["Light", "Dark"] {
            let app = launch(extra: ["--ui-test-document-reference", "--ui-test-open-conversation", "-AppleInterfaceStyle", appearance])
            let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "document-card-")).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 10))
            XCTAssertFalse(app.keyboards.firstMatch.exists, "Opening an existing conversation must not focus the composer")
            XCTAssertTrue(app.buttons["对话文件"].firstMatch.waitForExistence(timeout: 5))
            saveScreenshot(app, "document-chat-\(appearance)")
            for _ in 0..<3 {
                card.tap()
                let close = app.buttons["关闭文件预览"].firstMatch
                XCTAssertTrue(close.waitForExistence(timeout: 5))
                XCTAssertTrue(app.staticTexts["慢下来的艺术"].firstMatch.waitForExistence(timeout: 5))
                saveScreenshot(app, "document-preview-\(appearance)")
                close.tap()
                XCTAssertTrue(card.waitForExistence(timeout: 5))
            }
            app.buttons["对话文件"].firstMatch.tap()
            XCTAssertTrue(app.staticTexts["文件"].firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["全部下载"].firstMatch.isHittable)
            saveScreenshot(app, "document-files-\(appearance)")
            app.buttons["全部下载"].firstMatch.tap()
            XCTAssertTrue(app.buttons["Close"].firstMatch.waitForExistence(timeout: 5) || app.buttons["关闭"].firstMatch.exists)
            saveScreenshot(app, "document-download-\(appearance)")
            app.terminate()
        }
    }

    @MainActor func testUploadedPDFCardOpensOriginalAndToolsKeepThinkingOnly() {
        let app = launch(extra: ["--ui-test-uploaded-file-reference", "--ui-test-open-conversation", "-AppleInterfaceStyle", "Light"])
        let file = app.buttons["预览文件 reasoning-throughs.pdf"].firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10))
        saveScreenshot(app, "uploaded-pdf-card")
        file.tap()
        XCTAssertTrue(app.buttons["关闭文件预览"].firstMatch.waitForExistence(timeout: 5))
        saveScreenshot(app, "uploaded-pdf-preview")
        app.buttons["关闭文件预览"].firstMatch.tap()
        app.buttons["composer.model-picker"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["选择模型"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["扩展思考"].exists)
        XCTAssertFalse(app.staticTexts["思考深度"].exists)
        app.buttons["关闭"].firstMatch.tap()
        app.buttons["composer.add"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["添加到聊天"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["照片"].firstMatch.exists)
        XCTAssertTrue(app.buttons["拍照"].firstMatch.exists)
        XCTAssertTrue(app.buttons["添加文件"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["扩展思考"].firstMatch.exists)
        saveScreenshot(app, "add-to-chat")
        let photo = app.buttons["添加最近照片"].firstMatch
        if photo.exists {
            photo.tap()
            XCTAssertTrue(app.buttons["composer.model-picker"].firstMatch.waitForExistence(timeout: 10))
            let image = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "attachment.remove-")).firstMatch
            XCTAssertTrue(image.waitForExistence(timeout: 5))
            saveScreenshot(app, "recent-photo-attached")
        }
    }

    @MainActor private func saveScreenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
