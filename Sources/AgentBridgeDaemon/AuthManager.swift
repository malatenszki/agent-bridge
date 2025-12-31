import Foundation
import Crypto

/// Manages authentication tokens and device pairing
actor AuthManager {
    /// Pairing tokens (short-lived, single-use)
    private var pairingTokens: [String: PairingToken] = [:]

    /// Device session keys (long-lived, per-device)
    private var deviceKeys: [String: DeviceKey] = [:]

    /// File path for persisting device keys
    private let keysFilePath: URL

    /// Get platform-specific config directory
    private static func getConfigDirectory() -> URL {
        #if os(macOS)
        // macOS: ~/Library/Application Support/AgentBridge/
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("AgentBridge")
        #else
        // Linux: ~/.config/AgentBridge/
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/AgentBridge")
        #endif
    }

    init() {
        let appDir = Self.getConfigDirectory()

        // Create directory if needed
        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        keysFilePath = appDir.appendingPathComponent("device_keys.json")

        // Load existing keys
        loadDeviceKeys()
    }

    /// Load device keys from disk
    private func loadDeviceKeys() {
        guard FileManager.default.fileExists(atPath: keysFilePath.path) else { return }

        do {
            let data = try Data(contentsOf: keysFilePath)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let keys = try decoder.decode([DeviceKey].self, from: data)
            deviceKeys = Dictionary(uniqueKeysWithValues: keys.map { ($0.key, $0) })
        } catch {
            print("Failed to load device keys: \(error)")
        }
    }

    /// Save device keys to disk
    private func saveDeviceKeys() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(Array(deviceKeys.values))
            try data.write(to: keysFilePath)
        } catch {
            print("Failed to save device keys: \(error)")
        }
    }

    /// Generate a new pairing token
    func generatePairingToken(validFor seconds: TimeInterval = 60) -> PairingToken {
        let token = PairingToken(
            token: generateSecureToken(length: 6),
            expiresAt: Date().addingTimeInterval(seconds),
            used: false
        )
        pairingTokens[token.token] = token
        cleanupExpiredTokens()
        return token
    }

    /// Validate and consume a pairing token, returning a device key
    func validatePairingToken(_ token: String, deviceID: String) -> DeviceKey? {
        guard var pairingToken = pairingTokens[token] else {
            return nil
        }

        // Check if expired
        guard pairingToken.expiresAt > Date() else {
            pairingTokens.removeValue(forKey: token)
            return nil
        }

        // Check if already used
        guard !pairingToken.used else {
            return nil
        }

        // Mark as used
        pairingToken.used = true
        pairingTokens[token] = pairingToken

        // Generate device key
        let deviceKey = DeviceKey(
            deviceID: deviceID,
            key: generateSecureToken(length: 32),
            createdAt: Date(),
            lastUsed: Date()
        )
        deviceKeys[deviceKey.key] = deviceKey

        // Persist to disk
        saveDeviceKeys()

        return deviceKey
    }

    /// Validate a device key
    func validateDeviceKey(_ key: String) -> Bool {
        guard var deviceKey = deviceKeys[key] else {
            return false
        }

        // Update last used time
        deviceKey.lastUsed = Date()
        deviceKeys[key] = deviceKey

        return true
    }

    /// Revoke a device key
    func revokeDeviceKey(_ key: String) {
        deviceKeys.removeValue(forKey: key)
        saveDeviceKeys()
    }

    /// Get all paired devices
    func getPairedDevices() -> [DeviceKey] {
        return Array(deviceKeys.values)
    }

    /// Cleanup expired pairing tokens
    private func cleanupExpiredTokens() {
        let now = Date()
        pairingTokens = pairingTokens.filter { $0.value.expiresAt > now }
    }

    /// Generate a cryptographically secure token
    private func generateSecureToken(length: Int) -> String {
        let chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" // Avoid confusing chars like 0/O, 1/I
        var randomBytes = [UInt8](repeating: 0, count: length)

        #if os(macOS)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &randomBytes)
        #else
        // Linux: read from /dev/urandom
        guard let file = fopen("/dev/urandom", "r") else {
            // Fallback to Swift's random
            for _ in 0..<length {
                randomBytes.append(UInt8.random(in: 0...255))
            }
            randomBytes = Array(randomBytes.prefix(length))
            return generateFromBytes(randomBytes, chars: chars)
        }
        fread(&randomBytes, 1, length, file)
        fclose(file)
        #endif

        return generateFromBytes(randomBytes, chars: chars)
    }

    private func generateFromBytes(_ bytes: [UInt8], chars: String) -> String {
        var result = ""
        for byte in bytes {
            let index = Int(byte) % chars.count
            result.append(chars[chars.index(chars.startIndex, offsetBy: index)])
        }
        return result
    }
}

/// Short-lived pairing token
struct PairingToken: Codable, Sendable {
    let token: String
    let expiresAt: Date
    var used: Bool
}

/// Long-lived device key
struct DeviceKey: Codable, Sendable {
    let deviceID: String
    let key: String
    let createdAt: Date
    var lastUsed: Date
}

/// Pairing info for QR code
struct PairingInfo: Codable, Sendable {
    let host: String
    let port: Int
    let token: String
    let expiresAt: Date

    /// Generate QR code data
    func toQRData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Generate QR code string
    func toQRString() throws -> String {
        let data = try toQRData()
        return data.base64EncodedString()
    }
}
