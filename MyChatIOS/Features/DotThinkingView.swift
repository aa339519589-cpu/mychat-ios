import ImageIO
import SwiftUI
import UIKit

// The supplied 3D mascot is rendered into small atlases ahead of time. Playback
// stays in Core Animation; idle mode changes do not invalidate the transcript.
struct DotThinkingView: UIViewRepresentable {
    var isGenerating = true
    var isSuspended = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIView(context: Context) -> DotAnimationSurface { DotAnimationSurface() }
    func updateUIView(_ view: DotAnimationSurface, context: Context) {
        view.configure(isGenerating: isGenerating, reduceMotion: reduceMotion, isSuspended: isSuspended)
    }
    static func dismantleUIView(_ view: DotAnimationSurface, coordinator: ()) { view.stop() }
}

private enum DotCompanionMode: String, CaseIterable {
    case idle, think, draw, typing
    static let resting: [Self] = [.idle, .think, .draw]
}

private struct DotMotionFrames: @unchecked Sendable {
    let images: [CGImage]
    let duration: Double

    private static let typing = Task.detached(priority: .utility) { load(.typing) }
    private static let idle = Task.detached(priority: .utility) { load(.idle) }
    private static let think = Task.detached(priority: .utility) { load(.think) }
    private static let draw = Task.detached(priority: .utility) { load(.draw) }

    static func frames(for mode: DotCompanionMode) async -> DotMotionFrames? {
        switch mode {
        case .typing: return await typing.value
        case .idle: return await idle.value
        case .think: return await think.value
        case .draw: return await draw.value
        }
    }

    private static func load(_ mode: DotCompanionMode) -> DotMotionFrames? {
        guard let folder = Bundle.main.url(forResource: "DotMotion", withExtension: nil),
              let data = try? Data(contentsOf: folder.appendingPathComponent(mode == .typing ? "manifest.json" : "companion-manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.tileSize > 0, manifest.columns > 0, manifest.frames > 0,
              manifest.frames <= 240, manifest.duration.isFinite, manifest.duration > 0,
              let source = CGImageSourceCreateWithURL(folder.appendingPathComponent("\(mode.rawValue)-atlas.png") as CFURL, nil),
              let atlas = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        let frames = (0..<manifest.frames).compactMap { index in
            atlas.cropping(to: CGRect(x: (index % manifest.columns) * manifest.tileSize,
                                     y: (index / manifest.columns) * manifest.tileSize,
                                     width: manifest.tileSize, height: manifest.tileSize))
        }
        return frames.count == manifest.frames ? DotMotionFrames(images: frames, duration: manifest.duration) : nil
    }
    private struct Manifest: Decodable { let tileSize: Int; let columns: Int; let frames: Int; let duration: Double }
}

final class DotAnimationSurface: UIControl {
    private let imageLayer = CALayer()
    private var frames: DotMotionFrames?
    private var loading: Task<Void, Never>?
    private var idleTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var mode: DotCompanionMode = .idle
    private var isGenerating = false
    private var holdsCompletedPose = false
    private var reduceMotion = false
    private var modalVisible = false
    private var explicitlySuspended = false
    private var lastTap = -Double.infinity

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        imageLayer.contentsGravity = .resizeAspect
        layer.addSublayer(imageLayer)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityIdentifier = "companion.dot"
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshPlayback()
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: .myChatModalVisibilityChanged, object: nil, queue: .main) { [weak self] note in
            self?.modalVisible = note.object as? Bool ?? false
            self?.refreshPlayback()
        })
        show(.idle)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    deinit { loading?.cancel(); idleTimer?.invalidate(); observers.forEach(NotificationCenter.default.removeObserver) }

    fileprivate func configure(isGenerating: Bool, reduceMotion: Bool, isSuspended: Bool) {
        let changedGeneration = self.isGenerating != isGenerating
        self.isGenerating = isGenerating
        self.reduceMotion = reduceMotion
        explicitlySuspended = isSuspended
        // Only typing communicates real generation. Think/draw are playful
        // idle poses, never claims that an agent or tool is working.
        accessibilityLabel = isGenerating ? "dot，回复生成中" : "dot 动画伙伴"
        accessibilityHint = "轻点互动"
        if changedGeneration {
            if isGenerating { show(.typing) }
            else {
                // Keep the exact rendered pose at completion. Switching to
                // another atlas immediately made the mascot visibly teleport.
                let current = imageLayer.presentation()?.contents ?? imageLayer.contents
                holdsCompletedPose = true
                loading?.cancel(); loading = nil
                CATransaction.begin(); CATransaction.setDisableActions(true)
                imageLayer.removeAnimation(forKey: "dot-frames")
                imageLayer.contents = current
                CATransaction.commit()
            }
        }
        refreshPlayback()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }
    override func didMoveToWindow() { super.didMoveToWindow(); refreshPlayback() }
    override func accessibilityActivate() -> Bool { tapped(); return true }

    private func show(_ next: DotCompanionMode) {
        holdsCompletedPose = false
        mode = next
        loading?.cancel()
        imageLayer.removeAnimation(forKey: "dot-frames")
        if canAnimate, imageLayer.contents != nil {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.18
            imageLayer.add(transition, forKey: "dot-pose")
        }
        frames = nil
        if let url = Bundle.main.url(forResource: "\(next.rawValue)-still", withExtension: "png", subdirectory: "DotMotion") {
            imageLayer.contents = UIImage(contentsOfFile: url.path)?.cgImage
        } else { imageLayer.contents = nil }
        loading = Task { [weak self] in
            let result = await DotMotionFrames.frames(for: next)
            guard !Task.isCancelled, let self, self.mode == next else { return }
            self.frames = result
            self.refreshPlayback()
        }
    }

    private var canAnimate: Bool {
        window != nil && !reduceMotion && !modalVisible && !explicitlySuspended && UIApplication.shared.applicationState == .active
    }

    fileprivate func refreshPlayback() {
        if canAnimate, !holdsCompletedPose, let frames {
            if imageLayer.animation(forKey: "dot-frames") == nil {
                let animation = CAKeyframeAnimation(keyPath: "contents")
                animation.values = frames.images
                animation.duration = frames.duration
                animation.calculationMode = .discrete
                animation.repeatCount = .infinity
                imageLayer.add(animation, forKey: "dot-frames")
            }
        } else {
            imageLayer.removeAnimation(forKey: "dot-frames")
            if !holdsCompletedPose, let first = frames?.images.first { imageLayer.contents = first }
            imageLayer.removeAnimation(forKey: "dot-tap")
            imageLayer.removeAnimation(forKey: "dot-pose")
        }
        if canAnimate && !isGenerating {
            if idleTimer == nil {
                idleTimer = Timer.scheduledTimer(withTimeInterval: Double.random(in: 8...14), repeats: false) { [weak self] _ in
                    // The timer is created on this UIControl's main run loop.
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.idleTimer = nil
                        guard self.canAnimate, !self.isGenerating else { return }
                        self.show(DotCompanionMode.resting.filter { $0 != self.mode }.randomElement() ?? .idle)
                    }
                }
            }
        } else { idleTimer?.invalidate(); idleTimer = nil }
    }

    @objc private func tapped() {
        let now = CACurrentMediaTime()
        guard now - lastTap > 0.75, !modalVisible else { return }
        lastTap = now
        if !isGenerating, !reduceMotion {
            idleTimer?.invalidate(); idleTimer = nil
            show(DotCompanionMode.resting.filter { $0 != mode }.randomElement() ?? .idle)
        }
        guard canAnimate else { return }
        let bounce = CAKeyframeAnimation(keyPath: "transform.translation.y")
        bounce.values = [0, -3, 0, -1, 0]
        bounce.keyTimes = [0, 0.3, 0.62, 0.8, 1]
        bounce.duration = 0.42
        imageLayer.add(bounce, forKey: "dot-tap")
    }

    fileprivate func stop() {
        loading?.cancel(); loading = nil
        idleTimer?.invalidate(); idleTimer = nil
        imageLayer.removeAllAnimations()
    }
}
