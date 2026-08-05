import SwiftUI
import AppKit
import ServiceManagement

/// Mirrors the Rust app's menu bar exactly: ⌘Q quit, ⌘H hide, ⌘M minimize,
/// ⌃⌘F toggle full-screen. SwiftUI already provides the default app menu
/// (Hide/Quit) — we only need to add the Window menu items beyond what the
/// system supplies, plus the Process menu that acts on the table selection.
struct AppCommands: Commands {
    let monitor: ProcessMonitor

    var body: some Commands {
        CommandMenu("Process") {
            // Same shortcuts Activity Monitor uses. Both are no-ops with an
            // empty selection, so they stay safe when nothing is highlighted.
            Button("Quit Process") { monitor.requestTermination(mode: .quit) }
                .keyboardShortcut("q", modifiers: [.option, .command])
                .disabled(monitor.selection.isEmpty)

            Button("Force Quit Process") { monitor.requestTermination(mode: .forceQuit) }
                .keyboardShortcut("q", modifiers: [.option, .shift, .command])
                .disabled(monitor.selection.isEmpty)

            Divider()

            // Installing a root LaunchDaemon is a system-level change, so it
            // stays an explicit choice. Without it the ~30% of processes the
            // user doesn't own read "—" instead of a number.
            if monitor.helperStatus.isActive {
                Button("Disable Full Process Access") { monitor.disableFullProcessAccess() }
            } else {
                Button("Enable Full Process Access…") { monitor.enableFullProcessAccess() }
            }

            if monitor.helperStatus == .requiresApproval {
                Button("Open Login Items Settings…") {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        }

        // ⌘F where every other Mac app puts it: Edit ▸ Find.
        CommandGroup(after: .textEditing) {
            Button("Find") { monitor.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
        }

        CommandGroup(replacing: .appInfo) {
            Button("About App Monitor") {
                NSApp.orderFrontStandardAboutPanel(nil)
            }
        }
        CommandGroup(replacing: .newItem) {} // hide File ▸ New
        CommandGroup(after: .windowArrangement) {
            Button("Minimize") {
                NSApp.keyWindow?.miniaturize(nil)
            }
            .keyboardShortcut("m", modifiers: .command)

            Button("Zoom") {
                NSApp.keyWindow?.zoom(nil)
            }

            Divider()

            Button("Enter Full Screen") {
                NSApp.keyWindow?.toggleFullScreen(nil)
            }
            .keyboardShortcut("f", modifiers: [.control, .command])
        }
    }
}
