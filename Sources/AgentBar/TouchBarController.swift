import AppKit
import Foundation
import TouchBarPrivateBridge

final class TouchBarController: NSObject, NSTouchBarDelegate, AgentCoordinatorDelegate {
    private enum Identifier {
        static let controlStrip = NSTouchBarItem.Identifier("com.monicagraham.AgentBar.controlStrip")
        static let main = NSTouchBarItem.Identifier("com.monicagraham.AgentBar.main")
    }

    private let coordinator: AgentCoordinator
    private let touchBar = NSTouchBar()
    private let controlStripItem = NSCustomTouchBarItem(identifier: Identifier.controlStrip)
    private let providerControl: NSSegmentedControl
    private let statusButton = NSButton()
    private let usageLabel = NSTextField(labelWithString: "Usage —")
    private let microphoneButton = NSButton()
    private let sendButton = NSButton()
    private let approveButton = NSButton()
    private let denyButton = NSButton()
    private let minimizeButton = NSButton()
    private(set) var installed = false
    private(set) var isPresented = false
    private var autoMinimizeWorkItem: DispatchWorkItem?
    private var controlStripRecoveryTimer: Timer?
    private var installPending = false
    private var previousPresentationMode: String?
    private var changedPresentationMode = false
    private let managedPresentationModeKey = "managesTouchBarPresentationMode"
    private let previousPresentationModeKey = "previousTouchBarPresentationMode"
    private let systemDefaultPresentationMode = "__systemDefault__"

    init(coordinator: AgentCoordinator) {
        self.coordinator = coordinator
        providerControl = NSSegmentedControl(
            labels: ["Codex", "Claude"],
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
        super.init()
        coordinator.delegate = self
        configureTouchBar()
    }

    func install() {
        guard !installed, !installPending else { return }
        installPending = true
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: managedPresentationModeKey) {
            let stored = defaults.string(forKey: previousPresentationModeKey)
            previousPresentationMode = stored == systemDefaultPresentationMode ? nil : stored
        } else {
            previousPresentationMode = ABTouchBarPresentationMode()
            defaults.set(
                previousPresentationMode ?? systemDefaultPresentationMode,
                forKey: previousPresentationModeKey
            )
            defaults.set(true, forKey: managedPresentationModeKey)
        }
        changedPresentationMode = true
        let presentationNeedsReload = ABSetTouchBarPresentationMode("appWithControlStrip")
        guard presentationNeedsReload else {
            finishInstallation()
            return
        }

        ABRestartControlStrip()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.finishInstallation()
        }
    }

    private func finishInstallation() {
        guard installPending else { return }
        installPending = false
        let controlButton = NSButton(
            title: "AI",
            image: NSImage(
                systemSymbolName: "sparkles",
                accessibilityDescription: "Open AI controls"
            ) ?? NSImage(),
            target: self,
            action: #selector(showTouchBar)
        )
        controlButton.imagePosition = .imageLeading
        controlButton.bezelStyle = .texturedRounded
        controlButton.bezelColor = .controlAccentColor
        controlButton.toolTip = "Open AgentBar"
        controlButton.setAccessibilityLabel("Open AI controls")
        controlButton.frame = NSRect(x: 0, y: 0, width: 58, height: 30)
        controlStripItem.view = controlButton
        controlStripItem.customizationLabel = "AI"
        controlStripItem.visibilityPriority = .high
        installed = ABInstallControlStripItem(controlStripItem)
        if !installed {
            coordinator.connector(.codex, didChange: .failed("Touch Bar private controls are unavailable"))
        }
        reassertControlStripPresence()
        controlStripRecoveryTimer = Timer.scheduledTimer(
            withTimeInterval: 5,
            repeats: true
        ) { [weak self] _ in
            self?.reassertControlStripPresence()
        }
        updateUI()
    }

    func uninstall() {
        autoMinimizeWorkItem?.cancel()
        installPending = false
        controlStripRecoveryTimer?.invalidate()
        controlStripRecoveryTimer = nil
        if installed {
            ABRemoveControlStripItem(controlStripItem)
        }
        installed = false
        isPresented = false
        if changedPresentationMode,
           ABTouchBarPresentationMode() == "appWithControlStrip" {
            _ = ABSetTouchBarPresentationMode(previousPresentationMode)
            ABRestartControlStrip()
        }
        UserDefaults.standard.removeObject(forKey: managedPresentationModeKey)
        UserDefaults.standard.removeObject(forKey: previousPresentationModeKey)
        changedPresentationMode = false
    }

    @objc func showTouchBar() {
        guard installed else { return }
        updateUI()
        ABSetControlStripItemVisible(Identifier.controlStrip, true)
        isPresented = ABPresentSystemTouchBar(touchBar, Identifier.controlStrip, true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.updateUI()
        }
    }

    func minimize() {
        ABMinimizeSystemTouchBar(touchBar)
        isPresented = false
        reassertControlStripPresence()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.updateUI()
        }
    }

    func touchBar(
        _ touchBar: NSTouchBar,
        makeItemForIdentifier identifier: NSTouchBarItem.Identifier
    ) -> NSTouchBarItem? {
        guard identifier == Identifier.main else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = makeMainView()
        item.customizationLabel = "Codex and Claude controls"
        return item
    }

    func coordinatorDidUpdate(_ coordinator: AgentCoordinator) {
        updateUI()
    }

    func coordinator(
        _ coordinator: AgentCoordinator,
        shouldPresent event: AgentCoordinator.PresentationEvent
    ) {
        autoMinimizeWorkItem?.cancel()
        showTouchBar()
        guard event != .approval else { return }
        let work = DispatchWorkItem { [weak self] in self?.minimize() }
        autoMinimizeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: work)
    }

    private func configureTouchBar() {
        touchBar.delegate = self
        touchBar.customizationIdentifier = NSTouchBar.CustomizationIdentifier("com.monicagraham.AgentBar")
        touchBar.defaultItemIdentifiers = [Identifier.main]
        touchBar.customizationAllowedItemIdentifiers = [Identifier.main]

        providerControl.target = self
        providerControl.action = #selector(providerChanged)
        providerControl.selectedSegment = 0
        providerControl.setWidth(72, forSegment: 0)
        providerControl.setWidth(72, forSegment: 1)

        statusButton.title = "Connecting…"
        statusButton.target = self
        statusButton.action = #selector(statusPressed)
        statusButton.bezelStyle = .texturedRounded
        statusButton.lineBreakMode = .byTruncatingTail

        usageLabel.alignment = .center
        usageLabel.textColor = .secondaryLabelColor
        usageLabel.font = .systemFont(ofSize: 11, weight: .medium)

        microphoneButton.title = "Mic"
        microphoneButton.image = NSImage(
            systemSymbolName: "mic.fill",
            accessibilityDescription: "Dictate a new chat"
        )
        microphoneButton.imagePosition = .imageLeading
        microphoneButton.target = self
        microphoneButton.action = #selector(microphonePressed)
        microphoneButton.bezelStyle = .texturedRounded
        microphoneButton.toolTip = "Dictate a new chat; tap again to stop"
        microphoneButton.setAccessibilityLabel("Dictate new chat")

        sendButton.title = "Send"
        sendButton.target = self
        sendButton.action = #selector(sendPressed)
        sendButton.bezelColor = .controlAccentColor

        approveButton.title = "Allow"
        approveButton.target = self
        approveButton.action = #selector(approvePressed)
        approveButton.bezelColor = .systemGreen

        denyButton.title = "Deny"
        denyButton.target = self
        denyButton.action = #selector(denyPressed)
        denyButton.bezelColor = .systemRed

        minimizeButton.title = "Exit"
        minimizeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Exit AI controls"
        )
        minimizeButton.imagePosition = .imageLeading
        minimizeButton.target = self
        minimizeButton.action = #selector(minimizePressed)
        minimizeButton.bezelStyle = .texturedRounded
        minimizeButton.toolTip = "Exit AgentBar and restore normal Touch Bar controls"
        minimizeButton.setAccessibilityLabel("Exit AI controls")
    }

    private func makeMainView() -> NSView {
        let stack = NSStackView(views: [
            minimizeButton,
            providerControl,
            statusButton,
            usageLabel,
            microphoneButton,
            sendButton,
            denyButton,
            approveButton,
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)

        minimizeButton.widthAnchor.constraint(equalToConstant: 64).isActive = true
        providerControl.widthAnchor.constraint(equalToConstant: 148).isActive = true
        statusButton.widthAnchor.constraint(equalToConstant: 260).isActive = true
        usageLabel.widthAnchor.constraint(equalToConstant: 100).isActive = true
        microphoneButton.widthAnchor.constraint(equalToConstant: 72).isActive = true
        sendButton.widthAnchor.constraint(equalToConstant: 62).isActive = true
        approveButton.widthAnchor.constraint(equalToConstant: 62).isActive = true
        denyButton.widthAnchor.constraint(equalToConstant: 55).isActive = true
        return stack
    }

    private func updateUI() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.updateUI() }
            return
        }
        providerControl.selectedSegment = coordinator.selectedProvider == .codex ? 0 : 1
        usageLabel.stringValue = coordinator.selectedUsage.compactLabel
        microphoneButton.isHidden = false
        microphoneButton.title = coordinator.speech.isListening ? "Stop" : "Mic"
        microphoneButton.image = NSImage(
            systemSymbolName: coordinator.speech.isListening ? "stop.fill" : "mic.fill",
            accessibilityDescription: coordinator.speech.isListening ? "Stop dictation" : "Dictate a new chat"
        )

        let approval = coordinator.selectedApproval
        let canAnswer = approval != nil && approval?.requiresAppInteraction == false
        denyButton.isHidden = !canAnswer
        approveButton.isHidden = !canAnswer

        if let error = coordinator.speechError {
            statusButton.title = "⚠ \(error)"
        } else if coordinator.speech.isListening {
            statusButton.title = coordinator.draft.isEmpty ? "Listening…" : coordinator.draft
        } else if !coordinator.draft.isEmpty {
            statusButton.title = coordinator.draft
        } else if let approval {
            statusButton.title = "⚠ \(approval.detail)"
        } else {
            statusButton.title = coordinator.selectedActivity.compactLabel
        }
        if coordinator.selectedProvider == .claude && !coordinator.claude.isAuthenticated {
            statusButton.toolTip = "Connect the Claude.ai subscription"
        } else if coordinator.selectedApproval?.requiresAppInteraction == true {
            statusButton.toolTip = "Open the app to answer"
        } else {
            statusButton.toolTip = "Open \(coordinator.selectedProvider.rawValue)"
        }
        sendButton.isEnabled = !coordinator.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if let button = controlStripItem.view as? NSButton {
            if coordinator.approvals.isEmpty {
                button.title = "AI"
                button.contentTintColor = nil
            } else {
                button.title = "AI!"
                button.contentTintColor = .systemOrange
            }
        }
        writeDiagnostics()
    }

    private func writeDiagnostics() {
        let usage = coordinator.selectedUsage
        let codexUsage = coordinator.usages[.codex] ?? .unavailable
        let claudeUsage = coordinator.usages[.claude] ?? .unavailable
        let payload: [String: Any] = [
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "touchBarControlStripRegistered": installed,
            "touchBarLayout": "fullWidth",
            "touchBarPresented": isPresented,
            "touchBarButtonTitles": ABTouchBarButtonTitles(),
            "touchBarExpectedControls": ["Exit", "Codex", "Claude", "Mic", "Send"],
            "touchBarExitVisible": !minimizeButton.isHidden,
            "touchBarPresentationMode": ABTouchBarPresentationMode() ?? "systemDefault",
            "selectedProvider": coordinator.selectedProvider.rawValue,
            "workingDirectory": coordinator.workingDirectory.path,
            "codex": [
                "transport": "codex app-server",
                "connected": coordinator.codex.isReady,
                "status": coordinator.activities[.codex]?.compactLabel ?? "unknown",
                "desktopObserver": coordinator.codexDesktopObservation,
                "activeThreadAvailable": coordinator.codex.activeThreadID != nil,
                "approvalPending": coordinator.approvals[.codex] != nil,
                "usage": Self.usageDiagnostics(codexUsage),
            ],
            "claude": [
                "transport": "Claude Desktop bundled CLI",
                "authenticated": coordinator.claude.isAuthenticated,
                "authentication": coordinator.claude.authenticationStatus,
                "status": coordinator.activities[.claude]?.compactLabel ?? "unknown",
                "activeSessionAvailable": coordinator.claude.activeSessionID != nil,
                "approvalPending": coordinator.approvals[.claude] != nil,
                "usage": Self.usageDiagnostics(claudeUsage),
            ],
            "selectedUsage": [
                "primaryUsedPercent": usage.primaryUsedPercent.map { $0 as Any } ?? NSNull(),
                "secondaryUsedPercent": usage.secondaryUsedPercent.map { $0 as Any } ?? NSNull(),
                "planName": usage.planName.map { $0 as Any } ?? NSNull(),
                "stale": usage.isStale,
            ],
            "microphoneListening": coordinator.speech.isListening,
            "microphoneControlVisible": !microphoneButton.isHidden,
            "microphoneControlLabel": microphoneButton.title,
            "microphoneAuthorization": coordinator.speech.microphoneAuthorizationStatus,
            "speechRecognitionAuthorization": coordinator.speech.speechAuthorizationStatus,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        else { return }

        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("status.json"), options: .atomic)
    }

    private static func usageDiagnostics(_ usage: UsageSnapshot) -> [String: Any] {
        [
            "primaryUsedPercent": usage.primaryUsedPercent.map { $0 as Any } ?? NSNull(),
            "secondaryUsedPercent": usage.secondaryUsedPercent.map { $0 as Any } ?? NSNull(),
            "planName": usage.planName.map { $0 as Any } ?? NSNull(),
            "stale": usage.isStale,
        ]
    }

    @objc private func providerChanged() {
        let provider: AgentProvider = providerControl.selectedSegment == 0 ? .codex : .claude
        coordinator.select(provider, activateApplication: true)
        // Activating the selected desktop app can make macOS replace this
        // system-modal Touch Bar with that app's bar. Re-present immediately
        // and once more after LaunchServices finishes the activation so Mic
        // and Send remain available over both Codex and Claude.
        showTouchBar()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.showTouchBar()
        }
    }

    @objc private func statusPressed() {
        coordinator.performSelectedStatusAction()
    }

    @objc private func microphonePressed() {
        coordinator.toggleDictation()
    }

    @objc private func sendPressed() {
        coordinator.sendDraft()
    }

    @objc private func approvePressed() {
        coordinator.respondToSelectedApproval(approved: true)
    }

    @objc private func denyPressed() {
        coordinator.respondToSelectedApproval(approved: false)
    }

    @objc private func minimizePressed() {
        minimize()
    }

    private func reassertControlStripPresence() {
        guard installed else { return }
        ABSetControlStripItemVisible(Identifier.controlStrip, true)
        writeDiagnostics()
    }
}
