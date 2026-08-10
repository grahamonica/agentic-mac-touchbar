import Foundation

/// Watches only event types in Codex rollout files. Prompt, response, reasoning,
/// and tool payloads are deliberately ignored.
final class CodexHistoryMonitor {
    enum Event {
        case started(threadID: String)
        case completed(threadID: String)
        case interrupted(threadID: String)
    }

    var onEvent: ((Event) -> Void)?

    private let sessionsRoot: URL
    private let queue = DispatchQueue(label: "com.monicagraham.AgentBar.CodexHistoryMonitor", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var offsets: [URL: UInt64] = [:]
    private var partialLines: [URL: Data] = [:]

    init(sessionsRoot: URL? = nil) {
        self.sessionsRoot = sessionsRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    func start() {
        guard timer == nil else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.seedExistingFiles()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 2)
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    private func seedExistingFiles() {
        for url in recentRolloutFiles() {
            offsets[url] = fileSize(url)
        }
    }

    private func poll() {
        let currentFiles = recentRolloutFiles()
        let currentSet = Set(currentFiles)
        for url in Array(offsets.keys) where !currentSet.contains(url) {
            offsets.removeValue(forKey: url)
            partialLines.removeValue(forKey: url)
        }

        for url in currentFiles {
            let size = fileSize(url)
            guard let offset = offsets[url] else {
                offsets[url] = 0
                readChanges(at: url, size: size)
                continue
            }
            if size < offset {
                offsets[url] = 0
                partialLines.removeValue(forKey: url)
            }
            if size > (offsets[url] ?? 0) {
                readChanges(at: url, size: size)
            }
        }
    }

    private func readChanges(at url: URL, size: UInt64) {
        let offset = offsets[url] ?? 0
        guard size > offset,
              let fileHandle = try? FileHandle(forReadingFrom: url)
        else { return }
        defer { try? fileHandle.close() }

        do {
            try fileHandle.seek(toOffset: offset)
            guard let data = try fileHandle.readToEnd(), !data.isEmpty else { return }
            offsets[url] = offset + UInt64(data.count)

            var framed = partialLines[url] ?? Data()
            framed.append(data)
            let lines = framed.split(separator: 0x0A, omittingEmptySubsequences: false)
            partialLines[url] = lines.last.map { Data($0) } ?? Data()
            let threadID = Self.threadID(from: url)
            for line in lines.dropLast() where !line.isEmpty {
                handle(line: Data(line), threadID: threadID)
            }
        } catch {
            return
        }
    }

    private func handle(line: Data, threadID: String) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any],
              let type = payload["type"] as? String
        else { return }

        let event: Event
        switch type {
        case "task_started": event = .started(threadID: threadID)
        case "task_complete": event = .completed(threadID: threadID)
        case "turn_aborted": event = .interrupted(threadID: threadID)
        default: return
        }
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }

    private func recentRolloutFiles() -> [URL] {
        let fileManager = FileManager.default
        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd"

        var files: [URL] = []
        for offset in 0...1 {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let directory = sessionsRoot.appendingPathComponent(formatter.string(from: date), isDirectory: true)
            guard let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            files.append(contentsOf: urls.filter { $0.pathExtension == "jsonl" })
        }
        return files
    }

    private func fileSize(_ url: URL) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return UInt64(values?.fileSize ?? 0)
    }

    private static func threadID(from url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let parts = stem.split(separator: "-")
        guard parts.count >= 5 else { return stem }
        return parts.suffix(5).joined(separator: "-")
    }
}
