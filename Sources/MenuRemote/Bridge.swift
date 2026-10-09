import Foundation

/// Locations and one-time setup of the Python environment that runs pyatv.
enum PythonEnvironment {
    static let pyatvVersion = "0.18.0"
    static let pythonVersion = "3.13"

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MenuRemote", isDirectory: true)
    }

    static var venv: URL { supportDirectory.appendingPathComponent("venv", isDirectory: true) }
    static var python: URL { venv.appendingPathComponent("bin/python") }
    static var storageFile: URL { supportDirectory.appendingPathComponent("pyatv.conf") }
    static var logFile: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/MenuRemote.log")
    }

    private static var marker: URL { venv.appendingPathComponent(".pyatv-\(pyatvVersion)") }

    static var isReady: Bool {
        FileManager.default.isExecutableFile(atPath: python.path)
            && FileManager.default.fileExists(atPath: marker.path)
    }

    static var bridgeScript: URL? {
        Bundle.main.url(forResource: "atv_bridge", withExtension: "py")
    }

    static func findUV() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/uv", "/usr/local/bin/uv",
            "\(home)/.local/bin/uv", "\(home)/.cargo/bin/uv",
        ]
        return candidates.lazy.map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Creates the venv with uv and installs pyatv into it.
    static func install() async throws {
        guard let uv = findUV() else {
            throw SetupError("uv was not found. Install it with `brew install uv` and retry.")
        }
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try await run(uv, ["venv", "--clear", "--python", pythonVersion,
                           "--python-preference", "only-managed", venv.path])
        try await run(uv, ["pip", "install", "--python", python.path, "pyatv==\(pyatvVersion)"])
        FileManager.default.createFile(atPath: marker.path, contents: nil)
    }

    private static func run(_ executable: URL, _ arguments: [String]) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(decoding: errData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw SetupError(message.isEmpty ? "uv exited with \(process.terminationStatus)" : message)
            }
        }.value
    }

    struct SetupError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}

/// Runs atv_bridge.py and exchanges newline-delimited JSON with it.
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
        guard let script = PythonEnvironment.bridgeScript else {
            throw PythonEnvironment.SetupError("atv_bridge.py is missing from the app bundle.")
        }
        let process = Process()
        process.executableURL = PythonEnvironment.python
        process.arguments = ["-u", script.path, PythonEnvironment.storageFile.path]

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
