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

    private var lastProcesses: [RawProcess] = []
    private var lastCpuPercents: [Int32: Double] = [:]
    private let cpuSampler = ProcessCPUSampler()
    private let systemSampler = SystemSampler()
    private let iconLoader = AppIconLoader()
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
        let raws = await Task.detached { ProcessSampler.enumerate() }.value
        let stats = systemSampler.sample()
        let now = Date()
        let cpu = cpuSampler.cpuPercents(for: raws, sampledAt: now)
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
        self.rows = built
        self.stats = stats
    }

    private func resort() {
        // Re-sort the existing snapshot synchronously — clicking a header
        // shouldn't wait for the next 2 s tick.
        rows = AppGroupBuilder.build(
            from: lastProcesses,
            cpuPercents: lastCpuPercents,
            sort: sort
        )
    }
}
