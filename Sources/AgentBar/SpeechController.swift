import AVFoundation
import Foundation
import Speech

protocol SpeechControllerDelegate: AnyObject {
    func speechController(didUpdate transcript: String)
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
    private(set) var isListening = false
    private(set) var transcript = ""

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
        isListening ? stop() : requestAccessAndStart()
    }

    func requestAccessAndStart() {
        SFSpeechRecognizer.requestAuthorization { [weak self] speechStatus in
            guard let self else { return }
            guard speechStatus == .authorized else {
                DispatchQueue.main.async {
                    self.delegate?.speechController(didFail: "Speech recognition permission is required")
                }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    guard granted else {
                        self.delegate?.speechController(didFail: "Microphone permission is required")
                        return
                    }
                    self.start()
                }
            }
        }
    }

    func start() {
        guard !isListening else { return }
        guard let recognizer, recognizer.isAvailable else {
            delegate?.speechController(didFail: "Speech recognition is unavailable")
            return
        }

        task?.cancel()
        task = nil
        transcript = ""

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13, *) {
            request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        }
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            delegate?.speechController(didFail: "No microphone input is available")
            return
        }

        if tapInstalled {
            inputNode.removeTap(onBus: 0)
        }
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            request.append(buffer)
        }
        tapInstalled = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.transcript = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    self.delegate?.speechController(didUpdate: self.transcript)
                }
                if result.isFinal {
                    DispatchQueue.main.async { self.stop() }
                }
            }
            if error != nil {
                DispatchQueue.main.async { self.stop() }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
            delegate?.speechControllerDidStart()
        } catch {
            stop()
            delegate?.speechController(didFail: error.localizedDescription)
        }
    }

    func stop() {
        guard isListening || tapInstalled else { return }
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
        isListening = false
        delegate?.speechControllerDidStop(finalTranscript: transcript)
    }
}
