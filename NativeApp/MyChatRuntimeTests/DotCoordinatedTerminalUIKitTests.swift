// Local regression draft for the two-file coordinated candidate.
// Not compiled, executed, registered, or uploaded. Uses only synthetic views.
import XCTest
import UIKit
import QuartzCore
@testable import MyChat

@MainActor final class DotCoordinatedTerminalUIKitTests: XCTestCase {
    func testTerminalHandoffPreservesVisiblePositionUntilFramesConverge() async throws {
        let host = try DotTerminalUIKitHost()
        defer { host.stop() }
        host.beginGeneration()
        try await observe(host, description: "Establish generation tracking") { $0.count >= 3 }
        host.surface.center.y += 120
        try await observe(host, description: "Establish a real unsettled layer correction") {
            $0.last.map { $0.inner < -0.5 } ?? false
        }
        let before = host.sample().modelWindowY
        host.completeSurface()
        XCTAssertEqual(host.sample().modelWindowY, before, accuracy: 0.5,
            "Generation state alone must not release the remaining layer correction")
        let samples = try await observe(host, description: "Converge after terminal handoff") {
            $0.count >= 3 && abs($0.last?.inner ?? .infinity) < 0.01
        }
        assertApproachesTarget(samples, startingAt: before, target: host.sample().targetWindowY)
    }

    func testCombinedScrollHandoffIsContinuousInBothConfigurationOrders() async throws {
        for surfaceFirst in [true, false] {
            let host = try DotTerminalUIKitHost(withScrollController: true)
            defer { host.stop() }
            try await observe(host, description: "Establish synthetic initial reading anchor") {
                $0.count >= 3 && abs(($0.last?.scrollY ?? 0) - host.expectedScrollY) < 0.5
            }
            host.beginGeneration()
            try await observe(host, description: "Establish both generation trackers") { $0.count >= 3 }
            host.surface.center.y += 120
            host.bodyBottom += 120
            host.controller?.setLaidOutBodyBottom(host.bodyBottom)
            try await observe(host, description: "Both outer scroll and inner Dot remain unsettled") {
                $0.last.map { abs($0.outer) > 1 && $0.inner < -0.5 } ?? false
            }
            let before = host.sample().modelWindowY
            if surfaceFirst {
                host.completeSurface()
                host.controller?.setGenerationActive(false)
            } else {
                host.controller?.setGenerationActive(false)
                host.completeSurface()
            }
            XCTAssertEqual(host.sample().modelWindowY, before, accuracy: 0.5,
                "The two terminal configuration orders must preserve the same current position")
            let samples = try await observe(host, description: "Settle both UIKit trackers, surfaceFirst=\(surfaceFirst)") {
                $0.count >= 3 && ($0.last.map { abs($0.inner) < 0.01 && abs($0.outer) <= 0.5 } ?? false)
            }
            let final = host.sample()
            XCTAssertEqual(final.scrollY, host.expectedScrollY, accuracy: 0.5)
            assertApproachesTarget(samples, startingAt: before, target: final.targetWindowY)
        }
    }

    func testSettledTerminalPlacementHoldsLate24PointLayoutThenConverges() async throws {
        let host = try DotTerminalUIKitHost()
        defer { host.stop() }
        host.beginGeneration()
        try await observe(host, description: "Establish generation baseline") { $0.count >= 3 }
        host.completeSurface()
        try await observe(host, description: "Terminal tracker is already settled") {
            $0.count >= 4 && abs($0.last?.inner ?? .infinity) < 0.01
        }
        let before = host.sample().modelWindowY
        host.surface.center.y += 24
        // No await or display-link advancement occurs between these observations.
        XCTAssertEqual(host.sample().modelWindowY, before, accuracy: 0.5,
            "A late geometry setter must synchronously preserve the completed Dot position")
        let samples = try await observe(host, description: "Late geometry restarts convergence") {
            $0.count >= 3 && abs($0.last?.inner ?? .infinity) < 0.01
        }
        XCTAssertEqual(host.sample().modelWindowY, before + 24, accuracy: 0.5)
        assertApproachesTarget(samples, startingAt: before, target: before + 24)
    }

    @discardableResult
    private func observe(_ host: DotTerminalUIKitHost, description: String,
                         until predicate: @escaping ([DotTerminalUIKitSample]) -> Bool) async throws -> [DotTerminalUIKitSample] {
        let arrived = expectation(description: description)
        let observer = DotTerminalUIKitObserver(host: host, until: predicate) { arrived.fulfill() }
        let link = CADisplayLink(target: observer, selector: #selector(DotTerminalUIKitObserver.tick))
        link.add(to: .main, forMode: .common)
        defer { link.invalidate() }
        // This bounds a new synthetic fixture; it does not relax an existing test.
        await fulfillment(of: [arrived], timeout: 2)
        let data = try JSONEncoder().encode(observer.samples)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = description
        attachment.lifetime = .keepAlways
        add(attachment)
        guard observer.finished else { throw DotTerminalUIKitFailure.conditionNotReached }
        return observer.samples
    }

    private func assertApproachesTarget(_ samples: [DotTerminalUIKitSample], startingAt start: CGFloat,
                                       target: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        let lower = min(start, target) - 0.5, upper = max(start, target) + 0.5
        var previousDistance = abs(target - start)
        for sample in samples {
            XCTAssertGreaterThanOrEqual(sample.modelWindowY, lower, file: file, line: line)
            XCTAssertLessThanOrEqual(sample.modelWindowY, upper, file: file, line: line)
            let distance = abs(target - sample.modelWindowY)
            XCTAssertLessThanOrEqual(distance, previousDistance + 0.5,
                "A displayed frame must not move farther from the stable destination", file: file, line: line)
            previousDistance = distance
        }
    }
}

private enum DotTerminalUIKitFailure: Error { case conditionNotReached }

private struct DotTerminalUIKitSample: Encodable {
    let timestamp: TimeInterval
    let scrollY: CGFloat
    let outer: CGFloat
    let inner: CGFloat
    let targetWindowY: CGFloat
    let modelWindowY: CGFloat
    // Diagnostic only: CA presentation sampling is not a screenshot assertion.
    let presentationWindowY: CGFloat?
}

@MainActor private final class DotTerminalUIKitHost {
    let window: UIWindow
    let scroll: UIScrollView
    let surface: DotAnimationSurface
    let controller: ChatScrollController?
    var bodyBottom: CGFloat = 600
    private let identity = UUID()
    private let imageLayer: CALayer

    var expectedScrollY: CGFloat { bodyBottom - scroll.bounds.height * (2.0 / 3.0) }

    init(withScrollController: Bool = false) throws {
        guard UIApplication.shared.applicationState == .active,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else {
            throw XCTSkip("Needs an active, isolated XCTest app host for UIKit/display-link execution")
        }
        let testSurface = DotAnimationSurface(frame: CGRect(x: 20, y: 576, width: 48, height: 48))
        let testLayer = try XCTUnwrap(testSurface.layer.sublayers?.first)
        window = UIWindow(windowScene: scene)
        scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        surface = testSurface
        imageLayer = testLayer
        controller = withScrollController ? ChatScrollController() : nil
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.contentSize = CGSize(width: 390, height: 1_400)
        root.view.addSubview(scroll)
        scroll.addSubview(surface)
        surface.layoutIfNeeded()
        controller?.useReadingPositions(ChatReadingPositionStore(), remembersPosition: false)
        controller?.attach(scroll, conversationID: UUID())
        controller?.setLaidOutBodyBottom(bodyBottom)
        controller?.registerCompanion(surface)
    }

    func beginGeneration() {
        controller?.setGenerationActive(true)
        surface.configure(isGenerating: true, reduceMotion: false, isSuspended: false, positionID: identity)
        controller?.registerCompanion(surface)
    }

    func completeSurface() {
        surface.configure(isGenerating: false, reduceMotion: false, isSuspended: false, positionID: identity)
    }

    func sample() -> DotTerminalUIKitSample {
        let center = CGPoint(x: surface.bounds.midX, y: surface.bounds.midY)
        let target = surface.convert(center, to: window).y
        let modelPoint = CGPoint(x: center.x, y: center.y + imageLayer.transform.m42)
        let presentation = imageLayer.presentation().map {
            surface.convert(CGPoint(x: center.x, y: center.y + $0.transform.m42), to: window).y
        }
        return DotTerminalUIKitSample(timestamp: CACurrentMediaTime(), scrollY: scroll.contentOffset.y,
            outer: surface.transform.ty, inner: imageLayer.transform.m42, targetWindowY: target,
            modelWindowY: surface.convert(modelPoint, to: window).y, presentationWindowY: presentation)
    }

    func stop() {
        controller?.pauseFollowAnimation()
        surface.stop()
        window.isHidden = true
        surface.removeFromSuperview()
        window.rootViewController = nil
    }
}

@MainActor private final class DotTerminalUIKitObserver: NSObject {
    private let host: DotTerminalUIKitHost
    private let predicate: ([DotTerminalUIKitSample]) -> Bool
    private let complete: () -> Void
    private(set) var samples: [DotTerminalUIKitSample] = []
    private(set) var finished = false

    init(host: DotTerminalUIKitHost, until predicate: @escaping ([DotTerminalUIKitSample]) -> Bool,
         complete: @escaping () -> Void) {
        self.host = host; self.predicate = predicate; self.complete = complete
        super.init()
    }

    @objc func tick() {
        guard !finished else { return }
        samples.append(host.sample())
        if predicate(samples) { finished = true; complete() }
    }
}
