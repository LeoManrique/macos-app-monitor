import Darwin
import Dispatch
import Foundation
import ServiceManagement
import XPC

/// Talks to the privileged sampler when one is installed, and reports honestly
/// when it isn't.
///
/// Uses the raw C XPC API to mirror the helper's listener, which has to be C so
/// it can pin the caller's code signature (see `AppMonitorHelper/main.swift`).
/// Both sides therefore agree on one shape: an XPC dictionary carrying a single
/// JSON blob, so the `Codable` types in `HelperWire` are the only contract.
///
/// Every failure mode is non-fatal. If the daemon is missing, unapproved,
/// stale, or simply not answering, `sample()` returns nil and the caller falls
/// back to unprivileged sampling — a build that isn't notarized can never
/// register the daemon at all, and that's the normal case during development.
final class HelperClient: @unchecked Sendable {
    /// Why the privileged path isn't in use — surfaced so the UI can explain
    /// the "—" cells instead of leaving them unexplained.
    enum Status: Equatable, Sendable {
        case active
        case notInstalled
        case requiresApproval
        case versionMismatch(helper: Int, app: Int)
        case failed(String)

        var isActive: Bool { self == .active }
    }

    private let lock = NSLock()
    private var connection: xpc_connection_t?
    private var _status: Status = .notInstalled

    private let queue = DispatchQueue(label: "com.leonardomanrique.AppMonitor.helper.client")

    var status: Status {
        lock.lock()
        defer { lock.unlock() }
        return _status
    }

    /// Registration state of the daemon, independent of whether it answers.
    /// `SMAppService` reports `.requiresApproval` while the user hasn't yet
    /// enabled the item in System Settings > General > Login Items.
    static func registrationStatus() -> SMAppService.Status {
        SMAppService.daemon(plistName: HelperWire.plistName).status
    }

    /// Asks launchd to install the daemon. Throws when the app isn't notarized
    /// or signed appropriately — the caller is expected to carry on
    /// unprivileged rather than treat this as fatal.
    static func register() throws {
        try SMAppService.daemon(plistName: HelperWire.plistName).register()
    }

    static func unregister() throws {
        try SMAppService.daemon(plistName: HelperWire.plistName).unregister()
    }

    /// One round trip. Returns nil when the privileged path is unavailable for
    /// any reason; `status` then says why.
    ///
    /// Blocking by design — callers run it off the main actor, and the reply is
    /// a few milliseconds of syscalls. `..._with_reply_sync` also avoids
    /// juggling a continuation across the C callback boundary.
    func sample() -> [RawProcess]? {
        guard let connection = connectIfNeeded() else { return nil }

        guard let payload = try? JSONEncoder().encode(HelperRequest()) else {
            setStatus(.failed("could not encode request"))
            return nil
        }

        let message = xpc_dictionary_create(nil, nil, 0)
        payload.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            xpc_dictionary_set_data(message, HelperWire.requestKey, base, buffer.count)
        }

        let reply = xpc_connection_send_message_with_reply_sync(connection, message)

        guard xpc_get_type(reply) != XPC_TYPE_ERROR else {
            // The connection is dead or the peer rejected us; drop it so the
            // next tick reconnects rather than reusing a broken channel.
            invalidate(describing: reply)
            return nil
        }

        var length = 0
        guard let bytes = xpc_dictionary_get_data(reply, HelperWire.replyKey, &length),
              let decoded = try? JSONDecoder().decode(
                  HelperReply.self,
                  from: Data(bytes: bytes, count: length)
              )
        else {
            setStatus(.failed("malformed reply"))
            return nil
        }

        guard decoded.version == HelperWire.version else {
            // An installed helper from an older build. Refuse its data rather
            // than risk misreading it; re-registering replaces the executable.
            setStatus(.versionMismatch(helper: decoded.version, app: HelperWire.version))
            return nil
        }

        setStatus(.active)
        return decoded.processes
    }

    // MARK: - Connection lifecycle

    private func connectIfNeeded() -> xpc_connection_t? {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }

        // Deliberately *not* gated on `SMAppService.status`: a daemon installed
        // by other means (a legacy /Library/LaunchDaemons entry, or `launchctl
        // bootstrap` during development) works fine, and reads as
        // `.notRegistered` to SMAppService. Connecting to an absent mach
        // service fails cheaply and immediately, so trying first costs nothing
        // and registration status is consulted only to explain a failure.
        //
        // PRIVILEGED looks the name up in the system bootstrap, which is where
        // a /Library/LaunchDaemons job advertises it. Without this flag the
        // lookup happens in the user domain and always misses.
        let created = xpc_connection_create_mach_service(
            HelperWire.machServiceName,
            queue,
            UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED)
        )
        xpc_connection_set_event_handler(created) { _ in
            // Errors surface on the synchronous reply path; nothing to do here,
            // but XPC requires a handler before `resume`.
        }
        xpc_connection_resume(created)
        connection = created
        return created
    }


    /// Drops the channel and works out *why* it died, so "—" cells can be
    /// explained. A missing mach service and an unapproved daemon both surface
    /// here as XPC errors; only `SMAppService` can tell them apart.
    private func invalidate(describing error: xpc_object_t) {
        let description = xpc_dictionary_get_string(error, XPC_ERROR_KEY_DESCRIPTION)
            .map { String(cString: $0) } ?? "connection error"

        let reason: Status
        switch Self.registrationStatus() {
        case .requiresApproval: reason = .requiresApproval
        case .notRegistered, .notFound: reason = .notInstalled
        case .enabled: reason = .failed(description)
        @unknown default: reason = .failed(description)
        }

        lock.lock()
        if let connection { xpc_connection_cancel(connection) }
        connection = nil
        _status = reason
        lock.unlock()
    }

    private func setStatus(_ new: Status) {
        lock.lock()
        _status = new
        lock.unlock()
    }
}
