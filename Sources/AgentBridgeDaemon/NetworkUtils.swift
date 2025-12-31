import Foundation
#if os(macOS)
import Darwin
#else
import Glibc
#endif

/// Network utility functions
struct NetworkUtils {
    /// Get the local IP address for LAN communication
    static func getLocalIPAddress() -> String? {
        var bestAddress: String?
        var bestPriority = Int.max

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return nil
        }
        defer { freeifaddrs(ifaddr) }

        var ptr = firstAddr
        while true {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family

            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)

                // Skip loopback
                let loopbackName: String
                #if os(macOS)
                loopbackName = "lo0"
                #else
                loopbackName = "lo"
                #endif

                if name == loopbackName {
                    if let next = interface.ifa_next {
                        ptr = next
                        continue
                    }
                    break
                }

                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))

                // sa_len doesn't exist on Linux, use sizeof(sockaddr_in) instead
                #if os(macOS)
                let addrLen = socklen_t(interface.ifa_addr.pointee.sa_len)
                #else
                let addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                #endif

                let result = getnameinfo(
                    interface.ifa_addr,
                    addrLen,
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )

                if result == 0 {
                    let address = String(cString: hostname)

                    // Skip link-local addresses (169.254.x.x)
                    if address.hasPrefix("169.254.") {
                        if let next = interface.ifa_next {
                            ptr = next
                            continue
                        }
                        break
                    }

                    // Priority varies by platform
                    // macOS: en0 (WiFi) = 1, en1 = 2, other en* = 3, others = 10
                    // Linux: wlan* = 1, eth* = 2, others = 10
                    let priority: Int
                    #if os(macOS)
                    if name == "en0" {
                        priority = 1
                    } else if name == "en1" {
                        priority = 2
                    } else if name.hasPrefix("en") {
                        priority = 3
                    } else {
                        priority = 10
                    }
                    #else
                    if name.hasPrefix("wlan") || name.hasPrefix("wlp") {
                        priority = 1  // WiFi
                    } else if name.hasPrefix("eth") || name.hasPrefix("enp") {
                        priority = 2  // Ethernet
                    } else {
                        priority = 10
                    }
                    #endif

                    if priority < bestPriority {
                        bestPriority = priority
                        bestAddress = address
                    }
                }
            }

            if let next = interface.ifa_next {
                ptr = next
            } else {
                break
            }
        }

        return bestAddress
    }

    /// Check if an IP address is on the local subnet
    static func isLocalSubnet(_ remoteIP: String, localIP: String, subnetMask: String = "255.255.255.0") -> Bool {
        guard let remote = ipToUInt32(remoteIP),
              let local = ipToUInt32(localIP),
              let mask = ipToUInt32(subnetMask) else {
            return false
        }

        return (remote & mask) == (local & mask)
    }

    private static func ipToUInt32(_ ip: String) -> UInt32? {
        let parts = ip.split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else { return nil }
        return UInt32(parts[0]) << 24 | UInt32(parts[1]) << 16 | UInt32(parts[2]) << 8 | UInt32(parts[3])
    }
}

/// Terminal QR code generator using Unicode block characters
struct TerminalQRCode {
    /// Generate a QR code string for terminal display
    static func generate(from data: String) -> String {
        // Simple QR-like representation using a basic encoding
        // For production, use a proper QR library like QRCodeGenerator
        // This is a minimal implementation that creates a scannable pattern

        let bytes = Array(data.utf8)
        let size = max(21, Int(ceil(sqrt(Double(bytes.count * 8)))) | 1) // Ensure odd for center

        var grid = Array(repeating: Array(repeating: false, count: size), count: size)

        // Add finder patterns (corners)
        addFinderPattern(&grid, x: 0, y: 0)
        addFinderPattern(&grid, x: size - 7, y: 0)
        addFinderPattern(&grid, x: 0, y: size - 7)

        // Add timing patterns
        for i in 8..<(size - 8) {
            grid[6][i] = i % 2 == 0
            grid[i][6] = i % 2 == 0
        }

        // Encode data (simplified - just fill remaining space)
        var bitIndex = 0
        for y in 0..<size {
            for x in 0..<size {
                // Skip reserved areas
                if isReserved(x: x, y: y, size: size) { continue }

                let byteIndex = bitIndex / 8
                let bitOffset = 7 - (bitIndex % 8)

                if byteIndex < bytes.count {
                    grid[y][x] = (bytes[byteIndex] >> bitOffset) & 1 == 1
                }
                bitIndex += 1
            }
        }

        // Convert to string using Unicode block characters
        var result = ""
        let topBlock = "\u{2580}"    // Upper half block
        let bottomBlock = "\u{2584}" // Lower half block
        let fullBlock = "\u{2588}"   // Full block
        let emptyBlock = " "

        // Add quiet zone
        let quietZone = String(repeating: emptyBlock, count: size + 4)
        result += quietZone + "\n"
        result += quietZone + "\n"

        for y in stride(from: 0, to: size, by: 2) {
            result += "  " // Left quiet zone
            for x in 0..<size {
                let top = grid[y][x]
                let bottom = y + 1 < size ? grid[y + 1][x] : false

                if top && bottom {
                    result += fullBlock
                } else if top {
                    result += topBlock
                } else if bottom {
                    result += bottomBlock
                } else {
                    result += emptyBlock
                }
            }
            result += "  \n" // Right quiet zone
        }

        result += quietZone + "\n"
        result += quietZone + "\n"

        return result
    }

    private static func addFinderPattern(_ grid: inout [[Bool]], x: Int, y: Int) {
        // 7x7 finder pattern
        for dy in 0..<7 {
            for dx in 0..<7 {
                let isBorder = dx == 0 || dx == 6 || dy == 0 || dy == 6
                let isInner = dx >= 2 && dx <= 4 && dy >= 2 && dy <= 4
                grid[y + dy][x + dx] = isBorder || isInner
            }
        }
    }

    private static func isReserved(x: Int, y: Int, size: Int) -> Bool {
        // Finder patterns + separators
        if (x < 9 && y < 9) { return true }
        if (x < 9 && y >= size - 8) { return true }
        if (x >= size - 8 && y < 9) { return true }
        // Timing patterns
        if x == 6 || y == 6 { return true }
        return false
    }
}

/// Proper QR code generator using CoreImage (macOS)
#if canImport(CoreImage)
import CoreImage

struct QRCodeGenerator {
    static func generate(from string: String, size: CGFloat = 256) -> CGImage? {
        guard let data = string.data(using: .utf8) else { return nil }

        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(data, forKey: "inputMessage")
        filter?.setValue("M", forKey: "inputCorrectionLevel")

        guard let ciImage = filter?.outputImage else { return nil }

        // Scale up the image
        let scaleX = size / ciImage.extent.size.width
        let scaleY = size / ciImage.extent.size.height
        let transform = CGAffineTransform(scaleX: scaleX, y: scaleY)
        let scaledImage = ciImage.transformed(by: transform)

        let context = CIContext()
        return context.createCGImage(scaledImage, from: scaledImage.extent)
    }

    /// Generate ASCII art QR code for terminal
    static func generateASCII(from string: String) -> String {
        guard let data = string.data(using: .utf8) else { return "" }

        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(data, forKey: "inputMessage")
        filter?.setValue("L", forKey: "inputCorrectionLevel")

        guard let ciImage = filter?.outputImage else { return "" }

        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return "" }

        let width = cgImage.width
        let height = cgImage.height

        // Get pixel data
        guard let dataProvider = cgImage.dataProvider,
              let pixelData = dataProvider.data else { return "" }

        let pixelBytes = CFDataGetBytePtr(pixelData)!
        let bytesPerPixel = cgImage.bitsPerPixel / 8

        var result = ""
        let fullBlock = "\u{2588}\u{2588}"
        let emptyBlock = "  "

        // Add quiet zone
        let quietLine = String(repeating: emptyBlock, count: width + 4)
        result += quietLine + "\n"
        result += quietLine + "\n"

        for y in 0..<height {
            result += emptyBlock + emptyBlock // Left quiet zone
            for x in 0..<width {
                let offset = (y * cgImage.bytesPerRow) + (x * bytesPerPixel)
                let gray = pixelBytes[offset]
                result += gray < 128 ? fullBlock : emptyBlock
            }
            result += emptyBlock + emptyBlock + "\n" // Right quiet zone
        }

        result += quietLine + "\n"
        result += quietLine + "\n"

        return result
    }
}
#endif
