import Darwin
import Dispatch
import Foundation
import Security
import XPC

// Privileged sampler for App Monitor.
//
// Runs as root under launchd so `proc_pid_rusage` succeeds for every pid rather
// than only the ~70% the logged-in user owns. It does exactly one thing —
// enumerate processes on request — and holds no state between calls, so a
// compromised client gains nothing it couldn't get from `ps`.
//
// The raw C XPC API is used rather than Swift's `XPCListener` because only the
// C layer exposes `xpc_connection_set_peer_code_signing_requirement`. Vending
// root-read process data to *any* caller would be an information leak, and
// `XPCListener.IncomingSessionRequest` offers no way to identify the peer.

/// Code signing requirement a client must satisfy before the helper will talk
/// to it.
///
/// Pinned to our bundle id *and* the team that signed this helper, read from
/// our own signature at runtime so there's no team id to keep in sync in
/// source. An unsigned build (local development) has no team, and falls back to
/// matching the identifier alone — that path only exists so `launchctl
/// bootstrap` testing works, since an app containing a LaunchDaemon has to be
/// notarized before `SMAppService` will register it at all.
private func peerCodeSigningRequirement() -> String {
    let identifier = "identifier \"\(HelperWire.clientBundleIdentifier)\""
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return identifier }

    var info: CFDictionary?
    guard SecCodeCopySigningInformation(
        unsafeBitCast(code, to: SecStaticCode.self),
        SecCSFlags(rawValue: kSecCSSigningInformation),
        &info
    ) == errSecSuccess,
        let dict = info as? [String: Any],
        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
    else {
        FileHandle.standardError.write(Data(
            "AppMonitorHelper: no team identifier in our own signature; accepting on bundle id alone\n".utf8
        ))
        return identifier
    }
    return "\(identifier) and anchor apple generic "
        + "and certificate leaf[subject.OU] = \"\(team)\""
}

/// Serialises every reply. Sampling ~800 pids is a few milliseconds of cheap
/// syscalls, so one queue is ample and keeps the handler free of shared state.
private let workQueue = DispatchQueue(label: "com.leonardomanrique.AppMonitor.helper.work")

private func handle(message: xpc_object_t) {
    guard xpc_get_type(message) == XPC_TYPE_DICTIONARY,
          let remote = xpc_dictionary_get_remote_connection(message)
    else { return }

    var length = 0
    guard let bytes = xpc_dictionary_get_data(message, HelperWire.requestKey, &length),
          let request = try? JSONDecoder().decode(
              HelperRequest.self,
              from: Data(bytes: bytes, count: length)
          )
    else { return }

    let reply: xpc_object_t? = xpc_dictionary_create_reply(message)
    guard let reply else { return }

    switch request.kind {
    case .sample:
        let payload = HelperReply(version: HelperWire.version, processes: ProcessSampler.enumerate())
        guard let data = try? JSONEncoder().encode(payload) else { return }
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            xpc_dictionary_set_data(reply, HelperWire.replyKey, base, buffer.count)
        }
    }
    xpc_connection_send_message(remote, reply)
}

private let requirement = peerCodeSigningRequirement()

// LISTENER is only permitted for a service the process advertises in its
// launchd plist — see MachServices in the daemon plist alongside this file.
private let listener = xpc_connection_create_mach_service(
    HelperWire.machServiceName,
    workQueue,
    UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER)
)

xpc_connection_set_event_handler(listener) { event in
    // The listener's event stream delivers new peer connections; anything else
    // here is an error object (e.g. the service being torn down).
    guard xpc_get_type(event) == XPC_TYPE_CONNECTION else { return }
    let peer = unsafeBitCast(event, to: xpc_connection_t.self)

    // Requests failing the requirement are dropped by XPC before reaching the
    // handler. If the requirement itself won't compile we refuse the peer
    // outright rather than serve it unchecked.
    guard xpc_connection_set_peer_code_signing_requirement(peer, requirement) == 0 else {
        xpc_connection_cancel(peer)
        return
    }

    xpc_connection_set_event_handler(peer) { message in
        guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else { return }
        handle(message: message)
    }
    xpc_connection_resume(peer)
}

xpc_connection_resume(listener)
dispatchMain()
