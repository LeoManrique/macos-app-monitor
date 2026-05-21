import SwiftUI
import AppKit

/// Mirrors the Rust app's menu bar exactly: ⌘Q quit, ⌘H hide, ⌘M minimize,
/// ⌃⌘F toggle full-screen. SwiftUI already provides the default app menu
/// (Hide/Quit) — we only need to add the Window menu items beyond what the
/// system supplies.
struct AppCommands: Commands {
    var body: some Commands {
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
