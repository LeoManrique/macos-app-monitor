import SwiftUI

struct ProcessListView: View {
    @Bindable var monitor: ProcessMonitor
    @State private var sortOrder: [KeyPathComparator<AppRow>] = [
        KeyPathComparator(\AppRow.memory, order: .reverse)
    ]
    @FocusState private var searchFocused: Bool

    var body: some View {
        Table(monitor.rows, children: \.children, selection: $monitor.selection, sortOrder: $sortOrder) {
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
                Text(Formatters.cpu(percent: row.cpu, known: row.isReadable))
                    .monospacedDigit()
                    // Dim rather than recolor: an explicit foreground colour
                    // would override the tint Table applies to selected rows.
                    .opacity(row.isReadable ? 1 : 0.5)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 70, max: 90)

            TableColumn("Memory", value: \.memory) { row in
                Text(Formatters.memory(bytes: row.memory, known: row.isReadable))
                    .monospacedDigit()
                    // Dim rather than recolor: an explicit foreground colour
                    // would override the tint Table applies to selected rows.
                    .opacity(row.isReadable ? 1 : 0.5)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 90, ideal: 120, max: 150)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            // Only for a filter that matched nothing — an empty table with no
            // search text means the sampler hasn't returned its first snapshot.
            if monitor.rows.isEmpty && !monitor.searchText.isEmpty {
                ContentUnavailableView.search(text: monitor.searchText)
                    .background(Palette.bg)
            }
        }
        .searchable(text: $monitor.searchText, placement: .toolbar, prompt: "Search")
        .searchFocusedIfAvailable($searchFocused)
        .onChange(of: monitor.searchFocusRequests) { _, _ in
            searchFocused = true
        }
        .contextMenu(forSelectionType: AppRow.ID.self) { ids in
            // Empty set means the click landed on blank space below the rows —
            // no menu there.
            if !ids.isEmpty {
                Button("Quit") { monitor.requestTermination(ids: ids, mode: .quit) }
                Button("Force Quit") { monitor.requestTermination(ids: ids, mode: .forceQuit) }
            }
        }
        .confirmationDialog(
            monitor.pendingTermination?.title ?? "",
            isPresented: isPresentingTermination,
            titleVisibility: .visible,
            presenting: monitor.pendingTermination
        ) { request in
            // Both escalation paths stay reachable from either entry point,
            // the way Activity Monitor's quit sheet does it. The one that
            // opened the dialog is the default button.
            Button(request.mode.buttonTitle) { monitor.confirmTermination(mode: request.mode) }
                .keyboardShortcut(.defaultAction)
            Button(request.mode.alternate.buttonTitle) {
                monitor.confirmTermination(mode: request.mode.alternate)
            }
            Button("Cancel", role: .cancel) { monitor.pendingTermination = nil }
        } message: { request in
            Text(request.message)
        }
        .alert(
            monitor.terminationError?.title ?? "",
            isPresented: isPresentingTerminationError,
            presenting: monitor.terminationError
        ) { _ in
            Button("OK", role: .cancel) { monitor.terminationError = nil }
        } message: { error in
            Text(error.message)
        }
        .onChange(of: sortOrder) { _, new in
            // Defer one tick so we mutate the monitor *after* Table's own
            // delegate callback finishes — synchronous mutation here triggers
            // a reentrant-NSTableView warning that will become an assert.
            Task { @MainActor in applySortOrder(new) }
        }
    }

    private var isPresentingTermination: Binding<Bool> {
        Binding(
            get: { monitor.pendingTermination != nil },
            set: { if !$0 { monitor.pendingTermination = nil } }
        )
    }

    private var isPresentingTerminationError: Binding<Bool> {
        Binding(
            get: { monitor.terminationError != nil },
            set: { if !$0 { monitor.terminationError = nil } }
        )
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

private extension View {
    /// `searchFocused` only exists on macOS 15+. On 14 the Find command still
    /// works as a menu item, it just can't take focus — the field is a click
    /// away. The availability check is constant for a given run, so this
    /// doesn't churn view identity.
    @ViewBuilder
    func searchFocusedIfAvailable(_ binding: FocusState<Bool>.Binding) -> some View {
        if #available(macOS 15.0, *) {
            searchFocused(binding)
        } else {
            self
        }
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
