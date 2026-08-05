import Foundation

/// Text filter for the process list.
///
/// Matching is decided at the **group** level: a row survives if its own name
/// matches, or if any process underneath it does. Survivors keep every child,
/// so a filtered header still totals the whole app — the number stays an answer
/// to "how much would I reclaim by quitting this?" rather than "…the part that
/// happened to match". It also keeps quitting a header meaning the same thing
/// with a filter active as without one.
enum RowFilter {
    static func apply(_ rows: [AppRow], query: String) -> [AppRow] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return rows }
        // An all-digits query also matches a pid outright — pasting a pid from
        // a terminal is a common way to find a process. Substring-matching pids
        // instead would make "23" drag in every pid containing those digits.
        let pid = Int32(query)
        return rows.filter { $0.matches(query, pid: pid) }
    }
}

private extension AppRow {
    /// Case- and diacritic-insensitive, so "safari" finds "Safari".
    func matches(_ query: String, pid target: Int32?) -> Bool {
        if displayName.localizedStandardContains(query) { return true }
        if let target, pid == target { return true }
        return (children ?? []).contains { $0.matches(query, pid: target) }
    }
}
