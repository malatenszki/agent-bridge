import Foundation

/// Represents a single agent session
final class Session: @unchecked Sendable {
    let id: String
    let command: String
    let arguments: [String]
    let createdAt: Date

    private let process: PTYProcess
    private var outputHistory: [OutputChunk] = []
    private let historyLock = NSLock()
    private let promptDetector = PromptDetector()

    private(set) var state: SessionState = .running
    private(set) var exitCode: Int32?

    var onOutputChunk: ((OutputChunk) -> Void)?
    var onStateChange: ((SessionState) -> Void)?

    init(id: String, command: String, arguments: [String]) throws {
        self.id = id
        self.command = command
        self.arguments = arguments
        self.createdAt = Date()

        self.process = try PTYProcess(command: command, arguments: arguments)

        process.onOutput = { [weak self] data in
            self?.handleOutput(data)
        }

        process.onExit = { [weak self] code in
            self?.handleExit(code)
        }
    }

    private func handleOutput(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }

        // Strip ANSI escape codes for cleaner display
        let cleanText = stripANSI(text)
        guard !cleanText.isEmpty else { return }

        let chunk = OutputChunk(
            timestamp: Date(),
            content: cleanText,
            type: .stdout
        )

        historyLock.lock()
        outputHistory.append(chunk)
        historyLock.unlock()

        onOutputChunk?(chunk)

        // Check for prompt
        if promptDetector.detectPrompt(in: text) {
            updateState(.waitingForInput)
        }
    }

    /// Strip ANSI escape codes from text
    private func stripANSI(_ text: String) -> String {
        // ESC character
        let esc = "\u{001B}"

        // Match all ANSI escape sequences
        let patterns = [
            "\(esc)\\[[0-9;?]*[a-zA-Z]",     // CSI sequences
            "\(esc)\\][^\u{0007}]*\u{0007}", // OSC sequences ending with BEL
            "\(esc)[@-Z\\\\-_]",             // Fe sequences
            "\\[\\?[0-9]+[hl]"               // Private mode sequences without ESC
        ]

        var result = text
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    options: [],
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: ""
                )
            }
        }

        return result
    }

    private func handleExit(_ code: Int32) {
        exitCode = code
        updateState(.exited)
    }

    private func updateState(_ newState: SessionState) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
    }

    /// Send input to the agent
    func sendInput(_ input: String) {
        guard state != .exited else { return }

        // Record the input in history
        let chunk = OutputChunk(
            timestamp: Date(),
            content: input,
            type: .stdin
        )

        historyLock.lock()
        outputHistory.append(chunk)
        historyLock.unlock()

        // Send to process (add newline if not present)
        let inputWithNewline = input.hasSuffix("\n") ? input : input + "\n"
        process.write(inputWithNewline)

        // Update state
        if state == .waitingForInput {
            updateState(.running)
        }
    }

    /// Send a yes response
    func sendYes() {
        sendInput("y")
    }

    /// Send a no response
    func sendNo() {
        sendInput("n")
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

    /// Get the last N lines of output as text
    func getRecentOutput(lines: Int = 50) -> String {
        historyLock.lock()
        let chunks = outputHistory.suffix(100) // Get recent chunks
        historyLock.unlock()

        let text = chunks.filter { $0.type == .stdout }.map { $0.content }.joined()
        let allLines = text.components(separatedBy: .newlines)
        return allLines.suffix(lines).joined(separator: "\n")
    }

    /// Terminate the session
    func terminate() {
        process.terminate()
    }

    /// Interrupt the session (Ctrl+C)
    func interrupt() {
        process.interrupt()
    }

    /// Resize terminal
    func resize(cols: UInt16, rows: UInt16) {
        process.resize(cols: cols, rows: rows)
    }
}

/// Output chunk from the session
struct OutputChunk: Codable, Sendable {
    let timestamp: Date
    let content: String
    let type: OutputType

    enum OutputType: String, Codable, Sendable {
        case stdout
        case stderr
        case stdin
    }
}

/// Session state
enum SessionState: String, Codable, Sendable {
    case running
    case waitingForInput
    case exited
}

/// Session summary for API responses
struct SessionSummary: Codable, Sendable {
    let id: String
    let command: String
    let arguments: [String]
    let createdAt: Date
    let state: SessionState
    let exitCode: Int32?
    let isExternal: Bool
    let workingDirectory: String?

    init(from session: Session) {
        self.id = session.id
        self.command = session.command
        self.arguments = session.arguments
        self.createdAt = session.createdAt
        self.state = session.state
        self.exitCode = session.exitCode
        self.isExternal = false
        self.workingDirectory = nil
    }

    init(from external: ExternalSession) {
        self.id = external.id
        self.command = external.command
        self.arguments = []
        self.createdAt = external.createdAt
        self.state = external.state
        self.exitCode = nil
        self.isExternal = true
        self.workingDirectory = nil
    }

    init(from tmux: TMuxSession) {
        self.id = tmux.id
        self.command = tmux.command
        self.arguments = tmux.arguments
        self.createdAt = tmux.createdAt
        self.state = tmux.state
        self.exitCode = tmux.exitCode
        self.isExternal = false
        self.workingDirectory = tmux.workingDirectory
    }

    // For manual creation (e.g., in handleStateChange)
    init(id: String, command: String, arguments: [String], createdAt: Date, state: SessionState, exitCode: Int32?, isExternal: Bool = false, workingDirectory: String? = nil) {
        self.id = id
        self.command = command
        self.arguments = arguments
        self.createdAt = createdAt
        self.state = state
        self.exitCode = exitCode
        self.isExternal = isExternal
        self.workingDirectory = workingDirectory
    }
}

/// Represents an external Claude session (detected from running processes)
final class ExternalSession: @unchecked Sendable {
    let id: String
    let pid: Int32
    let command: String
    let tty: String
    let createdAt: Date

    private var ttyAttachment: TTYAttachment?
    private var outputHistory: [OutputChunk] = []
    private let historyLock = NSLock()
    private let promptDetector = PromptDetector()

    private(set) var state: SessionState = .running
    var isAttached: Bool { ttyAttachment != nil }

    var onOutputChunk: ((OutputChunk) -> Void)?
    var onStateChange: ((SessionState) -> Void)?

    init(from process: ExternalProcess) {
        self.id = "ext-\(process.pid)"
        self.pid = process.pid
        self.command = process.command
        self.tty = process.tty
        self.createdAt = process.startTime
    }

    /// Try to attach to the TTY for I/O
    func attach() -> Bool {
        guard ttyAttachment == nil else { return true }

        let attachment = TTYAttachment(tty: tty, pid: pid)
        attachment.onOutput = { [weak self] text in
            self?.handleOutput(text)
        }

        if attachment.attach() {
            ttyAttachment = attachment
            return true
        }
        return false
    }

    /// Detach from the TTY
    func detach() {
        ttyAttachment?.detach()
        ttyAttachment = nil
    }

    private func handleOutput(_ text: String) {
        let chunk = OutputChunk(
            timestamp: Date(),
            content: text,
            type: .stdout
        )

        historyLock.lock()
        outputHistory.append(chunk)
        historyLock.unlock()

        onOutputChunk?(chunk)

        // Check for prompt
        if promptDetector.detectPrompt(in: text) {
            updateState(.waitingForInput)
        }
    }

    private func updateState(_ newState: SessionState) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
    }

    /// Send input to the external process
    func sendInput(_ input: String) {
        // Record the input in history
        let chunk = OutputChunk(
            timestamp: Date(),
            content: input,
            type: .stdin
        )

        historyLock.lock()
        outputHistory.append(chunk)
        historyLock.unlock()

        // Send to TTY
        let inputWithNewline = input.hasSuffix("\n") ? input : input + "\n"
        _ = ttyAttachment?.sendInput(inputWithNewline)

        // Update state
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

    /// Check if the process is still running
    func isRunning() -> Bool {
        return kill(pid, 0) == 0
    }
}
