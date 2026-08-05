import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class ProcessMonitor {
    private(set) var rows: [AppRow] = []
    private(set) var stats: SystemStatsSnapshot = .empty
    var sort: GroupSort = .default {
        didSet { resort() }
    }

    /// Live text from the toolbar search field. Filtering runs against the last
    /// snapshot rather than a fresh sample, so typing updates the table
    /// immediately instead of waiting for the next 2 s tick.
    var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            applyFilter()
        }
    }
    /// Bumped by the Find command; the view watches it and moves focus into the
    /// search field. A counter rather than a flag so repeated ⌘F re-focuses.
    private(set) var searchFocusRequests = 0

    /// Row ids selected in the Table. Ids are stable across refreshes
    /// (`bundle-or-process-name` for top-level rows, `parent/pid` for
    /// children), so a selection survives the 2 s tick; `refresh()` prunes ids
    /// whose process has since exited.
    var selection: Set<AppRow.ID> = []
    /// Set when the user asks to quit something; drives the confirmation
    /// dialog. Cleared on confirm or cancel.
    var pendingTermination: TerminationRequest?
    /// Whatever refused to die on the last attempt; drives the failure alert.
    var terminationError: TerminationError?

    /// Why some rows may read "—". Mirrors the helper's state after each tick so
    /// the UI can explain an incomplete picture rather than just showing gaps.
    private(set) var helperStatus: HelperClient.Status = .notInstalled

    /// Every group in the last snapshot, before `searchText` is applied. `rows`
    /// is the visible subset; keeping both means a keystroke re-filters instead
    /// of re-grouping several hundred processes.
    private var allRows: [AppRow] = []
    private var lastProcesses: [RawProcess] = []
    private var lastCpuPercents: [Int32: Double] = [:]
    private let cpuSampler = ProcessCPUSampler()
    private let systemSampler = SystemSampler()
    private let iconLoader = AppIconLoader()
    private let helper = HelperClient()
    private var refreshTask: Task<Void, Never>?

    /// Public access for views: returns a cached icon if loaded, otherwise nil.
    /// Callers should `.task` themselves and call `loadIcon(forBundle:)` to
    /// trigger the async load.
    func icon(forBundle path: String) async -> NSImage? {
        await iconLoader.icon(forBundle: path)
    }

    func start() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            // Prime first frame immediately, then tick every 2 s.
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                await self?.refresh()
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func refresh() async {
        // Off-main: enumerate processes. The detached enumeration takes the
        // bulk of the time on machines with hundreds of processes; keeping it
        // off the main actor avoids stutter in the Table.
        let sort = self.sort
        // Prefer the privileged helper: unprivileged sampling can't see the
        // ~30% of processes the user doesn't own, which includes the biggest
        // CPU consumers (WindowServer, kernel_task). Falls back silently — a
        // non-notarized build can never register the daemon.
        let helper = self.helper
        let raws = await Task.detached { helper.sample() ?? ProcessSampler.enumerate() }.value
        let helperStatus = helper.status
        let stats = systemSampler.sample()
        // Each RawProcess carries the mach timestamp of its own counter read,
        // so the sampler needs no wall-clock reading from here.
        let cpu = cpuSampler.cpuPercents(for: raws)
        let built = AppGroupBuilder.build(from: raws, cpuPercents: cpu, sort: sort)

        // Push the state write to the *next* runloop iteration via
        // DispatchQueue.main.async — Task.yield alone isn't enough to escape
        // an in-flight NSTableView delegate callback, which produces a
        // reentrant-operation warning every refresh tick under SwiftUI Table.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        self.lastProcesses = raws
        self.lastCpuPercents = cpu
        self.allRows = built
        self.stats = stats
        self.helperStatus = helperStatus
        applyFilter()
    }

    // MARK: - Search

    /// Moves keyboard focus into the search field. Driven by the Find command,
    /// which can't reach the view's `@FocusState` directly.
    func focusSearch() {
        searchFocusRequests += 1
    }

    /// Recomputes the visible rows from the last snapshot. Selection is pruned
    /// to what's on screen, so a row hidden by the filter can't be quit by a
    /// menu command the user can no longer see the target of.
    private func applyFilter() {
        rows = RowFilter.apply(allRows, query: searchText)
        pruneSelection()
    }

    // MARK: - Privileged helper

    /// Installs the root sampler. Registration is deliberately user-initiated
    /// (a menu command) rather than automatic on launch — it puts a LaunchDaemon
    /// on the system, which isn't something to do behind the user's back.
    func enableFullProcessAccess() {
        do {
            try HelperClient.register()
            helperStatus = HelperClient.registrationStatus() == .requiresApproval
                ? .requiresApproval
                : .active
        } catch {
            helperStatus = .failed(error.localizedDescription)
        }
    }

    func disableFullProcessAccess() {
        do {
            try HelperClient.unregister()
            helperStatus = .notInstalled
        } catch {
            helperStatus = .failed(error.localizedDescription)
        }
    }

    /// Drops selected ids whose row no longer exists (process exited, or the
    /// group collapsed into a flat row after its helpers went away).
    private func pruneSelection() {
        guard !selection.isEmpty else { return }
        var live: Set<AppRow.ID> = []
        for row in rows {
            live.insert(row.id)
            for child in row.children ?? [] { live.insert(child.id) }
        }
        let pruned = selection.intersection(live)
        if pruned != selection { selection = pruned }
    }

    // MARK: - Termination

    /// Asks to end the current selection. No-op when nothing is selected, so
    /// menu items stay harmless if they fire with an empty table.
    func requestTermination(mode: TerminationMode) {
        requestTermination(ids: selection, mode: mode)
    }

    /// Asks to end a specific set of rows — the context menu passes the
    /// right-clicked rows, which may differ from `selection`.
    func requestTermination(ids: Set<AppRow.ID>, mode: TerminationMode) {
        let targets = terminationTargets(for: ids)
        guard !targets.isEmpty else { return }
        // One row is an unambiguous action — act on it directly, however many
        // processes it expands to. Only multi-row selections confirm, where a
        // stray ⌘-click could otherwise take down apps the user didn't mean.
        guard targets.count > 1 else {
            terminate(targets, mode: mode)
            return
        }
        pendingTermination = TerminationRequest(targets: targets, mode: mode)
    }

    /// Carries out the pending request. `mode` is passed in because the dialog
    /// offers both Quit and Force Quit regardless of which one opened it.
    func confirmTermination(mode: TerminationMode) {
        guard let request = pendingTermination else { return }
        pendingTermination = nil
        terminate(request.targets, mode: mode)
    }

    private func terminate(_ targets: [TerminationTarget], mode: TerminationMode) {
        let failures = ProcessTerminator.terminate(targets, mode: mode)
        terminationError = failures.isEmpty ? nil : TerminationError(mode: mode, failures: failures)
        Task { await refreshAfterTermination() }
    }

    /// Processes don't exit synchronously — give them a beat, then refresh so
    /// the row disappears without waiting for the next 2 s tick.
    private func refreshAfterTermination() async {
        try? await Task.sleep(for: .milliseconds(600))
        await refresh()
    }

    /// Maps selected row ids to termination targets, in display order. A
    /// selected group header covers every pid underneath it; child ids already
    /// covered by a selected parent are folded into that parent's target.
    private func terminationTargets(for ids: Set<AppRow.ID>) -> [TerminationTarget] {
        guard !ids.isEmpty else { return [] }
        var targets: [TerminationTarget] = []
        for row in rows {
            if ids.contains(row.id) {
                let pids = ([row.pid] + (row.children ?? []).map(\.pid)).compactMap { $0 }
                guard !pids.isEmpty else { continue }
                targets.append(TerminationTarget(id: row.id, displayName: row.displayName, pids: pids))
                continue
            }
            for child in row.children ?? [] where ids.contains(child.id) {
                guard let pid = child.pid else { continue }
                targets.append(TerminationTarget(id: child.id, displayName: child.displayName, pids: [pid]))
            }
        }
        return targets
    }

    private func resort() {
        // Re-sort the existing snapshot synchronously — clicking a header
        // shouldn't wait for the next 2 s tick.
        allRows = AppGroupBuilder.build(
            from: lastProcesses,
            cpuPercents: lastCpuPercents,
            sort: sort
        )
        applyFilter()
    }
}
