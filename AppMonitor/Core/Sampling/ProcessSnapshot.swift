import Foundation

struct RawProcess: Sendable, Hashable {
    let pid: Int32
    let name: String
    let executablePath: String?
    let memoryBytes: UInt64
    let cpuTimeNanos: UInt64
}

struct SystemStatsSnapshot: Sendable {
    let totalMemory: UInt64
    let usedMemory: UInt64
    let globalCpu: Double
    let totalDisk: UInt64
    let freeDisk: UInt64

    static let empty = SystemStatsSnapshot(
        totalMemory: 0, usedMemory: 0, globalCpu: 0, totalDisk: 0, freeDisk: 0
    )
}

struct ProcessSnapshot: Sendable {
    let processes: [RawProcess]
    let stats: SystemStatsSnapshot
    let sampledAt: Date
}
