import AVFoundation
import Foundation
import Speech

protocol SpeechControllerDelegate: AnyObject {
    func speechController(didUpdate transcript: String)
    func speechController(didUpdateAudioLevel level: Float)
    func speechControllerDidStart()
    func speechControllerDidStop(finalTranscript: String)
    func speechController(didFail message: String)
}

final class SpeechController {
    weak var delegate: SpeechControllerDelegate?

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var sessionGeneration = 0
    private var lastLevelUpdateTime = 0.0
    private(set) var isStarting = false
    private(set) var isListening = false
    private(set) var transcript = ""
    private(set) var audioLevel: Float = 0
    private(set) var lastErrorMessage: String?

    var microphoneAuthorizationStatus: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not requested"
        @unknown default: return "unknown"
        }
    }

    var speechAuthorizationStatus: String {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not requested"
        @unknown default: return "unknown"
        }
    }

    func toggle() {
        (isListening || isStarting) ? stop() : requestAccessAndStart()
    }

    func requestAccessAndStart() {
        guard !isStarting, !isListening else { return }
        isStarting = true
        lastErrorMessage = nil
        sessionGeneration += 1
        let generation = sessionGeneration

        if SFSpeechRecognizer.authorizationStatus() == .authorized,
           AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            start(generation: generation)
            return
        }

        SFSpeechRecognizer.requestAuthorization { [weak self] speechStatus in
            guard let self else { return }
            guard speechStatus == .authorized else {
                DispatchQueue.main.async {
                    guard self.sessionGeneration == generation else { return }
                    self.fail("Speech recognition permission is required")
                }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    guard self.sessionGeneration == generation else { return }
                    guard granted else {
                        self.fail("Microphone permission is required")
                        return
                    }
                    self.start(generation: generation)
                }
            }
        }
    }

    private func start(generation: Int) {
        guard generation == sessionGeneration, isStarting, !isListening else { return }
        guard let recognizer, recognizer.isAvailable else {
            fail("Speech recognition is unavailable")
            return
        }

        task?.cancel()
        task = nil
        transcript = ""
        audioLevel = 0
        lastLevelUpdateTime = 0

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            fail("No microphone input is available")
            return
        }

        if tapInstalled {
            inputNode.removeTap(onBus: 0)
        }
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            self?.publishAudioLevel(from: buffer, generation: generation)
        }
        tapInstalled = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            DispatchQueue.main.async {
                guard self.sessionGeneration == generation else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    self.delegate?.speechController(didUpdate: self.transcript)
                    if result.isFinal {
                        self.stop()
                        return
                    }
                }
                if let error {
                    self.fail(Self.userFacingMessage(for: error))
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isStarting = false
            isListening = true
            delegate?.speechControllerDidStart()
        } catch {
            fail(error.localizedDescription)
        }
    }

    func stop() {
        guard isStarting || isListening || tapInstalled else { return }
        let finalTranscript = transcript
        sessionGeneration += 1
        isStarting = false
        isListening = false
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        audioLevel = 0
        delegate?.speechController(didUpdateAudioLevel: 0)
        delegate?.speechControllerDidStop(finalTranscript: finalTranscript)
    }

    private func fail(_ message: String) {
        let wasActive = isStarting || isListening || tapInstalled
        if wasActive {
            stop()
        } else {
            isStarting = false
        }
        lastErrorMessage = message
        delegate?.speechController(didFail: message)
    }

    private func publishAudioLevel(
        from buffer: AVAudioPCMBuffer,
        generation: Int
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastLevelUpdateTime >= (1.0 / 15.0) else { return }
        lastLevelUpdateTime = now
        let level = Self.normalizedAudioLevel(from: buffer)
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.sessionGeneration == generation,
                  self.isListening
            else { return }
            self.audioLevel = level
            self.delegate?.speechController(didUpdateAudioLevel: level)
        }
    }

    private static func normalizedAudioLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData,
              buffer.frameLength > 0
        else { return 0 }

        let samples = channels[0]
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for index in 0..<count {
            let sample = samples[index]
            sum += sample * sample
        }
        let rootMeanSquare = sqrt(sum / Float(count))
        let decibels = 20 * log10(max(rootMeanSquare, 0.000_001))
        return min(max((decibels + 50) / 50, 0), 1)
    }

    private static func userFacingMessage(for error: Error) -> String {
        let value = error as NSError
        if value.domain == "kLSRErrorDomain", value.code == 201 {
            return "Apple Dictation is disabled in System Settings"
        }
        return value.localizedDescription
    }
}
