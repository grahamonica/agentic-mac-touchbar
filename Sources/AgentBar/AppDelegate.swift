import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let coordinator = AgentCoordinator()
    private var touchBarController: TouchBarController!
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let summaryItem = NSMenuItem(title: "Connecting…", action: nil, keyEquivalent: "")
    private let usageItem = NSMenuItem(title: "Usage —", action: nil, keyEquivalent: "")
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        touchBarController = TouchBarController(coordinator: coordinator)
        configureStatusItem()
        touchBarController.install()
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        touchBarController?.uninstall()
        coordinator.shutdown()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        touchBarController.showTouchBar()
        return true
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateMenuState()
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "AgentBar")
            button.imagePosition = .imageOnly
            button.toolTip = "AgentBar for Codex and Claude"
        }

        menu.delegate = self
        summaryItem.isEnabled = false
        usageItem.isEnabled = false
        menu.addItem(summaryItem)
        menu.addItem(usageItem)
        menu.addItem(.separator())

        let show = NSMenuItem(title: "Show Touch Bar", action: #selector(showTouchBar), keyEquivalent: "t")
        show.target = self
        menu.addItem(show)

        let codex = NSMenuItem(title: "Open Codex", action: #selector(openCodex), keyEquivalent: "1")
        codex.target = self
        menu.addItem(codex)

        let claude = NSMenuItem(title: "Open Claude", action: #selector(openClaude), keyEquivalent: "2")
        claude.target = self
        menu.addItem(claude)

        menu.addItem(.separator())

        let dictateCodex = NSMenuItem(title: "Dictate New Codex Chat", action: #selector(dictateCodex), keyEquivalent: "")
        dictateCodex.target = self
        menu.addItem(dictateCodex)

        let dictateClaude = NSMenuItem(title: "Dictate New Claude Chat", action: #selector(dictateClaude), keyEquivalent: "")
        dictateClaude.target = self
        menu.addItem(dictateClaude)

        let typeChat = NSMenuItem(title: "Type a New Chat…", action: #selector(typeNewChat), keyEquivalent: "n")
        typeChat.target = self
        menu.addItem(typeChat)

        menu.addItem(.separator())

        let folder = NSMenuItem(title: "Choose Working Folder…", action: #selector(chooseWorkingFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)

        let connectClaude = NSMenuItem(title: "Connect Claude Subscription…", action: #selector(connectClaude), keyEquivalent: "")
        connectClaude.target = self
        menu.addItem(connectClaude)

        let diagnostics = NSMenuItem(title: "Connection Diagnostics…", action: #selector(showDiagnostics), keyEquivalent: "")
        diagnostics.target = self
        menu.addItem(diagnostics)

        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit AgentBar", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        updateMenuState()
    }

    private func updateMenuState() {
        let provider = coordinator.selectedProvider
        summaryItem.title = "\(provider.rawValue): \(coordinator.selectedActivity.compactLabel)"
        usageItem.title = "\(coordinator.selectedUsage.compactLabel) · \(coordinator.workingDirectory.lastPathComponent)"
        launchAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func showTouchBar() {
        touchBarController.showTouchBar()
    }

    @objc private func openCodex() {
        coordinator.select(.codex, activateApplication: true)
    }

    @objc private func openClaude() {
        coordinator.select(.claude, activateApplication: true)
    }

    @objc private func dictateCodex() {
        coordinator.select(.codex, activateApplication: false)
        touchBarController.showTouchBar()
        coordinator.toggleDictation()
    }

    @objc private func dictateClaude() {
        coordinator.select(.claude, activateApplication: false)
        touchBarController.showTouchBar()
        coordinator.toggleDictation()
    }

    @objc private func typeNewChat() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "New \(coordinator.selectedProvider.rawValue) chat"
        alert.informativeText = "This uses the existing subscription-backed local agent session."
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 430, height: 70))
        field.placeholderString = "What should the agent do?"
        field.usesSingleLineMode = false
        field.lineBreakMode = .byWordWrapping
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        coordinator.setDraft(field.stringValue)
        coordinator.sendDraft()
        touchBarController.showTouchBar()
    }

    @objc private func chooseWorkingFolder() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Choose the folder for new Codex and Claude chats"
        panel.prompt = "Use Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = coordinator.workingDirectory
        if panel.runModal() == .OK, let url = panel.url {
            coordinator.workingDirectory = url
        }
    }

    @objc private func connectClaude() {
        coordinator.claude.beginSubscriptionLogin()
    }

    @objc private func showDiagnostics() {
        NSApp.activate(ignoringOtherApps: true)
        let codexState = coordinator.activities[.codex]?.compactLabel ?? "unknown"
        let claudeState = coordinator.activities[.claude]?.compactLabel ?? "unknown"
        let alert = NSAlert()
        alert.messageText = "AgentBar Connections"
        alert.informativeText = [
            "Touch Bar: \(touchBarController.installed ? "registered" : "unavailable")",
            "Codex: \(codexState)",
            "Claude: \(claudeState)",
            "Claude auth: \(coordinator.claude.authenticationStatus)",
            "Usage: \(coordinator.selectedUsage.compactLabel)",
            "Microphone: \(coordinator.speech.microphoneAuthorizationStatus)",
            "Speech recognition: \(coordinator.speech.speechAuthorizationStatus)",
            "Folder: \(coordinator.workingDirectory.path)",
        ].joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            showError("Launch at Login", error.localizedDescription)
        }
        updateMenuState()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showError(_ title: String, _ detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}
