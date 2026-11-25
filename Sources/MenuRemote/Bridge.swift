import Foundation

/// The private helper ships with Python and pyatv; only user data lives outside the app.
enum PythonEnvironment {
    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MenuRemote", isDirectory: true)
    }

    static var helper: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MenuRemoteHelper.app/Contents/MacOS/MenuRemoteHelper")
    }
    static var storageFile: URL { supportDirectory.appendingPathComponent("pyatv.conf") }
    static var logFile: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/MenuRemote.log")
    }

    struct SetupError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}

/// Runs the bundled helper and exchanges newline-delimited JSON with it.
final class BridgeProcess {
    typealias Event = [String: Any]

    var onEvent: ((Event) -> Void)?
    var onExit: ((Int32) -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private let queue = DispatchQueue(label: "MenuRemote.bridge")

    var isRunning: Bool { process?.isRunning ?? false }

    func start() throws {
        guard FileManager.default.isExecutableFile(atPath: PythonEnvironment.helper.path) else {
            throw PythonEnvironment.SetupError("MenuRemote’s helper is missing or damaged. Download a fresh copy of the app.")
        }
        try FileManager.default.createDirectory(at: PythonEnvironment.supportDirectory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = PythonEnvironment.helper
        process.arguments = [PythonEnvironment.storageFile.path]
        // A shell's Python configuration must not affect our private runtime.
        process.environment = ProcessInfo.processInfo.environment.filter {
            !$0.key.hasPrefix("PYTHON") && !$0.key.hasPrefix("_PYI") && $0.key != "LD_LIBRARY_PATH"
        }

        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = Self.openLog()

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] proc in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            let status = proc.terminationStatus
            DispatchQueue.main.async { self?.onExit?(status) }
        }

        try process.run()
        self.process = process
        self.input = stdinPipe.fileHandleForWriting
    }

    func stop() {
        process?.terminationHandler = nil
        try? input?.close()
        process?.terminate()
        process = nil
        input = nil
    }

    func send(_ command: [String: Any]) {
        guard let input, var data = try? JSONSerialization.data(withJSONObject: command) else { return }
        data.append(0x0A)
        queue.async { try? input.write(contentsOf: data) }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let event = try? JSONSerialization.jsonObject(with: line) as? Event else { continue }
            DispatchQueue.main.async { self.onEvent?(event) }
        }
    }

    private static func openLog() -> FileHandle {
        let url = PythonEnvironment.logFile
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep the log from growing forever.
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 2_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return .nullDevice }
        handle.seekToEndOfFile()
        return handle
    }
}
