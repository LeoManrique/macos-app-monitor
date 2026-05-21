import SwiftUI

struct ProcessListView: View {
    @Bindable var monitor: ProcessMonitor
    @State private var sortOrder: [KeyPathComparator<AppRow>] = [
        KeyPathComparator(\AppRow.memory, order: .reverse)
    ]

    var body: some View {
        Table(monitor.rows, children: \.children, sortOrder: $sortOrder) {
            TableColumn("PID", value: \.pidSortKey) { row in
                Text(row.pid.map(String.init) ?? "")
                    .monospacedDigit()
                    .foregroundStyle(Palette.textSecondary)
            }
            .width(min: 60, ideal: 80, max: 100)

            TableColumn("Process Name", value: \.displayName) { row in
                RowNameCell(row: row, monitor: monitor)
            }

            TableColumn("% CPU", value: \.cpu) { row in
                Text(Formatters.cpu(percent: row.cpu))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 70, max: 90)

            TableColumn("Memory", value: \.memory) { row in
                Text(Formatters.memory(bytes: row.memory))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 90, ideal: 120, max: 150)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .onChange(of: sortOrder) { _, new in
            // Defer one tick so we mutate the monitor *after* Table's own
            // delegate callback finishes — synchronous mutation here triggers
            // a reentrant-NSTableView warning that will become an assert.
            Task { @MainActor in applySortOrder(new) }
        }
    }

    private func applySortOrder(_ comparators: [KeyPathComparator<AppRow>]) {
        guard let first = comparators.first else { return }
        let column: SortColumn
        // KeyPathComparator's stored keyPath is type-erased AnyKeyPath at
        // runtime; we match on the keyPath value to figure out which column
        // changed.
        switch first.keyPath {
        case \AppRow.pidSortKey: column = .pid
        case \AppRow.displayName: column = .name
        case \AppRow.cpu: column = .cpu
        case \AppRow.memory: column = .memory
        default: return
        }
        monitor.sort = GroupSort(column: column, order: first.order)
    }
}

/// Name cell — async icon load via the monitor's `AppIconLoader`, falls back
/// to a blank slot so all rows align even when the icon hasn't resolved yet.
/// Child rows pass `bundlePath == nil` and stay icon-free.
private struct RowNameCell: View {
    let row: AppRow
    let monitor: ProcessMonitor
    @State private var icon: NSImage?

    var body: some View {
        HStack(spacing: 6) {
            iconView
                .frame(width: 16, height: 16)
            Text(row.displayName)
                .foregroundStyle(Palette.textAppName)
        }
        .task(id: row.bundlePath) {
            guard let path = row.bundlePath else {
                icon = nil
                return
            }
            icon = await monitor.icon(forBundle: path)
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
        } else {
            Color.clear
        }
    }
}

private extension AppRow {
    /// Sort key for the PID column. Header rows (children non-nil) report 0 so
    /// they cluster at the top under ascending sort. Header sort by PID is
    /// already handled at the group level by `AppGroupBuilder` via
    /// `lowestPid`, so this only affects ordering inside a single group's
    /// children.
    var pidSortKey: Int32 { pid ?? 0 }
}
