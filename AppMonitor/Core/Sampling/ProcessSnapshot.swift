import Foundation

/// `Codable` because the privileged helper ships these across XPC — see
/// `HelperWire`.
struct RawProcess: Sendable, Hashable, Codable {
    let pid: Int32
    let name: String
    let executablePath: String?
    let memoryBytes: UInt64
    /// Cumulative user+system CPU time in *mach absolute time units*, not
    /// nanoseconds — see `PhysFootprint.memoryAndCpu`.
    let cpuTimeMachTicks: UInt64
    /// `mach_absolute_time()` read immediately after this pid's CPU counter, so
    /// the CPU sampler can diff against a clock captured at the same instant
    /// rather than one stamped after the whole enumeration finished.
    let sampledAtMachTicks: UInt64
    /// False when `proc_pid_rusage` returned EPERM — we are not entitled to read
    /// this process, so its memory and CPU are unknown rather than zero.
    let isReadable: Bool
}

struct SystemStatsSnapshot: Sendable {
    let totalMemory: UInt64
    let usedMemory: UInt64
    let usedSwap: UInt64
    let globalCpu: Double
    let totalDisk: UInt64
    let freeDisk: UInt64

    static let empty = SystemStatsSnapshot(
        totalMemory: 0, usedMemory: 0, usedSwap: 0, globalCpu: 0, totalDisk: 0, freeDisk: 0
    )
}

struct ProcessSnapshot: Sendable {
    let processes: [RawProcess]
    let stats: SystemStatsSnapshot
    let sampledAt: Date
}
