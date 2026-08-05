import Darwin
import Foundation

/// Converts cumulative per-pid CPU counters into a per-tick percentage by
/// diffing against the previous sample.
///
/// The result is a **share of the whole machine**, so the column adds up to the
/// footer's global CPU figure and 100% means every core is saturated. This
/// deliberately departs from Activity Monitor and `top`, which report a share
/// of one core (a saturated 4-thread process shows 400% there and 33.3% here on
/// a 12-core machine). Making the rows reconcile with the total was the point;
/// see DESIGN.md.
///
/// Both the CPU counter (`ri_user_time + ri_system_time`) and the timestamp
/// (`mach_absolute_time`) are in mach absolute time units, so the core-relative
/// ratio is a pure division of the two and the mach timebase cancels out. That
/// is deliberate: it keeps the math correct on Apple Silicon (timebase 125/3)
/// and Intel (1/1) without branching on the platform or converting to
/// nanoseconds — the conversion this code previously got wrong.
final class ProcessCPUSampler: @unchecked Sendable {
    private struct Sample {
        let cpuTicks: UInt64
        let atTicks: UInt64
    }

    /// Logical CPU count — the divisor that turns "share of one core" into
    /// "share of the machine". Matches the denominator `SystemSampler` gets
    /// implicitly from `host_cpu_load_info`, whose tick counters already
    /// aggregate every logical CPU.
    private static let coreCount = Double(max(ProcessInfo.processInfo.processorCount, 1))

    private var previous: [Int32: Sample] = [:]

    func cpuPercents(for processes: [RawProcess]) -> [Int32: Double] {
        var out: [Int32: Double] = [:]
        out.reserveCapacity(processes.count)
        var next: [Int32: Sample] = [:]
        next.reserveCapacity(processes.count)

        for proc in processes {
            let current = Sample(cpuTicks: proc.cpuTimeMachTicks, atTicks: proc.sampledAtMachTicks)
            next[proc.pid] = current

            guard let prior = previous[proc.pid] else {
                out[proc.pid] = 0
                continue
            }
            // A pid recycled between ticks looks like a counter running
            // backwards. Restart from zero instead of wrapping into a huge
            // bogus delta.
            guard current.cpuTicks >= prior.cpuTicks, current.atTicks > prior.atTicks else {
                out[proc.pid] = 0
                continue
            }
            let cpuDelta = Double(current.cpuTicks - prior.cpuTicks)
            let elapsed = Double(current.atTicks - prior.atTicks)
            let shareOfMachine = cpuDelta / elapsed / Self.coreCount * 100.0
            // Nothing can exceed the whole machine; clamps the nonsense a
            // recycled pid or a clock hiccup would otherwise produce.
            out[proc.pid] = min(shareOfMachine, 100.0)
        }

        previous = next
        return out
    }
}
