import Foundation

/// Represents an available AI CLI tool
struct ExternalProcess: Identifiable, Sendable, Codable {
    let id: String
    let pid: Int32
    let command: String
    let tty: String
    let startTime: Date

    var displayName: String {
        command
    }

    /// Create an entry for an installed AI tool
    static func installed(name: String, path: String) -> ExternalProcess {
        ExternalProcess(
            id: name,
            pid: 0,
            command: path,
            tty: "",
            startTime: Date()
        )
    }
}

/// Scans for installed AI CLI tools on the system
actor ProcessScanner {
    private var knownTools: [String: ExternalProcess] = [:]
    private var scanTask: Task<Void, Never>?

    /// Callback when tools change - must be set before starting scanning
    private var onProcessesChanged: (([ExternalProcess]) -> Void)?

    /// Set the callback for tool changes
    func setOnProcessesChanged(_ callback: @escaping ([ExternalProcess]) -> Void) {
        onProcessesChanged = callback
    }

    /// Start periodic scanning
    func startScanning(interval: TimeInterval = 2.0) {
        stopScanning()

        scanTask = Task {
            // Do initial scan immediately
            await scan()

            // Then continue periodic scanning (in case new tools are installed)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                await scan()
            }
        }
    }

    /// Perform a single scan and wait for it to complete
    func scanNow() async -> [ExternalProcess] {
        let tools = findInstalledAITools()

        // Update known tools
        knownTools = Dictionary(uniqueKeysWithValues: tools.map { ($0.id, $0) })

        return tools
    }

    /// Stop scanning
    func stopScanning() {
        scanTask?.cancel()
        scanTask = nil
    }

    /// Get current known tools
    func getProcesses() -> [ExternalProcess] {
        Array(knownTools.values).sorted { $0.displayName < $1.displayName }
    }

    /// Perform a scan for installed AI tools
    private func scan() async {
        let tools = findInstalledAITools()

        // Check for changes
        let currentIDs = Set(tools.map { $0.id })
        let knownIDs = Set(knownTools.keys)

        if currentIDs != knownIDs {
            // Update known tools
            knownTools = Dictionary(uniqueKeysWithValues: tools.map { ($0.id, $0) })

            // Notify
            let toolsList = getProcesses()
            onProcessesChanged?(toolsList)
        }
    }

    /// Find all installed AI CLI tools
    nonisolated private func findInstalledAITools() -> [ExternalProcess] {
        var tools: [ExternalProcess] = []

        // Common AI CLI tool names to search for
        let aiToolNames = ["claude", "grok", "chatgpt", "cursor", "copilot", "aider", "cody"]

        // Common paths where CLI tools are installed
        let searchPaths = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/usr/bin",
            NSHomeDirectory() + "/.local/bin",
            NSHomeDirectory() + "/bin"
        ]

        for toolName in aiToolNames {
            // Try to find the tool using 'which'
            if let path = findExecutable(toolName) {
                tools.append(.installed(name: toolName, path: path))
            } else {
                // Manually check common paths
                for searchPath in searchPaths {
                    let fullPath = searchPath + "/" + toolName
                    if FileManager.default.isExecutableFile(atPath: fullPath) {
                        tools.append(.installed(name: toolName, path: fullPath))
                        break
                    }
                }
            }
        }

        return tools
    }

    /// Find executable using 'which' command
    nonisolated private func findExecutable(_ name: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = [name]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()

            guard task.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8) else {
                return nil
            }

            let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        } catch {
            return nil
        }
    }
}

/// Manages attachment to external TTYs for reading output
class TTYAttachment {
    let tty: String
    let pid: Int32
    private var fileHandle: FileHandle?
    private var readSource: DispatchSourceRead?

    var onOutput: ((String) -> Void)?

    init(tty: String, pid: Int32) {
        self.tty = tty
        self.pid = pid
    }

    /// Try to attach to the TTY for reading
    func attach() -> Bool {
        // Convert TTY name to device path
        let devicePath: String
        if tty.hasPrefix("/dev/") {
            devicePath = tty
        } else if tty.hasPrefix("ttys") {
            devicePath = "/dev/\(tty)"
        } else {
            devicePath = "/dev/tty\(tty)"
        }

        // Try to open the TTY
        let fd = open(devicePath, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else {
            return false
        }

        fileHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)

        // Set up read source
        readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        readSource?.setEventHandler { [weak self] in
            self?.handleRead()
        }
        readSource?.resume()

        return true
    }

    /// Send input to the TTY
    func sendInput(_ input: String) -> Bool {
        let devicePath: String
        if tty.hasPrefix("/dev/") {
            devicePath = tty
        } else if tty.hasPrefix("ttys") {
            devicePath = "/dev/\(tty)"
        } else {
            devicePath = "/dev/tty\(tty)"
        }

        let fd = open(devicePath, O_WRONLY)
        guard fd >= 0 else {
            return false
        }
        defer { close(fd) }

        let data = input + "\n"
        let result = data.withCString { ptr in
            write(fd, ptr, strlen(ptr))
        }

        return result > 0
    }

    private func handleRead() {
        guard let handle = fileHandle else { return }

        // Use low-level read() to handle non-blocking properly
        let fd = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(fd, &buffer, buffer.count)

        if bytesRead > 0 {
            let data = Data(buffer[0..<bytesRead])
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                onOutput?(str)
            }
        }
        // If bytesRead <= 0, it's either EAGAIN (no data) or error - just ignore
    }

    func detach() {
        readSource?.cancel()
        readSource = nil
        fileHandle = nil
    }

    deinit {
        detach()
    }
}
