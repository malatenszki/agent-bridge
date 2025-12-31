import Foundation
#if os(macOS)
import Darwin
#else
import Glibc
#endif

/// Manages a child process running in a pseudo-terminal (PTY)
/// Uses forkpty via Process for compatibility
final class PTYProcess: @unchecked Sendable {
    private let masterFD: Int32
    private let process: Process
    private var outputBuffer: Data = Data()
    private let outputQueue = DispatchQueue(label: "pty.output")
    private let readQueue = DispatchQueue(label: "pty.read")
    private var readSource: DispatchSourceRead?

    var onOutput: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?

    private(set) var isRunning: Bool = false

    init(command: String, arguments: [String] = [], environment: [String: String]? = nil) throws {
        var master: Int32 = 0
        var slave: Int32 = 0

        // Open a new PTY pair
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw PTYError.openPTYFailed(errno: errno)
        }

        self.masterFD = master

        // Create a FileHandle for the slave side
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)

        // Resolve command path - check if it's already absolute or find in PATH
        let executablePath: String
        if command.hasPrefix("/") {
            executablePath = command
        } else if let resolved = PTYProcess.findInPath(command) {
            executablePath = resolved
        } else {
            close(master)
            throw PTYError.commandNotFound(command)
        }

        // Create and configure Process
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = arguments

        // Set up environment
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["LANG"] = "en_US.UTF-8"
        if let customEnv = environment {
            for (key, value) in customEnv {
                env[key] = value
            }
        }
        proc.environment = env

        // Use the PTY slave as stdin/stdout/stderr
        proc.standardInput = slaveHandle
        proc.standardOutput = slaveHandle
        proc.standardError = slaveHandle

        self.process = proc

        // Set non-blocking mode on master
        let flags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        // Start reading output
        startReading()

        // Start the process
        do {
            try proc.run()
            self.isRunning = true
        } catch {
            close(master)
            throw PTYError.launchFailed(error)
        }

        // Monitor exit
        proc.terminationHandler = { [weak self] process in
            guard let self = self else { return }
            self.isRunning = false

            // Give a moment for final output
            Thread.sleep(forTimeInterval: 0.1)

            self.onExit?(process.terminationStatus)
        }
    }

    private func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: readQueue)

        source.setEventHandler { [weak self] in
            guard let self = self else { return }

            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytesRead = read(self.masterFD, &buffer, buffer.count)

            if bytesRead > 0 {
                let data = Data(bytes: buffer, count: bytesRead)
                self.outputQueue.async {
                    self.outputBuffer.append(data)
                    self.onOutput?(data)
                }
            } else if bytesRead == 0 || (bytesRead < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
                source.cancel()
            }
        }

        source.setCancelHandler { [weak self] in
            guard let self = self else { return }
            close(self.masterFD)
        }

        source.resume()
        self.readSource = source
    }

    /// Send input to the process
    func write(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        write(data)
    }

    /// Send raw data to the process
    func write(_ data: Data) {
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            #if os(macOS)
            _ = Darwin.write(masterFD, baseAddress, data.count)
            #else
            _ = Glibc.write(masterFD, baseAddress, data.count)
            #endif
        }
    }

    /// Terminate the process
    func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }

    /// Interrupt the process (Ctrl+C)
    func interrupt() {
        process.interrupt()
    }

    /// Get all buffered output
    func getOutputBuffer() -> Data {
        return outputQueue.sync { outputBuffer }
    }

    /// Resize the PTY window
    func resize(cols: UInt16, rows: UInt16) {
        var size = winsize()
        size.ws_col = cols
        size.ws_row = rows
        _ = ioctl(masterFD, TIOCSWINSZ, &size)
    }

    deinit {
        readSource?.cancel()
        if process.isRunning {
            terminate()
        }
    }

    /// Find a command in PATH
    private static func findInPath(_ command: String) -> String? {
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
        let paths = pathEnv.split(separator: ":").map(String.init)

        // Also check common locations for node-based tools like claude
        let additionalPaths = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            NSHomeDirectory() + "/.local/bin",
            NSHomeDirectory() + "/.npm-global/bin",
            NSHomeDirectory() + "/.nvm/current/bin"
        ]

        let allPaths = paths + additionalPaths

        for path in allPaths {
            let fullPath = (path as NSString).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: fullPath) {
                return fullPath
            }
        }

        return nil
    }
}

enum PTYError: Error, LocalizedError {
    case openPTYFailed(errno: Int32)
    case launchFailed(Error)
    case commandNotFound(String)

    var errorDescription: String? {
        switch self {
        case .openPTYFailed(let errno):
            return "Failed to open PTY: \(String(cString: strerror(errno)))"
        case .launchFailed(let error):
            return "Failed to launch process: \(error.localizedDescription)"
        case .commandNotFound(let cmd):
            return "Command not found: \(cmd)"
        }
    }
}
