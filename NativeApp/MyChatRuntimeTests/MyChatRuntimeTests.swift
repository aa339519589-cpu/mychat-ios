import XCTest
import SwiftUI
import Speech
import WebKit
import PDFKit
import HealthKit
import CoreText
import Combine
@testable import MyChat

@MainActor final class MyChatRuntimeTests: XCTestCase {
    override func setUp() { super.setUp(); URLProtocol.registerClass(NativeAuditURLProtocol.self) }

    func testHapticSemanticsRespectPreferenceAndReducedMotion() {
        let events: [HapticFeedback.Event] = [.surface, .selection, .send, .stop, .success, .error]
        for event in events {
            XCTAssertNil(HapticFeedback.pattern(for: event, enabled: false, reduceMotion: false))
            XCTAssertNil(HapticFeedback.pattern(for: event, enabled: false, reduceMotion: true))
        }
        XCTAssertEqual(HapticFeedback.pattern(for: .selection, enabled: true, reduceMotion: false), .selection)
        XCTAssertEqual(HapticFeedback.pattern(for: .send, enabled: true, reduceMotion: false), .impact(.medium, 0.65))
        XCTAssertEqual(HapticFeedback.pattern(for: .stop, enabled: true, reduceMotion: false), .impact(.rigid, 0.55))
        XCTAssertEqual(HapticFeedback.pattern(for: .success, enabled: true, reduceMotion: false), .notification(.success))
        XCTAssertEqual(HapticFeedback.pattern(for: .error, enabled: true, reduceMotion: false), .notification(.error))
        XCTAssertEqual(HapticFeedback.pattern(for: .surface, enabled: true, reduceMotion: true), .impact(.soft, 0.45))
        XCTAssertEqual(HapticFeedback.pattern(for: .send, enabled: true, reduceMotion: true), .impact(.medium, 0.45))
    }

    func testIMECompositionDoesNotSubmitUntilNativeTextIsCommitted() {
        var text = "", submissions: [String] = []
        let input = ComposerTextInput(text: Binding(get: { text }, set: { text = $0 }),
            focused: .constant(false), editor: ComposerEditorSession(), placeholder: "消息",
            submit: { submissions.append(text) })
        let coordinator = input.makeCoordinator()
        let view = ComposerTextView()
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
        XCTAssertNotNil(view.markedTextRange)
        XCTAssertTrue(coordinator.textView(view, shouldChangeTextIn: NSRange(location: 2, length: 0), replacementText: "\n"))
        XCTAssertTrue(submissions.isEmpty, "The candidate-confirmation Return is not a send command")
        view.unmarkText()
        view.text = "你好 👨‍👩‍👧‍👦 café"
        coordinator.textViewDidChange(view)
        XCTAssertFalse(coordinator.textView(view, shouldChangeTextIn: NSRange(location: (view.text as NSString).length, length: 0), replacementText: "\n"))
        XCTAssertEqual(submissions, ["你好 👨‍👩‍👧‍👦 café"])
    }

    func testComposerBudgetUsesMeasuredNavigationAndFinalKeyboardGeometry() async {
        let budget = ComposerLayoutBudget()
        budget.setNavigationBottom(52)
        budget.setInputBottom(175)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(budget.availableHeight, 115)
        budget.setInputBottom(630)
        budget.setNavigationBottom(106)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(budget.availableHeight, 516)
    }

    func testConversationSwitchKeepsGenerationAndReconcilesOnlyItsOwnMessages() async throws {
        let transport = ControlledChatTransport()
        let data = ControlledConversationStore()
        let model = NativeRuntimeFixture.makeModel(dataClient: data, chatClient: transport, stream: transport)
        await model.restoreAuthenticationIfNeeded()
        await model.reloadModels()
        model.beginNewChat()
        model.draft = "会话 A"
        model.sendDraft()
        try await waitUntil { transport.commands.count == 1 && transport.continuations.count == 1 }
        let first = transport.commands[0]
        let firstRecord = ConversationRecord(id: first.conversationID.uuidString, title: "会话 A", updatedAt: "",
            projectID: nil, starred: false, pinned: false)
        transport.emit(.textDelta("A 的第一段"), for: first, sequence: 1)
        model.beginNewChat()
        XCTAssertTrue(model.generatingConversationIDs.contains(first.conversationID))
        XCTAssertTrue(transport.cancelCalls.isEmpty)
        model.draft = "会话 B"
        model.sendDraft()
        try await waitUntil { transport.commands.count == 2 && transport.continuations.count == 2 }
        let second = transport.commands[1]
        await data.setMessages([
            ConversationMessageRecord(id: first.userMessageID.uuidString, role: .user, content: "会话 A",
                images: nil, thinking: nil, createdAt: nil, sequence: 1),
            ConversationMessageRecord(id: first.assistantMessageID.uuidString, role: .assistant, content: "A 在后台完成",
                images: nil, thinking: nil, createdAt: nil, sequence: 2)
        ], for: first.conversationID)
        transport.complete(first, text: "A 在后台完成", sequence: 2)
        try await waitUntil { !model.generatingConversationIDs.contains(first.conversationID) }
        XCTAssertEqual(model.activeConversationID, second.conversationID)
        XCTAssertFalse(model.messages.contains { $0.id == first.assistantMessageID })
        model.openConversation(firstRecord)
        XCTAssertTrue(model.isConversationLoadPending)
        try await waitUntil {
            !model.isConversationLoadPending
                && model.messages.contains { $0.id == first.assistantMessageID && $0.content == "A 在后台完成" }
        }
        XCTAssertTrue(model.generatingConversationIDs.contains(second.conversationID))
        transport.complete(second, text: "B 也独立完成", sequence: 1)
        try await waitUntil { !model.generatingConversationIDs.contains(second.conversationID) }
        XCTAssertEqual(model.messages.filter { $0.id == first.assistantMessageID }.count, 1)
        XCTAssertFalse(model.messages.contains { $0.id == second.assistantMessageID })
        XCTAssertEqual(transport.commands.count, 2)
        XCTAssertTrue(transport.cancelCalls.isEmpty)
    }

    func testReadingPositionSurvivesConversationSwitchRotationAndUserTakeover() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 900))
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 60, width: 390, height: 800))
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.contentSize = CGSize(width: 390, height: 3_000)
        window.addSubview(scroll)
        let row = UIView(frame: CGRect(x: 0, y: 1_000, width: 390, height: 180))
        scroll.addSubview(row)
        let controller = ChatScrollController()
        let first = UUID(), second = UUID()
        controller.setComposerGeometry(.init(bottomPadding: 300, topInWindow: 760))
        controller.registerReadingAnchor(row, id: UUID())
        controller.attach(scroll, conversationID: first)
        try await Task.sleep(for: .milliseconds(40))
        controller.setInteractionActive(true)
        scroll.contentOffset.y = 900
        controller.setInteractionActive(false)
        try await Task.sleep(for: .milliseconds(40))
        controller.attach(scroll, conversationID: second)
        try await Task.sleep(for: .milliseconds(40))
        controller.attach(scroll, conversationID: first)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(scroll.contentOffset.y, 900, accuracy: 0.5)
        row.frame.origin.y = 1_100
        scroll.frame.size.width = 600
        scroll.contentSize.width = 600
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(scroll.contentOffset.y, 1_000, accuracy: 0.5,
            "Reflow retains the same row and relative position, not a percentage of the whole document")
        controller.attach(scroll, conversationID: second)
        controller.attach(scroll, conversationID: first)
        controller.setInteractionActive(true)
        scroll.contentOffset.y = 200
        controller.setInteractionActive(false)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(scroll.contentOffset.y, 200, accuracy: 0.5,
            "A touch after scheduling restoration must cancel the old scroll intent")
        controller.pauseFollowAnimation()
    }

    func testHistoryLoadDefersInitialFollowUntilLayoutIsStable() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 900))
        let scroll = UIScrollView(frame: window.bounds)
        scroll.contentInsetAdjustmentBehavior = .never
        // The empty transcript still has nonzero content from its top and bottom breathing room.
        scroll.contentSize = CGSize(width: 390, height: 160)
        window.addSubview(scroll)
        let controller = ChatScrollController()
        controller.setComposerGeometry(.init(bottomPadding: 300, topInWindow: 760))
        let conversationID = UUID()
        controller.attach(scroll, conversationID: conversationID, loadPending: true)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(scroll.contentOffset.y, 0, accuracy: 0.5,
            "Padding-only layout must not consume initial positioning while history is still loading")

        scroll.contentSize = CGSize(width: 390, height: 3_000)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(scroll.contentOffset.y, 0, accuracy: 0.5,
            "History reflow must wait for the load state instead of starting a smooth follow")

        controller.attach(scroll, conversationID: conversationID, loadPending: false)
        try await Task.sleep(for: .milliseconds(20))
        let settledOffset = scroll.contentOffset.y
        XCTAssertGreaterThan(settledOffset, 1_000)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(scroll.contentOffset.y, settledOffset, accuracy: 0.5,
            "The final correction after history load should settle immediately, not drift over a follow animation")
        controller.pauseFollowAnimation()
    }

    func testReadingPositionsAreBoundedAndClearedOnAccountChange() {
        let store = ChatReadingPositionStore()
        store.setOwner("account-a")
        let ids = (0..<65).map { _ in UUID() }
        for id in ids {
            store.save(.init(offset: 100, anchorID: nil, anchorDistance: 0,
                following: false, explicitBottom: false), for: id)
        }
        XCTAssertNil(store.position(for: ids[0]))
        XCTAssertNotNil(store.position(for: ids[64]))
        store.setOwner("account-b")
        XCTAssertNil(store.position(for: ids[64]))
    }

    func testDrawerLayoutChangesDoNotBecomeManualReadingIntent() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 900))
        let scroll = UIScrollView(frame: window.bounds)
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.contentSize = CGSize(width: 390, height: 2_000)
        window.addSubview(scroll)
        let controller = ChatScrollController()
        controller.setComposerGeometry(.init(bottomPadding: 400, topInWindow: 760))
        controller.setDrawerInteractionActive(true)
        controller.attach(scroll, conversationID: UUID())
        scroll.contentOffset.y = 10
        controller.setDrawerInteractionActive(false)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertGreaterThan(scroll.contentOffset.y, 1_000,
            "Opening a history conversation while closing the drawer must still perform initial positioning")
        controller.pauseFollowAnimation()
    }

    func testLicensedReadingFacesAreRegisteredAndSecondaryTextKeepsContrast() throws {
        for name in ["Newsreader16pt-Regular", "Newsreader16pt-Italic", "Newsreader16pt-Bold"] {
            XCTAssertNotNil(UIFont(name: name, size: 17))
        }
        XCTAssertTrue(MyChatSystemFont.uiFont(size: 17, weight: .regular, serif: true).fontName.hasPrefix("Newsreader"))
        XCTAssertTrue(MyChatSystemFont.responseWebFontCSS.contains("font/ttf"))
        func luminance(_ color: Color, style: UIUserInterfaceStyle) -> CGFloat {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style)).getRed(&r, green: &g, blue: &b, alpha: &a)
            func linear(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return linear(r) * 0.2126 + linear(g) * 0.7152 + linear(b) * 0.0722
        }
        for style: UIUserInterfaceStyle in [.light, .dark] {
            for surface in [MyChatTheme.canvas, MyChatTheme.composer, MyChatTheme.controlSurface, MyChatTheme.userBubble] {
                let values = [luminance(surface, style: style), luminance(MyChatTheme.secondaryText, style: style)]
                XCTAssertGreaterThanOrEqual((values.max()! + 0.05) / (values.min()! + 0.05), 4.5)
            }
        }
    }

    func testImageOnlyAndMixedDraftsSubmitActualAttachmentsExactlyOnce() async throws {
        for (count, text) in [(1, ""), (3, ""), (2, "请比较这两张图片")] {
            let transport = ControlledChatTransport()
            let model = NativeRuntimeFixture.makeModel(chatClient: transport, stream: transport)
            await model.restoreAuthenticationIfNeeded()
            await model.reloadModels()
            model.beginNewChat()
            model.draft = " \n\t"
            XCTAssertFalse(model.canSendCurrentDraft)
            for index in 0..<count {
                model.addPendingAttachment(ChatPendingAttachment(kind: .image, name: "photo-\(index).png",
                    imageDataURL: NativeRuntimeFixture.imageSource))
            }
            model.draft = text
            XCTAssertTrue(model.canSendCurrentDraft)
            model.sendDraft()
            try await waitUntil { transport.commands.count == 1 && transport.continuations.count == 1 }
            let command = try XCTUnwrap(transport.commands.first)
            XCTAssertEqual(command.userMessage.content, text)
            XCTAssertEqual(command.userMessage.sourceImages?.count, count)
            XCTAssertTrue(command.userMessage.sourceImages?.allSatisfy { $0.hasPrefix("data:image/") } == true)
            XCTAssertTrue(model.pendingAttachments.isEmpty)
            XCTAssertTrue(model.draft.isEmpty)
            model.sendDraft()
            XCTAssertEqual(transport.commands.count, 1, "A rapid second tap cannot create an empty duplicate turn")
            transport.complete(command, text: "已收到图片", sequence: 1)
            try await waitUntil { !model.isCurrentConversationGenerating }
            XCTAssertEqual(model.messages.filter { $0.role == .user }.count, 1)
        }
    }

    func testHealthConnectorRequestsHeartSleepAndWorkoutAlongsideActivity() {
        let types = Set(HealthConnector.readTypes.map(\.identifier))
        for identifier in [HKQuantityTypeIdentifier.heartRate.rawValue, HKQuantityTypeIdentifier.restingHeartRate.rawValue,
            HKQuantityTypeIdentifier.appleExerciseTime.rawValue, HKQuantityTypeIdentifier.stepCount.rawValue,
            HKCategoryTypeIdentifier.sleepAnalysis.rawValue, HKObjectType.workoutType().identifier] {
            XCTAssertTrue(types.contains(identifier), identifier)
        }
        let start = Date(timeIntervalSince1970: 1000)
        let overlapping = [DateInterval(start: start, duration: 3600),
            DateInterval(start: start.addingTimeInterval(1800), duration: 3600)]
        XCTAssertEqual(HealthSummaryText.coveredDuration(overlapping), 5400)
    }

    func testDefaultConnectorHealthSummaryNeverInventsDeniedOrMissingValues() {
        XCTAssertNil(HealthSummaryText.make(date: Date(), steps: nil, kilometers: nil, kilocalories: nil))
        let partial = HealthSummaryText.make(date: Date(), steps: 1234, kilometers: nil, kilocalories: 0)
        XCTAssertTrue(partial?.contains("1234 步") == true)
        XCTAssertTrue(partial?.contains("0 千卡") == true)
        XCTAssertFalse(partial?.contains("距离：") == true)
        XCTAssertNil(HealthSummaryText.make(date: Date(), steps: .nan, kilometers: .infinity, kilocalories: nil))
    }

    func testHealthCatalogCoversNutritionVitalsSymptomsClinicalAndSpecialTypes() {
        let types = HealthConnector.readTypes
        XCTAssertGreaterThanOrEqual(types.count, 200)
        for type: HKObjectType in [HKQuantityType(.bloodGlucose), HKQuantityType(.oxygenSaturation), HKQuantityType(.dietaryVitaminC),
            HKQuantityType(.heartRateVariabilitySDNN), HKCategoryType(.menstrualFlow), HKCategoryType(.coughing),
            HKObjectType.electrocardiogramType(), HKObjectType.audiogramSampleType(), HKObjectType.visionPrescriptionType(),
            HKObjectType.activitySummaryType(), HKSeriesType.workoutRoute(), HKSeriesType.heartbeat(), HKClinicalType(.labResultRecord)] {
            XCTAssertTrue(types.contains(type), type.identifier)
        }
        if #available(iOS 26, *) {
            XCTAssertFalse(types.contains(HKObjectType.medicationDoseEventType()))
            XCTAssertTrue(HealthReadCatalog.sampleTypes.contains(HKObjectType.medicationDoseEventType()))
            XCTAssertTrue(types.contains(HKObjectType.userAnnotatedMedicationType()))
        }
    }

    func testHealthSleepIncludesOnsetWakeStagesAndExactIntervals() throws {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let start = try XCTUnwrap(formatter.date(from: "2026-10-07T23:00:00+08:00"))
        func sleep(_ value: HKCategoryValueSleepAnalysis, _ offset: Double, _ minutes: Double) -> HKCategorySample {
            HKCategorySample(type: HKCategoryType(.sleepAnalysis), value: value.rawValue,
                start: start.addingTimeInterval(offset * 60), end: start.addingTimeInterval((offset + minutes) * 60))
        }
        let samples = [sleep(.inBed, 0, 480), sleep(.asleepCore, 0, 120), sleep(.asleepCore, 0, 60),
            sleep(.asleepDeep, 120, 60), sleep(.awake, 180, 15), sleep(.asleepREM, 195, 105), sleep(.asleepCore, 300, 180)]
        let summary = HealthContextText.sleepSummary(samples, formatter: formatter)
        XCTAssertTrue(summary.contains("首段入睡=2026-10-07T23:00:00+08:00"))
        XCTAssertTrue(summary.contains("末段醒来=2026-10-08T07:00:00+08:00"))
        XCTAssertTrue(summary.contains("睡眠总时长=465分钟"))
        XCTAssertTrue(summary.contains("浅睡（核心睡眠）=300分钟"))
        XCTAssertTrue(summary.contains("深睡=60分钟"))
        XCTAssertTrue(summary.contains("REM=105分钟"))
        XCTAssertTrue(summary.contains("清醒=15分钟"))
        let detail = HealthContextText.record(samples[5], unit: nil, formatter: formatter)
        XCTAssertTrue(detail.contains("开始=2026-10-08T02:15:00+08:00"))
        XCTAssertTrue(detail.contains("结束=2026-10-08T04:00:00+08:00"))
        XCTAssertTrue(detail.contains("阶段=REM"))
        let unclassified = HealthContextText.sleepSummary([sleep(.asleepUnspecified, 0, 60)], formatter: formatter)
        XCTAssertFalse(unclassified.contains("深睡="))
        XCTAssertFalse(unclassified.contains("REM="))
    }

    func testHealthContextKeepsAllTypeSummariesWhenDetailsExceedCapacity() throws {
        let sections = (0..<210).map { HealthContextSection(name: "type\($0)", summary: "value=\($0)", details: [String(repeating: "细", count: 2_000)]) }
        let text = try XCTUnwrap(HealthContextText.make(sections: sections, date: Date()))
        XCTAssertLessThanOrEqual(text.utf16.count, HealthContextText.maximumCharacters)
        XCTAssertTrue(text.contains("【type209】value=209"))
        XCTAssertTrue(text.contains("部分明细超过"))
        XCTAssertNil(HealthContextText.make(sections: [], date: Date()))
        let long = try XCTUnwrap(HealthContextText.make(sections: [.init(name: "临床记录", summary: String(repeating: "字", count: 200_000), details: [])], date: Date()))
        XCTAssertLessThanOrEqual(long.utf16.count, HealthContextText.maximumCharacters)
    }

    func testHealthMedicationDetailsSurviveSmallPerTypeUTF16SummaryQuota() throws {
        let records = (1...20).map { "SYNTHETIC_MED_\($0); " + String(repeating: "x", count: 100) }
        let medication = try XCTUnwrap(HealthContextText.medicationSection(records))
        XCTAssertEqual(medication.details, records)
        let otherTypes = (0..<209).map {
            HealthContextSection(name: "syntheticType\($0)", summary: "available", details: [])
        }
        let text = try XCTUnwrap(HealthContextText.make(sections: otherTypes + [medication], date: Date()))
        for record in records { XCTAssertTrue(text.contains(record), "A medication must not vanish into the summary quota") }
        for index in 0..<209 { XCTAssertTrue(text.contains("【syntheticType\(index)】available")) }
        XCTAssertLessThanOrEqual(text.utf16.count, HealthContextText.maximumCharacters)
        XCTAssertFalse(text.contains("部分明细超过"))
        XCTAssertNil(HealthContextText.medicationSection([]))
    }

    func testHealthMedicationOverflowReportsRealOmissionWithinUTF16Budget() throws {
        let records = (1...2_000).map { "SYNTHETIC_MED_\($0); " + String(repeating: "x", count: 250) }
        let medication = try XCTUnwrap(HealthContextText.medicationSection(records))
        let text = try XCTUnwrap(HealthContextText.make(sections: [medication], date: Date()))
        XCTAssertTrue(text.contains("本次共读取2000条用药记录"))
        XCTAssertTrue(text.contains(records[0]))
        XCTAssertFalse(text.contains(records[records.count - 1]))
        XCTAssertTrue(text.contains("部分明细超过本次上下文容量"))
        XCTAssertLessThanOrEqual(text.utf16.count, HealthContextText.maximumCharacters)
    }

    func testHealthSummaryOnlyUTF16OverflowDoesNotPromiseMissingDetails() throws {
        let text = try XCTUnwrap(HealthContextText.make(sections: [
            .init(name: "syntheticLargeRecord", summary: String(repeating: "x", count: 200_000), details: [])
        ], date: Date()))
        XCTAssertTrue(text.contains("汇总已截短"))
        XCTAssertTrue(text.contains("部分明细超过本次上下文容量"))
        XCTAssertFalse(text.contains("详情见记录"))
        XCTAssertLessThanOrEqual(text.utf16.count, HealthContextText.maximumCharacters)
    }

    func testHealthPercentAndHeartRateUseReadableUnits() {
        let date = Date(timeIntervalSince1970: 1_000)
        let oxygen = HKQuantitySample(type: HKQuantityType(.oxygenSaturation), quantity: HKQuantity(unit: .percent(), doubleValue: 0.97), start: date, end: date)
        let text = HealthContextText.record(oxygen, unit: .percent(), formatter: ISO8601DateFormatter())
        XCTAssertTrue(text.contains("值=97.0 %"))
        let heartUnit = HKUnit.count().unitDivided(by: .minute())
        let heart = HKQuantitySample(type: HKQuantityType(.heartRate), quantity: HKQuantity(unit: heartUnit, doubleValue: 67), start: date, end: date)
        XCTAssertTrue(HealthContextText.record(heart, unit: heartUnit, formatter: ISO8601DateFormatter()).contains("值=67.0 count/min"))
    }

    func testConnectorOffPersistsPerAccountAndStopsHealthContext() async {
        let owner = "health-switch-test-" + UUID().uuidString
        let requestedKey = "mychat.health.authorization-requested.\(owner)"
        let versionKey = requestedKey + ".version"
        let enabledKey = ConnectorEnabledPreference.key(kind: "health", ownerID: owner)
        defer {
            UserDefaults.standard.removeObject(forKey: requestedKey)
            UserDefaults.standard.removeObject(forKey: enabledKey)
            UserDefaults.standard.removeObject(forKey: versionKey)
        }
        UserDefaults.standard.set(true, forKey: requestedKey)
        UserDefaults.standard.set(1, forKey: versionKey)
        let connector = HealthConnector(ownerID: owner)
        XCTAssertTrue(connector.isEnabled)
        connector.setEnabled(false)
        XCTAssertFalse(HealthConnector(ownerID: owner).isEnabled)
        let context = await HealthConnector.modelContext(ownerID: owner)
        XCTAssertNil(context)
        XCTAssertTrue(ConnectorEnabledPreference.value(kind: "health", ownerID: owner + "-other"))
        connector.setEnabled(true)
        XCTAssertTrue(HealthConnector(ownerID: owner).isEnabled)
        XCTAssertTrue(HealthConnector(ownerID: owner).authorizationWasRequested)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: versionKey), 1,
            "Switching off/on preserves the connection and never starts or completes authorization")
        connector.disconnect()
        XCTAssertFalse(HealthConnector(ownerID: owner).authorizationWasRequested)
    }

    func testGmailOAuthRejectsSpoofedAndDuplicateCallbacks() throws {
        let valid = URL(string: "com.mychat.ios:/oauth2redirect?state=expected&code=abc")!
        XCTAssertEqual(try GmailOAuth.authorizationCode(callback: valid, state: "expected"), "abc")
        for value in [
            "com.mychat.ios:/oauth2redirect?state=wrong&code=abc",
            "com.mychat.ios:/oauth2redirect?state=expected&state=expected&code=abc",
            "com.mychat.ios:/oauth2redirect?state=expected&code=abc&error=access_denied",
            "com.mychat.ios://attacker/oauth2redirect?state=expected&code=abc",
            "mychat:/oauth2redirect?state=expected&code=abc"
        ] { XCTAssertThrowsError(try GmailOAuth.authorizationCode(callback: URL(string: value)!, state: "expected")) }
        XCTAssertEqual(String(data: GmailOAuth.form(["code": "a+b&c =中文"]), encoding: .utf8), "code=a%2Bb%26c%20%3D%E4%B8%AD%E6%96%87")
        let gmail = GmailConnector(ownerID: "unit-test", clientID: "")
        XCTAssertFalse(gmail.isConfigured)
        XCTAssertFalse(gmail.isConnected)
    }

    func testGmailReadsPlainTextWithoutExecutingHTML() throws {
        let encoded = GmailOAuth.base64URL(Data("邮件正文 ✓".utf8))
        let data = Data("{\"mimeType\":\"multipart/alternative\",\"parts\":[{\"mimeType\":\"text/plain\",\"body\":{\"data\":\"\(encoded)\"}}]}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(GmailPayload.self, from: data).plainText, "邮件正文 ✓")
    }

    func testBuild102CodeSendEligibilityDoesNotSilentlyDisableForModelOrRepository() throws {
        XCTAssertTrue(CodeSendEligibility.canSubmit(draft: "哈哈", isBusy: false))
        XCTAssertFalse(CodeSendEligibility.canSubmit(draft: " \n\t", isBusy: false))
        XCTAssertFalse(CodeSendEligibility.canSubmit(draft: "哈哈", isBusy: true))
        XCTAssertNotNil(CodeSendEligibility.modelIssue(nil))
        let data = Data(#"{"id":"custom-sonnet","name":"Sonnet 5.5","provider":"custom","access":"premium","outputKind":"chat","promptPrice":0,"completionPrice":0,"contextLength":200000,"vision":true,"tools":false,"flagship":false,"reasoningEfforts":[],"reasoningMandatory":false,"endpointID":"70000000-0000-4000-8000-000000000001"}"#.utf8)
        let custom = try JSONDecoder().decode(ModelCatalogItem.self, from: data)
        XCTAssertNil(CodeSendEligibility.modelIssue(custom),
            "A connected custom text model must not depend on platform tools metadata")
    }

    func testChatBottomAnchorAccountsForKeyboardOcclusionOnce() {
        // A 1,000 pt body plus 484 pt of keyboard/input reservation must end
        // at y=416, independently of an ancestor's keyboard avoidance.
        let fullViewport = CGRect(x: 0, y: 60, width: 390, height: 840)
        let reducedViewport = CGRect(x: 0, y: 60, width: 390, height: 520)
        let fullOffset = ChatBottomAnchor.offset(contentHeight: 1_484,
            bottomPadding: 484, viewport: fullViewport, composerTop: 424, topInset: 0)
        let reducedOffset = ChatBottomAnchor.offset(contentHeight: 1_484,
            bottomPadding: 484, viewport: reducedViewport, composerTop: 424, topInset: 0)
        XCTAssertEqual(fullOffset, 644)
        XCTAssertEqual(reducedOffset, fullOffset,
            "A reduced viewport must not apply the keyboard height a second time")
        XCTAssertEqual(fullViewport.minY + 1_000 - fullOffset, 416,
            "The last body row belongs immediately above the input")
        let hiddenKeyboard = ChatBottomAnchor.offset(contentHeight: 1_148,
            bottomPadding: 148, viewport: fullViewport, composerTop: 760, topInset: 0)
        XCTAssertEqual(hiddenKeyboard, 308)
        XCTAssertEqual(ChatBottomAnchor.offset(contentHeight: 620, bottomPadding: 484,
            viewport: fullViewport, composerTop: 424, topInset: 60), -60,
            "A short transcript must retain its top inset instead of being pulled offscreen")
    }

    func testBuild102NativeDismissalConsumesFocusRequestAndCanFocusAgain() async throws {
        var text = "draft"
        var focused = false
        let editor = ComposerEditorSession()
        let input = ComposerTextInput(text: Binding(get: { text }, set: { text = $0 }),
            focused: Binding(get: { focused }, set: { focused = $0 }), editor: editor,
            placeholder: "Message", submit: {})
        let coordinator = input.makeCoordinator()
        let view = ComposerTextView()
        view.delegate = coordinator
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(view)
        view.frame = CGRect(x: 20, y: 100, width: 350, height: 50)
        window.makeKeyAndVisible()
        defer { view.resignFirstResponder(); window.isHidden = true }
        focused = true
        coordinator.requestFocus(true, in: view)
        XCTAssertTrue(view.isFirstResponder)
        await Task.yield()
        view.resignFirstResponder()
        coordinator.requestFocus(true, in: view)
        XCTAssertFalse(view.isFirstResponder, "A stale SwiftUI focus binding must not undo native dismissal")
        await Task.yield()
        coordinator.requestFocus(false, in: view)
        focused = true
        coordinator.requestFocus(true, in: view)
        XCTAssertTrue(view.isFirstResponder, "A new explicit focus action must still open the keyboard")
    }

    func testBuild102TypingAtlasLoadsAll471Frames() async throws {
        let frames = await DotMotionFrames.frames(for: .typing)
        XCTAssertEqual(frames?.images.count, 471)
        XCTAssertEqual(frames?.images.first?.width, 144)
        XCTAssertEqual(frames?.images.last?.height, 144)
        XCTAssertEqual(try XCTUnwrap(frames?.duration), 7.853981633974483, accuracy: 0.001)
    }

    func testBuild102SendCommitsTheLatestNativeTextBeforeDraftIsConsumed() {
        var text = "older"
        let input = ComposerTextInput(text: Binding(get: { text }, set: { text = $0 }),
            focused: .constant(false), editor: ComposerEditorSession(), placeholder: "Message", submit: {})
        let coordinator = input.makeCoordinator()
        let view = ComposerTextView()
        view.text = "latest text"
        coordinator.textViewDidChange(view)
        coordinator.commitText(view)
        XCTAssertEqual(text, "latest text")
        XCTAssertNil(coordinator.pendingEdit)
    }

    func testBuild102OlderTextAcknowledgementPreservesNewerNativeEdit() async {
        var text = ""
        let input = ComposerTextInput(text: Binding(get: { text }, set: { text = $0 }),
            focused: .constant(false), editor: ComposerEditorSession(), placeholder: "Message", submit: {})
        let coordinator = input.makeCoordinator()
        let view = ComposerTextView()
        view.text = "a"
        coordinator.textViewDidChange(view)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(text, "a")
        view.text = "ab"
        coordinator.textViewDidChange(view)
        coordinator.acceptModelText("a")
        XCTAssertEqual(coordinator.pendingEdit, "ab")
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(text, "ab")
        view.text = "abc"
        coordinator.textViewDidChange(view)
        coordinator.acceptModelText("")
        XCTAssertNil(coordinator.pendingEdit, "An explicit draft reset must still win")
    }

    func testBuild102PrimaryModelsUseRealRouteVersionsAndIncludePairedCurrentModels() async throws {
        func model(_ id: String, route: String? = nil) throws -> ModelCatalogItem {
            var object: [String: Any] = ["id": id, "name": "A custom display name", "provider": "Anthropic",
                "access": "quota", "outputKind": "chat", "promptPrice": 0, "completionPrice": 0,
                "contextLength": 100000, "vision": true, "tools": true, "flagship": false,
                "reasoningEfforts": [], "reasoningMandatory": false]
            if let route { object["endpointID"] = UUID().uuidString; object["upstreamModelID"] = route }
            return try JSONDecoder().decode(ModelCatalogItem.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let oldOpus = try model("anthropic/claude-opus-5")
        let oldSonnet = try model("anthropic/claude-sonnet-5")
        let fable = try model("anthropic/claude-fable-5-1")
        let opus = try model("anthropic/claude-opus-5-5")
        let sonnet = try model("paired-endpoint", route: "claude-sonnet-5-5")
        let haiku = try model("anthropic/claude-haiku-5-5")
        let primary = ModelCatalogItem.primaryChatModels([oldOpus, oldSonnet, sonnet, haiku, fable, opus], selectedID: sonnet.id)
        XCTAssertEqual(primary.map(\.chatDisplayName), ["Fable 5.1", "Opus 5.5", "Sonnet 5.5", "Haiku 5.5"])
        XCTAssertEqual(primary.map(\.id), [fable.id, opus.id, sonnet.id, haiku.id])
        XCTAssertEqual(oldOpus.chatDisplayName, "Opus 5", "Never rename an old wire route as a newer model")

        let catalogWithFallback = ModelCatalogItem.addingHaiku55Fallback(to: [fable, opus, sonnet])
        let fallbackPrimary = ModelCatalogItem.primaryChatModels(catalogWithFallback, selectedID: nil)
        XCTAssertEqual(fallbackPrimary.map(\.chatDisplayName), ["Fable 5.1", "Opus 5.5", "Sonnet 5.5", "Haiku 5.5"])
        XCTAssertEqual(fallbackPrimary.last?.id, "anthropic/claude-haiku-5.5")
        XCTAssertEqual(fallbackPrimary.last?.isSelectable, sonnet.isSelectable)
        XCTAssertEqual([AppDestination.chats.rawValue, AppDestination.projects.rawValue,
                        AppDestination.code.rawValue, AppDestination.artifacts.rawValue],
            ["聊天", "项目", "编程", "可视化"])

        let now = Date(timeIntervalSince1970: 1_000)
        let user = AuthUser(id: "fixture-user", email: nil, isAnonymous: false)
        let usable = AuthSession(accessToken: "token", refreshToken: "refresh", tokenType: "bearer",
            expiresAt: now.addingTimeInterval(45), user: user)
        let expiring = AuthSession(accessToken: "token", refreshToken: "refresh", tokenType: "bearer",
            expiresAt: now.addingTimeInterval(7), user: user)
        XCTAssertTrue(ChatAuthenticationPolicy.canAdmitImmediately(usable, now: now))
        XCTAssertFalse(ChatAuthenticationPolicy.canAdmitImmediately(expiring, now: now))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatAdmissionRetryFixtureURLProtocol.self]
        let client = ChatAPIClient(session: URLSession(configuration: configuration), baseURL: URL(string: "https://mychat.invalid")!)
        defer { ChatAdmissionRetryFixtureURLProtocol.recorder = nil }
        for item in primary {
            let message = ChatMessage(id: UUID(), role: .user, content: "test", thinking: nil, createdAt: Date())
            let command = ChatAppendCommand(conversationID: UUID(), userMessage: message, modelID: item.id,
                endpointID: item.endpointID.flatMap(UUID.init(uuidString:)), createConversation: true, title: "routing")
            let accepted = try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1, "jobId": UUID().uuidString.lowercased(),
                "generationId": command.generationID.uuidString.lowercased(),
                "userMessageId": command.userMessageID.uuidString.lowercased(),
                "assistantMessageId": command.assistantMessageID.uuidString.lowercased(),
                "status": "queued", "created": true,
                "streamUrl": "https://mychat.invalid/api/v1/jobs/fixture/events"
            ])
            let recorder = ChatAdmissionRetryRecorder(responses: [(202, accepted, [:])])
            ChatAdmissionRetryFixtureURLProtocol.recorder = recorder
            _ = try await client.enqueueAppendTurn(command, accessToken: "fixture-token")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(recorder.requestBodies.first)) as? [String: Any])
            if let endpoint = item.endpointID {
                XCTAssertEqual(body["endpointId"] as? String, endpoint.lowercased())
                XCTAssertNil(body["modelId"])
            } else { XCTAssertEqual(body["modelId"] as? String, item.id) }
        }
    }

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

    func testAnimatedDrawingReservesSpaceBeyondOld620PointClip() async throws {
        var reportedHeight: CGFloat = 0
        let raw = #"<svg viewBox="0 0 300 300"><circle id="moving" cx="100" cy="100" r="20"><animate id="motion" attributeName="cy" values="100;1000;100" dur="1s" repeatCount="indefinite"/></circle></svg>"#
        let coordinator = ArtifactSandboxView.Coordinator()
        let parent = ArtifactSandboxView(rawHTML: raw, colorScheme: .light, inline: true,
            reduceMotion: false, contentHeight: { reportedHeight = max(reportedHeight, $0) })
        let view = parent.makeWebView(coordinator: coordinator)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 180)
        defer { ArtifactSandboxView.dismantleUIView(view, coordinator: coordinator) }
        func evaluate(_ script: String) async throws -> Bool {
            try await withCheckedThrowingContinuation { continuation in
                view.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
                    switch result {
                    case .success(let value): continuation.resume(returning: value as? Bool ?? false)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
            }
        }
        for _ in 0..<100 {
            if (try? await evaluate("document.getElementById('motion') !== null && !!window.__mychatMeasureArtifact")) == true { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let measured = try await evaluate("const svg=document.querySelector('svg'); svg.pauseAnimations(); svg.setCurrentTime(0.5); window.__mychatMeasureArtifact(); getComputedStyle(svg).overflow==='visible'")
        XCTAssertTrue(measured)
        for _ in 0..<50 where reportedHeight <= 620 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertGreaterThan(reportedHeight, 620, "Animated content outside the original viewBox must expand the actual surface")
        let contained = try await evaluate("document.getElementById('moving').getBoundingClientRect().bottom <= document.getElementById('artifact').getBoundingClientRect().bottom")
        XCTAssertTrue(contained)
    }

    func testSourcesBadgeOnlyAcceptsActualWebSearchResults() throws {
        func search(kind: String?, url: String, conversation: String? = nil) throws -> ChatToolSearch {
            var result: [String: Any] = ["title": "source", "url": url]
            if let conversation { result["conversation_id"] = conversation }
            var payload: [String: Any] = ["query": "query", "results": [result]]
            if let kind { payload["kind"] = kind }
            return try JSONDecoder().decode(ChatToolSearch.self, from: JSONSerialization.data(withJSONObject: payload))
        }
        XCTAssertTrue(try search(kind: "web", url: "https://example.com").isWebSearch)
        XCTAssertTrue(try search(kind: nil, url: "https://example.com").isWebSearch)
        XCTAssertFalse(try search(kind: "history", url: "https://example.com").isWebSearch)
        XCTAssertFalse(try search(kind: "connector", url: "https://example.com").isWebSearch)
        XCTAssertFalse(try search(kind: nil, url: "mychat://conversation/old").isWebSearch)
        XCTAssertFalse(try search(kind: nil, url: "https://example.com", conversation: UUID().uuidString).isWebSearch)
    }

    /// Opt-in API probe only: no window, UI automation, screenshots or fixture
    /// replies. The existing account secret stays in Keychain/server storage.
    func testOptInLiveCustomEndpointFirstTextTiming() async throws {
        guard let probeMode = ProcessInfo.processInfo.environment["MYCHAT_LIVE_NETWORK_PROBE"],
              ["1", "catalog", "connect-models", "code"].contains(probeMode) else {
            throw XCTSkip("Live network probe is opt-in")
        }
        let store = KeychainAuthSessionStore()
        guard try store.load() != nil else { throw XCTSkip("No signed-in account in this simulator") }
        URLProtocol.unregisterClass(NativeAuditURLProtocol.self)
        defer { URLProtocol.registerClass(NativeAuditURLProtocol.self) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = []
        let deadlineSeconds: Double = ["connect-models", "code"].contains(probeMode) ? 120 : 55
        configuration.timeoutIntervalForRequest = probeMode == "connect-models" ? 45 : 25
        configuration.timeoutIntervalForResource = deadlineSeconds
        let session = URLSession(configuration: configuration)
        let deadline = Task {
            try? await Task.sleep(for: .seconds(deadlineSeconds))
            if !Task.isCancelled { session.invalidateAndCancel() }
        }
        defer { deadline.cancel(); session.invalidateAndCancel() }
        let config = MobileConfigurationClient(session: session)
        let auth = SupabaseAuthClient(configurationClient: config, sessionStore: store, networkSession: session)
        let token: String
        print("LIVE_PROBE_STAGE auth")
        if let stored = try store.load(), !stored.expires(within: 0) {
            token = stored.accessToken
        } else {
            do {
                guard let refreshed = try await auth.accessToken() else { throw XCTSkip("No active account") }
                token = refreshed
            } catch is CancellationError {
                // The host app can refresh the same Keychain session at launch.
                guard let current = try store.load(), !current.expires(within: 0) else { throw CancellationError() }
                token = current.accessToken
            }
        }
        print("LIVE_PROBE_STAGE endpoints")
        let endpoints = try await AccountSettingsClient(configurationClient: config, session: session)
            .fetchModelEndpoints(accessToken: token)
        let candidates = endpoints.filter { !$0.needsReconnect && $0.outputKind == .chat }
        let requestedModel = ProcessInfo.processInfo.environment["MYCHAT_LIVE_MODEL_ID"]
        guard let endpoint = candidates.first(where: { $0.model == requestedModel })
                ?? candidates.first(where: { $0.model.localizedCaseInsensitiveContains("sonnet") })
                ?? candidates.first(where: { $0.model.localizedCaseInsensitiveContains("haiku") }),
              let endpointID = UUID(uuidString: endpoint.id) else {
            throw XCTSkip("This account has no connected Claude endpoint; no public-route fallback was used")
        }
        if probeMode == "catalog" || probeMode == "connect-models" {
            print("CONNECTED_MODEL_IDS " + candidates.map(\.model).sorted().joined(separator: ", "))
            var request = URLRequest(url: URL(string: "https://mychat-nm6x.onrender.com/api/endpoints/discover")!)
            request.httpMethod = "POST"
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["endpointId": endpoint.id])
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return XCTFail("Stored-endpoint model discovery failed; credentials and body omitted")
            }
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let models = try XCTUnwrap(payload["models"] as? [[String: Any]])
            let claude = models.compactMap { $0["id"] as? String }.filter { $0.localizedCaseInsensitiveContains("claude") }
            print("DISCOVERED_CLAUDE_MODEL_IDS " + claude.sorted().joined(separator: ", "))
            XCTAssertFalse(claude.isEmpty)
            if probeMode == "connect-models" {
                let currentModels = ["claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-4-5"]
                for model in currentModels {
                    guard claude.contains(model) else { return XCTFail("Requested model absent from the real upstream catalog: " + model) }
                    if candidates.contains(where: { $0.model == model && $0.baseURL == endpoint.baseURL }) { continue }
                    var create = URLRequest(url: URL(string: "https://mychat-nm6x.onrender.com/api/endpoints")!)
                    create.httpMethod = "POST"
                    create.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                    create.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    create.httpBody = try JSONSerialization.data(withJSONObject: [
                        "sourceEndpointId": endpoint.id, "model": model, "outputKind": "chat"
                    ])
                    let (createdData, createdResponse) = try await session.data(for: create)
                    guard (createdResponse as? HTTPURLResponse)?.statusCode == 201 else {
                        return XCTFail("Model connection failed: " + model + "; response body omitted")
                    }
                    let result = try XCTUnwrap(JSONSerialization.jsonObject(with: createdData) as? [String: Any])
                    let saved = try XCTUnwrap(result["endpoint"] as? [String: Any])
                    XCTAssertEqual(saved["model"] as? String, model)
                    XCTAssertNil(saved["apiKey"])
                    XCTAssertNil(saved["api_key"])
                    print("CONNECTED_VERIFIED_MODEL " + model)
                }
                let saved = try await AccountSettingsClient(configurationClient: config, session: session)
                    .fetchModelEndpoints(accessToken: token)
                for model in currentModels {
                    XCTAssertTrue(saved.contains { $0.model == model && $0.baseURL == endpoint.baseURL && !$0.needsReconnect })
                }
                print("ALL_CURRENT_MODELS_CONNECTED")
            }
            return
        }
        if probeMode == "code" {
            print("LIVE_PROBE_STAGE code-session")
            let account = try XCTUnwrap(store.load())
            let workspace = WorkspaceDataClient(configurationClient: config, session: session)
            let record = try await workspace.createCodeSession(userID: account.user.id,
                repository: nil, title: "API check · Build 102", accessToken: token)
            let sessionID = try XCTUnwrap(UUID(uuidString: record.id))
            _ = try await workspace.createCodeMessage(userID: account.user.id, sessionID: record.id,
                role: "user", content: "仅回复 OK。", metadata: nil, accessToken: token)
            print("LIVE_PROBE_STAGE code-enqueue")
            let command = CodeChatCommand(repository: record.repository, modelID: endpoint.model,
                endpointID: endpointID, reasoningEffort: nil,
                messages: [CodeContextMessage(role: "user", content: "仅回复 OK。")],
                taskID: nil, responseID: UUID(), sessionID: sessionID)
            let started = Date()
            let admission: CodeAdmission
            do {
                admission = try await CodeAPIClient(session: session).enqueue(command, accessToken: token)
            } catch {
                let failure = error as NSError
                print("CODE_ENQUEUE_FAILURE type=" + String(reflecting: type(of: error))
                    + " domain=" + failure.domain + " code=" + String(failure.code)
                    + " cancelled=" + String(Task.isCancelled))
                throw error
            }
            print("CODE_API_ACCEPTED model=" + endpoint.model + " admittedMs=" + String(Int(Date().timeIntervalSince(started) * 1000)))
            var firstText = false
            var completed = false
            for try await event in JobEventStream(session: session).events(admission: admission, accessToken: token) {
                switch event.payload {
                case let .textDelta(text) where !text.isEmpty:
                    if !firstText { print("CODE_FIRST_TEXT_MS " + String(Int(Date().timeIntervalSince(started) * 1000))) }
                    firstText = true
                case let .terminal(terminal):
                    XCTAssertEqual(terminal.status, .completed)
                    completed = terminal.status == .completed
                    print("CODE_TERMINAL " + terminal.status.rawValue)
                default: break
                }
            }
            XCTAssertTrue(firstText)
            XCTAssertTrue(completed)
            return
        }
        let command = ChatAppendCommand(conversationID: UUID(),
            userMessage: ChatMessage(id: UUID(), role: .user,
                content: ProcessInfo.processInfo.environment["MYCHAT_LIVE_PROMPT"] ?? "仅回复 OK。",
                thinking: nil, createdAt: Date()),
            modelID: endpoint.model, endpointID: endpointID, createConversation: true,
            conversationMemoryEnabled: false, title: "Latency check · Build 102")
        let start = Date()
        var metrics: [String: Any] = ["model": endpoint.model, "generationID": command.generationID.uuidString]
        func mark(_ key: String) { metrics[key] = Int(Date().timeIntervalSince(start) * 1000) }
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys]) {
                let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("live-network-probe.json")
                try? data.write(to: url, options: .atomic)
                print("LIVE_NETWORK_TIMING " + (String(data: data, encoding: .utf8) ?? ""))
            }
        }
        let client = ChatAPIClient(session: session)
        let connection = try await client.openAppendTurn(command, accessToken: token)
        mark("admittedMs")
        let events: AsyncThrowingStream<ChatJobEvent, Error>
        if let admitted = connection.events { events = admitted }
        else { events = JobEventStream(session: session).events(admission: connection.admission, accessToken: token) }
        var firstText = false
        for try await event in events {
            if metrics["firstEventMs"] == nil { mark("firstEventMs") }
            switch event.payload {
            case let .textDelta(delta) where !delta.isEmpty:
                if !firstText { firstText = true; mark("firstTextMs") }
            case .modelOutputCompleted:
                mark("modelOutputCompletedMs")
            case let .terminal(terminal):
                mark("terminalMs")
                metrics["terminalStatus"] = terminal.status.rawValue
                XCTAssertEqual(terminal.status, .completed)
            default: break
            }
        }
        XCTAssertTrue(firstText, "A completed first-token measurement requires actual model text")
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

    func testDotOutputPositionNeverReversesDuringLayoutReparse() {
        var displayed: CGFloat = 100
        for target in [CGFloat(140), 120, 160, 130, 170] {
            let next = DotOutputPosition.advance(displayed: displayed, target: target, elapsed: 1 / 60)
            XCTAssertGreaterThanOrEqual(next, displayed)
            XCTAssertLessThanOrEqual(next, max(displayed, target))
            displayed = next
        }
        XCTAssertEqual(DotOutputPosition.advance(displayed: 100, target: 80, elapsed: 1 / 60), 100)
        XCTAssertEqual(DotOutputPosition.advance(displayed: 100, target: 100.1, elapsed: 1 / 60), 100.1)
    }

    func testResponseRevealStartsEveryReceivedGraphemeImmediately() {
        for source in ["中文渐进显示", "English streaming", "标题 **粗体** 👨‍👩‍👧‍👦 e\u{301}"] {
            let count = source.count
            let step = ResponseRevealTiming.step(added: count)
            XCTAssertEqual(step, 0, "A received delta must not be paced character by character")
            for index in 0..<count {
                let born = 100 + Double(index) * step
                XCTAssertEqual(ResponseRevealTiming.opacity(now: born - 0.01, born: born), 0)
                XCTAssertEqual(ResponseRevealTiming.opacity(now: born, born: born), 0.10)
                XCTAssertEqual(ResponseRevealTiming.opacity(now: born + 0.12, born: born), 0.8875, accuracy: 0.000001)
                XCTAssertEqual(ResponseRevealTiming.opacity(now: 100.33, born: born), 1)
            }
        }
        XCTAssertEqual(ResponseRevealTiming.step(added: 1), 0)
        XCTAssertEqual(ResponseRevealTiming.step(added: 10_000), 0)
        var births = ResponseGlyphBirths<Int>()
        XCTAssertEqual(births.update(indices: [0, 1, 2], now: 100), [0: 100, 1: 100, 2: 100])
        XCTAssertEqual(births.update(indices: [0, 1, 2, 3, 4], now: 101),
            [0: 100, 1: 100, 2: 100, 3: 101, 4: 101])
        XCTAssertEqual(Array("👨‍👩‍👧‍👦e\u{301}").count, 2)
    }

    func testMarkdownPublicationDoesNotWaitForScrollInteractionToEnd() async throws {
        let controller = ChatScrollController()
        controller.setInteractionActive(true)
        defer { controller.setInteractionActive(false) }
        let key = "offline-stream-publication:" + UUID().uuidString
        let renderer = MessageRenderModel(key: key, source: "first", isStreaming: true)
        let published = expectation(description: "The next received body is published during scrolling")
        var received = false
        let observation = renderer.$document.dropFirst().sink { document in
            guard !received, document.blocks == [.paragraph("first second")] else { return }
            received = true
            published.fulfill()
        }
        defer { observation.cancel() }
        // Unlike first-ink initialization, this is the normal asynchronous
        // Markdown path. It previously queued its publication until scroll idle.
        await renderer.update(key: key, source: "first second", isStreaming: true,
            scrollController: controller)
        await fulfillment(of: [published], timeout: 2)
        XCTAssertEqual(renderer.document.blocks, [.paragraph("first second")])
    }

    func testGenerationDiagnosticsSeparateNetworkTextFromMarkdownPresentation() {
        let command = ChatAppendCommand(
            conversationID: UUID(),
            userMessage: ChatMessage(id: UUID(), role: .user, content: "时序测试", thinking: nil, createdAt: Date()),
            createConversation: true,
            title: "时序测试"
        )
        ChatGenerationDiagnostics.begin(command)
        let start = ChatGenerationDiagnostics.records[command.generationID]!.monotonicStart

        ChatGenerationDiagnostics.mark(command.generationID, stage: .authenticationReady, receivedAt: start + 0.005)
        ChatGenerationDiagnostics.mark(command.generationID, stage: .healthContextReady, receivedAt: start + 0.010)
        ChatGenerationDiagnostics.mark(command.generationID, stage: .requestStarted, receivedAt: start + 0.015)
        ChatGenerationDiagnostics.mark(command.generationID, stage: .firstText, receivedAt: start + 0.020)
        ChatGenerationDiagnostics.markFirstMarkdownPublished(
            assistantMessageID: command.assistantMessageID, receivedAt: start + 0.030
        )
        ChatGenerationDiagnostics.markFirstGlyphDrawn(
            assistantMessageID: command.assistantMessageID, receivedAt: start + 0.040
        )
        // A callback delivered out of order must retain the actual earliest draw.
        ChatGenerationDiagnostics.markFirstGlyphDrawn(
            assistantMessageID: command.assistantMessageID, receivedAt: start + 0.035
        )

        let record = ChatGenerationDiagnostics.records[command.generationID]!
        XCTAssertEqual(record.assistantMessageID, command.assistantMessageID)
        XCTAssertEqual(record.milliseconds["authenticationReady"] ?? -1, 5, accuracy: 0.02)
        XCTAssertEqual(record.milliseconds["healthContextReady"] ?? -1, 10, accuracy: 0.02)
        XCTAssertEqual(record.milliseconds["requestStarted"] ?? -1, 15, accuracy: 0.02)
        XCTAssertEqual(record.milliseconds["firstText"] ?? -1, 20, accuracy: 0.02)
        XCTAssertEqual(record.milliseconds["firstMarkdownPublished"] ?? -1, 30, accuracy: 0.02)
        XCTAssertEqual(record.milliseconds["firstGlyphDrawn"] ?? -1, 35, accuracy: 0.02)
    }

    func testConversationNavigationAnchorsWithoutInheritingThePreviousGenerationAnimation() async throws {
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 60, width: 390, height: 840))
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.contentSize = CGSize(width: 390, height: 1_600)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 900))
        window.addSubview(scroll)
        let controller = ChatScrollController()
        controller.setComposerGeometry(ChatComposerGeometry(bottomPadding: 650, topInWindow: 424))
        controller.setGenerationActive(true)
        controller.attach(scroll, conversationID: UUID())
        scroll.setContentOffset(CGPoint(x: 0, y: 40), animated: false)
        controller.attach(scroll, conversationID: UUID())
        try await Task.sleep(for: .milliseconds(30))
        let expected = ChatReadingAnchor.offset(contentHeight: scroll.contentSize.height,
            bottomPadding: 650, viewport: scroll.convert(scroll.bounds, to: nil),
            composerTop: 424, topInset: scroll.adjustedContentInset.top)
        XCTAssertEqual(scroll.contentOffset.y, expected, accuracy: 0.5,
            "A new conversation must anchor once rather than animate from the previous conversation's offset")
        controller.pauseFollowAnimation()
    }

    func testModelDisplayLabelsRemoveSeparatorsWithoutChangingRoutingIdentifiers() throws {
        for (route, label, expected) in [("z-ai/glm-5.2", "GLM-5.2", "GLM 5.2"),
            ("chatgpt-plan:gpt-6-astra", "GPT-6-Astra", "GPT 6 Astra"),
            ("chatgpt-plan:gpt-5.6-sol", "GPT-5.6-Sol", "GPT 5.6 Sol")] {
            let payload: [String: Any] = ["id": route, "name": label, "provider": "test", "access": "quota",
                "outputKind": "chat", "promptPrice": 0, "completionPrice": 0, "contextLength": 1000,
                "vision": false, "tools": false, "flagship": false, "reasoningEfforts": [], "reasoningMandatory": false]
            let model = try JSONDecoder().decode(ModelCatalogItem.self,
                from: JSONSerialization.data(withJSONObject: payload))
            XCTAssertEqual(model.chatDisplayName, expected)
            XCTAssertEqual(model.id, route)
        }
    }

    func testPrivateSendNeverAppearsInHistoryAndExitRemovesAllLocalGenerationState() async {
        let model = NativeRuntimeFixture.makeModel()
        await model.restoreAuthenticationIfNeeded()
        await model.reloadModels()
        let history = model.conversations
        model.beginPrivateChat()
        let id = model.activeConversationID!
        model.draft = "private message"
        model.sendDraft()
        XCTAssertTrue(model.isPrivateChat)
        XCTAssertEqual(model.activeConversationID, id)
        XCTAssertEqual(model.conversations, history, "A private send must not create ordinary history metadata")
        XCTAssertEqual(model.messages.count, 2)
        model.beginNewChat()
        XCTAssertFalse(model.isPrivateChat)
        XCTAssertNil(model.activeConversationID)
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertEqual(model.conversations, history)
        XCTAssertFalse(model.generatingConversationIDs.contains(id))
        XCTAssertNil(model.conversationErrors[id])
        XCTAssertNil(model.queuedCommands[id])
        XCTAssertTrue(model.isPrivateConversation(id.uuidString))
        model.openConversation(ConversationRecord(id: id.uuidString, title: "Private chat", updatedAt: "",
            projectID: nil, starred: false, pinned: false))
        XCTAssertNil(model.activeConversationID, "A stale private history entry must not trigger ordinary loading")
    }

    func testChinesePageHeadingPreservesItsRequestedWeight() {
        let text = "选择模型" as CFString
        let body = CTFontCreateForString(MyChatSystemFont.appUIFont(size: 17), text, CFRange(location: 0, length: 4))
        let heading = CTFontCreateForString(MyChatSystemFont.appUIFont(size: 17, weight: .semibold), text, CFRange(location: 0, length: 4))
        let bodyTraits = CTFontCopyTraits(body) as NSDictionary
        let headingTraits = CTFontCopyTraits(heading) as NSDictionary
        XCTAssertGreaterThan((headingTraits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0,
            (bodyTraits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0)
        XCTAssertEqual(CTFontGetSize(body), CTFontGetSize(heading))
    }

    func testDrawerShortSwipeWorksWhenReleaseVelocityIsZero() {
        let singleSample = DrawerMotion.draggedOffset(origin: 0, translation: 252, width: 320)
        XCTAssertEqual(singleSample, 252, "The began/ended samples must carry the real displacement even without changed")
        XCTAssertTrue(DrawerMotion.targetIsOpen(offset: singleSample, velocity: 0, width: 320,
            cancelled: false, wasOpen: false))
        XCTAssertEqual(DrawerMotion.draggedOffset(origin: 320, translation: -252, width: 320), 68)
        XCTAssertEqual(DrawerMotion.draggedOffset(origin: 0, translation: -30, width: 320), 0)
        XCTAssertLessThan(DrawerMotion.draggedOffset(origin: 320, translation: 1_000, width: 320), 332)
        XCTAssertTrue(DrawerMotion.targetIsOpen(offset: 40, velocity: 800, width: 320,
            cancelled: false, wasOpen: false))
        XCTAssertFalse(DrawerMotion.targetIsOpen(offset: 280, velocity: -800, width: 320,
            cancelled: false, wasOpen: true))
        XCTAssertTrue(DrawerMotion.targetIsOpen(offset: 40, velocity: 0, width: 320,
            cancelled: false, wasOpen: false))
        XCTAssertFalse(DrawerMotion.targetIsOpen(offset: 280, velocity: 0, width: 320,
            cancelled: false, wasOpen: true))
        XCTAssertTrue(DrawerMotion.targetIsOpen(offset: 120, velocity: 1_200, width: 320,
            cancelled: false, wasOpen: false))
        XCTAssertFalse(DrawerMotion.targetIsOpen(offset: 200, velocity: -1_200, width: 320,
            cancelled: false, wasOpen: true))
        XCTAssertTrue(DrawerMotion.targetIsOpen(offset: 170, velocity: 0, width: 320,
            cancelled: false, wasOpen: false))
        XCTAssertFalse(DrawerMotion.targetIsOpen(offset: 150, velocity: 0, width: 320,
            cancelled: false, wasOpen: true))
        XCTAssertTrue(DrawerMotion.targetIsOpen(offset: 20, velocity: -10_000, width: 320,
            cancelled: true, wasOpen: true))
        XCTAssertFalse(DrawerMotion.targetIsOpen(offset: 300, velocity: 10_000, width: 320,
            cancelled: true, wasOpen: false))
        XCTAssertEqual(DrawerMotion.initialVelocity(10_000, distance: 10), 20)
        XCTAssertEqual(DrawerMotion.initialVelocity(-400, distance: 100), -4)
        XCTAssertEqual(DrawerMotion.initialVelocity(-400, distance: -200), 2)
    }

    func testDrawerRequiresHorizontalIntentWithoutRaisingShortSwipeThreshold() {
        XCTAssertEqual(DrawerMotion.intent(CGPoint(x: 4, y: 2)), .undecided)
        XCTAssertEqual(DrawerMotion.intent(CGPoint(x: 7, y: 14)), .vertical)
        XCTAssertEqual(DrawerMotion.intent(CGPoint(x: 18, y: 12)), .vertical)
        XCTAssertEqual(DrawerMotion.intent(CGPoint(x: 16, y: 3)), .horizontal)
        XCTAssertEqual(DrawerMotion.intent(CGPoint(x: -16, y: 3)), .horizontal)
        XCTAssertTrue(DrawerMotion.targetIsOpen(offset: 40, velocity: 0, width: 320, cancelled: false, wasOpen: false))
        XCTAssertEqual(DrawerMotion.shadeOpacity(progress: 0), 0.38, accuracy: 0.0001)
        XCTAssertEqual(DrawerMotion.shadeOpacity(progress: 0.5), 0.19, accuracy: 0.0001)
        XCTAssertEqual(DrawerMotion.shadeOpacity(progress: 1), 0)
        XCTAssertEqual(HapticFeedback.intensity, 0.9)
    }

    func testVisibleProcessTimelinePreservesTextToolSummaryOrderAndDeduplicatesSteps() {
        let job = UUID()
        var entries: [ChatProcessEntry] = []
        let step = CodeAgentStep(kind: "read", label: "读取文件", eventID: "step-1")
        let payloads: [ChatJobEventPayload] = [.textDelta("先看"), .textDelta("目录。"),
            .agentStep(step), .reasoningSummaryDelta("核对文件"), .textDelta("目录有三份文件。"), .agentStep(step)]
        for (index, payload) in payloads.enumerated() {
            ChatProcessEntry.record(ChatJobEvent(jobID: job, sequence: index + 1, payload: payload), into: &entries)
        }
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries[0].content, .text("先看目录。"))
        XCTAssertEqual(entries[1].content, .step(step))
        XCTAssertEqual(entries[2].content, .reasoningSummary("核对文件"))
        XCTAssertEqual(entries[3].content, .text("目录有三份文件。"))
    }

    func testDrawerIgnoresSmallMovementAndHonorsAReversedRelease() {
        XCTAssertFalse(DrawerMotion.targetIsOpen(offset: 10, velocity: 0, width: 320, cancelled: false, wasOpen: false))
        XCTAssertTrue(DrawerMotion.targetIsOpen(offset: 310, velocity: 0, width: 320, cancelled: false, wasOpen: true))
        XCTAssertFalse(DrawerMotion.targetIsOpen(offset: 40, velocity: -150, width: 320, cancelled: false, wasOpen: false))
        XCTAssertTrue(DrawerMotion.targetIsOpen(offset: 280, velocity: 150, width: 320, cancelled: false, wasOpen: true))
        XCTAssertTrue(DrawerMotion.targetIsOpen(offset: 40, velocity: 0, width: 320, cancelled: true, wasOpen: true))
        XCTAssertFalse(DrawerMotion.targetIsOpen(offset: 280, velocity: 0, width: 320, cancelled: true, wasOpen: false))
        XCTAssertFalse(DrawerMotion.targetIsOpen(offset: 145, velocity: 0, width: 320, cancelled: false, wasOpen: false, origin: 150))
    }

    func testSheetDragSharesGeometryAndDimmerAndRestoresCancelledDetent() {
        let geometry = SheetMotionGeometry(bounds: CGRect(x: 0, y: 0, width: 390, height: 844),
            topInset: 60, fraction: 0.63)
        XCTAssertEqual(geometry.expanded.minY, 68)
        XCTAssertEqual(geometry.compact.maxY, 844)
        XCTAssertEqual(geometry.dimming(top: geometry.compact.minY), 1)
        let drag = geometry.dragged(top: geometry.compact.minY + 100, reduceMotion: false)
        XCTAssertEqual(drag.height, geometry.compact.height)
        XCTAssertLessThan(geometry.dimming(top: drag.minY), 1)
        XCTAssertEqual(geometry.target(top: drag.minY, velocity: 2_000, cancelled: true, origin: .compact), .compact)
        XCTAssertEqual(geometry.target(top: drag.minY, velocity: 2_000, cancelled: false, origin: .compact), .dismissed)
        XCTAssertEqual(geometry.target(top: geometry.expanded.minY, velocity: 0, cancelled: false, origin: .compact), .expanded)
        XCTAssertEqual(geometry.dragged(top: -200, reduceMotion: true).minY, geometry.expanded.minY,
            "Reduced motion must suppress overshoot")
        XCTAssertEqual(geometry.dimming(top: geometry.compact.minY + geometry.compact.height), 0)
    }

    func testResponseGlyphBirthsPreserveNativeClustersAcrossAppendAndMarkdownRestyling() {
        var births = ResponseGlyphBirths<Int>()
        let initial = births.update(indices: [0, 1, 1, 4], now: 100)
        XCTAssertEqual(initial.count, 3, "A shared native cluster must not be split into multiple fading fragments")
        XCTAssertGreaterThan(ResponseRevealTiming.opacity(now: 100, born: initial[0]!), 0,
            "The first glyph must have visible ink on its first frame")
        let appended = births.update(indices: [0, 1, 1, 4, 8, 9], now: 101)
        for index in [0, 1, 4] { XCTAssertEqual(appended[index], initial[index]) }
        XCTAssertEqual(appended[8], 101)
        XCTAssertEqual(births.update(indices: [0, 1, 4, 8, 9], now: 102), appended,
            "A Markdown style change must not restart settled text")
        let burst = births.update(indices: Array(0..<10_000), now: 103)
        XCTAssertLessThanOrEqual(burst.values.max()!, 103.080001,
            "A large received chunk must not become a seconds-long display queue")
    }

    func testJumpToLatestReleasesFrozenTranscriptAndUsesTheActualEndOfTheScrollRange() {
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 60, width: 390, height: 840))
        scroll.contentSize = CGSize(width: 390, height: 1_600)
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.contentInset = UIEdgeInsets(top: 10, left: 0, bottom: 16, right: 0)
        let controller = ChatScrollController()
        controller.pauseFollowAnimation()
        controller.attach(scroll, conversationID: UUID())
        controller.setComposerGeometry(ChatComposerGeometry(bottomPadding: 600, topInWindow: 424))
        var activeStates: [Bool] = []
        controller.onInteractionChanged = { activeStates.append($0) }
        controller.setInteractionActive(true)
        var published = false
        controller.publishWhenIdle(id: UUID()) { published = true }
        XCTAssertFalse(published)
        controller.jumpToLatest(animated: false)
        XCTAssertTrue(controller.latestVisible, "The jump button disappears immediately after its action")
        XCTAssertTrue(published, "The button must flush content held during a scroll interaction")
        XCTAssertEqual(activeStates, [true, false])
        XCTAssertEqual(scroll.contentOffset.y, 776, accuracy: 0.001,
            "Extra reading space must not turn the explicit bottom action into a reading-anchor jump")
    }

    func testStreamingArtifactRetainsAnimationAcrossUnkeyedInsertionAndCompletion() async throws {
        let first = #"<svg id="drawing" viewBox="0 0 300 200"><circle id="sun" data-label="太阳" cx="100" cy="100" r="20"><animate attributeName="r" values="20;25;20" dur="1s" repeatCount="indefinite"/></circle></svg>"#
        let coordinator = ArtifactSandboxView.Coordinator()
        let web = ArtifactSandboxView(rawHTML: first, colorScheme: .light, isStreaming: true,
            inline: true, reduceMotion: false).makeWebView(coordinator: coordinator)
        web.frame = CGRect(x: 0, y: 0, width: 390, height: 260)
        defer { web.stopLoading(); web.navigationDelegate = nil }
        func evaluate(_ expression: String) async throws -> Bool {
            try await withCheckedThrowingContinuation { continuation in
                web.evaluateJavaScript(expression, in: nil, in: .defaultClient) { result in
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
            throw NSError(domain: "ArtifactRuntimeTest", code: 1,
                userInfo: [NSLocalizedDescriptionKey: expression])
        }
        try await waitFor("document.getElementById('sun') !== null")
        _ = try await evaluate("window.originalSun = document.getElementById('sun'); window.originalDrawing = document.getElementById('drawing'); window.started = window.originalDrawing.getCurrentTime(); true")
        try await Task.sleep(for: .milliseconds(150))
        let growing = first.replacingOccurrences(of: "<circle", with: "\n<defs><linearGradient id='light'/></defs><circle")
        coordinator.update(ArtifactSandboxView(rawHTML: growing, colorScheme: .light, isStreaming: true,
            inline: true, reduceMotion: false), in: web)
        try await waitFor("document.getElementById('light') !== null")
        let retained = try await evaluate("document.getElementById('sun') === window.originalSun && document.getElementById('drawing') === window.originalDrawing && window.originalDrawing.getCurrentTime() > window.started")
        XCTAssertTrue(retained, "Whitespace/defs insertion must not replace the animated node")
        _ = try await evaluate("window.beforeCompletion = window.originalDrawing.getCurrentTime(); true")
        coordinator.update(ArtifactSandboxView(rawHTML: growing, colorScheme: .dark, isStreaming: false,
            inline: true, reduceMotion: false), in: web)
        try await waitFor("document.documentElement.style.colorScheme === 'dark'")
        try await Task.sleep(for: .milliseconds(150))
        let completed = try await evaluate("document.getElementById('sun') === window.originalSun && window.originalDrawing.getCurrentTime() > window.beforeCompletion")
        XCTAssertTrue(completed, "Completion must not stop the SVG timeline")
        _ = try await evaluate("window.originalSun.dispatchEvent(new MouseEvent('click', {bubbles: true})); true")
        try await waitFor("document.getElementById('artifact-label')?.textContent === '太阳'")
    }

    func testCompletedHTMLArtifactRunsInteractionInsideOpaqueSandbox() async throws {
        let html = #"<button id="counter">0</button><script>let count=0; document.getElementById('counter').onclick=()=>{document.getElementById('counter').textContent=String(++count); parent.postMessage({artifactTestCount:count}, '*')}; window.addEventListener('message', e=>{if(e.data==='test-click') document.getElementById('counter').click()});</script>"#
        let coordinator = InteractiveArtifactView.Coordinator()
        let web = InteractiveArtifactView(rawHTML: html, colorScheme: .light).makeWebView(coordinator: coordinator)
        web.frame = CGRect(x: 0, y: 0, width: 390, height: 260)
        defer { web.stopLoading(); web.navigationDelegate = nil; web.uiDelegate = nil }
        func evaluate(_ expression: String) async throws -> Bool {
            try await withCheckedThrowingContinuation { continuation in
                web.evaluateJavaScript(expression) { value, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: value as? Bool ?? false) }
                }
            }
        }
        var clicked = false
        for _ in 0..<100 {
            clicked = (try? await evaluate("(() => { if (!window.artifactTestListener) { window.artifactTestListener=true; window.addEventListener('message', e=>{if(e.data?.artifactTestCount) window.artifactTestCount=e.data.artifactTestCount}) }; const frame=document.getElementById('app'); if(frame?.srcdoc) frame.contentWindow.postMessage('test-click', '*'); return window.artifactTestCount > 0 })()")) == true
            if clicked { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(clicked, "Completed HTML must execute its own button handler")
        let isolated = try await evaluate("(() => { const frame=document.getElementById('app'); try { void frame.contentWindow.document; return false } catch { return frame.getAttribute('sandbox') === 'allow-scripts' } })()")
        XCTAssertTrue(isolated, "Runtime must not grant same-origin access to generated HTML")
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

    func testLiveAdmissionUsesOneConnectionAndReplaysOnlyAfterDisconnect() async throws {
        for disconnect in [false, true] {
            let command = ChatAppendCommand(conversationID: UUID(),
                userMessage: ChatMessage(id: UUID(), role: .user, content: "hello", thinking: nil, createdAt: Date()),
                modelID: "custom/claude-sonnet-5-5", createConversation: true, title: "Live test")
            func frame(_ sequence: Int, _ kind: String, _ payload: [String: Any]) throws -> Data {
                let json = try JSONSerialization.data(withJSONObject: ["jobId": command.generationID.uuidString,
                    "seq": sequence, "kind": kind, "payload": payload])
                return Data("id: \(sequence)\nevent: \(kind)\ndata: \(String(decoding: json, as: UTF8.self))\n\n".utf8)
            }
            let first = try frame(1, "text.delta", ["text": "首字"])
            let terminal = try frame(2, "job.terminal", ["status": "completed", "result": ["content": "首字"]])
            let headers = ["Content-Type": "text/event-stream", "X-MyChat-Job-Id": command.generationID.uuidString,
                "X-MyChat-Job-Status": "queued", "X-MyChat-Job-Created": "1",
                "X-MyChat-Stream-Url": "/api/v1/jobs/\(command.generationID.uuidString)/live"]
            var responses = [(200, disconnect ? first : first + terminal, headers)]
            if disconnect { responses.append((200, first + terminal, ["Content-Type": "text/event-stream"])) }
            let recorder = ChatAdmissionRetryRecorder(responses: responses)
            ChatAdmissionRetryFixtureURLProtocol.recorder = recorder
            defer { ChatAdmissionRetryFixtureURLProtocol.recorder = nil }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ChatAdmissionRetryFixtureURLProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let client = ChatAPIClient(session: session, baseURL: URL(string: "https://mychat.invalid")!)
            let connection = try await client.openAppendTurn(command, accessToken: "fixture-token")
            let stream = try XCTUnwrap(connection.events)
            var received: [Int] = []
            for try await event in stream { received.append(event.sequence) }
            XCTAssertEqual(received, [1, 2], "Reconnect must discard already delivered sequence 1")
            XCTAssertEqual(recorder.requestCount, disconnect ? 2 : 1)
            XCTAssertEqual(connection.admission.generationID, command.generationID)
        }
    }

    func testLiveAdmissionRejectsAReceiptForAnotherGeneration() async throws {
        let command = ChatAppendCommand(conversationID: UUID(),
            userMessage: ChatMessage(id: UUID(), role: .user, content: "hello", thinking: nil, createdAt: Date()),
            modelID: "custom/claude-sonnet-5-5", createConversation: true, title: "Identity test")
        let recorder = ChatAdmissionRetryRecorder(responses: [(200, Data(), [
            "Content-Type": "text/event-stream", "X-MyChat-Job-Id": UUID().uuidString,
            "X-MyChat-Stream-Url": "/api/v1/jobs/other/live"])])
        ChatAdmissionRetryFixtureURLProtocol.recorder = recorder
        defer { ChatAdmissionRetryFixtureURLProtocol.recorder = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatAdmissionRetryFixtureURLProtocol.self]
        let client = ChatAPIClient(session: URLSession(configuration: configuration), baseURL: URL(string: "https://mychat.invalid")!)
        do {
            _ = try await client.openAppendTurn(command, accessToken: "fixture-token")
            XCTFail("A different generation must not attach")
        } catch ChatTransportError.mismatchedAdmission {}
        XCTAssertEqual(recorder.requestCount, 1)
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

    func testHeaderControlsOwnFullHitTargetAndPerformPrivacyAndNewChatActions() {
        let model = NativeRuntimeFixture.makeModel()
        let privacy = HeaderActionControl(label: Text("privacy")) {
            if model.isPrivateChat { model.beginNewChat() } else { model.beginPrivateChat() }
        }
        privacy.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        privacy.layoutIfNeeded()
        for point in [CGPoint(x: 2, y: 2), CGPoint(x: 22, y: 22), CGPoint(x: 42, y: 42)] {
            XCTAssertTrue(privacy.hitTest(point, with: nil) === privacy,
                "Transparent glyph gaps must hit the actionable control")
        }
        privacy.sendActions(for: .touchUpInside)
        XCTAssertTrue(model.isPrivateChat)
        XCTAssertNotNil(model.activeConversationID)
        privacy.sendActions(for: .touchUpInside)
        XCTAssertFalse(model.isPrivateChat)
        XCTAssertNil(model.activeConversationID)

        model.beginPrivateChat()
        model.draft = "draft"
        let revision = model.newChatRevision
        let newChat = HeaderActionControl(label: Text("new"), action: model.beginNewChat)
        newChat.frame = privacy.frame
        newChat.sendActions(for: .touchUpInside)
        XCTAssertEqual(model.newChatRevision, revision + 1)
        XCTAssertFalse(model.isPrivateChat)
        XCTAssertEqual(model.draft, "")
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertNil(model.activeConversationID)
    }

    func testDocumentHeaderControlHitsWholeBubbleAndInvokesPresentationCallback() {
        var opened = false
        let modalID = UUID()
        let button = HeaderActionControl(label: Text("document")) {
            NativeDocumentModalActivity.set(modalID, active: true)
            opened = true
        }
        defer { NativeDocumentModalActivity.set(modalID, active: false) }
        button.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        button.layoutIfNeeded()
        XCTAssertTrue(button.hitTest(CGPoint(x: 22, y: 22), with: nil) === button)
        XCTAssertTrue(button.hitTest(CGPoint(x: 3, y: 22), with: nil) === button)
        XCTAssertFalse(opened)
        button.sendActions(for: .touchUpInside)
        XCTAssertTrue(opened)
    }

    func testReadingAnchorKeepsReplyAtEyeLevelAndShortContentAtTop() {
        let viewport = CGRect(x: 0, y: 60, width: 390, height: 840)
        let padding = ChatReadingAnchor.bottomPadding(viewport: viewport, composerTop: 760, minimum: 148)
        XCTAssertGreaterThan(padding, 148)
        let offset = ChatReadingAnchor.offset(contentHeight: 1_000 + padding,
            bottomPadding: padding, viewport: viewport, composerTop: 760, topInset: 0)
        XCTAssertEqual(1_000 - offset, 692 * (2.0 / 3.0), accuracy: 0.001)
        XCTAssertEqual(ChatReadingAnchor.offset(contentHeight: 200 + padding,
            bottomPadding: padding, viewport: viewport, composerTop: 760, topInset: 60), -60)
    }

    func testReadingAnchorDoesNotApplyKeyboardOcclusionTwice() {
        let full = CGRect(x: 0, y: 60, width: 390, height: 840)
        let reduced = CGRect(x: 0, y: 60, width: 390, height: 520)
        XCTAssertEqual(ChatReadingAnchor.readingHeight(viewport: full, composerTop: 424),
            ChatReadingAnchor.readingHeight(viewport: reduced, composerTop: 424), accuracy: 0.001)
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
        let data = ControlledConversationStore()
        let model = NativeRuntimeFixture.makeModel(dataClient: data, chatClient: transport, stream: transport)
        await model.restoreAuthenticationIfNeeded()
        await model.reloadModels()
        model.beginNewChat()
        model.draft = "切回前台后继续这条回复"
        model.sendDraft()
        try await waitUntil { transport.commands.count == 1 && transport.streamStarts.count == 1 }

        let command = try XCTUnwrap(transport.commands.first)
        // Admission persists a real conversation on the server. The original
        // generic URL fixture returned only its unrelated seeded conversation.
        await data.addConversation(ConversationRecord(id: command.conversationID.uuidString,
            title: "恢复测试", updatedAt: "", projectID: nil, starred: false, pinned: false))
        await model.reloadConversations()
        transport.emit(.textDelta("已生成"), for: command, sequence: 1)
        try await waitUntil { model.messages.last?.content == "已生成" }
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

        transport.emit(.textDelta("，继续"), for: command, sequence: checkpoint + 1)
        try await waitUntil {
            model.processEntriesByMessageID[command.assistantMessageID, default: []].compactMap {
                if case let .text(value) = $0.content { return value }; return nil
            }.joined() == "已生成的检查点，继续"
        }
        XCTAssertTrue(model.isCurrentConversationGenerating)
        transport.complete(command, text: "已生成的检查点，继续完成。", sequence: checkpoint + 2)
        try await waitUntil { !model.isCurrentConversationGenerating }
        XCTAssertEqual(model.messages.last(where: { $0.role == .assistant })?.content, "已生成的检查点，继续完成。")
        XCTAssertEqual(transport.commands.count, 1)
    }

    func testRecoveryNeverRelabelsPrivateThinkingAsPublicSummary() async throws {
        let publicSummary = "Checking the available evidence."
        let tagged = try XCTUnwrap(ChatReasoningSummaryStorage.encode(publicSummary))
        for (storedThinking, expectedSummary) in [("private-provider-reasoning", nil as String?), (tagged, publicSummary)] {
            let conversationID = UUID(), userID = UUID(), assistantID = UUID(), generationID = UUID()
            let conversation = ConversationRecord(id: conversationID.uuidString,
                title: "Offline recovery privacy", updatedAt: "", projectID: nil, starred: false, pinned: false)
            let data = ControlledConversationStore()
            await data.addConversation(conversation)
            // The missing assistant row exercises the initial recovery publish,
            // before an accumulator or another event can reconcile its thinking.
            await data.setMessages([
                ConversationMessageRecord(id: userID.uuidString, role: .user, content: "Resume this reply",
                    images: nil, thinking: nil, createdAt: nil, sequence: 1)
            ], for: conversationID)
            let transport = ControlledChatTransport()
            transport.recovery = ChatGenerationRecovery(
                admission: ChatAdmission(schemaVersion: 1, jobID: generationID, generationID: generationID,
                    userMessageID: userID, assistantMessageID: assistantID, status: "running", created: false,
                    streamURL: URL(string: "https://isolated.mychat.invalid/events")!,
                    trialRemaining: nil, trialLimit: nil),
                sequence: 1, content: "Recovered response", thinking: storedThinking, media: [], terminal: nil
            )
            let model = NativeRuntimeFixture.makeModel(dataClient: data, chatClient: transport, stream: transport)
            model.acceptAuthentication(NativeRuntimeFixture.session)
            await model.reloadConversations()
            var sawAssistant = false
            var visibleSummaries: [String] = []
            let observation = model.$messages.sink { messages in
                guard let assistant = messages.first(where: { $0.id == assistantID }) else { return }
                sawAssistant = true
                if let summary = ChatReasoningSummaryStorage.decode(assistant.thinking) {
                    visibleSummaries.append(summary)
                }
            }
            defer {
                observation.cancel()
                transport.continuations[generationID]?.finish()
            }
            model.openConversation(conversation)
            try await waitUntil { transport.continuations[generationID] != nil }
            XCTAssertTrue(sawAssistant)
            if let expectedSummary {
                XCTAssertFalse(visibleSummaries.isEmpty)
                XCTAssertTrue(visibleSummaries.allSatisfy { $0 == expectedSummary },
                    "Already-tagged summaries must not acquire a second visible storage tag")
            } else {
                XCTAssertTrue(visibleSummaries.isEmpty,
                    "Even the first recovered-message publish must hide unmarked private thinking")
            }
            XCTAssertTrue(transport.commands.isEmpty, "Recovery must not submit a new model request")
            transport.continuations[generationID]?.yield(ChatJobEvent(jobID: generationID, sequence: 2,
                payload: .terminal(ChatTerminalSnapshot(status: .completed, content: "Recovered response",
                    thinking: storedThinking, sequence: 2, errorCode: nil, media: [], tokenUsage: nil, codeReceipt: nil))))
            transport.continuations[generationID]?.finish()
            try await waitUntil { !model.isCurrentConversationGenerating }
        }
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

    func testAdmissionStopFenceRequiresMatchingOwnerGenerationAndTerminalEvidence() async throws {
        let generation = UUID(), epoch = UUID()
        let fence = ChatAdmissionStopFence(generationID: generation, ownerID: "fixture-owner", accountGeneration: epoch)
        var started = false, released = false
        let waiter = Task {
            started = true
            try await fence.wait()
            released = true
        }
        defer { waiter.cancel(); fence.invalidate() }
        try await waitUntil { started }
        for status in ["queued", "running", "unknown", "not_found"] {
            XCTAssertFalse(fence.confirm(.init(jobID: generation, status: status),
                ownerID: "fixture-owner", accountGeneration: epoch))
        }
        XCTAssertFalse(fence.confirm(.init(jobID: UUID(), status: "cancelled"),
            ownerID: "fixture-owner", accountGeneration: epoch))
        XCTAssertFalse(fence.confirm(.init(jobID: generation, status: "cancelled"),
            ownerID: "other-owner", accountGeneration: epoch))
        XCTAssertFalse(fence.confirm(.init(jobID: generation, status: "cancelled"),
            ownerID: "fixture-owner", accountGeneration: UUID()))
        XCTAssertFalse(released)
        XCTAssertTrue(fence.confirm(.init(jobID: generation, status: "cancelled"),
            ownerID: "fixture-owner", accountGeneration: epoch))
        try await waiter.value
        XCTAssertTrue(released)
        XCTAssertTrue(fence.isResolved)
        XCTAssertFalse(fence.confirm(.init(jobID: generation, status: "queued"),
            ownerID: "fixture-owner", accountGeneration: epoch))
        XCTAssertTrue(fence.isResolved, "A stale receipt cannot undo terminal evidence")
    }

    func testCancellingAdmissionFenceWaiterDoesNotConfirmTheOldJob() async throws {
        let fence = ChatAdmissionStopFence(generationID: UUID(), ownerID: "fixture-owner", accountGeneration: UUID())
        for cancelBeforeStart in [true, false] {
            let waiter = Task { try await fence.wait() }
            if !cancelBeforeStart { await Task.yield() }
            waiter.cancel()
            do { try await waiter.value; XCTFail("Cancelled local wait must throw") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertFalse(fence.isResolved)
        }
        fence.invalidate()
        do { try await fence.wait(); XCTFail("An invalidated account fence must remain closed") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testLostAdmissionReceiptUsesExactJobStatusWithoutRepostingOrWaitingForHTTP() async throws {
        let transport = ControlledChatTransport()
        transport.holdAdmission = true
        let model = NativeRuntimeFixture.makeModel(chatClient: transport, stream: transport)
        await model.restoreAuthenticationIfNeeded(); await model.reloadModels(); model.beginNewChat()
        model.draft = "Original admitted turn"; model.sendDraft()
        try await waitUntil { transport.commands.count == 1 && transport.heldAdmissions.count == 1 }
        let original = transport.commands[0]
        defer { transport.heldAdmissions.removeValue(forKey: original.generationID)?.resume() }
        // Operational admission state must survive eviction from the bounded
        // diagnostics cache; timing records are not cancellation authority.
        for _ in 0..<65 {
            ChatGenerationDiagnostics.begin(ChatAppendCommand(conversationID: UUID(),
                userMessage: ChatMessage(id: UUID(), role: .user, content: "synthetic timing record", thinking: nil, createdAt: Date()),
                createConversation: true, title: "synthetic"))
        }
        XCTAssertNil(ChatGenerationDiagnostics.records[original.generationID])
        transport.admissionStatuses[original.generationID] = .init(jobID: original.generationID, status: "queued")
        model.stopCurrentGeneration()
        transport.holdAdmission = false
        model.draft = "Next authorized user turn"; model.sendDraft()
        try await waitUntil { transport.commands.count == 2 && transport.continuations[transport.commands[1].generationID] != nil }
        XCTAssertNotNil(transport.heldAdmissions[original.generationID], "The original HTTP receipt remains withheld")
        XCTAssertEqual(transport.cancelCalls, [original.generationID])
        XCTAssertTrue(transport.admissionStatusCalls.allSatisfy { $0 == original.generationID })
        XCTAssertEqual(transport.commands.filter { $0.generationID == original.generationID }.count, 1)
        let next = transport.commands[1]
        transport.heldAdmissions.removeValue(forKey: original.generationID)?.resume()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(transport.streamStarts.contains { $0.jobID == original.generationID })
        XCTAssertEqual(model.messages.last?.id, next.assistantMessageID)
        XCTAssertEqual(transport.commands.count, 2)
        transport.complete(next, text: "Complete", sequence: 1)
        try await waitUntil { !model.isCurrentConversationGenerating }
    }

    func testUnknownAdmissionCannotReleaseNextTurnAndUnsentWaitCanBeCancelled() async throws {
        let transport = ControlledChatTransport()
        transport.holdAdmission = true
        let model = NativeRuntimeFixture.makeModel(chatClient: transport, stream: transport)
        await model.restoreAuthenticationIfNeeded(); await model.reloadModels(); model.beginNewChat()
        model.draft = "First"; model.sendDraft()
        try await waitUntil { transport.commands.count == 1 && transport.heldAdmissions.count == 1 }
        let original = transport.commands[0]
        defer { transport.heldAdmissions.removeValue(forKey: original.generationID)?.resume() }
        model.stopCurrentGeneration()
        model.draft = "Unsent second"; model.sendDraft()
        try await waitUntil { !transport.admissionStatusCalls.isEmpty }
        XCTAssertEqual(transport.commands.count, 1)
        XCTAssertTrue(transport.cancelCalls.isEmpty, "Unknown lookup must not fabricate an admitted job")
        let checks = transport.admissionStatusCalls.count
        model.retryCurrentGeneration()
        try await waitUntil { transport.admissionStatusCalls.count > checks }
        XCTAssertEqual(transport.commands.count, 1, "Retry must check the old job rather than replay a model POST")
        XCTAssertTrue(transport.admissionStatusCalls.allSatisfy { $0 == original.generationID })
        model.stopCurrentGeneration()
        XCTAssertFalse(model.isCurrentConversationGenerating)
        model.draft = "Third user turn"; model.sendDraft()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(transport.commands.count, 1, "404/nil status cannot release either waiting turn")
        transport.holdAdmission = false
        transport.heldAdmissions.removeValue(forKey: original.generationID)?.resume()
        try await waitUntil { transport.commands.count == 2 && transport.continuations[transport.commands[1].generationID] != nil }
        XCTAssertEqual(transport.commands[1].userMessage.content, "Third user turn")
        XCTAssertFalse(transport.commands.contains { $0.userMessage.content == "Unsent second" })
        let third = transport.commands[1]
        transport.complete(third, text: "Complete", sequence: 1)
        try await waitUntil { !model.isCurrentConversationGenerating }
    }

    func testAdmissionStatusGETRejectsMismatchedSubjectAndKeeps404Unknown() async throws {
        let command = ChatAppendCommand(conversationID: UUID(),
            userMessage: ChatMessage(id: UUID(), role: .user, content: "synthetic request", thinking: nil, createdAt: Date()),
            createConversation: true, title: "synthetic")
        func response(userMessageID: UUID) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["job": [
                "id": command.generationID.uuidString, "type": "chat.generation", "queue": "chat",
                "status": "cancelled", "eventSequence": 2,
                "subject": ["conversationId": command.conversationID.uuidString,
                    "userMessageId": userMessageID.uuidString, "assistantMessageId": command.assistantMessageID.uuidString]
            ]])
        }
        let recorder = ChatGPTPlanRequestRecorder()
        recorder.scriptedResponses = [(200, try response(userMessageID: command.userMessageID), "application/json"),
            (404, Data("{}".utf8), "application/json"), (200, try response(userMessageID: UUID()), "application/json")]
        ChatGPTPlanFixtureURLProtocol.recorder = recorder
        defer { ChatGPTPlanFixtureURLProtocol.recorder = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatGPTPlanFixtureURLProtocol.self]
        let network = URLSession(configuration: configuration)
        defer { network.invalidateAndCancel() }
        let client = ChatAPIClient(session: network, baseURL: URL(string: "https://admission-fixture.example.invalid")!)
        let terminal = try await client.admissionStatus(command: command, accessToken: "isolated-fixture")
        XCTAssertEqual(terminal?.jobID, command.generationID)
        XCTAssertEqual(terminal?.isTerminal, true)
        let missing = try await client.admissionStatus(command: command, accessToken: "isolated-fixture")
        XCTAssertNil(missing)
        do {
            _ = try await client.admissionStatus(command: command, accessToken: "isolated-fixture")
            XCTFail("A different user-message identity must be rejected")
        } catch { XCTAssertEqual(error as? ChatTransportError, .mismatchedJob) }
        XCTAssertEqual(recorder.requests.count, 3)
        XCTAssertTrue(recorder.requests.allSatisfy { $0.httpMethod == "GET"
            && $0.url?.path == "/api/v1/jobs/" + command.generationID.uuidString.lowercased() })
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

    func testHTTPAuthorityDoesNotCompareDatabaseAndLiveSequenceNumbers() throws {
        let job = UUID()
        var accumulator = ChatStreamAccumulator()
        XCTAssertTrue(accumulator.apply(ChatJobEvent(jobID: job, sequence: 100, payload: .textDelta("A"))))
        let terminal = ChatTerminalSnapshot(status: .completed, content: "AB", thinking: "", sequence: 2,
            errorCode: nil, media: [], tokenUsage: nil, codeReceipt: nil)
        XCTAssertFalse(accumulator.applyAuthoritativeTerminal(terminal, jobID: UUID()))
        XCTAssertTrue(accumulator.applyAuthoritativeTerminal(terminal, jobID: job),
            "A database terminal at 2 remains authoritative after live frame 100")
        XCTAssertEqual(accumulator.sequence, 100, "HTTP must not rewrite the SSE cursor")
        XCTAssertEqual(accumulator.content, "AB")
        XCTAssertFalse(accumulator.applyAuthoritativeTerminal(terminal, jobID: job))
        XCTAssertFalse(accumulator.apply(ChatJobEvent(jobID: job, sequence: 101, payload: .textDelta("LATE"))))
        XCTAssertEqual(accumulator.content, "AB")
    }

    func testRecoveryCheckpointPolicyUsesRequestRevisionNotDatabaseCursor() throws {
        let job = UUID()
        let admission = ChatAdmission(schemaVersion: 1, jobID: job, generationID: job,
            userMessageID: UUID(), assistantMessageID: UUID(), status: "running", created: false,
            streamURL: URL(string: "https://isolated.mychat.invalid/live")!, trialRemaining: nil, trialLimit: nil)
        var current = ChatStreamAccumulator()
        current.apply(ChatJobEvent(jobID: job, sequence: 99, payload: .reasoningSummaryDelta("Checking")))
        current.apply(ChatJobEvent(jobID: job, sequence: 100, payload: .textDelta("A")))
        let publicSummary = try XCTUnwrap(ChatReasoningSummaryStorage.encode("Checking inputs."))
        for databaseSequence in [2, 999] {
            let recovery = ChatGenerationRecovery(admission: admission, sequence: databaseSequence,
                content: "AB", thinking: publicSummary, media: [], terminal: nil)
            XCTAssertTrue(ChatRecoveryCheckpointPolicy.mayReplaceRunningStream(recovery, current: current,
                requestedStreamRevision: 100))
            XCTAssertFalse(ChatRecoveryCheckpointPolicy.mayReplaceRunningStream(recovery, current: current,
                requestedStreamRevision: 99), "A changed local revision rejects the late response regardless of DB seq")
        }
        for (body, thinking) in [("", publicSummary), ("OTHER", publicSummary), ("AB", "PRIVATE_REASONING")] {
            let recovery = ChatGenerationRecovery(admission: admission, sequence: 999,
                content: body, thinking: thinking, media: [], terminal: nil)
            XCTAssertFalse(ChatRecoveryCheckpointPolicy.mayReplaceRunningStream(recovery, current: current,
                requestedStreamRevision: 100), "A checkpoint cannot roll back visible body or public summary")
        }
    }

    func testHTTPAuthoritativeTerminalWithSmallerDatabaseSequenceFinishesLiveStream() async throws {
        let transport = ControlledChatTransport()
        let model = NativeRuntimeFixture.makeModel(chatClient: transport, stream: transport)
        await model.restoreAuthenticationIfNeeded()
        await model.reloadModels()
        model.beginNewChat()
        model.draft = "Synthetic independent terminal cursors"
        model.sendDraft()
        try await waitUntil { transport.commands.count == 1 && transport.continuations.count == 1 }
        let command = try XCTUnwrap(transport.commands.first)
        defer { transport.continuations[command.generationID]?.finish() }
        transport.emit(.textDelta("A"), for: command, sequence: 100)
        try await waitUntil { model.messages.last?.content == "A" }
        let finalSummary = "Checked the complete response."
        transport.terminalSnapshots[command.generationID] = ChatTerminalSnapshot(status: .completed,
            content: "AB", thinking: try XCTUnwrap(ChatReasoningSummaryStorage.encode(finalSummary)), sequence: 2,
            errorCode: nil, media: [], tokenUsage: nil, codeReceipt: nil)
        try await waitUntil { !model.isCurrentConversationGenerating }
        XCTAssertEqual(model.messages.last?.content, "AB")
        XCTAssertEqual(ChatReasoningSummaryStorage.decode(model.messages.last?.thinking), finalSummary)
        XCTAssertEqual(transport.commands.count, 1)
    }

    func testForegroundRecoveryAcceptsSmallerDatabaseCursorWithoutResubmitting() async throws {
        let transport = ControlledChatTransport()
        let data = ControlledConversationStore()
        let model = NativeRuntimeFixture.makeModel(dataClient: data, chatClient: transport, stream: transport)
        await model.restoreAuthenticationIfNeeded()
        await model.reloadModels()
        model.beginNewChat()
        model.draft = "Synthetic independent recovery cursors"
        model.sendDraft()
        try await waitUntil { transport.commands.count == 1 && transport.streamStarts.count == 1 }
        let command = try XCTUnwrap(transport.commands.first)
        defer { transport.continuations[command.generationID]?.finish() }
        await data.addConversation(ConversationRecord(id: command.conversationID.uuidString,
            title: "Cursor domains", updatedAt: "", projectID: nil, starred: false, pinned: false))
        await model.reloadConversations()
        transport.emit(.textDelta("A"), for: command, sequence: 100)
        try await waitUntil { model.messages.last?.content == "A" }
        transport.recovery = ChatGenerationRecovery(admission: ChatAdmission(schemaVersion: 1,
            jobID: command.generationID, generationID: command.generationID,
            userMessageID: command.userMessageID, assistantMessageID: command.assistantMessageID,
            status: "running", created: false, streamURL: URL(string: "https://isolated.mychat.invalid/live")!,
            trialRemaining: nil, trialLimit: nil), sequence: 2, content: "AB", thinking: "", media: [], terminal: nil)
        await model.resumeAuthentication()
        try await waitUntil { transport.streamStarts.count == 2 && model.messages.last?.content == "AB" }
        XCTAssertEqual(transport.streamStarts.map { $0.fromSequence }, [0, 2])
        XCTAssertEqual(transport.commands.count, 1)
        transport.emit(.textDelta("C"), for: command, sequence: 3)
        try await waitUntil {
            model.processEntriesByMessageID[command.assistantMessageID, default: []].compactMap {
                if case let .text(value) = $0.content { return value }; return nil
            }.joined() == "ABC"
        }
        transport.complete(command, text: "ABC", sequence: 4)
        try await waitUntil { !model.isCurrentConversationGenerating }
        XCTAssertEqual(model.messages.last?.content, "ABC")
    }

    func testHTTPCheckpointCannotReplaceLiveUpdatesAfterLookupStarts() async throws {
        let transport = ControlledChatTransport()
        let data = ControlledConversationStore()
        let model = NativeRuntimeFixture.makeModel(dataClient: data, chatClient: transport, stream: transport)
        await model.restoreAuthenticationIfNeeded()
        await model.reloadModels()
        model.beginNewChat()
        model.draft = "Synthetic lookup revision fence"
        model.sendDraft()
        try await waitUntil { transport.commands.count == 1 && transport.streamStarts.count == 1 }
        let command = try XCTUnwrap(transport.commands.first)
        defer {
            transport.heldRecovery?.resume()
            transport.heldRecovery = nil
            transport.continuations[command.generationID]?.finish()
        }
        await data.addConversation(ConversationRecord(id: command.conversationID.uuidString,
            title: "Request revision", updatedAt: "", projectID: nil, starred: false, pinned: false))
        await model.reloadConversations()
        transport.emit(.textDelta("A"), for: command, sequence: 100)
        try await waitUntil { model.messages.last?.content == "A" }
        transport.recovery = ChatGenerationRecovery(admission: ChatAdmission(schemaVersion: 1,
            jobID: command.generationID, generationID: command.generationID,
            userMessageID: command.userMessageID, assistantMessageID: command.assistantMessageID,
            status: "running", created: false, streamURL: URL(string: "https://isolated.mychat.invalid/live")!,
            trialRemaining: nil, trialLimit: nil), sequence: 999, content: "AB", thinking: "", media: [], terminal: nil)
        transport.holdRecovery = true
        await model.resumeAuthentication()
        try await waitUntil { transport.heldRecovery != nil }
        transport.emit(.textDelta("B"), for: command, sequence: 101)
        func body() -> String {
            model.processEntriesByMessageID[command.assistantMessageID, default: []].compactMap {
                if case let .text(value) = $0.content { return value }; return nil
            }.joined()
        }
        try await waitUntil { body() == "AB" }
        transport.holdRecovery = false
        transport.recovery = nil
        transport.heldRecovery?.resume()
        transport.heldRecovery = nil
        let deadline = Date().addingTimeInterval(1)
        while transport.recoveryReadCount < 2, Date() < deadline {
            await model.resumeAuthentication()
            await Task.yield()
        }
        XCTAssertGreaterThanOrEqual(transport.recoveryReadCount, 2)
        XCTAssertEqual(transport.streamStarts.count, 1,
            "Even matching text and a larger DB seq cannot replace a consumer that advanced during the lookup")
        XCTAssertEqual(body(), "AB")
        transport.complete(command, text: "ABC", sequence: 102)
        try await waitUntil { !model.isCurrentConversationGenerating }
    }

    func testHTTPRecoveryDecodesDedicatedPublicSummaryWithoutRelabelingRawThinking() async throws {
        let conversation = UUID(), job = UUID(), user = UUID(), assistant = UUID()
        for summary in ["Checked the inputs.", nil] as [String?] {
            var output: [String: Any] = ["content": "AB", "thinking": "PRIVATE_REASONING"]
            if let summary { output["reasoningSummary"] = summary }
            let data = try JSONSerialization.data(withJSONObject: ["job": [
                "id": job.uuidString, "type": "chat.generation", "queue": "chat", "status": "completed",
                "subject": ["conversationId": conversation.uuidString, "userMessageId": user.uuidString,
                    "assistantMessageId": assistant.uuidString], "eventSequence": 2, "result": output
            ], "streamUrl": "/api/v1/jobs/\(job.uuidString)/live"])
            let recorder = ChatAdmissionRetryRecorder(responses: [
                (200, data, ["Content-Type": "application/json"]),
                (200, data, ["Content-Type": "application/json"])
            ])
            ChatAdmissionRetryFixtureURLProtocol.recorder = recorder
            defer { ChatAdmissionRetryFixtureURLProtocol.recorder = nil }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ChatAdmissionRetryFixtureURLProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let client = ChatAPIClient(session: session, baseURL: URL(string: "https://mychat.invalid")!)
            let recovered = try await client.conversationGeneration(conversationID: conversation, accessToken: "fixture-only")
            let observed = try await client.terminalSnapshot(conversationID: conversation, jobID: job, accessToken: "fixture-only")
            let recovery = try XCTUnwrap(recovered)
            let terminal = try XCTUnwrap(observed)
            XCTAssertEqual(recovery.sequence, 2)
            XCTAssertEqual(ChatReasoningSummaryStorage.decode(recovery.thinking), summary)
            XCTAssertEqual(ChatReasoningSummaryStorage.decode(terminal.thinking), summary)
            if summary == nil {
                XCTAssertEqual(recovery.thinking, "PRIVATE_REASONING", "Raw reasoning stays untagged")
            }
            XCTAssertEqual(recorder.requestCount, 2)
        }
    }

    func testTerminalSummaryUsesOnlyTaggedValuesAndIsIdempotent() throws {
        let job = UUID()
        var entries: [ChatProcessEntry] = []
        let tool = ChatToolActivity(toolCallID: "terminal-tool", toolName: "search", isComplete: true)
        let before: [ChatJobEventPayload] = [.reasoningSummaryDelta("Checking inputs."), .toolActivity(tool), .textDelta("A")]
        for (index, payload) in before.enumerated() {
            ChatProcessEntry.record(ChatJobEvent(jobID: job, sequence: index + 1, payload: payload), into: &entries)
        }
        let summary = "Checked the inputs and compared the results."
        let terminal = ChatJobEvent(jobID: job, sequence: 4, payload: .terminal(ChatTerminalSnapshot(
            status: .completed, content: "A", thinking: try XCTUnwrap(ChatReasoningSummaryStorage.encode(summary)),
            sequence: 4, errorCode: nil, media: [], tokenUsage: nil, codeReceipt: nil)))
        ChatProcessEntry.record(terminal, into: &entries)
        XCTAssertEqual(entries.map(\.content), [.reasoningSummary(summary), .tool(tool), .text("A")])
        let settled = entries
        ChatProcessEntry.record(terminal, into: &entries)
        XCTAssertEqual(entries, settled, "A repeated terminal cannot add another summary row or tool")
        let privateTerminal = ChatJobEvent(jobID: job, sequence: 5, payload: .terminal(ChatTerminalSnapshot(
            status: .completed, content: "A", thinking: "PRIVATE_REASONING", sequence: 5,
            errorCode: nil, media: [], tokenUsage: nil, codeReceipt: nil)))
        ChatProcessEntry.record(privateTerminal, into: &entries)
        XCTAssertEqual(entries, settled, "Unmarked terminal thinking cannot overwrite a public summary")
        var accumulator = ChatStreamAccumulator()
        XCTAssertTrue(accumulator.apply(terminal))
        XCTAssertFalse(accumulator.apply(terminal))
        XCTAssertFalse(accumulator.apply(privateTerminal))
        XCTAssertEqual(accumulator.reasoningSummary, summary)

        var recovered: [ChatProcessEntry] = []
        let checkpoint = ChatJobEvent(jobID: job, sequence: 8, payload: .snapshot(ChatJobSnapshot(
            content: "A", thinking: try XCTUnwrap(ChatReasoningSummaryStorage.encode("Checking")), media: [])))
        ChatProcessEntry.record(checkpoint, into: &recovered)
        let sameCursorTerminal = ChatJobEvent(jobID: job, sequence: 8, payload: .terminal(ChatTerminalSnapshot(
            status: .completed, content: "A", thinking: try XCTUnwrap(ChatReasoningSummaryStorage.encode("Checking inputs.")),
            sequence: 8, errorCode: nil, media: [], tokenUsage: nil, codeReceipt: nil)))
        ChatProcessEntry.record(sameCursorTerminal, into: &recovered)
        XCTAssertEqual(recovered.compactMap {
            if case let .reasoningSummary(value) = $0.content { return value }; return nil
        }.joined(), "Checking inputs.")
        XCTAssertEqual(Set(recovered.map(\.id)).count, recovered.count,
            "A same-cursor terminal extension needs a different ID from the checkpoint summary")
    }

    func testTerminalPublicSummaryReachesExistingTranscriptBeforeFinish() async throws {
        let oldSummary = "Checking inputs."
        let finalSummary = "Checked the inputs and compared the results."
        for (thinking, expected) in [
            (try XCTUnwrap(ChatReasoningSummaryStorage.encode(finalSummary)), finalSummary),
            ("PRIVATE_REASONING", oldSummary)
        ] {
            let transport = ControlledChatTransport()
            let model = NativeRuntimeFixture.makeModel(chatClient: transport, stream: transport)
            await model.restoreAuthenticationIfNeeded()
            await model.reloadModels()
            model.beginNewChat()
            model.draft = "Synthetic terminal summary"
            model.sendDraft()
            try await waitUntil { transport.commands.count == 1 && transport.continuations.count == 1 }
            let command = try XCTUnwrap(transport.commands.first)
            defer { transport.continuations[command.generationID]?.finish() }
            let updates = ChatTranscriptUpdates(model)
            updates.setInteracting(true)
            updates.setModalVisible(true)
            func visibleSummary() -> String {
                updates.snapshot.processEntries[command.assistantMessageID, default: []].compactMap {
                    if case let .reasoningSummary(value) = $0.content { return value }; return nil
                }.joined()
            }
            var summaryWhileGenerating: [String] = []
            let observation = updates.$snapshot.sink { snapshot in
                guard model.isCurrentConversationGenerating else { return }
                let summary = snapshot.processEntries[command.assistantMessageID, default: []].compactMap {
                    if case let .reasoningSummary(value) = $0.content { return value }; return nil
                }.joined()
                summaryWhileGenerating.append(summary)
            }
            defer { observation.cancel() }
            transport.emit(.reasoningSummaryDelta(oldSummary), for: command, sequence: 1)
            transport.emit(.textDelta("A"), for: command, sequence: 2)
            try await waitUntil { model.messages.last?.content == "A" && visibleSummary() == oldSummary }
            transport.emit(.terminal(ChatTerminalSnapshot(status: .completed, content: "A", thinking: thinking,
                sequence: 3, errorCode: nil, media: [], tokenUsage: nil, codeReceipt: nil)), for: command, sequence: 3)
            transport.continuations[command.generationID]?.finish()
            try await waitUntil { !model.isCurrentConversationGenerating }
            XCTAssertEqual(visibleSummary(), expected)
            XCTAssertTrue(summaryWhileGenerating.contains(expected))
            XCTAssertFalse(summaryWhileGenerating.contains { $0.contains("PRIVATE_REASONING") })
            XCTAssertEqual(ChatReasoningSummaryStorage.decode(model.messages.last?.thinking), expected)
            XCTAssertEqual(model.messages.last?.content, "A")
        }
    }

    func testTerminalObserverPublishesFinalPublicSummaryWithoutSSETerminal() async throws {
        let transport = ControlledChatTransport()
        let model = NativeRuntimeFixture.makeModel(chatClient: transport, stream: transport)
        await model.restoreAuthenticationIfNeeded()
        await model.reloadModels()
        model.beginNewChat()
        model.draft = "Synthetic terminal observer summary"
        model.sendDraft()
        try await waitUntil { transport.commands.count == 1 && transport.continuations.count == 1 }
        let command = try XCTUnwrap(transport.commands.first)
        defer { transport.continuations[command.generationID]?.finish() }
        transport.emit(.reasoningSummaryDelta("Checking inputs."), for: command, sequence: 1)
        transport.emit(.textDelta("A"), for: command, sequence: 2)
        try await waitUntil { model.messages.last?.content == "A" }
        let summary = "Checked the inputs and compared the results."
        transport.terminalSnapshots[command.generationID] = ChatTerminalSnapshot(status: .completed,
            content: "A", thinking: try XCTUnwrap(ChatReasoningSummaryStorage.encode(summary)), sequence: 3,
            errorCode: nil, media: [], tokenUsage: nil, codeReceipt: nil)
        // No terminal enters the held SSE continuation. Exercise the existing
        // production terminal observer with a synthetic status response instead.
        try await waitUntil { !model.isCurrentConversationGenerating }
        XCTAssertEqual(model.processEntriesByMessageID[command.assistantMessageID, default: []].compactMap {
            if case let .reasoningSummary(value) = $0.content { return value }; return nil
        }.joined(), summary)
        XCTAssertEqual(ChatReasoningSummaryStorage.decode(model.messages.last?.thinking), summary)
        XCTAssertEqual(transport.commands.count, 1)
    }

    func testCompletedForegroundRecoveryReconcilesExistingPublicSummary() async throws {
        let transport = ControlledChatTransport()
        let data = ControlledConversationStore()
        let model = NativeRuntimeFixture.makeModel(dataClient: data, chatClient: transport, stream: transport)
        await model.restoreAuthenticationIfNeeded()
        await model.reloadModels()
        model.beginNewChat()
        model.draft = "Synthetic completed recovery summary"
        model.sendDraft()
        try await waitUntil { transport.commands.count == 1 && transport.streamStarts.count == 1 }
        let command = try XCTUnwrap(transport.commands.first)
        defer { transport.continuations[command.generationID]?.finish() }
        await data.addConversation(ConversationRecord(id: command.conversationID.uuidString,
            title: "Terminal recovery", updatedAt: "", projectID: nil, starred: false, pinned: false))
        await model.reloadConversations()
        transport.emit(.reasoningSummaryDelta("Checking inputs."), for: command, sequence: 1)
        transport.emit(.textDelta("A"), for: command, sequence: 2)
        try await waitUntil { model.messages.last?.content == "A" }
        let summary = "Checked the inputs and compared the results."
        let thinking = try XCTUnwrap(ChatReasoningSummaryStorage.encode(summary))
        let terminal = ChatTerminalSnapshot(status: .completed, content: "A", thinking: thinking,
            sequence: 3, errorCode: nil, media: [], tokenUsage: nil, codeReceipt: nil)
        transport.recovery = ChatGenerationRecovery(admission: ChatAdmission(schemaVersion: 1,
            jobID: command.generationID, generationID: command.generationID,
            userMessageID: command.userMessageID, assistantMessageID: command.assistantMessageID,
            status: "completed", created: false, streamURL: URL(string: "https://isolated.mychat.invalid/events")!,
            trialRemaining: nil, trialLimit: nil), sequence: 3, content: "A", thinking: thinking, media: [], terminal: terminal)
        await model.resumeAuthentication()
        try await waitUntil {
            model.processEntriesByMessageID[command.assistantMessageID, default: []].compactMap {
                if case let .reasoningSummary(value) = $0.content { return value }; return nil
            }.joined() == summary
        }
        XCTAssertFalse(model.isCurrentConversationGenerating)
        XCTAssertEqual(ChatReasoningSummaryStorage.decode(model.messages.last?.thinking), summary)
        XCTAssertEqual(transport.commands.count, 1, "Completed recovery must not submit a new generation")
        XCTAssertEqual(transport.streamStarts.count, 1, "A completed checkpoint needs no replacement SSE stream")
    }

    func testNonemptySnapshotReconcilesProcessTextAndOnlyPublicSummaries() throws {
        let job = UUID()
        var entries: [ChatProcessEntry] = []
        let tool = ChatToolActivity(toolCallID: "snapshot-tool", toolName: "search", isComplete: true)
        func record(_ payload: ChatJobEventPayload, _ sequence: Int) {
            ChatProcessEntry.record(ChatJobEvent(jobID: job, sequence: sequence, payload: payload), into: &entries)
        }
        func text() -> String {
            entries.compactMap { if case let .text(value) = $0.content { return value }; return nil }.joined()
        }
        func summary() -> String {
            entries.compactMap { if case let .reasoningSummary(value) = $0.content { return value }; return nil }.joined()
        }
        record(.textDelta("A"), 1)
        record(.toolActivity(tool), 2)
        record(.reasoningSummaryDelta("Checking "), 3)
        record(.snapshot(ChatJobSnapshot(content: "AB", thinking:
            try XCTUnwrap(ChatReasoningSummaryStorage.encode("Checking inputs.")), media: [])), 4)
        XCTAssertEqual(text(), "AB")
        XCTAssertEqual(summary(), "Checking inputs.")
        XCTAssertEqual(entries[0].content, .text("A"))
        XCTAssertEqual(entries[1].content, .tool(tool))
        record(.textDelta("C"), 5)
        XCTAssertEqual(text(), "ABC", "The checkpoint's B must not disappear before terminal")
        record(.snapshot(ChatJobSnapshot(content: "AX", thinking: "PRIVATE_REASONING", media: [])), 6)
        XCTAssertEqual(text(), "AX", "A checkpoint is an authoritative replacement, not an append")
        XCTAssertEqual(summary(), "Checking inputs.")
        XCTAssertFalse(entries.contains { if case .thinking = $0.content { return true }; return false })
        XCTAssertTrue(entries.contains { $0.content == .tool(tool) })
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count)
        record(.snapshot(ChatJobSnapshot(content: "", thinking: "", media: [])), 7)
        XCTAssertTrue(entries.isEmpty)

        record(.snapshot(ChatJobSnapshot(content: "Recovered", thinking:
            try XCTUnwrap(ChatReasoningSummaryStorage.encode("Reviewing evidence.")), media: [])), 8)
        XCTAssertEqual(text(), "Recovered")
        XCTAssertEqual(summary(), "Reviewing evidence.")
        XCTAssertEqual(Set(entries.map(\.id)).count, 2, "Snapshot text and summary need distinct stable row IDs")
    }

    func testSnapshotCursorRejectsOlderReplayAndOtherJobsBeforeProjection() {
        let job = UUID()
        var accumulator = ChatStreamAccumulator()
        var entries: [ChatProcessEntry] = []
        func apply(_ event: ChatJobEvent) -> Bool {
            guard accumulator.apply(event) else { return false }
            ChatProcessEntry.record(event, into: &entries)
            return true
        }
        XCTAssertTrue(apply(ChatJobEvent(jobID: job, sequence: 5, payload: .textDelta("A"))))
        XCTAssertTrue(apply(ChatJobEvent(jobID: job, sequence: 6,
            payload: .snapshot(ChatJobSnapshot(content: "AB", thinking: "", media: [])))))
        XCTAssertFalse(apply(ChatJobEvent(jobID: job, sequence: 5,
            payload: .snapshot(ChatJobSnapshot(content: "OLD", thinking: "", media: [])))))
        XCTAssertFalse(apply(ChatJobEvent(jobID: job, sequence: 6,
            payload: .snapshot(ChatJobSnapshot(content: "DUPLICATE", thinking: "", media: [])))))
        XCTAssertFalse(apply(ChatJobEvent(jobID: UUID(), sequence: 7,
            payload: .snapshot(ChatJobSnapshot(content: "OTHER_JOB", thinking: "", media: [])))))
        XCTAssertTrue(apply(ChatJobEvent(jobID: job, sequence: 7, payload: .textDelta("C"))))
        XCTAssertEqual(accumulator.content, "ABC")
        XCTAssertEqual(accumulator.sequence, 7)
        XCTAssertEqual(entries.compactMap {
            if case let .text(value) = $0.content { return value }; return nil
        }.joined(), "ABC")
        let terminal = ChatTerminalSnapshot(status: .completed, content: "ABC", thinking: "", sequence: 7,
            errorCode: nil, media: [], tokenUsage: nil, codeReceipt: nil)
        XCTAssertTrue(apply(ChatJobEvent(jobID: job, sequence: 7, payload: .terminal(terminal))),
            "A recovered terminal may share the checkpoint cursor")
        XCTAssertFalse(apply(ChatJobEvent(jobID: job, sequence: 8,
            payload: .snapshot(ChatJobSnapshot(content: "LATE", thinking: "", media: [])))))
        XCTAssertEqual(accumulator.content, "ABC")
    }

    func testNonemptySnapshotsReachAppModelAndTranscriptBeforeTerminalWhileInteracting() async throws {
        let transport = ControlledChatTransport()
        let model = NativeRuntimeFixture.makeModel(chatClient: transport, stream: transport)
        await model.restoreAuthenticationIfNeeded()
        await model.reloadModels()
        model.beginNewChat()
        model.draft = "Synthetic snapshot publication"
        model.sendDraft()
        try await waitUntil { transport.commands.count == 1 && transport.continuations.count == 1 }
        let command = try XCTUnwrap(transport.commands.first)
        defer { transport.continuations[command.generationID]?.finish() }
        let updates = ChatTranscriptUpdates(model)
        updates.setInteracting(true)
        updates.setModalVisible(true)
        var bodies: [String] = []
        var summaries: [String] = []
        let observation = updates.$snapshot.sink { snapshot in
            let entries = snapshot.processEntries[command.assistantMessageID, default: []]
            let body = entries.compactMap { if case let .text(value) = $0.content { return value }; return nil }.joined()
            let summary = entries.compactMap { if case let .reasoningSummary(value) = $0.content { return value }; return nil }.joined()
            if !body.isEmpty, bodies.last != body { bodies.append(body) }
            if !summary.isEmpty, summaries.last != summary { summaries.append(summary) }
        }
        defer { observation.cancel() }
        // Deliver without sleeps or terminal. The production AppModel consumer
        // and ChatTranscriptUpdates must publish each upstream value in order.
        transport.emit(.textDelta("A"), for: command, sequence: 1)
        transport.emit(.reasoningSummaryDelta("Checking "), for: command, sequence: 2)
        transport.emit(.snapshot(ChatJobSnapshot(content: "AB", thinking:
            try XCTUnwrap(ChatReasoningSummaryStorage.encode("Checking inputs.")), media: [])), for: command, sequence: 3)
        transport.emit(.textDelta("C"), for: command, sequence: 4)
        try await waitUntil { bodies.last == "ABC" }
        XCTAssertEqual(bodies, ["A", "AB", "ABC"])
        XCTAssertEqual(summaries, ["Checking ", "Checking inputs."])
        XCTAssertTrue(model.isCurrentConversationGenerating)
        XCTAssertEqual(model.messages.last?.content, "AB", "Nonempty checkpoints must flush canonical text too")
        XCTAssertEqual(updates.snapshot.messages.last?.content, "AB")

        transport.emit(.snapshot(ChatJobSnapshot(content: "OLD", thinking: "PRIVATE_OLD", media: [])),
            for: command, sequence: 2)
        transport.emit(.textDelta("D"), for: command, sequence: 5)
        try await waitUntil { bodies.last == "ABCD" }
        XCTAssertFalse(bodies.contains("OLD"))
        transport.emit(.snapshot(ChatJobSnapshot(content: "XYZ", thinking:
            try XCTUnwrap(ChatReasoningSummaryStorage.encode("Comparing alternatives.")), media: [])), for: command, sequence: 6)
        try await waitUntil { updates.snapshot.messages.last?.content == "XYZ" }
        XCTAssertEqual(bodies.last, "XYZ", "Non-prefix corrections cannot wait for scroll or modal dismissal")
        transport.emit(.textDelta("!"), for: command, sequence: 7)
        try await waitUntil { bodies.last == "XYZ!" }
        transport.emit(.snapshot(ChatJobSnapshot(content: "XY", thinking: "PRIVATE_REASONING", media: [])),
            for: command, sequence: 8)
        try await waitUntil { updates.snapshot.messages.last?.content == "XY" }
        XCTAssertEqual(summaries.last, "Comparing alternatives.")
        XCTAssertFalse(summaries.contains { $0.contains("PRIVATE") })
        XCTAssertTrue(model.isCurrentConversationGenerating)
        transport.complete(command, text: "XY", sequence: 9)
        try await waitUntil { !model.isCurrentConversationGenerating }
        XCTAssertEqual(model.messages.last?.content, "XY")
    }

    func testForegroundCheckpointCannotRollBackPublishedBody() async throws {
        for checkpoint in [1, 2] {
            let transport = ControlledChatTransport()
            let data = ControlledConversationStore()
            let model = NativeRuntimeFixture.makeModel(dataClient: data, chatClient: transport, stream: transport)
            await model.restoreAuthenticationIfNeeded()
            await model.reloadModels()
            model.beginNewChat()
            model.draft = "Synthetic stale foreground checkpoint"
            model.sendDraft()
            try await waitUntil { transport.commands.count == 1 && transport.streamStarts.count == 1 }
            let command = try XCTUnwrap(transport.commands.first)
            defer {
                transport.heldRecovery?.resume()
                transport.heldRecovery = nil
                transport.continuations[command.generationID]?.finish()
            }
            await data.addConversation(ConversationRecord(id: command.conversationID.uuidString,
                title: "Stale checkpoint", updatedAt: "", projectID: nil, starred: false, pinned: false))
            await model.reloadConversations()
            transport.emit(.textDelta("A"), for: command, sequence: 1)
            try await waitUntil { model.messages.last?.content == "A" }
            transport.recovery = ChatGenerationRecovery(admission: ChatAdmission(schemaVersion: 1,
                jobID: command.generationID, generationID: command.generationID,
                userMessageID: command.userMessageID, assistantMessageID: command.assistantMessageID,
                status: "running", created: false, streamURL: URL(string: "https://isolated.mychat.invalid/events")!,
                trialRemaining: nil, trialLimit: nil), sequence: checkpoint, content: "OLD", thinking: "", media: [], terminal: nil)
            transport.holdRecovery = true
            await model.resumeAuthentication()
            try await waitUntil { transport.heldRecovery != nil }
            transport.emit(.textDelta("B"), for: command, sequence: 2)
            func projectedText() -> String {
                model.processEntriesByMessageID[command.assistantMessageID, default: []].compactMap {
                    if case let .text(value) = $0.content { return value }; return nil
                }.joined()
            }
            try await waitUntil { projectedText() == "AB" }
            transport.holdRecovery = false
            transport.recovery = nil
            transport.heldRecovery?.resume()
            transport.heldRecovery = nil
            // A second lookup can begin only after the first recovery task's
            // defer has finished. This settles the stale response without a
            // guessed sleep duration or changing the production recovery API.
            let deadline = Date().addingTimeInterval(1)
            while transport.recoveryReadCount < 2, Date() < deadline {
                await model.resumeAuthentication()
                await Task.yield()
            }
            XCTAssertGreaterThanOrEqual(transport.recoveryReadCount, 2)
            XCTAssertEqual(transport.streamStarts.count, 1, "A database cursor never authorizes rolling back the published body")
            XCTAssertEqual(projectedText(), "AB")
            transport.emit(.textDelta("C"), for: command, sequence: 3)
            try await waitUntil { projectedText() == "ABC" }
            transport.complete(command, text: "ABC", sequence: 4)
            try await waitUntil { !model.isCurrentConversationGenerating }
            XCTAssertEqual(model.messages.last?.content, "ABC")
            XCTAssertEqual(transport.commands.count, 1)
        }
    }

    func testSSEReplayCannotInjectAnOlderNonemptySnapshot() async throws {
        let job = UUID()
        func frame(_ sequence: Int, _ kind: String, _ payload: [String: Any]) throws -> Data {
            let json = try JSONSerialization.data(withJSONObject: ["jobId": job.uuidString,
                "seq": sequence, "kind": kind, "payload": payload])
            return Data("id: \(sequence)\nevent: \(kind)\ndata: \(String(decoding: json, as: UTF8.self))\n\n".utf8)
        }
        let frames = try frame(1, "text.delta", ["text": "A"])
            + frame(2, "job.snapshot", ["content": "AB", "reasoningSummary": "Checking inputs."])
            + frame(1, "job.snapshot", ["content": "OLD", "reasoningSummary": "OLD SUMMARY"])
            + frame(3, "text.delta", ["text": "C"])
            + frame(4, "job.terminal", ["status": "completed", "result": ["content": "ABC"]])
        let recorder = ChatAdmissionRetryRecorder(responses: [(200, frames, ["Content-Type": "text/event-stream"])])
        ChatAdmissionRetryFixtureURLProtocol.recorder = recorder
        defer { ChatAdmissionRetryFixtureURLProtocol.recorder = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatAdmissionRetryFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let origin = URL(string: "https://mychat.invalid")!
        let admission = ChatAdmission(schemaVersion: 1, jobID: job, generationID: job,
            userMessageID: UUID(), assistantMessageID: UUID(), status: "running", created: false,
            streamURL: origin.appendingPathComponent("events"), trialRemaining: nil, trialLimit: nil)
        var sequences: [Int] = []
        var accumulator = ChatStreamAccumulator()
        var projected: [String] = []
        for try await event in JobEventStream(session: session, allowedOrigin: origin, maximumDuration: 2)
            .events(admission: admission, accessToken: "fixture-only") {
            sequences.append(event.sequence)
            accumulator.apply(event)
            if projected.last != accumulator.content { projected.append(accumulator.content) }
        }
        XCTAssertEqual(sequences, [1, 2, 3, 4])
        XCTAssertEqual(projected, ["A", "AB", "ABC"])
        XCTAssertEqual(accumulator.reasoningSummary, "Checking inputs.")
        XCTAssertEqual(recorder.requestCount, 1)
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

    func testPlanProviderDeltasReachAppModelAndTranscriptBeforeCompletion() async throws {
        let transport = ControlledChatTransport()
        let model = NativeRuntimeFixture.makeModel(chatClient: transport, stream: transport)
        await model.restoreAuthenticationIfNeeded()
        await model.reloadModels()
        model.beginNewChat()
        model.draft = "Offline Plan stream regression"
        model.sendDraft()
        try await waitUntil { transport.commands.count == 1 && transport.continuations.count == 1 }
        let command = try XCTUnwrap(transport.commands.first)
        defer { transport.continuations[command.generationID]?.finish() }

        let updates = ChatTranscriptUpdates(model)
        // Scrolling or an open sheet must not turn the stream back into a
        // terminal-only snapshot. These flags only own non-stream layout state.
        updates.setInteracting(true)
        updates.setModalVisible(true)
        var bodies: [String] = []
        var summaries: [String] = []
        let observation = updates.$snapshot.sink { snapshot in
            guard model.isCurrentConversationGenerating else { return }
            let entries = snapshot.processEntries[command.assistantMessageID, default: []]
            let body = entries.compactMap { entry -> String? in
                if case let .text(value) = entry.content { return value }
                return nil
            }.joined()
            let summary = entries.compactMap { entry -> String? in
                if case let .reasoningSummary(value) = entry.content { return value }
                return nil
            }.joined()
            if !body.isEmpty, bodies.last != body { bodies.append(body) }
            if !summary.isEmpty, summaries.last != summary { summaries.append(summary) }
        }
        defer { observation.cancel() }

        let events: [[String: Any]] = [
            ["type": "response.reasoning_summary_text.delta", "delta": "Checking "],
            ["type": "response.reasoning_summary_text.delta", "delta": "the inputs"],
            ["type": "response.reasoning_summary_text.delta", "delta": ", then deciding."],
            ["type": "response.output_text.delta", "delta": "first"],
            ["type": "response.output_text.delta", "delta": " second"],
            ["type": "response.output_text.delta", "delta": " third"],
            ["type": "response.completed", "response": ["output": [[
                "type": "message", "content": [["type": "output_text", "text": "first second third"]]
            ]]]]
        ]
        let frames = try events.map { event in
            let data = try JSONSerialization.data(withJSONObject: event)
            return "data: " + String(decoding: data, as: UTF8.self) + "\n\n"
        }.joined()
        let recorder = ChatGPTPlanRequestRecorder()
        recorder.scriptedResponses = [(200, Data(frames.utf8), "text/event-stream")]
        ChatGPTPlanFixtureURLProtocol.recorder = recorder
        defer { ChatGPTPlanFixtureURLProtocol.recorder = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChatGPTPlanFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let stream = ChatGPTPlanProvider.stream(
            session: session, requestBody: Data("{}".utf8), accessToken: "isolated-plan-fixture",
            executeTool: { _, _ in XCTFail("No tool call belongs in this fixture"); return "{}" },
            refresh: { XCTFail("The offline stream must not refresh credentials"); return "" }
        )
        // Exercise the same event loop runChatGPTPlan calls. No sleeps, fake
        // display timer, or reducer-only substitute exists between these deltas.
        try await model.consumeChatGPTPlanEvents(
            stream, command: command, isPrivate: true,
            accumulator: ChatStreamAccumulator(), sequence: 0
        )
        XCTAssertEqual(bodies, ["first", "first second", "first second third"])
        XCTAssertEqual(summaries, ["Checking ", "Checking the inputs", "Checking the inputs, then deciding."])
        XCTAssertEqual(model.messages.last?.content, "first second third")
        XCTAssertFalse(model.isCurrentConversationGenerating)
        let timing = try XCTUnwrap(ChatGenerationDiagnostics.records[command.generationID])
        XCTAssertNotNil(timing.milliseconds["firstText"])
        XCTAssertNotNil(timing.milliseconds["firstReasoningSummary"])
        XCTAssertNotNil(timing.milliseconds["completed"])
        XCTAssertEqual(recorder.requests.count, 1)
        transport.complete(command, text: "first second third", sequence: 8)
        try await waitUntil { model.generatingConversationIDs.isEmpty }
    }

    func testStreamDeltasReachTheRenderedProcessSnapshotOneByOneWithoutWaiting() {
        let job = UUID()
        var bodyEntries: [ChatProcessEntry] = []
        var summaryEntries: [ChatProcessEntry] = []
        var bodySnapshot = ""
        var summarySnapshot = ""
        let bodyParts = ["first", " second", " third"]
        let summaryParts = ["Checking ", "the inputs", ", then deciding."]
        let bodyPrefixes = ["first", "first second", "first second third"]
        let summaryPrefixes = ["Checking ", "Checking the inputs", "Checking the inputs, then deciding."]

        for index in bodyParts.indices {
            ChatProcessEntry.record(
                ChatJobEvent(jobID: job, sequence: index + 1, payload: .textDelta(bodyParts[index])),
                into: &bodyEntries
            )
            bodySnapshot = bodyEntries.compactMap {
                if case let .text(value) = $0.content { return value }
                return nil
            }.joined()
            XCTAssertEqual(bodySnapshot, bodyPrefixes[index])

            ChatProcessEntry.record(
                ChatJobEvent(jobID: job, sequence: index + 4, payload: .reasoningSummaryDelta(summaryParts[index])),
                into: &summaryEntries
            )
            summarySnapshot = summaryEntries.compactMap {
                if case let .reasoningSummary(value) = $0.content { return value }
                return nil
            }.joined()
            XCTAssertEqual(summarySnapshot, summaryPrefixes[index])
        }
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
    var records = ["20000000-0000-4000-8000-000000000001", "20000000-0000-4000-8000-000000000002"].map {
        ConversationRecord(id: $0, title: $0, updatedAt: "2026-10-03", projectID: nil, starred: false, pinned: false)
    }
    var pending: [String: CheckedContinuation<Void, Error>] = [:]
    var messages: [UUID: [ConversationMessageRecord]] = [:]
    func addConversation(_ record: ConversationRecord) { records.append(record) }
    func setMessages(_ value: [ConversationMessageRecord], for id: UUID) { messages[id] = value }
    func fetchConversations(accessToken: String) async throws -> [ConversationRecord] { records }
    func fetchMessages(conversationID: String, accessToken: String, limit: Int) async throws -> [ConversationMessageRecord] {
        UUID(uuidString: conversationID).flatMap { messages[$0] } ?? []
    }
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
    var holdRecovery = false
    var heldRecovery: CheckedContinuation<Void, Never>?
    var recoveryReadCount = 0
    var terminalSnapshots: [UUID: ChatTerminalSnapshot] = [:]
    var admissionStatuses: [UUID: ChatAdmissionJobStatus] = [:]
    var admissionStatusCalls: [UUID] = []
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
    func conversationGeneration(conversationID: UUID, accessToken: String) async throws -> ChatGenerationRecovery? {
        recoveryReadCount += 1
        let checkpoint = recovery
        if holdRecovery { await withCheckedContinuation { heldRecovery = $0 } }
        return checkpoint
    }
    func admissionStatus(command: ChatAppendCommand, accessToken: String) async throws -> ChatAdmissionJobStatus? {
        admissionStatusCalls.append(command.generationID)
        return admissionStatuses[command.generationID]
    }
    func terminalSnapshot(conversationID: UUID, jobID: UUID, accessToken: String) async throws -> ChatTerminalSnapshot? { terminalSnapshots[jobID] }
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
