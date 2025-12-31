import Foundation

/// Session that runs in tmux - visible in terminal and controllable from iOS
final class TMuxSession: @unchecked Sendable {
    let id: String
    let command: String
    let arguments: [String]
    let createdAt: Date
    let workingDirectory: String

    private var outputHistory: [OutputChunk] = []
    private let historyLock = NSLock()
    private var lastSentContent: String = ""

    private(set) var state: SessionState = .running
    private(set) var exitCode: Int32?

    var onOutputChunk: ((OutputChunk) -> Void)?
    var onStateChange: ((SessionState) -> Void)?

    /// Find tmux executable in PATH
    private static func findTmux() -> String {
        // Common locations
        let paths = [
            "/opt/homebrew/bin/tmux",  // macOS ARM
            "/usr/local/bin/tmux",      // macOS Intel / Linux manual install
            "/usr/bin/tmux"             // Linux package manager
        ]

        for path in paths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Fallback - assume it's in PATH
        return "/usr/bin/env"
    }

    private static var tmuxPath: String = {
        findTmux()
    }()

    private static var tmuxArgs: [String] {
        if tmuxPath == "/usr/bin/env" {
            return ["tmux"]
        }
        return []
    }

    init(id: String, command: String, arguments: [String]) throws {
        self.id = id
        self.command = command
        self.arguments = arguments
        self.createdAt = Date()
        self.workingDirectory = FileManager.default.currentDirectoryPath

        // Create tmux session - use shell to keep session alive even if command fails
        let fullCommand = ([command] + arguments).joined(separator: " ")
        let shellCommand = "\(fullCommand); echo ''; echo '[Session ended. Press Enter to close]'; read"

        let tmuxCreate = Process()
        tmuxCreate.executableURL = URL(fileURLWithPath: Self.tmuxPath)
        tmuxCreate.arguments = Self.tmuxArgs + ["new-session", "-d", "-s", id, "bash", "-c", shellCommand]
        tmuxCreate.environment = ProcessInfo.processInfo.environment

        try tmuxCreate.run()
        tmuxCreate.waitUntilExit()

        guard tmuxCreate.terminationStatus == 0 else {
            throw TMuxError.failedToCreateSession
        }

        // Wait for session to be ready
        Thread.sleep(forTimeInterval: 0.3)

        // Open terminal attached to the tmux session (macOS only)
        #if os(macOS)
        openTerminal()
        #endif

        // Start polling for output
        startOutputPolling()
    }

    #if os(macOS)
    private func openTerminal() {
        // Wait a moment for tmux session to be ready
        Thread.sleep(forTimeInterval: 0.5)

        // Use full path to tmux in case Terminal.app has different PATH
        let tmuxCmd = Self.tmuxPath == "/usr/bin/env" ? "tmux" : Self.tmuxPath
        let script = """
        tell application "Terminal"
            activate
            do script "\(tmuxCmd) attach -t \(id)"
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }
    #endif

    private func startOutputPolling() {
        // Use a background queue for polling
        let queue = DispatchQueue(label: "tmux.output.polling")
        queue.async { [weak self] in
            while self?.state != .exited {
                self?.pollOutput()
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }

    private func pollOutput() {
        // Check if session still exists
        guard isSessionAlive() else {
            updateState(.exited)
            return
        }

        // Capture pane content
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: Self.tmuxPath)
        process.arguments = Self.tmuxArgs + ["capture-pane", "-t", id, "-p", "-S", "-1000"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                processOutput(output)
            }
        } catch {
            // Ignore errors
        }
    }

    private func processOutput(_ fullOutput: String) {
        // Get the last 50 lines for display
        let lines = fullOutput.components(separatedBy: "\n")
        let recentLines = lines.suffix(50).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Only send if content actually changed
        guard recentLines != lastSentContent else { return }
        guard !recentLines.isEmpty else { return }

        lastSentContent = recentLines

        let chunk = OutputChunk(
            timestamp: Date(),
            content: recentLines,
            type: .stdout
        )

        historyLock.lock()
        outputHistory = [chunk]
        historyLock.unlock()

        onOutputChunk?(chunk)

        // Check for prompt (waiting for input)
        if recentLines.contains("> ") || recentLines.hasSuffix(">") {
            updateState(.waitingForInput)
        } else {
            updateState(.running)
        }
    }

    private func isSessionAlive() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.tmuxPath)
        process.arguments = Self.tmuxArgs + ["has-session", "-t", id]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func updateState(_ newState: SessionState) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
    }

    /// Send input to the session
    func sendInput(_ input: String) {
        guard state != .exited else { return }

        // Record the input
        let chunk = OutputChunk(
            timestamp: Date(),
            content: input,
            type: .stdin
        )

        historyLock.lock()
        outputHistory.append(chunk)
        historyLock.unlock()

        // Send via tmux - use -l for literal text, then send Enter separately
        let textProcess = Process()
        textProcess.executableURL = URL(fileURLWithPath: Self.tmuxPath)
        textProcess.arguments = Self.tmuxArgs + ["send-keys", "-t", id, "-l", input]
        textProcess.standardOutput = FileHandle.nullDevice
        textProcess.standardError = FileHandle.nullDevice
        try? textProcess.run()
        textProcess.waitUntilExit()

        // Send Enter key
        let enterProcess = Process()
        enterProcess.executableURL = URL(fileURLWithPath: Self.tmuxPath)
        enterProcess.arguments = Self.tmuxArgs + ["send-keys", "-t", id, "Enter"]
        enterProcess.standardOutput = FileHandle.nullDevice
        enterProcess.standardError = FileHandle.nullDevice
        try? enterProcess.run()
        enterProcess.waitUntilExit()

        if state == .waitingForInput {
            updateState(.running)
        }
    }

    /// Get output history
    func getHistory(limit: Int? = nil, offset: Int = 0) -> [OutputChunk] {
        historyLock.lock()
        defer { historyLock.unlock() }

        let start = max(0, offset)
        let end = limit.map { min(start + $0, outputHistory.count) } ?? outputHistory.count

        guard start < outputHistory.count else { return [] }
        return Array(outputHistory[start..<end])
    }

    /// Terminate the session
    func terminate() {
        updateState(.exited)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.tmuxPath)
        process.arguments = Self.tmuxArgs + ["kill-session", "-t", id]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try? process.run()
        process.waitUntilExit()
    }

    deinit {
        if state != .exited {
            terminate()
        }
    }
}

enum TMuxError: Error, LocalizedError {
    case failedToCreateSession

    var errorDescription: String? {
        switch self {
        case .failedToCreateSession:
            return "Failed to create tmux session"
        }
    }
}
