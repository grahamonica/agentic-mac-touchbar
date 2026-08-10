import Foundation

final class CodexConnector {
    weak var delegate: AgentConnectorDelegate?

    private let process = JSONLineProcess()
    private let lock = NSLock()
    private var nextRequestID = 1
    private var callbacks: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var pendingRPCIDs: [String: Any] = [:]
    private var pendingApprovalMethods: [String: String] = [:]
    private var pendingApprovalParams: [String: [String: Any]] = [:]
    private(set) var activeThreadID: String?
    private(set) var isReady = false

    init() {
        process.onMessage = { [weak self] message in
            self?.handle(message)
        }
        process.onTermination = { [weak self] status, errorText in
            guard let self else { return }
            self.isReady = false
            let detail = errorText.isEmpty ? "Codex disconnected (\(status))" : errorText
            self.notifyActivity(.disconnected(detail))
        }
    }

    func start() {
        guard !process.isRunning else { return }
        notifyActivity(.connecting)

        do {
            try process.start(
                executable: try Self.findExecutable(),
                arguments: ["app-server", "--listen", "stdio://"]
            )
            sendRequest(
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": "agentic-mac-touchbar",
                        "title": "AgentBar",
                        "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0",
                    ],
                    "capabilities": ["experimentalApi": true],
                ]
            ) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    try? self.process.send(["method": "initialized", "params": [:]])
                    self.isReady = true
                    self.notifyActivity(.ready)
                    self.refreshUsage()
                case .failure(let error):
                    self.notifyActivity(.failed(error.localizedDescription))
                }
            }
        } catch {
            notifyActivity(.failed(error.localizedDescription))
        }
    }

    func stop() {
        process.stop()
        isReady = false
    }

    func sendNewChat(_ prompt: String, workingDirectory: URL) {
        guard isReady else {
            notifyActivity(.failed("Codex is not connected"))
            start()
            return
        }

        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        notifyActivity(.working("Starting chat…"))

        sendRequest(
            method: "thread/start",
            params: [
                "cwd": workingDirectory.path,
                "approvalPolicy": "on-request",
                "ephemeral": false,
            ]
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.notifyActivity(.failed(error.localizedDescription))
            case .success(let response):
                guard let thread = response["thread"] as? [String: Any],
                      let threadID = thread["id"] as? String
                else {
                    self.notifyActivity(.failed("Codex did not return a thread ID"))
                    return
                }
                self.activeThreadID = threadID
                self.sendRequest(
                    method: "turn/start",
                    params: [
                        "threadId": threadID,
                        "input": [["type": "text", "text": trimmed]],
                    ]
                ) { result in
                    if case .failure(let error) = result {
                        self.notifyActivity(.failed(error.localizedDescription))
                    } else {
                        self.notifyActivity(.working("Codex is working…"))
                    }
                }
            }
        }
    }

    func refreshUsage() {
        guard isReady else { return }
        sendRequest(method: "account/rateLimits/read", params: [:]) { [weak self] result in
            guard let self, case .success(let response) = result else { return }
            let limits = response["rateLimits"] as? [String: Any] ?? [:]
            let primary = limits["primary"] as? [String: Any]
            let secondary = limits["secondary"] as? [String: Any]
            let snapshot = UsageSnapshot(
                primaryUsedPercent: Self.integer(primary?["usedPercent"]),
                secondaryUsedPercent: Self.integer(secondary?["usedPercent"]),
                planName: limits["planType"] as? String
            )
            DispatchQueue.main.async {
                self.delegate?.connector(.codex, didUpdate: snapshot)
            }
        }
    }

    private func sendRequest(
        method: String,
        params: [String: Any],
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        lock.lock()
        let id = nextRequestID
        nextRequestID += 1
        callbacks[id] = completion
        lock.unlock()

        do {
            try process.send(["id": id, "method": method, "params": params])
        } catch {
            lock.lock()
            callbacks.removeValue(forKey: id)
            lock.unlock()
            completion(.failure(error))
        }
    }

    private func handle(_ message: [String: Any]) {
        if let id = Self.integer(message["id"]), message["method"] == nil {
            lock.lock()
            let callback = callbacks.removeValue(forKey: id)
            lock.unlock()
            if let error = message["error"] as? [String: Any] {
                callback?(.failure(AgentBarError.invalidResponse(Self.errorMessage(error))))
            } else {
                callback?(.success(message["result"] as? [String: Any] ?? [:]))
            }
            return
        }

        guard let method = message["method"] as? String else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        if let rpcID = message["id"] {
            handleServerRequest(method: method, rpcID: rpcID, params: params)
        } else {
            handleNotification(method: method, params: params)
        }
    }

    private func handleNotification(method: String, params: [String: Any]) {
        switch method {
        case "turn/started":
            notifyActivity(.working("Codex is working…"))
        case "turn/completed":
            notifyActivity(Self.turnCompletionActivity(params: params))
            refreshUsage()
        case "serverRequest/resolved":
            guard let requestID = params["requestId"] else { return }
            let key = Self.rpcKey(requestID)
            lock.lock()
            pendingRPCIDs.removeValue(forKey: key)
            pendingApprovalMethods.removeValue(forKey: key)
            pendingApprovalParams.removeValue(forKey: key)
            lock.unlock()
            DispatchQueue.main.async {
                self.delegate?.connector(.codex, didClearApproval: key)
            }
        case "thread/status/changed":
            guard let status = params["status"] as? [String: Any],
                  status["type"] as? String == "active",
                  let flags = status["activeFlags"] as? [String],
                  flags.contains("waitingOnApproval")
            else { return }
            notifyActivity(.waitingForApproval("Permission needed"))
        case "account/rateLimits/updated":
            if let rateLimits = params["rateLimits"] as? [String: Any] {
                let primary = rateLimits["primary"] as? [String: Any]
                let secondary = rateLimits["secondary"] as? [String: Any]
                let usage = UsageSnapshot(
                    primaryUsedPercent: Self.integer(primary?["usedPercent"]),
                    secondaryUsedPercent: Self.integer(secondary?["usedPercent"]),
                    planName: rateLimits["planType"] as? String
                )
                DispatchQueue.main.async {
                    self.delegate?.connector(.codex, didUpdate: usage)
                }
            }
        default:
            break
        }
    }

    private func handleServerRequest(method: String, rpcID: Any, params: [String: Any]) {
        let approvalMethods = [
            "item/commandExecution/requestApproval",
            "item/fileChange/requestApproval",
            "item/permissions/requestApproval",
            "execCommandApproval",
            "applyPatchApproval",
        ]

        if method == "item/tool/requestUserInput" {
            let key = Self.rpcKey(rpcID)
            let request = ApprovalRequest(
                provider: .codex,
                id: key,
                title: "Codex needs input",
                detail: "Open Codex to answer this question.",
                requiresAppInteraction: true,
                respond: { _ in }
            )
            DispatchQueue.main.async {
                self.delegate?.connector(.codex, needs: request)
            }
            return
        }

        guard approvalMethods.contains(method) else { return }
        let key = Self.rpcKey(rpcID)
        lock.lock()
        pendingRPCIDs[key] = rpcID
        pendingApprovalMethods[key] = method
        pendingApprovalParams[key] = params
        lock.unlock()

        let detail = Self.approvalDetail(method: method, params: params)
        let request = ApprovalRequest(
            provider: .codex,
            id: key,
            title: "Codex permission",
            detail: detail,
            requiresAppInteraction: false,
            respond: { [weak self] approved in
                self?.respondToApproval(key: key, approved: approved)
            }
        )
        notifyActivity(.waitingForApproval(detail))
        DispatchQueue.main.async {
            self.delegate?.connector(.codex, needs: request)
        }
    }

    private func respondToApproval(key: String, approved: Bool) {
        lock.lock()
        let rpcID = pendingRPCIDs.removeValue(forKey: key)
        let method = pendingApprovalMethods.removeValue(forKey: key)
        let params = pendingApprovalParams.removeValue(forKey: key) ?? [:]
        lock.unlock()
        guard let rpcID, let method else { return }

        let result: [String: Any]
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            result = ["decision": approved ? "accept" : "decline"]
        case "item/permissions/requestApproval":
            result = [
                "permissions": approved ? (params["permissions"] as? [String: Any] ?? [:]) : [:],
                "scope": "turn",
            ]
        default:
            result = [
                "decision": approved
                    ? "approved"
                    : ["denied": ["rejection": "Denied from AgentBar"]],
            ]
        }
        try? process.send(["id": rpcID, "result": result])
        DispatchQueue.main.async {
            self.delegate?.connector(.codex, didClearApproval: key)
        }
        notifyActivity(.working(approved ? "Approved" : "Denied"))
    }

    private func notifyActivity(_ activity: AgentActivity) {
        DispatchQueue.main.async {
            self.delegate?.connector(.codex, didChange: activity)
        }
    }

    private static func findExecutable() throws -> URL {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        throw AgentBarError.executableNotFound("Codex")
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func rpcKey(_ value: Any) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return String(describing: value)
    }

    private static func errorMessage(_ value: [String: Any]) -> String {
        value["message"] as? String ?? String(describing: value)
    }

    static func turnCompletionActivity(params: [String: Any]) -> AgentActivity {
        guard let turn = params["turn"] as? [String: Any],
              let status = turn["status"] as? String
        else { return .failed("Codex ended with an unknown status") }

        switch status {
        case "completed":
            return .completed("Codex finished")
        case "interrupted":
            return .failed("Codex was interrupted")
        case "failed":
            let error = turn["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "Codex failed"
            return .failed(String(ANSIText.sanitize(message).prefix(140)))
        default:
            return .failed("Codex ended with status: \(status)")
        }
    }

    static func approvalDetail(method: String, params: [String: Any]) -> String {
        if let network = params["networkApprovalContext"] as? [String: Any],
           let host = network["host"] as? String,
           let protocolName = network["protocol"] as? String {
            return String("Network \(protocolName) access to \(host)".prefix(120))
        }
        if let reason = params["reason"] as? String, !reason.isEmpty {
            return String(ANSIText.sanitize(reason).prefix(120))
        }
        if let command = params["command"] as? String, !command.isEmpty {
            return String(ANSIText.sanitize(command).prefix(120))
        }
        if let command = params["command"] as? [String], !command.isEmpty {
            return String(command.joined(separator: " ").prefix(120))
        }
        if let changes = params["fileChanges"] as? [String: Any], !changes.isEmpty {
            return "Change \(changes.keys.sorted().prefix(2).joined(separator: ", "))"
        }
        if method.contains("permissions") { return "Grant additional access" }
        if method.contains("fileChange") || method.contains("Patch") { return "Apply file changes" }
        return "Run requested action"
    }
}
