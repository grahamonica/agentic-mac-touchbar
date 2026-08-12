import AppKit
import Foundation
import TouchBarPrivateBridge

private enum TouchBarButtonArtwork {
    static let height: CGFloat = 30

    static func make(title: String, fillColor: NSColor, width: CGFloat) -> NSImage {
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size, flipped: false) { bounds in
            draw(title: title, fillColor: fillColor, in: bounds)
            return true
        }
        image.isTemplate = false
        return image
    }

    static func draw(title: String, fillColor: NSColor, in bounds: NSRect) {
        fillColor.setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5),
            xRadius: 6,
            yRadius: 6
        ).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
        let lineHeight = font.ascender - font.descender
        let titleRect = NSRect(
            x: bounds.minX + 6,
            y: bounds.midY - lineHeight / 2 - 1,
            width: bounds.width - 12,
            height: lineHeight + 2
        )
        (title as NSString).draw(in: titleRect, withAttributes: attributes)
    }
}

private final class RecordingLevelView: NSView {
    private var samples = Array(repeating: CGFloat(0), count: 18)

    var level: CGFloat = 0 {
        didSet {
            samples.removeFirst()
            samples.append(min(max(level, 0), 1))
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 72, height: TouchBarButtonArtwork.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let centerY = bounds.midY
        let dotBounds = NSRect(x: 2, y: centerY - 3, width: 6, height: 6)
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: dotBounds).fill()

        let startX: CGFloat = 14
        let availableWidth = max(bounds.width - startX - 2, 1)
        let spacing = availableWidth / CGFloat(max(samples.count - 1, 1))
        let maximumAmplitude = max((bounds.height - 8) / 2, 1)

        let baseline = NSBezierPath()
        baseline.move(to: NSPoint(x: startX, y: centerY))
        baseline.line(to: NSPoint(x: bounds.maxX - 2, y: centerY))
        baseline.lineWidth = 1
        NSColor.white.withAlphaComponent(0.22).setStroke()
        baseline.stroke()

        let waveform = NSBezierPath()
        for (index, sample) in samples.enumerated() {
            let x = startX + CGFloat(index) * spacing
            let amplitude = max(sample * maximumAmplitude, 0.75)
            waveform.move(to: NSPoint(x: x, y: centerY - amplitude))
            waveform.line(to: NSPoint(x: x, y: centerY + amplitude))
        }
        waveform.lineWidth = 1.5
        waveform.lineCapStyle = .round
        NSColor.systemRed.setStroke()
        waveform.stroke()
    }

    func reset() {
        samples = Array(repeating: 0, count: samples.count)
        needsDisplay = true
    }
}

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
    private let recordingLevelView = RecordingLevelView()
    private let sendButton = NSButton()
    private let approveButton = NSButton()
    private let denyButton = NSButton()
    private let minimizeButton = NSButton()
    private(set) var installed = false
    private(set) var isPresented = false
    private var launcherPressCount = 0
    private var presentationRequestCount = 0
    private var lastTouchBarAction = "none"
    private var lastPresentationTrigger = "none"
    private var lastPresentationLatencyMilliseconds = 0.0
    private var lastPresentationRequestedAt: Date?
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
            image: TouchBarButtonArtwork.make(
                title: "AI",
                fillColor: .controlAccentColor,
                width: 58
            ),
            target: self,
            action: #selector(showTouchBar)
        )
        controlButton.imageScaling = .scaleProportionallyDown
        controlButton.toolTip = "Open AgentBar"
        controlButton.setAccessibilityLabel("Open AI controls")

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
        launcherPressCount += 1
        lastTouchBarAction = "launcher"
        presentTouchBar(trigger: "launcher")
    }

    func presentTouchBar(trigger: String) {
        guard installed else { return }
        presentationRequestCount += 1
        lastPresentationTrigger = trigger
        lastPresentationRequestedAt = Date()
        let startedAt = ProcessInfo.processInfo.systemUptime
        updateUI()
        ABSetControlStripItemVisible(Identifier.controlStrip, true)
        isPresented = ABPresentSystemTouchBar(touchBar, Identifier.controlStrip, true)
        lastPresentationLatencyMilliseconds = (
            ProcessInfo.processInfo.systemUptime - startedAt
        ) * 1_000
        writeDiagnostics()
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
        didUpdateSpeechLevel level: Float
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.recordingLevelView.level = CGFloat(level)
            }
            return
        }
        recordingLevelView.level = CGFloat(level)
    }

    func coordinator(
        _ coordinator: AgentCoordinator,
        shouldPresent event: AgentCoordinator.PresentationEvent
    ) {
        autoMinimizeWorkItem?.cancel()
        let trigger: String
        switch event {
        case .approval: trigger = "approval"
        case .completion: trigger = "completion"
        case .error: trigger = "error"
        }
        presentTouchBar(trigger: trigger)
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
        providerControl.appearance = NSAppearance(named: .darkAqua)
        providerControl.setWidth(72, forSegment: 0)
        providerControl.setWidth(72, forSegment: 1)

        statusButton.title = "Connecting…"
        statusButton.target = self
        statusButton.action = #selector(statusPressed)
        statusButton.lineBreakMode = .byTruncatingTail
        styleButton(
            statusButton,
            title: statusButton.title,
            color: NSColor.white.withAlphaComponent(0.16),
            width: 260
        )

        usageLabel.alignment = .center
        usageLabel.textColor = .white
        usageLabel.font = .systemFont(ofSize: 11, weight: .medium)

        microphoneButton.title = "Mic"
        microphoneButton.target = self
        microphoneButton.action = #selector(microphonePressed)
        styleButton(
            microphoneButton,
            title: microphoneButton.title,
            color: NSColor.white.withAlphaComponent(0.18),
            width: 72
        )
        microphoneButton.toolTip = "Dictate a new chat; tap again to stop"
        microphoneButton.setAccessibilityLabel("Dictate new chat")

        recordingLevelView.isHidden = true
        recordingLevelView.setAccessibilityLabel("Live microphone level")

        sendButton.title = "Send"
        sendButton.target = self
        sendButton.action = #selector(sendPressed)
        styleButton(sendButton, title: sendButton.title, color: .controlAccentColor, width: 62)

        approveButton.title = "Allow"
        approveButton.target = self
        approveButton.action = #selector(approvePressed)
        styleButton(approveButton, title: approveButton.title, color: .systemGreen, width: 62)

        denyButton.title = "Deny"
        denyButton.target = self
        denyButton.action = #selector(denyPressed)
        styleButton(denyButton, title: denyButton.title, color: .systemRed, width: 55)

        minimizeButton.title = "Exit"
        minimizeButton.target = self
        minimizeButton.action = #selector(minimizePressed)
        styleButton(minimizeButton, title: minimizeButton.title, color: .systemGray, width: 64)
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
            recordingLevelView,
            sendButton,
            denyButton,
            approveButton,
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)
        stack.appearance = NSAppearance(named: .darkAqua)

        minimizeButton.widthAnchor.constraint(equalToConstant: 64).isActive = true
        providerControl.widthAnchor.constraint(equalToConstant: 148).isActive = true
        statusButton.widthAnchor.constraint(equalToConstant: 260).isActive = true
        usageLabel.widthAnchor.constraint(equalToConstant: 100).isActive = true
        microphoneButton.widthAnchor.constraint(equalToConstant: 72).isActive = true
        recordingLevelView.widthAnchor.constraint(equalToConstant: 72).isActive = true
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
        let microphoneIsActive = coordinator.speech.isStarting || coordinator.speech.isListening
        microphoneButton.isHidden = false
        microphoneButton.title = microphoneIsActive ? "Stop" : "Mic"
        styleButton(
            microphoneButton,
            title: microphoneButton.title,
            color: microphoneIsActive ? .systemRed : NSColor.white.withAlphaComponent(0.18),
            width: 72
        )
        microphoneButton.toolTip = microphoneIsActive
            ? "Stop dictation"
            : "Dictate a new chat; tap again to stop"
        microphoneButton.setAccessibilityLabel(
            microphoneIsActive ? "Stop dictation" : "Dictate new chat"
        )
        recordingLevelView.isHidden = !coordinator.speech.isListening
        if !coordinator.speech.isListening {
            recordingLevelView.reset()
        }

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
        styleButton(
            statusButton,
            title: statusButton.title,
            color: NSColor.white.withAlphaComponent(0.16),
            width: 260
        )
        if coordinator.selectedProvider == .claude && !coordinator.claude.isAuthenticated {
            statusButton.toolTip = "Connect the Claude.ai subscription"
        } else if coordinator.selectedApproval?.requiresAppInteraction == true {
            statusButton.toolTip = "Open the app to answer"
        } else {
            statusButton.toolTip = "Open \(coordinator.selectedProvider.rawValue)"
        }
        sendButton.isEnabled = !coordinator.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if let button = controlStripItem.view as? NSButton {
            let title: String
            let color: NSColor
            if coordinator.approvals.isEmpty {
                title = "AI"
                color = .controlAccentColor
            } else {
                title = "AI!"
                color = .systemOrange
            }
            button.image = TouchBarButtonArtwork.make(title: title, fillColor: color, width: 58)
        }
        writeDiagnostics()
    }

    private func styleButton(
        _ button: NSButton,
        title: String,
        color: NSColor,
        width: CGFloat
    ) {
        button.title = title
        button.image = TouchBarButtonArtwork.make(title: title, fillColor: color, width: width)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .texturedRounded
        button.bezelColor = color
        button.frame = NSRect(x: 0, y: 0, width: width, height: TouchBarButtonArtwork.height)
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
            "touchBarExpectedControls": [
                "Exit", "Codex", "Claude", "Mic/Stop", "Recording level", "Send",
            ],
            "touchBarExitVisible": !minimizeButton.isHidden,
            "touchBarPresentationMode": ABTouchBarPresentationMode() ?? "systemDefault",
            "touchBarRendering": "touchBarImageButton",
            "touchBarLauncherPressCount": launcherPressCount,
            "touchBarPresentationRequestCount": presentationRequestCount,
            "lastTouchBarAction": lastTouchBarAction,
            "lastTouchBarPresentationTrigger": lastPresentationTrigger,
            "lastTouchBarPresentationLatencyMilliseconds": lastPresentationLatencyMilliseconds,
            "lastTouchBarPresentationRequestedAt": lastPresentationRequestedAt.map {
                ISO8601DateFormatter().string(from: $0)
            } ?? NSNull(),
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
            "microphoneStarting": coordinator.speech.isStarting,
            "microphoneAudioLevel": coordinator.speechLevel,
            "microphoneLastError": coordinator.speech.lastErrorMessage.map { $0 as Any } ?? NSNull(),
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
        lastTouchBarAction = "provider"
        let provider: AgentProvider = providerControl.selectedSegment == 0 ? .codex : .claude
        coordinator.select(provider, activateApplication: true)
        // Activating the selected desktop app can make macOS replace this
        // system-modal Touch Bar with that app's bar. Re-present immediately
        // and once more after LaunchServices finishes the activation so Mic
        // and Send remain available over both Codex and Claude.
        presentTouchBar(trigger: "providerChange")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.presentTouchBar(trigger: "providerChangeFollowUp")
        }
    }

    @objc private func statusPressed() {
        lastTouchBarAction = "status"
        coordinator.performSelectedStatusAction()
    }

    @objc private func microphonePressed() {
        lastTouchBarAction = "microphone"
        coordinator.toggleDictation()
    }

    @objc private func sendPressed() {
        lastTouchBarAction = "send"
        coordinator.sendDraft()
    }

    @objc private func approvePressed() {
        lastTouchBarAction = "approve"
        coordinator.respondToSelectedApproval(approved: true)
    }

    @objc private func denyPressed() {
        lastTouchBarAction = "deny"
        coordinator.respondToSelectedApproval(approved: false)
    }

    @objc private func minimizePressed() {
        lastTouchBarAction = "exit"
        minimize()
    }

    private func reassertControlStripPresence() {
        guard installed else { return }
        ABSetControlStripItemVisible(Identifier.controlStrip, true)
        writeDiagnostics()
    }
}
