import SwiftUI

@main
struct AppMonitorApp: App {
    @State private var monitor = ProcessMonitor()

    var body: some Scene {
        Window("App Monitor", id: "main") {
            ContentView(monitor: monitor)
                .frame(minWidth: 480, minHeight: 320)
                .background(Palette.bg, ignoresSafeAreaEdges: .all)
                .preferredColorScheme(.dark)
        }
        .defaultSize(defaultWindowSize())
        // Compact chrome: the search field is the only toolbar item, so the
        // full-height unified bar was mostly empty space above the table.
        // Title moves inline beside the traffic lights.
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            AppCommands(monitor: monitor)
        }
    }

    private func defaultWindowSize() -> CGSize {
        // Match the Rust app's 50% × 70% of the primary display, centered.
        let frame = NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900)
        return CGSize(width: frame.width * 0.5, height: frame.height * 0.7)
    }
}

private struct ContentView: View {
    let monitor: ProcessMonitor

    var body: some View {
        VStack(spacing: 0) {
            ProcessListView(monitor: monitor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            StatusFooterView(stats: monitor.stats)
        }
        .task {
            monitor.start()
        }
        .onDisappear {
            monitor.stop()
        }
    }
}
