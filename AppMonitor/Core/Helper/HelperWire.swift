import Foundation

/// Contract shared by the app and the privileged helper. This file is compiled
/// into *both* targets, so it must stay free of UI and app-only dependencies.
///
/// Why a helper exists at all: `proc_pid_rusage` returns EPERM for any process
/// the caller doesn't own, which on a normal desktop is ~250 of ~800 processes
/// — including the heaviest CPU consumers (`WindowServer`, `kernel_task`). An
/// unprivileged sampler therefore attributes only about half the machine's CPU
/// and the rows can never add up to the footer total. Root can read all of
/// them; `/bin/ps` gets there by being setuid-root, which an app bundle can't
/// be, so we run a LaunchDaemon instead.
enum HelperWire {
    /// Mach service vended by the daemon. Must match the `MachServices` key in
    /// `Contents/Library/LaunchDaemons/<plist>` and the label registered with
    /// `SMAppService.daemon(plistName:)`.
    static let machServiceName = "com.leonardomanrique.AppMonitor.helper"

    /// Name of the LaunchDaemon plist inside `Contents/Library/LaunchDaemons/`.
    static let plistName = "com.leonardomanrique.AppMonitor.helper.plist"

    /// Bundle identifier the helper demands of anything that connects to it.
    static let clientBundleIdentifier = "com.leonardomanrique.AppMonitor"

    /// Bumped whenever the payload shape changes. A helper left behind by an
    /// older install answers with its own version, and the app falls back to
    /// unprivileged sampling rather than decoding a payload it doesn't
    /// understand.
    static let version = 1

    /// XPC dictionary keys. The payloads themselves are JSON blobs so the two
    /// sides share one `Codable` definition instead of hand-rolling
    /// `xpc_dictionary_*` accessors per field.
    static let requestKey = "request"
    static let replyKey = "reply"
}

struct HelperRequest: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Full process enumeration, the only thing the helper does.
        case sample
    }

    var kind: Kind = .sample
    var clientVersion: Int = HelperWire.version
}

struct HelperReply: Codable, Sendable {
    var version: Int
    var processes: [RawProcess]
}
