import Darwin

enum PhysFootprint {
    /// Reads `ri_phys_footprint` via `proc_pid_rusage(pid, RUSAGE_INFO_V4, &)`.
    /// Returns nil on EPERM (processes the user doesn't own); caller falls back to RSS.
    static func read(pid: Int32) -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPtr in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, reboundPtr)
            }
        }
        guard result == 0 else { return nil }
        return info.ri_phys_footprint
    }

    /// CPU time consumed by the process so far (user + system), in nanoseconds.
    /// Returned alongside the memory read so a CPU sampler can diff across ticks.
    static func cpuTimeNanos(pid: Int32) -> UInt64 {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPtr in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, reboundPtr)
            }
        }
        guard result == 0 else { return 0 }
        return info.ri_user_time &+ info.ri_system_time
    }

    /// Reads phys_footprint and cpu time in one syscall — avoids paying the
    /// rusage_info cost twice when we want both numbers for the same pid.
    static func memoryAndCpu(pid: Int32) -> (memory: UInt64?, cpuNanos: UInt64) {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPtr in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, reboundPtr)
            }
        }
        if result == 0 {
            return (info.ri_phys_footprint, info.ri_user_time &+ info.ri_system_time)
        }
        return (nil, 0)
    }
}
