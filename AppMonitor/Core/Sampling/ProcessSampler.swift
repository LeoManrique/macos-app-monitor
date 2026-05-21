import Darwin
import Foundation

enum ProcessSampler {
    /// Enumerates every process via `proc_listpids` and returns a per-pid
    /// snapshot. `RUSAGE_INFO_V4` provides both phys_footprint and CPU time in
    /// one syscall; we fall back to `proc_pidinfo`'s resident_size when the
    /// kernel returns EPERM (processes the user doesn't own).
    static func enumerate() -> [RawProcess] {
        let pids = listAllPids()
        var out: [RawProcess] = []
        out.reserveCapacity(pids.count)

        for pid in pids where pid > 0 {
            let name = processName(pid: pid)
            let path = executablePath(pid: pid)
            let (memory, cpu) = PhysFootprint.memoryAndCpu(pid: pid)
            let resolvedMemory = memory ?? residentSize(pid: pid)
            out.append(RawProcess(
                pid: pid,
                name: name,
                executablePath: path,
                memoryBytes: resolvedMemory,
                cpuTimeNanos: cpu
            ))
        }
        return out
    }

    private static func listAllPids() -> [Int32] {
        // Sized query → allocation → real query. Re-asking gives a stable count
        // even if processes spawn/die between calls (we just truncate to what fit).
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return [] }
        let slots = Int(needed) / MemoryLayout<Int32>.size + 16
        var buffer = [Int32](repeating: 0, count: slots)
        let written = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, ptr.baseAddress, Int32(ptr.count * MemoryLayout<Int32>.size))
        }
        guard written > 0 else { return [] }
        let count = Int(written) / MemoryLayout<Int32>.size
        return Array(buffer.prefix(count))
    }

    private static func executablePath(pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE = MAXPATHLEN * 4 = 4096; not always bridged
        // as a Swift constant, so we hard-code it. Matches sys/proc_info.h.
        var buffer = [CChar](repeating: 0, count: 4096)
        let written = buffer.withUnsafeMutableBufferPointer { ptr in
            proc_pidpath(pid, ptr.baseAddress, UInt32(ptr.count))
        }
        guard written > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func processName(pid: Int32) -> String {
        // proc_name caps at MAXCOMLEN+1 (16 chars + null) — that's all the
        // kernel keeps. For the full bundled name we'd need argv parsing
        // (sysctl KERN_PROCARGS2), but every existing call site already keys
        // off the exe path's basename, so the short name is enough.
        var buffer = [CChar](repeating: 0, count: 4096)
        let written = buffer.withUnsafeMutableBufferPointer { ptr in
            proc_name(pid, ptr.baseAddress, UInt32(ptr.count))
        }
        if written > 0 {
            return String(cString: buffer)
        }
        // Last resort — basename of the exe.
        if let path = executablePath(pid: pid) {
            return (path as NSString).lastPathComponent
        }
        return ""
    }

    private static func residentSize(pid: Int32) -> UInt64 {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let written = withUnsafeMutablePointer(to: &info) { ptr in
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, ptr, size)
        }
        guard written == size else { return 0 }
        return info.pti_resident_size
    }
}
