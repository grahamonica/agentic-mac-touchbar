import Foundation

enum AgentProvider: String, CaseIterable, Codable {
    case codex = "Codex"
    case claude = "Claude"

    var bundleIdentifier: String {
        switch self {
        case .codex: return "com.openai.codex"
        case .claude: return "com.anthropic.claudefordesktop"
        }
    }
}

enum AgentActivity: Equatable {
    case disconnected(String)
    case connecting
    case ready
    case working(String)
    case waitingForApproval(String)
    case completed(String)
    case failed(String)

    var compactLabel: String {
        switch self {
        case .disconnected(let reason): return reason
        case .connecting: return "Connecting…"
        case .ready: return "Ready"
        case .working(let detail): return detail.isEmpty ? "Working…" : detail
        case .waitingForApproval(let detail): return detail.isEmpty ? "Permission needed" : detail
        case .completed(let detail): return detail.isEmpty ? "Done" : detail
        case .failed(let detail): return detail.isEmpty ? "Error" : detail
        }
    }

    var isWorking: Bool {
        if case .working = self { return true }
        return false
    }
}

struct UsageSnapshot: Equatable {
    var primaryUsedPercent: Int?
    var secondaryUsedPercent: Int?
    var planName: String?
    var isStale = false

    static let unavailable = UsageSnapshot()

    var compactLabel: String {
        if isStale { return "Usage needs refresh" }
        switch (primaryUsedPercent, secondaryUsedPercent) {
        case let (primary?, secondary?): return "5h \(primary)% · 7d \(secondary)%"
        case let (primary?, nil): return "Usage \(primary)%"
        case let (nil, secondary?): return "Usage \(secondary)%"
        default: return "Usage —"
        }
    }
}

struct ApprovalRequest {
    let provider: AgentProvider
    let id: String
    let title: String
    let detail: String
    let requiresAppInteraction: Bool
    let respond: (Bool) -> Void
}

protocol AgentConnectorDelegate: AnyObject {
    func connector(_ provider: AgentProvider, didChange activity: AgentActivity)
    func connector(_ provider: AgentProvider, didUpdate usage: UsageSnapshot)
    func connector(_ provider: AgentProvider, needs approval: ApprovalRequest)
    func connector(_ provider: AgentProvider, didClearApproval id: String)
}

enum AgentBarError: LocalizedError {
    case executableNotFound(String)
    case processLaunchFailed(String)
    case invalidResponse(String)
    case notReady(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let name): return "Could not find \(name)."
        case .processLaunchFailed(let detail): return "Could not start the agent: \(detail)"
        case .invalidResponse(let detail): return "The agent returned an invalid response: \(detail)"
        case .notReady(let detail): return detail
        }
    }
}

struct ANSIText {
    private static let expression = try? NSRegularExpression(
        pattern: "\\u001B\\[[0-?]*[ -/]*[@-~]",
        options: []
    )

    static func sanitize(_ value: String) -> String {
        guard let expression else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(in: value, range: range, withTemplate: "")
    }
}
