import Foundation

/// Converts cumulative per-pid CPU nanoseconds into a per-tick percentage by
/// diffing against the previous sample. Mirrors `sysinfo`'s "delta over wall
/// clock × cores" model so the resulting % matches what users see in Activity
/// Monitor (a single fully-busy core ≈ 100%).
final class ProcessCPUSampler: @unchecked Sendable {
    private struct Sample {
        let cpuNanos: UInt64
        let at: Date
    }

    private var previous: [Int32: Sample] = [:]

    func cpuPercents(for processes: [RawProcess], sampledAt now: Date) -> [Int32: Double] {
        var out: [Int32: Double] = [:]
        out.reserveCapacity(processes.count)
        var next: [Int32: Sample] = [:]
        next.reserveCapacity(processes.count)

        for proc in processes {
            let current = Sample(cpuNanos: proc.cpuTimeNanos, at: now)
            next[proc.pid] = current

            guard let prior = previous[proc.pid] else {
                out[proc.pid] = 0
                continue
            }
            let elapsedSecs = now.timeIntervalSince(prior.at)
            guard elapsedSecs > 0 else {
                out[proc.pid] = 0
                continue
            }
            let cpuSecs = Double(current.cpuNanos &- prior.cpuNanos) / 1e9
            out[proc.pid] = (cpuSecs / elapsedSecs) * 100.0
        }

        previous = next
        return out
    }
}
