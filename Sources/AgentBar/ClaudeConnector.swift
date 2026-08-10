import AppKit
import Foundation

final class ClaudeConnector {
    weak var delegate: AgentConnectorDelegate?

    private var process: JSONLineProcess?
    private var usageProcess: JSONLineProcess?
    private var usageInitializeID: String?
    private var usageRequestID: String?
    private var activeApproval: (id: String, request: [String: Any])?
    private var assistantText = ""
    private var usageTimer: Timer?
    private var usageTimeoutWorkItem: DispatchWorkItem?
    private var loginPollTimer: Timer?
    private var loginPollingUntil: Date?
    private var authenticationCheckInFlight = false
    private(set) var authenticationStatus = "Checking subscription…"
    private(set) var isAuthenticated = false
    private(set) var activeSessionID: String?
    private(set) var subscriptionPlanName: String?

    init() {
        refreshUsage()
        DispatchQueue.main.async { [weak self] in
            self?.usageTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                guard let self else { return }
                if !self.isAuthenticated {
                    self.checkAuthentication()
                }
                self.refreshUsage()
            }
        }
    }

    deinit {
        stop()
    }

    func stop() {
        usageTimer?.invalidate()
        usageTimer = nil
        usageTimeoutWorkItem?.cancel()
        usageTimeoutWorkItem = nil
        loginPollTimer?.invalidate()
        loginPollTimer = nil
        process?.stop()
        process = nil
        usageProcess?.stop()
        usageProcess = nil
    }

    func checkAuthentication() {
        guard !authenticationCheckInFlight else { return }
        authenticationCheckInFlight = true
        notifyActivity(.connecting)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                let executable = try Self.findExecutable()
                let process = Process()
                let output = Pipe()
                process.executableURL = executable
                process.arguments = ["auth", "status", "--json"]
                process.standardOutput = output
                process.standardError = Pipe()
                try process.run()
                process.waitUntilExit()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let loggedIn = object?["loggedIn"] as? Bool == true
                let method = object?["authMethod"] as? String ?? ""
                let subscriptionType = object?["subscriptionType"] as? String
                DispatchQueue.main.async {
                    let becameAuthenticated = !self.isAuthenticated && loggedIn
                    self.authenticationCheckInFlight = false
                    self.isAuthenticated = loggedIn
                    self.subscriptionPlanName = subscriptionType
                    if loggedIn {
                        self.stopLoginPolling()
                        self.authenticationStatus = "Connected through \(method)"
                    } else if self.loginPollingUntil != nil {
                        self.authenticationStatus = "Waiting for Claude subscription sign-in…"
                    } else {
                        self.authenticationStatus = "Claude subscription sign-in needed"
                    }
                    self.delegate?.connector(
                        .claude,
                        didChange: loggedIn
                            ? .ready
                            : (self.loginPollingUntil != nil
                                ? .connecting
                                : .disconnected("Connect Claude"))
                    )
                    if becameAuthenticated {
                        self.refreshUsage()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.authenticationCheckInFlight = false
                }
                self.notifyActivity(.failed(error.localizedDescription))
            }
        }
    }

    func sendNewChat(_ prompt: String, workingDirectory: URL) {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard isAuthenticated else {
            notifyActivity(.disconnected("Tap to connect Claude"))
            return
        }

        process?.stop()
        assistantText = ""
        activeApproval = nil
        activeSessionID = nil
        notifyActivity(.working("Claude is working…"))

        do {
            let stream = JSONLineProcess()
            stream.onMessage = { [weak self] message in
                self?.handle(message)
            }
            stream.onTermination = { [weak self, weak stream] status, errorText in
                guard let self, let stream, self.process === stream, status != 0 else { return }
                let detail = errorText.isEmpty ? "Claude disconnected (\(status))" : errorText
                self.notifyActivity(.failed(detail))
            }
            try stream.start(
                executable: try Self.findExecutable(),
                arguments: [
                    "-p",
                    "--input-format", "stream-json",
                    "--output-format", "stream-json",
                    "--verbose",
                    "--replay-user-messages",
                    "--permission-mode", "manual",
                    "--permission-prompt-tool", "stdio",
                ],
                currentDirectory: workingDirectory
            )
            process = stream
            try stream.send([
                "type": "user",
                "message": [
                    "role": "user",
                    "content": [["type": "text", "text": trimmed]],
                ],
                "parent_tool_use_id": NSNull(),
            ])
        } catch {
            notifyActivity(.failed(error.localizedDescription))
        }
    }

    func beginSubscriptionLogin() {
        do {
            if isAuthenticated {
                authenticationStatus = "Connected through Claude.ai subscription"
                notifyActivity(.ready)
                return
            }
            isAuthenticated = false
            authenticationStatus = "Claude.ai sign-in opened in Terminal"
            let executable = try Self.findExecutable()
            let command = "\(Self.shellQuoted(executable.path)) auth login --claudeai"
            let source = """
            tell application "Terminal"
                activate
                do script \(Self.appleScriptQuoted(command))
            end tell
            """
            guard let script = NSAppleScript(source: source) else {
                throw AgentBarError.processLaunchFailed("Could not create the Terminal login command")
            }
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            if let error {
                throw AgentBarError.processLaunchFailed(error.description)
            }
            notifyActivity(.working("Finish Claude.ai sign-in in the browser"))
            startLoginPolling()
        } catch {
            notifyActivity(.failed(error.localizedDescription))
        }
    }

    private func startLoginPolling() {
        loginPollTimer?.invalidate()
        loginPollingUntil = Date().addingTimeInterval(10 * 60)
        let timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            guard let deadline = self.loginPollingUntil, Date() < deadline else {
                self.stopLoginPolling()
                self.authenticationStatus = "Claude subscription sign-in needed"
                self.delegate?.connector(.claude, didChange: .disconnected("Connect Claude"))
                return
            }
            self.checkAuthentication()
        }
        loginPollTimer = timer
        timer.fire()
    }

    private func stopLoginPolling() {
        loginPollTimer?.invalidate()
        loginPollTimer = nil
        loginPollingUntil = nil
    }

    func refreshUsage() {
        guard usageProcess?.isRunning != true else { return }
        do {
            let stream = JSONLineProcess()
            let initializeID = UUID().uuidString
            let requestID = UUID().uuidString
            usageInitializeID = initializeID
            usageRequestID = requestID
            stream.onMessage = { [weak self, weak stream] message in
                self?.handleUsageMessage(message, stream: stream)
            }
            stream.onTermination = { [weak self, weak stream] _, _ in
                guard let self, let stream, self.usageProcess === stream else { return }
                self.usageProcess = nil
                if self.usageTimeoutWorkItem?.isCancelled == false {
                    self.usageTimeoutWorkItem?.cancel()
                    self.usageTimeoutWorkItem = nil
                    self.refreshUsageFromDesktopCache()
                }
            }
            try stream.start(
                executable: try Self.findExecutable(),
                arguments: [
                    "-p",
                    "--input-format", "stream-json",
                    "--output-format", "stream-json",
                    "--verbose",
                    "--permission-prompt-tool", "stdio",
                ],
                currentDirectory: FileManager.default.homeDirectoryForCurrentUser
            )
            usageProcess = stream
            try stream.send([
                "type": "control_request",
                "request_id": initializeID,
                "request": ["subtype": "initialize"],
            ])
            let timeout = DispatchWorkItem { [weak self, weak stream] in
                guard let self, let stream, self.usageProcess === stream else { return }
                stream.stop()
                self.usageProcess = nil
                self.usageTimeoutWorkItem = nil
                self.refreshUsageFromDesktopCache()
            }
            usageTimeoutWorkItem?.cancel()
            usageTimeoutWorkItem = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
        } catch {
            usageProcess?.stop()
            usageProcess = nil
            refreshUsageFromDesktopCache()
        }
    }

    private func handleUsageMessage(_ message: [String: Any], stream: JSONLineProcess?) {
        guard message["type"] as? String == "control_response",
              let response = message["response"] as? [String: Any],
              response["subtype"] as? String == "success",
              let requestID = response["request_id"] as? String
        else { return }

        if requestID == usageInitializeID {
            guard let usageRequestID else { return }
            try? stream?.send([
                "type": "control_request",
                "request_id": usageRequestID,
                "request": ["subtype": "get_usage"],
            ])
            return
        }

        guard requestID == usageRequestID,
              let payload = response["response"] as? [String: Any]
        else { return }

        usageTimeoutWorkItem?.cancel()
        usageTimeoutWorkItem = nil
        if payload["rate_limits_available"] as? Bool == true,
           let limits = payload["rate_limits"] as? [String: Any] {
            let fiveHour = limits["five_hour"] as? [String: Any]
            let sevenDay = limits["seven_day"] as? [String: Any]
            let snapshot = UsageSnapshot(
                primaryUsedPercent: Self.percentage(fiveHour?["utilization"]),
                secondaryUsedPercent: Self.percentage(sevenDay?["utilization"]),
                planName: payload["subscription_type"] as? String,
                isStale: false
            )
            DispatchQueue.main.async {
                self.delegate?.connector(.claude, didUpdate: snapshot)
            }
        } else {
            refreshUsageFromDesktopCache()
        }
        stream?.closeInput()
    }

    private func refreshUsageFromDesktopCache() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/plan-usage-history.json")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self,
                  let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let samples = object["samples"] as? [[String: Any]],
                  let sample = samples.last,
                  let usage = sample["u"] as? [String: Any]
            else { return }

            let primary = Self.percentage(usage["fh"])
            let secondary = Self.percentage(usage["sd"])
            let timestamp = (sample["t"] as? NSNumber)?.doubleValue ?? 0
            let age = Date().timeIntervalSince1970 - (timestamp / 1_000)
            let snapshot = UsageSnapshot(
                primaryUsedPercent: primary,
                secondaryUsedPercent: secondary,
                planName: self.subscriptionPlanName ?? "Claude subscription",
                isStale: age > (6 * 60 * 60)
            )
            DispatchQueue.main.async {
                self.delegate?.connector(.claude, didUpdate: snapshot)
            }
        }
    }

    private func handle(_ message: [String: Any]) {
        if let sessionID = message["session_id"] as? String, !sessionID.isEmpty {
            activeSessionID = sessionID
        }
        guard let type = message["type"] as? String else { return }
        switch type {
        case "assistant":
            if let assistant = message["message"] as? [String: Any],
               let content = assistant["content"] as? [[String: Any]] {
                for block in content where block["type"] as? String == "text" {
                    if let text = block["text"] as? String {
                        assistantText.append(text)
                    }
                }
            }
        case "control_request":
            handleControlRequest(message)
        case "result":
            let isError = message["is_error"] as? Bool == true
            let summary = String(assistantText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
            if isError {
                if assistantText.localizedCaseInsensitiveContains("oauth")
                    || assistantText.localizedCaseInsensitiveContains("authenticate") {
                    isAuthenticated = false
                    authenticationStatus = "Claude subscription needs reconnecting"
                    notifyActivity(.disconnected("Reconnect Claude"))
                } else {
                    notifyActivity(.failed(summary.isEmpty ? "Claude failed" : summary))
                }
            } else {
                notifyActivity(.completed(summary.isEmpty ? "Claude finished" : summary))
            }
            refreshUsage()
            process?.closeInput()
        case "system":
            if message["subtype"] as? String == "init" {
                notifyActivity(.working("Claude is working…"))
            }
        default:
            break
        }
    }

    private func handleControlRequest(_ message: [String: Any]) {
        guard let requestID = message["request_id"] as? String,
              let request = message["request"] as? [String: Any],
              request["subtype"] as? String == "can_use_tool"
        else { return }

        let title = (request["title"] as? String)
            ?? (request["display_name"] as? String)
            ?? "Claude permission"
        let detail = (request["description"] as? String)
            ?? (request["decision_reason"] as? String)
            ?? (request["tool_name"] as? String)
            ?? "Run requested tool"
        let cleanDetail = String(ANSIText.sanitize(detail).prefix(140))
        activeApproval = (requestID, request)
        let requiresInteraction = request["requires_user_interaction"] as? Bool == true
        let approval = ApprovalRequest(
            provider: .claude,
            id: requestID,
            title: String(ANSIText.sanitize(title).prefix(80)),
            detail: cleanDetail,
            requiresAppInteraction: requiresInteraction,
            respond: { [weak self] approved in
                self?.respondToApproval(id: requestID, approved: approved)
            }
        )
        notifyActivity(.waitingForApproval(cleanDetail))
        DispatchQueue.main.async {
            self.delegate?.connector(.claude, needs: approval)
        }
    }

    private func respondToApproval(id: String, approved: Bool) {
        guard let activeApproval, activeApproval.id == id else { return }
        let request = activeApproval.request
        var permissionResult: [String: Any]
        if approved {
            permissionResult = [
                "behavior": "allow",
                "updatedInput": request["input"] as? [String: Any] ?? [:],
            ]
        } else {
            permissionResult = [
                "behavior": "deny",
                "message": "Denied from AgentBar",
                "interrupt": false,
            ]
        }
        if let toolUseID = request["tool_use_id"] as? String {
            permissionResult["toolUseID"] = toolUseID
        }

        try? process?.send([
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": id,
                "response": permissionResult,
            ],
        ])
        self.activeApproval = nil
        DispatchQueue.main.async {
            self.delegate?.connector(.claude, didClearApproval: id)
        }
        notifyActivity(.working(approved ? "Approved" : "Denied"))
    }

    private func notifyActivity(_ activity: AgentActivity) {
        DispatchQueue.main.async {
            self.delegate?.connector(.claude, didChange: activity)
        }
    }

    static func findExecutable() throws -> URL {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent("Library/Application Support/Claude/claude-code")
        var candidates: [URL] = []
        if let versions = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            candidates.append(contentsOf: versions.map {
                $0.appendingPathComponent("claude.app/Contents/MacOS/claude")
            })
        }
        candidates.append(home.appendingPathComponent(".local/bin/claude"))
        candidates.append(home.appendingPathComponent("Library/Application Support/Claude/claude-code-vm/2.1.209/claude"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/claude"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/claude"))

        let executableCandidates = candidates.filter {
            fileManager.isExecutableFile(atPath: $0.path)
        }
        if let best = executableCandidates.max(by: {
            $0.path.compare($1.path, options: .numeric) == .orderedAscending
        }) {
            return best
        }
        throw AgentBarError.executableNotFound("Claude Code from Claude Desktop")
    }

    private static func percentage(_ value: Any?) -> Int? {
        let number: Double?
        if let value = value as? Double { number = value }
        else if let value = value as? NSNumber { number = value.doubleValue }
        else { number = nil }
        guard let number else { return nil }
        // Claude's live get_usage response and Desktop cache both store
        // utilization as a percentage in the 0...100 range (so 1 means 1%).
        return max(0, min(100, Int(number.rounded())))
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuoted(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
