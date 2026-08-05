import AppKit
import Darwin

/// How hard to ask a process to go away.
enum TerminationMode: Hashable {
    /// Apple-event quit for real apps, `SIGTERM` for everything else.
    case quit
    /// `forceTerminate()` / `SIGKILL` — no chance to save state.
    case forceQuit

    var verb: String { self == .quit ? "quit" : "force quit" }
    var buttonTitle: String { self == .quit ? "Quit" : "Force Quit" }
    /// The other escalation level — the confirmation dialog offers both.
    var alternate: TerminationMode { self == .quit ? .forceQuit : .quit }
}

/// One selected row's worth of processes. A group header expands to every pid
/// underneath it — quitting "Google Chrome" means quitting Chrome, not one
/// helper.
struct TerminationTarget: Identifiable, Hashable {
    let id: String          // AppRow.id
    let displayName: String
    let pids: [Int32]
}

struct TerminationFailure: Identifiable, Hashable {
    var id: Int32 { pid }
    let pid: Int32
    let name: String
    let reason: String
}

/// A multi-row confirmation the user hasn't answered yet. Owns its own copy —
/// the selection can change (or a process can exit) while the dialog is up.
/// Single-row quits skip this entirely and act immediately.
struct TerminationRequest: Hashable {
    let targets: [TerminationTarget]
    let mode: TerminationMode

    var title: String {
        "Are you sure you want to \(mode.verb) these \(targets.count) processes?"
    }

    var message: String {
        targets.map { target in
            target.pids.count == 1
                ? "“\(target.displayName)”"
                : "“\(target.displayName)” (\(target.pids.count) processes)"
        }
        .joined(separator: "\n")
    }
}

struct TerminationError: Hashable {
    let mode: TerminationMode
    let failures: [TerminationFailure]

    var title: String {
        if let only = failures.first, failures.count == 1 {
            return "Couldn’t \(mode.verb) “\(only.name)”"
        }
        return "Couldn’t \(mode.verb) \(failures.count) processes"
    }

    var message: String {
        failures.map { "“\($0.name)” (PID \($0.pid)): \($0.reason)" }.joined(separator: "\n")
    }
}

@MainActor
enum ProcessTerminator {
    /// Ends every process in `targets`, returning whatever refused to die.
    /// Processes that were already gone are not reported — the user's intent
    /// was satisfied either way.
    static func terminate(_ targets: [TerminationTarget], mode: TerminationMode) -> [TerminationFailure] {
        var failures: [TerminationFailure] = []
        for target in targets {
            failures.append(contentsOf: terminate(target, mode: mode))
        }
        return failures
    }

    private static func terminate(_ target: TerminationTarget, mode: TerminationMode) -> [TerminationFailure] {
        // Prefer the app-level route when the target contains a real app: one
        // Quit request tears down its own helpers cleanly, whereas signalling
        // each helper individually makes apps like Chrome think they crashed.
        // `.prohibited` filters out helper bundles, which are registered with
        // launch services but never user-facing.
        let apps = target.pids
            .compactMap { NSRunningApplication(processIdentifier: $0) }
            .filter { $0.activationPolicy != .prohibited }

        guard apps.isEmpty else {
            return apps.compactMap { app in
                let sent = mode == .quit ? app.terminate() : app.forceTerminate()
                // A `false` return means the request never got sent (app already
                // exiting, or not accepting events) — fall back to a signal
                // rather than silently doing nothing.
                guard !sent else { return nil }
                return signal(pid: app.processIdentifier, name: target.displayName, mode: mode)
            }
        }

        return target.pids.compactMap { signal(pid: $0, name: target.displayName, mode: mode) }
    }

    private static func signal(pid: Int32, name: String, mode: TerminationMode) -> TerminationFailure? {
        guard kill(pid, mode == .quit ? SIGTERM : SIGKILL) != 0 else { return nil }
        switch errno {
        case ESRCH:
            return nil  // already exited
        case EPERM:
            return TerminationFailure(
                pid: pid,
                name: name,
                reason: "not permitted — the process belongs to another user"
            )
        default:
            return TerminationFailure(pid: pid, name: name, reason: String(cString: strerror(errno)))
        }
    }
}
