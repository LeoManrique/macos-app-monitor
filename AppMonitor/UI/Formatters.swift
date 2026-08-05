import Foundation

enum Formatters {
    /// Shown when macOS refused us a process's counters. An em dash reads as
    /// "not available" where a 0 would read as "idle" — see `RawProcess.isReadable`.
    static let unknown = "—"

    static func memory(bytes: UInt64, known: Bool = true) -> String {
        guard known else { return unknown }
        let mb = Double(bytes) / 1024.0 / 1024.0
        if mb >= 1024.0 {
            return String(format: "%.2f GB", mb / 1024.0)
        }
        return String(format: "%.1f MB", mb)
    }

    static func cpu(percent: Double, known: Bool = true) -> String {
        guard known else { return unknown }
        return String(format: "%.1f", percent)
    }

    static func gigabytes(bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1024.0 / 1024.0 / 1024.0)
    }
}
