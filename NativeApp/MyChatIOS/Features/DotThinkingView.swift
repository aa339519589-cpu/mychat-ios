import ImageIO
import SwiftUI
import UIKit

// The supplied 3D mascot is rendered into small atlases ahead of time. Playback
// stays in Core Animation; idle mode changes do not invalidate the transcript.
struct DotThinkingView: UIViewRepresentable {
    var isGenerating = true
    var isSuspended = false
    @State private var positionID = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIView(context: Context) -> DotAnimationSurface { DotAnimationSurface() }
    func updateUIView(_ view: DotAnimationSurface, context: Context) {
        view.configure(isGenerating: isGenerating, reduceMotion: reduceMotion, isSuspended: isSuspended,
                       positionID: positionID)
    }
    static func dismantleUIView(_ view: DotAnimationSurface, coordinator: ()) { view.stop() }
}

enum DotCompanionMode: String, CaseIterable {
    case idle, think, draw, typing
    static let resting: [Self] = [.idle]
}

struct DotMotionFrames: @unchecked Sendable {
    let images: [CGImage]
    let duration: Double

    private static let typing = Task.detached(priority: .utility) { load(.typing) }
    private static let idle = Task.detached(priority: .utility) { load(.idle) }

    static func frames(for mode: DotCompanionMode) async -> DotMotionFrames? {
        switch mode {
        case .typing: return await typing.value
        case .idle, .think, .draw: return await idle.value
        }
    }

    private static func load(_ mode: DotCompanionMode) -> DotMotionFrames? {
        if mode != .typing {
            guard let url = Bundle.main.url(forResource: "coherent-idle", withExtension: "png", subdirectory: "DotMotion"),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 192,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            return DotMotionFrames(images: [image], duration: 4)
        }
        guard let folder = Bundle.main.url(forResource: "DotMotion", withExtension: nil),
              let data = try? Data(contentsOf: folder.appendingPathComponent(mode == .typing ? "manifest.json" : "companion-manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              (1...256).contains(manifest.tileSize), (1...32).contains(manifest.columns),
              (1...600).contains(manifest.frames), manifest.duration.isFinite, manifest.duration > 0,
              let source = CGImageSourceCreateWithURL(folder.appendingPathComponent("\(mode.rawValue)-atlas.png") as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width == manifest.columns * manifest.tileSize,
              height >= ((manifest.frames + manifest.columns - 1) / manifest.columns) * manifest.tileSize,
              width > 0, height > 0, width <= 8192, height <= 8192,
              width * height * 4 <= 64 * 1024 * 1024,
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
    private let outgoingLayer = CALayer()
    private let screenGlow = CAShapeLayer()
    private var positionLink: CADisplayLink?
    private var displayedContentY: CGFloat?
    private var targetContentY: CGFloat?
    private var positionID: UUID?
    private var previousPositionTime: CFTimeInterval?
    private lazy var positionTarget = DotPositionTarget(self)
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
        outgoingLayer.contentsGravity = .resizeAspect
        outgoingLayer.opacity = 0
        layer.addSublayer(outgoingLayer)
        screenGlow.fillColor = UIColor(red: 0.78, green: 0.98, blue: 0.95, alpha: 1).cgColor
        screenGlow.opacity = 0
        screenGlow.shadowColor = UIColor(red: 0.75, green: 0.96, blue: 0.90, alpha: 1).cgColor
        screenGlow.shadowRadius = 2
        screenGlow.shadowOpacity = 0.35
        screenGlow.shadowOffset = .zero
        imageLayer.addSublayer(screenGlow)
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
    deinit { loading?.cancel(); idleTimer?.invalidate(); positionLink?.invalidate(); observers.forEach(NotificationCenter.default.removeObserver) }

    func configure(isGenerating: Bool, reduceMotion: Bool, isSuspended: Bool, positionID: UUID) {
        if self.positionID != positionID {
            self.positionID = positionID
            displayedContentY = nil
            targetContentY = nil
            previousPositionTime = nil
        }
        let changedGeneration = self.isGenerating != isGenerating
        self.isGenerating = isGenerating
        self.reduceMotion = reduceMotion
        explicitlySuspended = isSuspended
        // Only typing communicates real generation; the aligned idle pose
        // keeps the same face, palette and body scale between replies.
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
                idleTimer?.invalidate(); idleTimer = nil
            }
        }
        refreshPlayback()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        outgoingLayer.frame = bounds
        screenGlow.frame = bounds
        let screen = UIBezierPath()
        screen.move(to: CGPoint(x: bounds.width * 0.30, y: bounds.height * 0.45))
        screen.addLine(to: CGPoint(x: bounds.width * 0.96, y: bounds.height * 0.44))
        screen.addLine(to: CGPoint(x: bounds.width * 0.97, y: bounds.height * 0.81))
        screen.addLine(to: CGPoint(x: bounds.width * 0.31, y: bounds.height * 0.86))
        screen.close()
        screenGlow.path = screen.cgPath
        CATransaction.commit()
    }
    override func didMoveToWindow() { super.didMoveToWindow(); refreshPlayback() }
    override func accessibilityActivate() -> Bool { tapped(); return true }

    private func show(_ next: DotCompanionMode) {
        mode = next
        loading?.cancel()
        // Keep the displayed pose while the next atlas loads; never insert
        // an unrelated still or rewind the old animation during the handoff.
        loading = Task { [weak self] in
            let result = await DotMotionFrames.frames(for: next)
            guard !Task.isCancelled, let self, self.mode == next,
                  let result, let first = result.images.first else { return }
            let current = self.imageLayer.presentation()?.contents ?? self.imageLayer.contents
            let animated = self.canAnimate && current != nil
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.outgoingLayer.removeAllAnimations()
            self.outgoingLayer.contents = current
            self.outgoingLayer.opacity = 0
            self.imageLayer.removeAnimation(forKey: "dot-frames")
            self.imageLayer.contents = first
            self.imageLayer.opacity = 1
            self.frames = result
            self.holdsCompletedPose = false
            CATransaction.commit()
            self.refreshPlayback()
            if animated {
                let incoming = CABasicAnimation(keyPath: "opacity")
                incoming.fromValue = 0
                incoming.toValue = 1
                incoming.duration = 0.36
                incoming.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                let outgoing = incoming.copy() as! CABasicAnimation
                outgoing.fromValue = 1
                outgoing.toValue = 0
                self.imageLayer.add(incoming, forKey: "dot-pose")
                self.outgoingLayer.add(outgoing, forKey: "dot-pose")
            }
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
        updateGenerationMotion()
        if canAnimate && !isGenerating && holdsCompletedPose {
            if idleTimer == nil {
                idleTimer = Timer.scheduledTimer(withTimeInterval: holdsCompletedPose ? 1.2 : Double.random(in: 8...14), repeats: false) { [weak self] _ in
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

    private func updateGenerationMotion() {
        let active = canAnimate && isGenerating
        if active {
            if screenGlow.animation(forKey: "key-light") == nil {
                let pulse = CAKeyframeAnimation(keyPath: "opacity")
                pulse.values = [0.08, 0.38, 0.12, 0.28, 0.08]
                pulse.keyTimes = [0, 0.20, 0.48, 0.72, 1]
                pulse.duration = 1.25
                pulse.repeatCount = .infinity
                pulse.calculationMode = .cubic
                screenGlow.add(pulse, forKey: "key-light")
            }
            if positionLink == nil {
                let link = CADisplayLink(target: positionTarget, selector: #selector(DotPositionTarget.tick))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
                link.add(to: .main, forMode: .common)
                positionLink = link
            }
        } else {
            screenGlow.removeAllAnimations()
            screenGlow.opacity = 0
            positionLink?.invalidate(); positionLink = nil
            displayedContentY = nil
            targetContentY = nil
            previousPositionTime = nil
            CATransaction.begin(); CATransaction.setDisableActions(true)
            imageLayer.transform = CATransform3DIdentity
            outgoingLayer.transform = CATransform3DIdentity
            CATransaction.commit()
        }
        if canAnimate && !isGenerating && !holdsCompletedPose {
            if imageLayer.animation(forKey: "rest-breath") == nil {
                let breath = CABasicAnimation(keyPath: "transform.translation.y")
                breath.fromValue = 0; breath.toValue = -0.7
                breath.duration = 1.8; breath.autoreverses = true; breath.repeatCount = .infinity
                breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                imageLayer.add(breath, forKey: "rest-breath")
            }
        } else { imageLayer.removeAnimation(forKey: "rest-breath") }
    }

    fileprivate func followLayout() {
        guard window != nil else { return }
        var ancestor = superview
        while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
        guard let scroll = ancestor as? UIScrollView else { return }
        // Scroll-view coordinates are content coordinates: scroll/keyboard
        // movement must not be mistaken for a new output line.
        let y = convert(CGPoint(x: bounds.midX, y: bounds.midY), to: scroll).y
        let now = CACurrentMediaTime()
        let elapsed = min(1.0 / 30, max(1.0 / 120, now - (previousPositionTime ?? now - 1.0 / 60)))
        previousPositionTime = now
        var displayed = displayedContentY ?? y
        if scroll.isTracking || scroll.isDragging || scroll.isDecelerating {
            displayed = y
        } else {
            // A reparse can briefly reduce layout height. Keep the visual
            // anchor steady instead of launching an opposite-direction bounce.
            displayed = DotOutputPosition.advance(displayed: displayed, target: y, elapsed: elapsed)
        }
        displayedContentY = displayed
        targetContentY = y
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.transform = CATransform3DMakeTranslation(0, displayed - y, 0)
        outgoingLayer.transform = imageLayer.transform
        CATransaction.commit()
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

    func stop() {
        loading?.cancel(); loading = nil
        idleTimer?.invalidate(); idleTimer = nil
        imageLayer.removeAllAnimations()
        outgoingLayer.removeAllAnimations()
        screenGlow.removeAllAnimations()
        positionLink?.invalidate(); positionLink = nil
    }
}

enum DotOutputPosition {
    static func advance(displayed: CGFloat, target: CGFloat, elapsed: TimeInterval) -> CGFloat {
        let destination = max(displayed, target)
        let next = displayed + (destination - displayed) * (1 - exp(-max(0, elapsed) / 0.09))
        return abs(destination - next) < 0.25 ? destination : next
    }
}

@MainActor private final class DotPositionTarget: NSObject {
    weak var surface: DotAnimationSurface?
    init(_ surface: DotAnimationSurface) { self.surface = surface }
    @objc func tick() { surface?.followLayout() }
}
