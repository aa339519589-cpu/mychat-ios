import AVFoundation
import Foundation

// State is shared by response buttons, without invalidating the transcript tree.
enum SpeechPlaybackState: String {
    case idle, loading, playing, failed
    var accessibilityLabel: String {
        switch self {
        case .idle: "朗读"
        case .loading: "正在生成语音"
        case .playing: "停止朗读"
        case .failed: "重试朗读"
        }
    }
}
extension Notification.Name {
    static let myChatSpeechPlaybackDidChange = Notification.Name("mychat.speechPlaybackDidChange")
}

/// Raw signed 16-bit mono PCM arrives at arbitrary byte boundaries.
/// Decode away from the UI thread and retain a final half-sample between chunks.
struct PCMFrameDecoder {
    private var trailingByte: UInt8?
    mutating func decode(_ data: Data) -> [Float] {
        var result: [Float] = []
        result.reserveCapacity((data.count + (trailingByte == nil ? 0 : 1)) / 2)
        for byte in data {
            if let low = trailingByte {
                result.append(Float(Int16(bitPattern: UInt16(low) | UInt16(byte) << 8)) / 32768)
                trailingByte = nil
            } else { trailingByte = byte }
        }
        return result
    }
    var hasIncompleteSample: Bool { trailingByte != nil }
}

@MainActor protocol PCMPlaybackSink: AnyObject {
    var queuedSeconds: Double { get }
    var elapsedSeconds: Double { get }
    var onStarted: (() -> Void)? { get set }
    var onDrain: (() -> Void)? { get set }
    func append(_ samples: [Float]) throws
    func finish(_ completion: @escaping () -> Void)
    func stop()
}

@MainActor final class NativePCMSink: PCMPlaybackSink {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    private var queuedFrames = 0
    private var completion: (() -> Void)?
    private var startTimer: Timer?
    private var running = false
    private var generation = UUID()
    var onStarted: (() -> Void)?
    var onDrain: (() -> Void)?
    var queuedSeconds: Double { Double(queuedFrames) / 24_000 }
    var elapsedSeconds: Double {
        guard let time = node.lastRenderTime, let playerTime = node.playerTime(forNodeTime: time) else { return 0 }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }
    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }
    func append(_ samples: [Float]) throws {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { source in channel.update(from: source.baseAddress!, count: samples.count) }
        queuedFrames += samples.count
        let attempt = generation
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == attempt else { return }
                self.queuedFrames -= samples.count
                self.onDrain?()
                if self.queuedFrames == 0, let completed = self.completion {
                    self.completion = nil
                    completed()
                }
            }
        }
        if !running {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
            engine.prepare()
            try engine.start()
            node.play()
            running = true
            startTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.elapsedSeconds > 0 else { return }
                    self.startTimer?.invalidate(); self.startTimer = nil
                    self.onStarted?()
                }
            }
        }
    }
    func finish(_ completion: @escaping () -> Void) {
        if queuedFrames == 0 { completion() } else { self.completion = completion }
    }
    func stop() {
        generation = UUID()
        startTimer?.invalidate(); startTimer = nil
        completion = nil; onStarted = nil; onDrain = nil
        node.stop(); engine.stop(); queuedFrames = 0; running = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Networking/PCM decoding run on a serial background delegate queue. There is
/// no MP3 metadata request and no dependency on the end of the response.
final class PCMStreamTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var decoder = PCMFrameDecoder()
    private var totalBytes = 0
    private var validResponse = false
    private var terminal = false
    private let onSamples: @MainActor ([Float]) -> Void
    private let onEnd: @MainActor (Error?) -> Void
    private let queue = DispatchQueue(label: "mychat.tts.transport", qos: .userInitiated)
    init(request: URLRequest, configuration: URLSessionConfiguration,
         onSamples: @escaping @MainActor ([Float]) -> Void, onEnd: @escaping @MainActor (Error?) -> Void) {
        self.onSamples = onSamples; self.onEnd = onEnd
        super.init()
        let config = configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 300
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        let session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        self.session = session
        task = session.dataTask(with: request)
    }
    func start() { task?.resume() }
    func pause() { task?.suspend() }
    func resume() { task?.resume() }
    func cancel() { task?.cancel(); session?.invalidateAndCancel() }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.mimeType == "audio/pcm", http.value(forHTTPHeaderField: "X-Audio-Sample-Rate") == "24000" else {
            completionHandler(.cancel); end(PCMTransportError.invalidResponse); return
        }
        validResponse = true
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !terminal else { return }
        totalBytes += data.count
        guard totalBytes <= 20 * 1024 * 1024 else { end(PCMTransportError.tooLarge); cancel(); return }
        let samples = decoder.decode(data)
        if !samples.isEmpty { DispatchQueue.main.async { self.onSamples(samples) } }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result = error ?? (!validResponse || totalBytes == 0 || decoder.hasIncompleteSample ? PCMTransportError.invalidResponse : nil)
        end(result)
        session.finishTasksAndInvalidate()
    }
    private func end(_ error: Error?) {
        guard !terminal else { return }; terminal = true
        DispatchQueue.main.async { self.onEnd(error) }
    }
}
private enum PCMTransportError: Error { case invalidResponse, tooLarge }

@MainActor final class SpeechPlaybackController: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = SpeechPlaybackController()
    private var activeMessageID: UUID?
    private var playbackID = UUID()
    private var playbackState: SpeechPlaybackState = .idle
    private var requestTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var transport: PCMStreamTransport?
    private var sink: (any PCMPlaybackSink)?
    private var paused = false
    private var speakableText = ""
    private var synthesizer: AVSpeechSynthesizer?
    private var systemUtterance: AVSpeechUtterance?
    private let configuration: URLSessionConfiguration
    private let sinkFactory: @MainActor () -> any PCMPlaybackSink
    private let firstAudioDeadline: Duration
    private var startedAt = Date()
    private(set) var firstAudioLatencyMilliseconds: Double?
    init(streamingConfiguration: URLSessionConfiguration = .default,
         firstAudioDeadline: Duration = .seconds(4),
         sinkFactory: @escaping @MainActor () -> any PCMPlaybackSink = { NativePCMSink() }) {
        configuration = streamingConfiguration
        self.sinkFactory = sinkFactory; self.firstAudioDeadline = firstAudioDeadline
        super.init()
    }
    func state(for messageID: UUID) -> SpeechPlaybackState { activeMessageID == messageID ? playbackState : .idle }
    var elapsedPlaybackSeconds: Double { sink?.elapsedSeconds ?? 0 }
    func toggle(messageID: UUID, text: String, accessToken: @escaping @MainActor () async throws -> String) {
        if activeMessageID == messageID && playbackState != .failed { stop(); return }
        stop(); activeMessageID = messageID; startedAt = Date(); firstAudioLatencyMilliseconds = nil
        setState(.loading, for: messageID)
        let attempt = playbackID
        deadlineTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: firstAudioDeadline) } catch { return }
            guard playbackID == attempt, playbackState == .loading else { return }
            fail(messageID, message: "语音首段未在 4 秒内返回，请重试。")
        }
        requestTask = Task { [weak self] in
            guard let self else { return }
            do {
                let plain = await Task.detached(priority: .userInitiated) { Self.readableText(text) }.value
                try Task.checkCancellation()
                guard playbackID == attempt else { return }
                speakableText = plain
                guard !plain.isEmpty else { stop(); return }
                let token = try await accessToken()
                try Task.checkCancellation()
                guard playbackID == attempt else { return }
                let request = try CloudTTSClient().streamingRequest(text: plain, accessToken: token)
                let transport = PCMStreamTransport(request: request, configuration: configuration,
                    onSamples: { [weak self] samples in self?.append(samples, messageID: messageID, attempt: attempt) },
                    onEnd: { [weak self] error in self?.receivedEnd(error, messageID: messageID, attempt: attempt) })
                self.transport = transport
                transport.start()
            } catch {
                guard playbackID == attempt else { return }
                fail(messageID, message: "语音连接失败，请重试。")
            }
        }
    }
    private func append(_ samples: [Float], messageID: UUID, attempt: UUID) {
        guard playbackID == attempt, activeMessageID == messageID else { return }
        do {
            if sink == nil {
                let next = sinkFactory()
                next.onStarted = { [weak self] in
                    guard let self, self.playbackID == attempt else { return }
                    self.firstAudioLatencyMilliseconds = Date().timeIntervalSince(self.startedAt) * 1000
                    self.deadlineTask?.cancel(); self.deadlineTask = nil
                    self.setState(.playing, for: messageID)
                }
                next.onDrain = { [weak self] in
                    guard let self, self.playbackID == attempt else { return }
                    if self.paused, (self.sink?.queuedSeconds ?? 0) < 20 { self.paused = false; self.transport?.resume() }
                }
                sink = next
            }
            try sink?.append(samples)
            if !paused, (sink?.queuedSeconds ?? 0) > 30 { paused = true; transport?.pause() }
        } catch { fail(messageID, message: "无法开始音频播放，请重试。") }
    }
    private func receivedEnd(_ error: Error?, messageID: UUID, attempt: UUID) {
        guard playbackID == attempt, activeMessageID == messageID else { return }
        if error != nil { fail(messageID, message: "语音连接中断，请重试。"); return }
        guard let sink else { fail(messageID, message: "没有收到可播放的音频。"); return }
        sink.finish { [weak self] in guard self?.playbackID == attempt else { return }; self?.stop() }
    }
    func stop() {
        playbackID = UUID()
        deadlineTask?.cancel(); deadlineTask = nil; requestTask?.cancel(); requestTask = nil
        transport?.cancel(); transport = nil; sink?.stop(); sink = nil; paused = false
        synthesizer?.stopSpeaking(at: .immediate); systemUtterance = nil
        if synthesizer != nil { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        guard let messageID = activeMessageID else { return }
        activeMessageID = nil; speakableText = ""
        setState(.idle, for: messageID)
    }
    private func fail(_ messageID: UUID, message: String) {
        guard activeMessageID == messageID else { return }
        playbackID = UUID()
        deadlineTask?.cancel(); deadlineTask = nil; requestTask?.cancel(); requestTask = nil
        transport?.cancel(); transport = nil; sink?.stop(); sink = nil; paused = false
        playbackState = .failed
        NotificationCenter.default.post(name: .myChatSpeechPlaybackDidChange, object: nil,
            userInfo: ["messageID": messageID, "state": SpeechPlaybackState.failed.rawValue, "error": message])
    }
    func useSystemVoice(for messageID: UUID) {
        guard activeMessageID == messageID, !speakableText.isEmpty else { return }
        deadlineTask?.cancel(); requestTask?.cancel(); transport?.cancel(); transport = nil; sink?.stop(); sink = nil
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers]); try? session.setActive(true)
        let speech = synthesizer ?? AVSpeechSynthesizer(); synthesizer = speech; speech.delegate = self
        let utterance = AVSpeechUtterance(string: speakableText)
        utterance.voice = AVSpeechSynthesisVoice(language: speakableText.range(of: #"\p{Han}"#, options: .regularExpression) == nil ? "en-US" : "zh-CN")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        systemUtterance = utterance; setState(.playing, for: messageID); speech.speak(utterance)
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in if self.systemUtterance === utterance { self.stop() } }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in if self.systemUtterance === utterance { self.stop() } }
    }
    private func setState(_ state: SpeechPlaybackState, for messageID: UUID) {
        playbackState = state
        NotificationCenter.default.post(name: .myChatSpeechPlaybackDidChange, object: nil,
            userInfo: ["messageID": messageID, "state": state.rawValue])
    }
    nonisolated static func readableText(_ text: String) -> String {
        let visible = ChatArtifactParser.parse(text).displayText
            .replacingOccurrences(of: #"```[\s\S]*?(?:```|$)"#, with: "（代码略）", options: .regularExpression)
        return PresentationText.plain(visible)
    }
}
