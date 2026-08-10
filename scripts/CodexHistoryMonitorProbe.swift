import Foundation

@main
struct CodexHistoryMonitorProbe {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentBarHistoryMonitorProbe-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd"
        let day = root.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)

        let threadID = "11111111-2222-3333-4444-555555555555"
        let rollout = day.appendingPathComponent("rollout-2026-08-09T00-00-00-\(threadID).jsonl")
        let oldEvent = #"{"type":"event_msg","payload":{"type":"task_complete","message":"ignored"}}"# + "\n"
        try Data(oldEvent.utf8).write(to: rollout)

        let monitor = CodexHistoryMonitor(sessionsRoot: root)
        var observed: [String] = []
        monitor.onEvent = { event in
            switch event {
            case .started(let id): observed.append("started:\(id)")
            case .completed(let id): observed.append("completed:\(id)")
            case .interrupted(let id): observed.append("interrupted:\(id)")
            }
        }
        monitor.start()
        Thread.sleep(forTimeInterval: 0.25)

        let appended = [
            #"{"type":"response_item","payload":{"type":"message","content":"private text must be ignored"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_complete"}}"#,
        ].joined(separator: "\n") + "\n"
        let handle = try FileHandle(forWritingTo: rollout)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()

        let deadline = Date().addingTimeInterval(5)
        while observed.count < 2 && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        monitor.stop()

        let expected = ["started:\(threadID)", "completed:\(threadID)"]
        guard observed == expected else {
            throw NSError(
                domain: "AgentBarSmokeTest",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unexpected history events: \(observed)"]
            )
        }
        print("Codex history monitor probe passed")
    }
}
