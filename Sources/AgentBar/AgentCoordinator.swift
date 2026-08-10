import AppKit
import Foundation

protocol AgentCoordinatorDelegate: AnyObject {
    func coordinatorDidUpdate(_ coordinator: AgentCoordinator)
    func coordinator(_ coordinator: AgentCoordinator, shouldPresent event: AgentCoordinator.PresentationEvent)
}

final class AgentCoordinator: AgentConnectorDelegate, SpeechControllerDelegate {
    enum PresentationEvent {
        case approval
        case completion
        case error
    }

    weak var delegate: AgentCoordinatorDelegate?

    let codex = CodexConnector()
    let codexHistory = CodexHistoryMonitor()
    let claude = ClaudeConnector()
    let speech = SpeechController()

    private(set) var selectedProvider: AgentProvider = .codex
    private(set) var activities: [AgentProvider: AgentActivity] = [
        .codex: .connecting,
        .claude: .connecting,
    ]
    private(set) var usages: [AgentProvider: UsageSnapshot] = [
        .codex: .unavailable,
        .claude: .unavailable,
    ]
    private(set) var approvals: [AgentProvider: ApprovalRequest] = [:]
    private(set) var draft = ""
    private(set) var speechError: String?
    private(set) var codexDesktopObservation = "Watching desktop tasks"

    var workingDirectory: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: "workingDirectory"),
               FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            if let path = Bundle.main.object(forInfoDictionaryKey: "AgentBarDefaultWorkspace") as? String,
               FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return FileManager.default.homeDirectoryForCurrentUser
        }
        set {
            UserDefaults.standard.set(newValue.path, forKey: "workingDirectory")
            delegate?.coordinatorDidUpdate(self)
        }
    }

    var selectedActivity: AgentActivity {
        if speech.isListening { return .working("Listening…") }
        if !draft.isEmpty { return .ready }
        return activities[selectedProvider] ?? .connecting
    }

    var selectedUsage: UsageSnapshot {
        usages[selectedProvider] ?? .unavailable
    }

    var selectedApproval: ApprovalRequest? {
        approvals[selectedProvider]
    }

    init() {
        codex.delegate = self
        claude.delegate = self
        speech.delegate = self
        codexHistory.onEvent = { [weak self] event in
            self?.handleCodexHistory(event)
        }
    }

    func start() {
        codex.start()
        codexHistory.start()
        claude.checkAuthentication()
        claude.refreshUsage()
    }

    func shutdown() {
        codex.stop()
        codexHistory.stop()
        claude.stop()
        speech.stop()
    }

    func select(_ provider: AgentProvider, activateApplication: Bool) {
        selectedProvider = provider
        if activateApplication {
            activate(provider)
        }
        delegate?.coordinatorDidUpdate(self)
    }

    func activate(_ provider: AgentProvider) {
        if let conversationURL = activeConversationURL(for: provider) {
            NSWorkspace.shared.open(conversationURL)
            return
        }

        if let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: provider.bundleIdentifier
        ).first {
            running.activate(options: [.activateIgnoringOtherApps])
            return
        }

        let path: String
        switch provider {
        case .codex: path = "/Applications/ChatGPT.app"
        case .claude: path = "/Applications/Claude.app"
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: path),
            configuration: configuration
        )
    }

    private func activeConversationURL(for provider: AgentProvider) -> URL? {
        switch provider {
        case .codex:
            guard let threadID = codex.activeThreadID else { return nil }
            return URL(string: "codex://threads/\(threadID)")
        case .claude:
            guard let sessionID = claude.activeSessionID,
                  var components = URLComponents(string: "claude://resume")
            else { return nil }
            components.queryItems = [URLQueryItem(name: "session", value: sessionID)]
            return components.url
        }
    }

    func toggleDictation() {
        speechError = nil
        speech.toggle()
        delegate?.coordinatorDidUpdate(self)
    }

    func setDraft(_ value: String) {
        draft = value
        speechError = nil
        delegate?.coordinatorDidUpdate(self)
    }

    func sendDraft() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard selectedProvider != .claude || claude.isAuthenticated else {
            activities[.claude] = .disconnected("Tap to connect Claude")
            delegate?.coordinatorDidUpdate(self)
            return
        }
        draft = ""
        switch selectedProvider {
        case .codex:
            codex.sendNewChat(prompt, workingDirectory: workingDirectory)
        case .claude:
            claude.sendNewChat(prompt, workingDirectory: workingDirectory)
        }
        delegate?.coordinatorDidUpdate(self)
    }

    func respondToSelectedApproval(approved: Bool) {
        guard let approval = selectedApproval else { return }
        if approval.requiresAppInteraction {
            activate(approval.provider)
            return
        }
        approval.respond(approved)
        approvals.removeValue(forKey: approval.provider)
        delegate?.coordinatorDidUpdate(self)
    }

    func performSelectedStatusAction() {
        if selectedApproval?.requiresAppInteraction == true {
            activate(selectedProvider)
            return
        }

        switch selectedProvider {
        case .claude where !claude.isAuthenticated:
            claude.beginSubscriptionLogin()
            delegate?.coordinatorDidUpdate(self)
        case .codex where !codex.isReady:
            codex.start()
        default:
            activate(selectedProvider)
        }
    }

    func connector(_ provider: AgentProvider, didChange activity: AgentActivity) {
        let previous = activities[provider]
        activities[provider] = activity
        if case .waitingForApproval = activity {
            selectedProvider = provider
        }
        delegate?.coordinatorDidUpdate(self)

        switch activity {
        case .completed where previous != activity:
            NSSound(named: NSSound.Name("Glass"))?.play()
            delegate?.coordinator(self, shouldPresent: .completion)
        case .failed where previous != activity:
            delegate?.coordinator(self, shouldPresent: .error)
        default:
            break
        }
    }

    func connector(_ provider: AgentProvider, didUpdate usage: UsageSnapshot) {
        usages[provider] = usage
        delegate?.coordinatorDidUpdate(self)
    }

    func connector(_ provider: AgentProvider, needs approval: ApprovalRequest) {
        approvals[provider] = approval
        selectedProvider = provider
        delegate?.coordinatorDidUpdate(self)
        delegate?.coordinator(self, shouldPresent: .approval)
    }

    func connector(_ provider: AgentProvider, didClearApproval id: String) {
        if approvals[provider]?.id == id {
            approvals.removeValue(forKey: provider)
        }
        delegate?.coordinatorDidUpdate(self)
    }

    func speechController(didUpdate transcript: String) {
        draft = transcript
        delegate?.coordinatorDidUpdate(self)
    }

    func speechControllerDidStart() {
        draft = ""
        delegate?.coordinatorDidUpdate(self)
    }

    func speechControllerDidStop(finalTranscript: String) {
        draft = finalTranscript
        delegate?.coordinatorDidUpdate(self)
    }

    func speechController(didFail message: String) {
        speechError = message
        delegate?.coordinatorDidUpdate(self)
        delegate?.coordinator(self, shouldPresent: .error)
    }

    private func handleCodexHistory(_ event: CodexHistoryMonitor.Event) {
        let threadID: String
        switch event {
        case .started(let id), .completed(let id), .interrupted(let id): threadID = id
        }
        guard threadID != codex.activeThreadID else { return }

        selectedProvider = .codex
        switch event {
        case .started:
            codexDesktopObservation = "Desktop task active"
            activities[.codex] = .working("Codex Desktop is working…")
            delegate?.coordinatorDidUpdate(self)
        case .completed:
            codexDesktopObservation = "Desktop task completed"
            connector(.codex, didChange: .completed("Codex Desktop finished"))
        case .interrupted:
            codexDesktopObservation = "Desktop task interrupted"
            connector(.codex, didChange: .failed("Codex Desktop task interrupted"))
        }
    }
}
