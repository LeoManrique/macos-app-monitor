# Technical notes

## Stack

- **Swift 6** (strict concurrency), targeting **macOS 26 SDK**.
- **SwiftUI** for the UI: hierarchical `Table(_:children:)`, `KeyPathComparator` sort, native `CommandMenu`.
- **`@Observable` model** (`ProcessMonitor`) running on `@MainActor`, sampled off-main via `Task.detached`.
- No third-party Swift dependencies. All system access goes through `Darwin` / `AppKit`.

## Project layout

```
AppMonitor/
  App/          @main scene + menu bar (AppMonitorApp, AppCommands)
  Features/
    ProcessList/   Table view, sort state, group builder, refresh model
    Footer/        Status bar with system totals
  Core/
    Sampling/      proc_listpids, proc_pid_rusage, host_statistics64
    AppBundles/    leftmost-`.app/` resolver
    Icons/         NSWorkspace.shared.icon(forFile:) cache (actor)
  UI/             Palette, Formatters
  Resources/      Info.plist, Assets.xcassets (AppIcon ladder)
```

The Xcode project is generated from `project.yml` via **xcodegen**: `xcodegen generate` recreates `AppMonitor.xcodeproj` whenever sources or settings change. `scripts/bundle.sh` runs it on every build, so the checked-in `.xcodeproj` is effectively a cache.

## Memory readings

Per-process memory comes from `proc_pid_rusage(pid, RUSAGE_INFO_V4, &info).ri_phys_footprint`. The `rusage_info_v4` struct is auto-bridged from `Darwin` — no FFI struct mirror needed.

For processes the user doesn't own, the call returns EPERM; the code falls back to `proc_pidinfo(PROC_PIDTASKINFO).pti_resident_size`.

## CPU readings

`proc_pid_rusage` returns cumulative user+system time in nanoseconds. `ProcessCPUSampler` keeps a per-pid sample from the previous tick and computes `(Δcpu_ns / 1e9) / Δwall_seconds * 100` to produce the same "single fully-busy core = 100%" semantics Activity Monitor uses.

System-wide CPU is read via `host_statistics(HOST_CPU_LOAD_INFO)` and diffed against the previous reading inside `SystemSampler`.

## App-bundle detection

`AppBundleResolver.resolve(executablePath:)` finds the **leftmost** `.app/` substring in the executable path. For nested bundles (e.g. `Google Chrome.app/.../Google Chrome Helper.app/...`), the leftmost match is the outermost bundle — the user-facing app. Processes whose exe has no `.app/` in the path become their own single-member group keyed by process name.

The bundle path (everything up to and including the `.app`) is captured alongside the name and threaded through to the icon loader.

## Icon loading

`NSWorkspace.shared.icon(forFile: bundlePath)` returns the same icon Finder shows for the bundle. That single call replaces the Rust app's ~50 lines of:

- `Info.plist` parse to find `CFBundleIconFile`
- `.icns` decode via the `icns` crate
- PNG-magic-byte sniff for Electron apps that ship a PNG with an `.icns` extension
- "Pick the smallest variant ≥ 32 px" selection
- `Assets.car` fall-through

NSWorkspace handles all of those internally. Icons are cached on an `actor AppIconLoader`, keyed by bundle path; a successful load stays cached, a failed load (invalid bundle) is cached as `nil` so the lookup isn't retried every tick.

## Refresh loop

`ProcessMonitor.start()` spawns a single `Task` that runs `while !Task.isCancelled { refresh(); try? await Task.sleep(for: .seconds(2)) }`. SwiftUI's `.task {}` modifier on the root view starts it; `.onDisappear {}` calls `stop()` to cancel.

Inside `refresh()`:

1. `Task.detached { ProcessSampler.enumerate() }.value` enumerates all pids off-main (the bulk of the work on machines with hundreds of processes).
2. `SystemSampler.sample()` reads memory / CPU / disk on main.
3. `ProcessCPUSampler.cpuPercents(...)` diffs against the previous sample.
4. `AppGroupBuilder.build(...)` runs as a pure function — same input always yields the same `[AppRow]`.
5. The state write is pushed to the *next* runloop iteration via `DispatchQueue.main.async` so it doesn't fire during an in-flight NSTableView delegate callback.

## UI structure

`ProcessListView` is a single SwiftUI `Table(_:children:)` over `[AppRow]`. `AppRow` is the unified row type — header rows have `children: [AppRow]`, leaf rows have `children: nil`. SwiftUI's `Table` renders disclosure triangles, virtualizes off-screen rows, and drives sort via the `sortOrder:` binding.

Sort changes flow through `onChange(of: sortOrder)` and are deferred one tick via `Task { @MainActor in ... }` to avoid the reentrant-NSTableView-delegate warning that synchronous mutation produces.

`StatusFooterView` is a sibling `HStack` that reads `monitor.stats` directly.

## Window

`Window("App Monitor", id: "main")` with `.defaultSize(...)` computed at scene init from `NSScreen.main?.frame` (50% × 70%). Window positioning is delegated to the system; SwiftUI centers the window automatically on first launch.

## Menu bar

`AppCommands` adds Minimize (⌘M), Zoom, and Enter Full Screen (⌃⌘F) under the system Window menu. Hide (⌘H) and Quit (⌘Q) are provided by SwiftUI's default app menu. `CommandGroup(replacing: .newItem) {}` hides the File ▸ New item we don't need.

## Building

Requirements: macOS 26 (Apple Silicon), Xcode 26+, xcodegen (`brew install xcodegen`).

```
xcodegen generate                 # regenerate AppMonitor.xcodeproj from project.yml
xcodebuild -scheme AppMonitor build  # build into ~/Library/Developer/Xcode/DerivedData
scripts/bundle.sh                 # build + lay out AppMonitor.app at target/release/bundle/
scripts/deploy_releases.sh x.y.z  # tag, build, bundle, and publish a GitHub release
```

`project.yml` is the source of truth for build settings, deployment target, and version. `xcodegen` regenerates `AppMonitor.xcodeproj` from it.

## Packaging

`scripts/bundle.sh` drives `xcodebuild` for the Release configuration into a local `build/` derived-data path, then copies `Build/Products/Release/AppMonitor.app` to `target/release/bundle/AppMonitor.app` (the path `deploy_releases.sh` and `install.sh` expect). The Xcode build produces the executable, Info.plist (with `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` substituted via xcodebuild settings), and the compiled asset catalog (`Assets.car`) with the AppIcon ladder. Final ad-hoc signing happens via `codesign --force --deep --sign -`.
