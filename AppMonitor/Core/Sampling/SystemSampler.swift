import Darwin
import Foundation

/// System-wide totals for the footer: memory pressure, global CPU%, and root
/// volume disk space. Each call to `sample()` performs an independent reading
/// — global CPU is diffed against the previous call internally.
final class SystemSampler: @unchecked Sendable {
    private var previousCpuTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?

    func sample() -> SystemStatsSnapshot {
        SystemStatsSnapshot(
            totalMemory: totalPhysicalMemory(),
            usedMemory: usedPhysicalMemory(),
            usedSwap: usedSwap(),
            globalCpu: globalCpuUsage(),
            totalDisk: totalDisk(),
            freeDisk: freeDisk()
        )
    }

    // MARK: - Memory

    private func totalPhysicalMemory() -> UInt64 {
        var size: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &size, &len, nil, 0)
        return size
    }

    private func usedPhysicalMemory() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride
            / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        // Matches Activity Monitor's prominent "Memory Used" total exactly:
        //   Memory Used = Physical Memory - Free - Cached Files
        // Computing it additively (internal + speculative + wired + compressor)
        // undercounts by ~0.5 GB on typical systems because the kernel holds memory
        // that isn't tagged into any of those vm_statistics64 buckets (IOKit slabs,
        // misc kernel allocations). The subtractive form sidesteps that — anything
        // the kernel doesn't tag as freeable is, by definition, in use.
        // Swift 6 strict concurrency rejects `vm_kernel_page_size` (global var);
        // `host_page_size` is the concurrency-safe equivalent.
        var pageSizeRaw: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSizeRaw)
        let pageSize = UInt64(pageSizeRaw)
        let free = UInt64(stats.free_count) * pageSize
        let cached = UInt64(stats.external_page_count) * pageSize
        let total = totalPhysicalMemory()
        let freeable = free &+ cached
        return total > freeable ? total &- freeable : 0
    }

    // MARK: - Swap

    private func usedSwap() -> UInt64 {
        var usage = xsw_usage()
        var len = MemoryLayout<xsw_usage>.size
        let result = sysctlbyname("vm.swapusage", &usage, &len, nil, 0)
        guard result == 0 else { return 0 }
        return usage.xsu_used
    }

    // MARK: - CPU

    private func globalCpuUsage() -> Double {
        var info: host_cpu_load_info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride
            / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, reboundPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)

        defer { previousCpuTicks = (user, system, idle, nice) }
        guard let prior = previousCpuTicks else { return 0 }

        let userDelta = user &- prior.user
        let systemDelta = system &- prior.system
        let idleDelta = idle &- prior.idle
        let niceDelta = nice &- prior.nice
        let busy = userDelta + systemDelta + niceDelta
        let total = busy + idleDelta
        guard total > 0 else { return 0 }
        return Double(busy) / Double(total) * 100.0
    }

    // MARK: - Disk

    private func totalDisk() -> UInt64 {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
              let total = attrs[.systemSize] as? NSNumber
        else { return 0 }
        return total.uint64Value
    }

    private func freeDisk() -> UInt64 {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
              let free = attrs[.systemFreeSize] as? NSNumber
        else { return 0 }
        return free.uint64Value
    }
}
