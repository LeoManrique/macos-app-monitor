import Foundation

/// Pure function: maps a `[RawProcess]` snapshot + per-pid CPU% into the
/// hierarchical `[AppRow]` the UI renders. Grouping rule mirrors the Rust
/// app's `build_groups`: each process keys on its enclosing `.app` (leftmost
/// match) when there is one, otherwise on the bare process name. A group
/// renders flat when it has only one process AND that process's name matches
/// the bundle name (or the process isn't in any bundle).
enum AppGroupBuilder {
    static func build(
        from processes: [RawProcess],
        cpuPercents: [Int32: Double],
        sort: GroupSort
    ) -> [AppRow] {
        var byKey: [String: (isAppBundle: Bool, bundlePath: String?, procs: [MonitoredProcess])] = [:]

        for raw in processes {
            let cpu = cpuPercents[raw.pid] ?? 0
            let monitored = MonitoredProcess(
                pid: raw.pid,
                name: raw.name,
                memoryBytes: raw.memoryBytes,
                cpuPercent: cpu,
                isReadable: raw.isReadable
            )

            let key: String
            let isAppBundle: Bool
            let bundlePath: String?
            if let exePath = raw.executablePath,
               let bundle = AppBundleResolver.resolve(executablePath: exePath) {
                key = bundle.name
                isAppBundle = true
                bundlePath = bundle.bundlePath
            } else {
                key = raw.name
                isAppBundle = false
                bundlePath = nil
            }

            var entry = byKey[key] ?? (isAppBundle, bundlePath, [])
            entry.isAppBundle = entry.isAppBundle || isAppBundle
            if entry.bundlePath == nil { entry.bundlePath = bundlePath }
            entry.procs.append(monitored)
            byKey[key] = entry
        }

        let processComparators = sort.processComparators
        let groupComparators = sort.groupComparators

        var groups: [AppGroup] = byKey.map { name, entry in
            let sortedProcs = entry.procs.sorted(using: processComparators)
            let totalMemory = sortedProcs.reduce(UInt64(0)) { $0 + $1.memoryBytes }
            let totalCpu = sortedProcs.reduce(0.0) { $0 + $1.cpuPercent }
            let lowestPid = sortedProcs.map(\.pid).min() ?? 0

            let singleSelfMatches = sortedProcs.count == 1
                && entry.isAppBundle
                && sortedProcs[0].name == name
            let isFlat = !entry.isAppBundle || singleSelfMatches

            return AppGroup(
                id: name,
                displayName: name,
                isAppBundle: entry.isAppBundle,
                bundlePath: entry.bundlePath,
                totalMemory: totalMemory,
                totalCpu: totalCpu,
                lowestPid: lowestPid,
                processes: sortedProcs,
                isFlat: isFlat
            )
        }

        groups.sort(using: groupComparators)
        return groups.map { $0.intoRow() }
    }
}
