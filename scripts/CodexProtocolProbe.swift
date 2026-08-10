import Foundation

@main
enum CodexProtocolProbe {
    static func main() {
        precondition(
            CodexConnector.turnCompletionActivity(
                params: ["turn": ["status": "completed"]]
            ) == .completed("Codex finished")
        )
        precondition(
            CodexConnector.turnCompletionActivity(
                params: ["turn": ["status": "interrupted"]]
            ) == .failed("Codex was interrupted")
        )
        precondition(
            CodexConnector.turnCompletionActivity(
                params: [
                    "turn": [
                        "status": "failed",
                        "error": ["message": "Permission denied"],
                    ],
                ]
            ) == .failed("Permission denied")
        )
        precondition(
            CodexConnector.approvalDetail(
                method: "item/commandExecution/requestApproval",
                params: [
                    "command": "curl https://wrong.example",
                    "networkApprovalContext": [
                        "host": "api.example.com:443",
                        "protocol": "https",
                    ],
                ]
            ) == "Network https access to api.example.com:443"
        )

        print("Codex completion and approval protocol probe passed")
    }
}
