import Foundation
import ArgumentParser

@main
struct AgentBridgeCLI: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "agent-bridge",
        abstract: "Control the Agent Bridge daemon",
        version: "1.0.0",
        subcommands: [
            Start.self,
            Run.self,
            Sessions.self,
            Pair.self,
            Status.self
        ],
        defaultSubcommand: Start.self
    )
}

// MARK: - Start Command

struct Start: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Start the Agent Bridge daemon"
    )

    @Option(name: .shortAndLong, help: "Port to listen on")
    var port: Int = 8765

    @Flag(name: .long, help: "Run in foreground (don't daemonize)")
    var foreground: Bool = false

    func run() async throws {
        if foreground {
            // Run in foreground
            let daemonPath = getDaemonPath()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: daemonPath)
            process.environment = ProcessInfo.processInfo.environment
            process.environment?["AGENT_BRIDGE_PORT"] = String(port)

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            try process.run()

            // Forward output
            let handle = pipe.fileHandleForReading
            handle.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    FileHandle.standardOutput.write(data)
                }
            }

            process.waitUntilExit()
        } else {
            // Start as background daemon
            let daemonPath = getDaemonPath()

            let process = Process()
            process.executableURL = URL(fileURLWithPath: daemonPath)
            process.environment = ProcessInfo.processInfo.environment
            process.environment?["AGENT_BRIDGE_PORT"] = String(port)

            // Redirect to log file
            let logPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".agent-bridge")
                .appendingPathComponent("daemon.log")

            try FileManager.default.createDirectory(
                at: logPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let logHandle = try FileHandle(forWritingTo: logPath)
            process.standardOutput = logHandle
            process.standardError = logHandle

            try process.run()

            print("Agent Bridge daemon started on port \(port)")
            print("PID: \(process.processIdentifier)")
            print("Log: \(logPath.path)")
        }
    }

    private func getDaemonPath() -> String {
        // Look for daemon executable
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        let binDir = executableURL.deletingLastPathComponent()

        let possiblePaths = [
            binDir.appendingPathComponent("agent-bridge-daemon").path,
            "/usr/local/bin/agent-bridge-daemon",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/agent-bridge-daemon").path
        ]

        for path in possiblePaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Default to same directory
        return binDir.appendingPathComponent("agent-bridge-daemon").path
    }
}

// MARK: - Run Command

struct Run: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Run an agent command through Agent Bridge"
    )

    @Option(name: .shortAndLong, help: "Daemon host")
    var host: String = "localhost"

    @Option(name: .shortAndLong, help: "Daemon port")
    var port: Int = 8765

    @Option(name: .shortAndLong, help: "Device key for authentication")
    var key: String?

    @Argument(help: "Command to run")
    var command: String

    @Argument(parsing: .remaining, help: "Command arguments")
    var arguments: [String] = []

    func run() async throws {
        guard let deviceKey = key ?? getStoredKey() else {
            print("Error: No device key provided. Use --key or pair first.")
            throw ExitCode.failure
        }

        let url = URL(string: "http://\(host):\(port)/sessions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(deviceKey)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "command": command,
            "arguments": arguments
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            print("Error: Invalid response")
            throw ExitCode.failure
        }

        if httpResponse.statusCode == 200 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sessionID = json["id"] as? String {
                print("Session created: \(sessionID)")
                print("Command: \(command) \(arguments.joined(separator: " "))")
            }
        } else {
            print("Error: \(httpResponse.statusCode)")
            if let errorText = String(data: data, encoding: .utf8) {
                print(errorText)
            }
            throw ExitCode.failure
        }
    }

    private func getStoredKey() -> String? {
        let keyPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agent-bridge")
            .appendingPathComponent("device.key")

        return try? String(contentsOf: keyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Sessions Command

struct Sessions: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "List active sessions"
    )

    @Option(name: .shortAndLong, help: "Daemon host")
    var host: String = "localhost"

    @Option(name: .shortAndLong, help: "Daemon port")
    var port: Int = 8765

    @Option(name: .shortAndLong, help: "Device key for authentication")
    var key: String?

    func run() async throws {
        guard let deviceKey = key ?? getStoredKey() else {
            print("Error: No device key provided. Use --key or pair first.")
            throw ExitCode.failure
        }

        let url = URL(string: "http://\(host):\(port)/sessions")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(deviceKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            print("Error: Invalid response")
            throw ExitCode.failure
        }

        if httpResponse.statusCode == 200 {
            if let sessions = try? JSONDecoder().decode([SessionInfo].self, from: data) {
                if sessions.isEmpty {
                    print("No active sessions")
                } else {
                    print("Active Sessions:")
                    print("-----------------")
                    for session in sessions {
                        print("[\(session.id)] \(session.command) - \(session.state)")
                    }
                }
            }
        } else {
            print("Error: \(httpResponse.statusCode)")
            throw ExitCode.failure
        }
    }

    private func getStoredKey() -> String? {
        let keyPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agent-bridge")
            .appendingPathComponent("device.key")

        return try? String(contentsOf: keyPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SessionInfo: Codable {
    let id: String
    let command: String
    let state: String
}

// MARK: - Pair Command

struct Pair: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Pair with a running daemon using a token"
    )

    @Option(name: .shortAndLong, help: "Daemon host")
    var host: String = "localhost"

    @Option(name: .shortAndLong, help: "Daemon port")
    var port: Int = 8765

    @Argument(help: "Pairing token")
    var token: String

    func run() async throws {
        let url = URL(string: "http://\(host):\(port)/pair")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let deviceID = getDeviceID()
        let body: [String: Any] = [
            "token": token,
            "deviceID": deviceID
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            print("Error: Invalid response")
            throw ExitCode.failure
        }

        if httpResponse.statusCode == 200 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let deviceKey = json["deviceKey"] as? String {
                // Store the key
                let keyDir = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".agent-bridge")

                try FileManager.default.createDirectory(at: keyDir, withIntermediateDirectories: true)

                let keyPath = keyDir.appendingPathComponent("device.key")
                try deviceKey.write(to: keyPath, atomically: true, encoding: .utf8)

                print("Successfully paired!")
                print("Device key stored at: \(keyPath.path)")
            }
        } else {
            print("Error: Pairing failed (\(httpResponse.statusCode))")
            if let errorText = String(data: data, encoding: .utf8) {
                print(errorText)
            }
            throw ExitCode.failure
        }
    }

    private func getDeviceID() -> String {
        // Use a stable device identifier
        let idPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".agent-bridge")
            .appendingPathComponent("device.id")

        if let existingID = try? String(contentsOf: idPath, encoding: .utf8) {
            return existingID.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Generate new ID
        let newID = UUID().uuidString
        try? FileManager.default.createDirectory(
            at: idPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? newID.write(to: idPath, atomically: true, encoding: .utf8)
        return newID
    }
}

// MARK: - Status Command

struct Status: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        abstract: "Check daemon status"
    )

    @Option(name: .shortAndLong, help: "Daemon host")
    var host: String = "localhost"

    @Option(name: .shortAndLong, help: "Daemon port")
    var port: Int = 8765

    func run() async throws {
        let url = URL(string: "http://\(host):\(port)/health")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 2

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                print("Status: Unknown")
                throw ExitCode.failure
            }

            if httpResponse.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let status = json["status"] as? String {
                    print("Status: \(status)")
                    print("Endpoint: http://\(host):\(port)")
                }
            } else {
                print("Status: Error (\(httpResponse.statusCode))")
                throw ExitCode.failure
            }
        } catch {
            print("Status: Not running")
            print("Error: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}
