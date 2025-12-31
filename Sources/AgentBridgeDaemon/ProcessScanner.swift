import Foundation

/// Represents an externally detected Claude process
struct ExternalProcess: Identifiable, Sendable {
    let id: String  // PID as string
    let pid: Int32
    let command: String
    let tty: String
    let startTime: Date

    var displayName: String {
        "claude (PID: \(pid))"
    }
}

/// Scans for running Claude processes on the system
actor ProcessScanner {
    private var knownProcesses: [Int32: ExternalProcess] = [:]
    private var scanTask: Task<Void, Never>?

    /// Callback when processes change - must be set before starting scanning
    private var onProcessesChanged: (([ExternalProcess]) -> Void)?

    /// Set the callback for process changes
    func setOnProcessesChanged(_ callback: @escaping ([ExternalProcess]) -> Void) {
        onProcessesChanged = callback
    }

    /// Start periodic scanning
    func startScanning(interval: TimeInterval = 2.0) {
        stopScanning()

        scanTask = Task {
            // Do initial scan immediately
            await scan()

            // Then continue periodic scanning
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                await scan()
            }
        }
    }

    /// Perform a single scan and wait for it to complete
    func scanNow() async -> [ExternalProcess] {
        let processes = findClaudeProcesses()

        // Update known processes
        knownProcesses = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })

        return processes
    }

    /// Stop scanning
    func stopScanning() {
        scanTask?.cancel()
        scanTask = nil
    }

    /// Get current known processes
    func getProcesses() -> [ExternalProcess] {
        Array(knownProcesses.values).sorted { $0.pid < $1.pid }
    }

    /// Perform a scan for Claude processes
    private func scan() async {
        let processes = findClaudeProcesses()

        // Check for changes
        let currentPIDs = Set(processes.map { $0.pid })
        let knownPIDs = Set(knownProcesses.keys)

        if currentPIDs != knownPIDs {
            // Update known processes
            knownProcesses = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })

            // Notify
            let processList = getProcesses()
            onProcessesChanged?(processList)
        }
    }

    /// Find all running Claude processes
    private func findClaudeProcesses() -> [ExternalProcess] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["aux"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()

            // Read output BEFORE waiting (to avoid deadlock if pipe buffer fills)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()

            task.waitUntilExit()

            guard let output = String(data: data, encoding: .utf8) else { return [] }

            return parseProcessList(output)
        } catch {
            print("Error running ps: \(error)")
            return []
        }
    }

    /// Parse ps output to find Claude processes
    private func parseProcessList(_ output: String) -> [ExternalProcess] {
        var processes: [ExternalProcess] = []

        let lines = output.components(separatedBy: "\n")

        for line in lines.dropFirst() { // Skip header
            // Look for claude processes (but not this daemon or grep)
            let lowercased = line.lowercased()
            guard lowercased.contains("claude") else { continue }
            guard !lowercased.contains("agent-bridge") else { continue }
            guard !lowercased.contains("grep") else { continue }

            // Parse the line: USER PID %CPU %MEM VSZ RSS TT STAT STARTED TIME COMMAND
            let components = line.split(separator: " ", omittingEmptySubsequences: true)
            guard components.count >= 11 else { continue }

            guard let pid = Int32(components[1]) else { continue }

            let tty = String(components[6])
            let command = components[10...].joined(separator: " ")

            // Skip if TTY is "??" (no controlling terminal)
            guard tty != "??" else { continue }

            let process = ExternalProcess(
                id: String(pid),
                pid: pid,
                command: command,
                tty: tty,
                startTime: Date() // We don't parse the actual start time for simplicity
            )
            processes.append(process)
        }

        return processes
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
