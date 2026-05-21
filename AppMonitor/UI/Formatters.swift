import Foundation

enum Formatters {
    static func memory(bytes: UInt64) -> String {
        let mb = Double(bytes) / 1024.0 / 1024.0
        if mb >= 1024.0 {
            return String(format: "%.2f GB", mb / 1024.0)
        }
        return String(format: "%.1f MB", mb)
    }

    static func cpu(percent: Double) -> String {
        String(format: "%.1f", percent)
    }

    static func gigabytes(bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1024.0 / 1024.0 / 1024.0)
    }
}
