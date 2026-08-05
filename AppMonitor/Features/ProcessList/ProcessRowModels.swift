import Foundation

/// One process row inside an `AppGroup`. Named to avoid colliding with
/// `Foundation.ProcessInfo`.
struct MonitoredProcess: Identifiable, Hashable {
    let id: Int32
    let pid: Int32
    let name: String
    let memoryBytes: UInt64
    let cpuPercent: Double
    /// False when the kernel refused to hand over this process's counters, so
    /// `memoryBytes` and `cpuPercent` are placeholder zeros rather than
    /// measurements. Kept separate from the values (instead of making them
    /// optional) because `Table`'s `value:` key paths require `Comparable`,
    /// which `Optional` is not — unknown rows sort as 0 and display as "—".
    let isReadable: Bool

    init(pid: Int32, name: String, memoryBytes: UInt64, cpuPercent: Double, isReadable: Bool) {
        self.id = pid
        self.pid = pid
        self.name = name
        self.memoryBytes = memoryBytes
        self.cpuPercent = cpuPercent
        self.isReadable = isReadable
    }
}

/// Top-level grouping built by `AppGroupBuilder`. Not rendered directly —
/// transformed into `[AppRow]` for the hierarchical `Table` (which requires
/// children to be the same type as the parent).
struct AppGroup: Identifiable, Hashable {
    let id: String
    let displayName: String
    let isAppBundle: Bool
    let bundlePath: String?
    let totalMemory: UInt64
    let totalCpu: Double
    let lowestPid: Int32
    let processes: [MonitoredProcess]
    /// Indicates whether the group should render flat (no disclosure) or as a
    /// header with children. See `AppGroupBuilder` for the rule.
    let isFlat: Bool

    /// True when at least one process in the group could be read. A partially
    /// readable group still shows its totals — they're a real lower bound —
    /// and only a group we couldn't read at all renders as "—".
    var isReadable: Bool { processes.contains(where: \.isReadable) }
}

/// Single row type used by the hierarchical `Table`. Children must be the same
/// type as the parent in SwiftUI's `Table(_:children:)`, so we collapse the
/// app-group/process distinction into one struct: header rows carry a
/// non-nil `children` array, leaf rows leave it nil.
struct AppRow: Identifiable, Hashable {
    let id: String
    let pid: Int32?       // shown on flat rows + child processes; nil for headers
    let displayName: String
    let bundlePath: String?
    let memory: UInt64
    let cpu: Double
    /// False when `memory`/`cpu` are placeholders for counters the kernel
    /// wouldn't give us — the cells render "—" instead of a misleading 0.
    let isReadable: Bool
    var children: [AppRow]?
}

extension AppGroup {
    /// Projects this group into the hierarchical row form Table consumes.
    func intoRow() -> AppRow {
        if isFlat, let first = processes.first {
            return AppRow(
                id: id,
                pid: first.pid,
                displayName: displayName,
                bundlePath: bundlePath,
                memory: totalMemory,
                cpu: totalCpu,
                isReadable: isReadable,
                children: nil
            )
        }
        return AppRow(
            id: id,
            pid: nil,
            displayName: displayName,
            bundlePath: bundlePath,
            memory: totalMemory,
            cpu: totalCpu,
            isReadable: isReadable,
            children: processes.map { proc in
                AppRow(
                    id: "\(id)/\(proc.pid)",
                    pid: proc.pid,
                    displayName: proc.name,
                    bundlePath: nil,
                    memory: proc.memoryBytes,
                    cpu: proc.cpuPercent,
                    isReadable: proc.isReadable,
                    children: nil
                )
            }
        )
    }
}
