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

    /// Reads phys_footprint and CPU time in one syscall — avoids paying the
    /// rusage_info cost twice when we want both numbers for the same pid.
    ///
    /// `cpuMachTicks` is user+system time in **mach absolute time units**, NOT
    /// nanoseconds. `<sys/resource.h>` documents no unit for `ri_user_time` /
    /// `ri_system_time`, and the natural reading ("it's a uint64 of time, so
    /// nanoseconds") is wrong: the kernel stores raw mach ticks. On Apple
    /// Silicon the timebase is 125/3, so treating these as nanoseconds
    /// undercounts CPU by 41.67x. Verified against `ps -o time`, which is
    /// setuid-root and reads the same counters: for a long-lived process
    /// `ps` reported 602:32.40 where the mach-tick conversion gives 36153 s
    /// (= 602:33) and the nanosecond reading gives 868 s.
    ///
    /// Callers should not convert to nanoseconds — pair this with a
    /// `mach_absolute_time()` reading and take the ratio, so the timebase
    /// cancels out and the math is correct on Intel and Apple Silicon alike.
    ///
    /// Returns `nil` memory and 0 ticks on EPERM (processes we aren't entitled
    /// to inspect); `readable` reports which happened.
    static func memoryAndCpu(pid: Int32) -> (memory: UInt64?, cpuMachTicks: UInt64, readable: Bool) {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { reboundPtr in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, reboundPtr)
            }
        }
        if result == 0 {
            return (info.ri_phys_footprint, info.ri_user_time &+ info.ri_system_time, true)
        }
        return (nil, 0, false)
    }
}
