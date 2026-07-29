import AVFoundation
import Speech

enum SpeechPhase: Equatable {
    case idle
    case preparing
    case recording
    case transcribing
    case ready

    var isActive: Bool {
        self == .preparing || self == .recording || self == .transcribing
    }
}

@MainActor
final class SpeechInput: ObservableObject {
    @Published private(set) var phase: SpeechPhase = .idle
    @Published private(set) var audioLevel: CGFloat = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var transcript = ""
    @Published var error: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var clockTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var recordingStartedAt: Date?
    private var tapInstalled = false

    var isRecording: Bool {
        phase == .recording
    }

    func toggle() async {
        switch phase {
        case .recording:
            finish()
        case .preparing, .transcribing:
            break
        case .idle, .ready:
            do {
                try await start()
            } catch {
                self.error = error.localizedDescription
                cancel()
            }
        }
    }

    func finish() {
        guard phase == .recording else { return }
        phase = .transcribing
        stopClock()
        stopAudioCapture()
        request?.endAudio()
        audioLevel = 0

        completionTask?.cancel()
        completionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled, let self, self.phase == .transcribing else { return }
            self.completeTranscription()
        }
    }

    func cancel() {
        completionTask?.cancel()
        completionTask = nil
        stopClock()
        stopAudioCapture()
        request?.endAudio()
        recognitionTask?.cancel()
        request = nil
        recognitionTask = nil
        recordingStartedAt = nil
        elapsed = 0
        audioLevel = 0
        phase = .idle
        transcript = ""
        deactivateAudioSession()
    }

    func consumeTranscript() -> String {
        let value = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript = ""
        phase = .idle
        elapsed = 0
        return value
    }

    private func start() async throws {
        cancel()
        phase = .preparing

        guard await speechPermission() == .authorized else {
            throw APIError.message("请在系统设置中允许语音识别")
        }
        guard await microphonePermission() else {
            throw APIError.message("请在系统设置中允许使用麦克风")
        }
        guard let recognizer, recognizer.isAvailable else {
            throw APIError.message("语音识别暂时不可用")
        }

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let level = Self.normalizedLevel(buffer)
            Task { @MainActor [weak self] in
                guard self?.phase == .recording else { return }
                self?.audioLevel = level
            }
        }
        tapInstalled = true

        audioEngine.prepare()
        try audioEngine.start()
        recordingStartedAt = Date()
        elapsed = 0
        phase = .recording
        startClock()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.completeTranscription()
                    }
                    return
                }
                if let error {
                    if self.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.error = error.localizedDescription
                        self.cancel()
                    } else {
                        self.completeTranscription()
                    }
                }
            }
        }
    }

    private func completeTranscription() {
        completionTask?.cancel()
        completionTask = nil
        stopClock()
        stopAudioCapture()
        request = nil
        recognitionTask = nil
        recordingStartedAt = nil
        audioLevel = 0
        phase = transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .idle : .ready
        deactivateAudioSession()
    }

    private func startClock() {
        clockTask?.cancel()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard !Task.isCancelled, let self, let started = self.recordingStartedAt else { return }
                self.elapsed = Date().timeIntervalSince(started)
            }
        }
    }

    private func stopClock() {
        clockTask?.cancel()
        clockTask = nil
    }

    private func stopAudioCapture() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated private static func normalizedLevel(_ buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let samples = buffer.floatChannelData?.pointee else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<count {
            let sample = samples[index]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(count))
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return CGFloat(min(max((decibels + 52) / 52, 0), 1))
    }

    private func speechPermission() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    private func microphonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission {
                continuation.resume(returning: $0)
            }
        }
    }
}
