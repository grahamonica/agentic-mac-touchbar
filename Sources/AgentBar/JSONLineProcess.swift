import Darwin
import Foundation

final class JSONLineFramer {
    private var buffer = Data()

    func append(_ data: Data) -> [[String: Any]] {
        buffer.append(data)
        var messages: [[String: Any]] = []

        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let value = try? JSONSerialization.jsonObject(with: Data(line)),
                  let message = value as? [String: Any]
            else { continue }
            messages.append(message)
        }

        return messages
    }
}

final class JSONLineProcess {
    typealias MessageHandler = ([String: Any]) -> Void
    typealias TerminationHandler = (Int32, String) -> Void

    private let queue = DispatchQueue(label: "com.monicagraham.AgentBar.JSONLineProcess")
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputFramer = JSONLineFramer()
    private var errorBuffer = ""
    private let writeLock = NSLock()

    var onMessage: MessageHandler?
    var onTermination: TerminationHandler?

    var isRunning: Bool { process?.isRunning == true }

    func start(executable: URL, arguments: [String], currentDirectory: URL? = nil) throws {
        stop()

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async {
                guard let self else { return }
                for message in self.outputFramer.append(data) {
                    self.onMessage?(message)
                }
            }
        }

        error.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            self?.queue.async {
                guard let self else { return }
                self.errorBuffer.append(text)
                if self.errorBuffer.count > 4_096 {
                    self.errorBuffer = String(self.errorBuffer.suffix(4_096))
                }
            }
        }

        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.queue.async {
                let error = self.errorBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                self.cleanupHandles()
                self.onTermination?(process.terminationStatus, error)
            }
        }

        do {
            try process.run()
        } catch {
            cleanupHandles()
            throw AgentBarError.processLaunchFailed(error.localizedDescription)
        }

        self.process = process
        self.inputPipe = input
    }

    func send(_ object: [String: Any]) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard let process, process.isRunning, let inputPipe else {
            throw AgentBarError.notReady("The agent connection is not running.")
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        var line = data
        line.append(0x0A)
        try inputPipe.fileHandleForWriting.write(contentsOf: line)
    }

    func closeInput() {
        try? inputPipe?.fileHandleForWriting.close()
        inputPipe = nil
    }

    func stop() {
        guard let process else {
            cleanupHandles()
            return
        }
        closeInput()
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        self.process = nil
    }

    private func cleanupHandles() {
        process?.standardOutput.flatMap { $0 as? Pipe }?.fileHandleForReading.readabilityHandler = nil
        process?.standardError.flatMap { $0 as? Pipe }?.fileHandleForReading.readabilityHandler = nil
        inputPipe = nil
        process = nil
    }
}
