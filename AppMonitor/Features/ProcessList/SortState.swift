import Foundation
import SwiftUI

enum SortColumn: String, CaseIterable, Hashable {
    case pid
    case name
    case cpu
    case memory

    /// First-click direction matches Activity Monitor:
    /// PID + Name → ascending; CPU + Memory → descending.
    var defaultDirection: SortOrder {
        switch self {
        case .pid, .name: return .forward
        case .cpu, .memory: return .reverse
        }
    }
}

/// `Table(sortOrder:)` expects `[KeyPathComparator<Row>]`. We keep the
/// column + direction in a single state value and project comparators on
/// demand for `AppGroup` (used by the builder when ordering top-level rows)
/// and `AppRow` (used as Table's sortOrder binding type).
struct GroupSort: Equatable {
    var column: SortColumn = .memory
    var order: SortOrder = .reverse

    static let `default` = GroupSort()

    /// Comparators applied by the builder when ordering `[AppGroup]` before
    /// projecting to rows. Memory and CPU sort by group totals; PID sorts by
    /// the lowest PID in the group.
    var groupComparators: [KeyPathComparator<AppGroup>] {
        switch column {
        case .pid:
            return [KeyPathComparator(\AppGroup.lowestPid, order: order)]
        case .name:
            return [KeyPathComparator(\AppGroup.displayName, order: order)]
        case .cpu:
            return [KeyPathComparator(\AppGroup.totalCpu, order: order)]
        case .memory:
            return [KeyPathComparator(\AppGroup.totalMemory, order: order)]
        }
    }

    /// Comparators for the child `MonitoredProcess` rows inside a group.
    var processComparators: [KeyPathComparator<MonitoredProcess>] {
        switch column {
        case .pid:
            return [KeyPathComparator(\MonitoredProcess.pid, order: order)]
        case .name:
            return [KeyPathComparator(\MonitoredProcess.name, order: order)]
        case .cpu:
            return [KeyPathComparator(\MonitoredProcess.cpuPercent, order: order)]
        case .memory:
            return [KeyPathComparator(\MonitoredProcess.memoryBytes, order: order)]
        }
    }
}
