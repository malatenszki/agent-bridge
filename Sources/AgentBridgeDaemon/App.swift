import Foundation
#if os(macOS)
import Darwin
#else
import Glibc
#endif

struct AgentBridgeDaemon {
    static func main() {
        // Use RunLoop to keep the main thread alive
        // This is necessary because Vapor's server runs on background threads

        Task {
            do {
                try await run()
            } catch {
                print("Error: \(error)")
                Foundation.exit(1)
            }
            // Note: run() should never return normally - server keeps running
            // If we get here, something went wrong
        }

        // Keep main thread alive forever (until SIGINT)
        dispatchMain()
    }

    static func run() async throws {
        print("Agent Bridge Daemon v1.0.0")
        print("==========================")

        let sessionManager = SessionManager()
        let authManager = AuthManager()

        // Get local IP
        guard let localIP = NetworkUtils.getLocalIPAddress() else {
            print("Error: Could not determine local IP address")
            Foundation.exit(1)
        }

        let port = ProcessInfo.processInfo.environment["AGENT_BRIDGE_PORT"].flatMap(Int.init) ?? 8765

        print("Starting server on \(localIP):\(port)")

        // Create API server
        let server: APIServer
        do {
            server = try APIServer(
                sessionManager: sessionManager,
                authManager: authManager,
                host: "0.0.0.0",
                port: port
            )
        } catch {
            print("Error: Failed to create server: \(error)")
            Foundation.exit(1)
        }

        // Generate pairing token
        let pairingToken = await authManager.generatePairingToken(validFor: 300)

        let pairingInfo = PairingInfo(
            host: localIP,
            port: port,
            token: pairingToken.token,
            expiresAt: pairingToken.expiresAt
        )

        // Display pairing info
        print("")
        print("=== PAIRING INFO ===")
        print("Host: \(localIP)")
        print("Port: \(port)")
        print("Token: \(pairingToken.token)")
        print("Expires: \(formatDate(pairingToken.expiresAt))")
        print("")

        // Generate and display QR code
        if let qrString = try? pairingInfo.toQRString() {
            print("Scan this QR code with the Agent Bridge iOS app:")
            print("")
            #if canImport(CoreImage)
            let qrCode = QRCodeGenerator.generateASCII(from: qrString)
            if qrCode.isEmpty {
                // Fallback to terminal QR code
                print(TerminalQRCode.generate(from: qrString))
            } else {
                print(qrCode)
            }
            #else
            // Linux: use terminal QR code generator
            print(TerminalQRCode.generate(from: qrString))
            #endif
            print("")
        } else {
            print("[Could not generate QR string]")
        }

        print("Waiting for connections...")
        print("Press Ctrl+C to stop")
        print("")

        // Flush stdout to ensure QR code is visible before server starts
        fflush(stdout)

        // Handle signals
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signalSource.setEventHandler {
            print("\nShutting down...")
            Task {
                try? await server.shutdown()
                Foundation.exit(0)
            }
        }
        #if os(macOS)
        Darwin.signal(SIGINT, SIG_IGN)
        #else
        Glibc.signal(SIGINT, SIG_IGN)
        #endif
        signalSource.resume()

        // Periodically refresh pairing token
        Task {
            while true {
                try await Task.sleep(nanoseconds: 60_000_000_000)
                let newToken = await authManager.generatePairingToken(validFor: 300)
                let newInfo = PairingInfo(
                    host: localIP,
                    port: port,
                    token: newToken.token,
                    expiresAt: newToken.expiresAt
                )

                print("\n=== NEW PAIRING TOKEN ===")
                print("Token: \(newToken.token)")
                print("Expires: \(formatDate(newToken.expiresAt))")
                if let qrString = try? newInfo.toQRString() {
                    print("")
                    #if canImport(CoreImage)
                    let qrCode = QRCodeGenerator.generateASCII(from: qrString)
                    print(qrCode.isEmpty ? TerminalQRCode.generate(from: qrString) : qrCode)
                    #else
                    print(TerminalQRCode.generate(from: qrString))
                    #endif
                }
                print("")
            }
        }

        // Start server
        do {
            try await server.start()
        } catch {
            print("Error: Server failed: \(error)")
            Foundation.exit(1)
        }
    }

    static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
