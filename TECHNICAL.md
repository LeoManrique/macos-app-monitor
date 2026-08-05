# Technical notes

## Stack

- **Swift 6** (strict concurrency), built against the **macOS 26 SDK** with a **macOS 14 deployment target**.
- **SwiftUI** for the UI: hierarchical `Table(_:children:)`, `KeyPathComparator` sort, native `CommandMenu`.
- **`@Observable` model** (`ProcessMonitor`) running on `@MainActor`, sampled off-main via `Task.detached`.
- No third-party Swift dependencies. All system access goes through `Darwin` / `AppKit`.

## Project layout

```
AppMonitor/
  App/          @main scene + menu bar (AppMonitorApp, AppCommands)
  Features/
    ProcessList/   Table view, sort state, group builder, row filter, refresh model
    Footer/        Status bar with system totals
  Core/
    Sampling/      proc_listpids, proc_pid_rusage, host_statistics64
    Helper/        XPC contract (shared with the helper) + client
    AppBundles/    leftmost-`.app/` resolver
    Icons/         NSWorkspace.shared.icon(forFile:) cache (actor)
    Termination/   NSRunningApplication / kill(2) quit paths
  UI/             Palette, Formatters
  Resources/      Info.plist, Assets.xcassets (AppIcon ladder)
AppMonitorHelper/ root LaunchDaemon: XPC listener + its launchd plist
```

`AppMonitorHelper` is a separate `tool` target that recompiles `Core/Sampling` and `Core/Helper/HelperWire.swift`; the app embeds it at `Contents/MacOS/AppMonitorHelper` and copies the daemon plist into `Contents/Library/LaunchDaemons/`.

The Xcode project is generated from `project.yml` via **xcodegen**: `xcodegen generate` recreates `AppMonitor.xcodeproj` whenever sources or settings change. `scripts/bundle.py` runs it on every build, so the checked-in `.xcodeproj` is effectively a cache.

## Memory readings

Per-process memory comes from `proc_pid_rusage(pid, RUSAGE_INFO_V4, &info).ri_phys_footprint`. The `rusage_info_v4` struct is auto-bridged from `Darwin` — no FFI struct mirror needed.

For processes the user doesn't own, the call returns EPERM. The code falls back to `proc_pidinfo(PROC_PIDTASKINFO).pti_resident_size`, but that path is EPERM-gated identically, so unprivileged it recovers nothing — such rows carry `isReadable: false` and render `—`. See *Privileged helper*.

## CPU readings

`ri_user_time` / `ri_system_time` from `proc_pid_rusage` are in **mach absolute time units, not nanoseconds**. `<sys/resource.h>` documents no unit, and reading them as nanoseconds undercounts CPU by the timebase ratio — 125/3 ≈ 41.67× on Apple Silicon. (Ground truth: `ps -o time` reported `602:32` for a process where the mach-tick conversion gives 36153 s and the nanosecond reading gives 868 s.)

`ProcessSampler` therefore pairs each pid's counter with a `mach_absolute_time()` stamp taken at the same instant, and `ProcessCPUSampler` divides one delta by the other. Both are mach units, so the timebase cancels and no conversion is needed on either architecture. The quotient is then divided by `processorCount` to express a share of the machine rather than of one core — that is what makes the column reconcile with the footer, and it is the one place the app deliberately diverges from Activity Monitor's semantics.

Per-pid timestamps rather than one stamp per tick: enumerating ~800 pids spans milliseconds, so a single post-hoc stamp would attribute the same elapsed window to the first and last process sampled.

Counters that run backwards (a recycled pid) reset that pid to 0 instead of wrapping into a huge delta.

System-wide CPU is read via `host_statistics(HOST_CPU_LOAD_INFO)` and diffed against the previous reading inside `SystemSampler`. Its tick counters already aggregate every logical CPU, which is why `processorCount` is the right divisor to make the two agree.

## Privileged helper

`proc_pid_rusage` and `proc_pidinfo(PROC_PIDTASKINFO)` both return EPERM for processes the caller doesn't own — ~250 of ~800, including `WindowServer` and `kernel_task`, together roughly half the machine's CPU. There is no unprivileged workaround: `/bin/ps` succeeds only because it is setuid-root *and* carries `com.apple.system-task-ports.read`, neither of which an app bundle can have. `kinfo_proc.p_pctcpu` from `sysctl` is always 0 on modern Darwin. Running as root, however, reads 807/807 with no special entitlement — so a root LaunchDaemon is sufficient.

```
AppMonitorHelper/          root sampler: XPC listener + the daemon plist
AppMonitor/Core/Helper/    HelperWire (shared contract), HelperClient (app side)
```

`HelperWire.swift` is compiled into **both** targets and is the only contract: an XPC dictionary carrying one JSON blob, so a single set of `Codable` types serves both sides. `RawProcess` is `Codable` for this reason.

Both ends use the **C** XPC API rather than Swift's `XPCListener`/`XPCSession`, because only the C layer exposes `xpc_connection_set_peer_code_signing_requirement`. A root daemon vending system-wide process data to any caller would be an information leak, and `XPCListener.IncomingSessionRequest` offers no way to identify the peer. The helper pins callers to our bundle id plus the team that signed the helper, read from its own signature at runtime so no team id is hard-coded. Unsigned builds fall back to matching the identifier alone.

The daemon is registered with `SMAppService.daemon(plistName:)` from an explicit menu command, never automatically. The plist lives in `Contents/Library/LaunchDaemons/` (the only place `SMAppService` looks) and uses `BundleProgram` so the helper keeps working if the app is moved. It is `RunAtLoad: false` / `KeepAlive: false` — launchd starts it on connect and lets it idle out.

`HelperClient.sample()` returns nil on every failure path and the caller falls back to unprivileged sampling. It deliberately does **not** gate on `SMAppService.status`: a daemon installed by other means reads as `.notRegistered`, and connecting to an absent mach service fails in under 10 ms anyway, so trying first costs nothing. Registration status is consulted only to explain a failure (`requiresApproval` vs `notInstalled`) so the UI can say why cells read `—`.

**A build containing a LaunchDaemon must be notarized before `SMAppService` will register it** (`SMAppService.h` states this outright). The ad-hoc-signed dev and release bundles therefore always run unprivileged.

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

## Search

`.searchable(text:placement:.toolbar)` on the table hoists an `NSSearchField` into the window's toolbar — the `Window` scene declares no `.toolbar {}` of its own, SwiftUI creates one for the search field.

`ProcessMonitor` keeps two row arrays: `allRows` (everything the last snapshot produced) and the published `rows` (what passes the filter). A keystroke re-runs `RowFilter.apply` over `allRows` rather than re-grouping several hundred processes, and `refresh()` / `resort()` both write `allRows` then re-apply. `applyFilter()` also re-runs `pruneSelection()`, so the selection can never contain a row that isn't on screen.

`RowFilter` matches per top-level row: `localizedStandardContains` (case- and diacritic-insensitive) against the row's name or any child's, plus an exact `Int32` pid match when the query parses as one. Children are never filtered out of a surviving group — the header's totals stay the whole app's, which keeps both the memory figure and the meaning of quitting the header identical with or without a filter.

⌘F is a `CommandGroup(after: .textEditing)` item. Commands can't touch the view's `@FocusState`, so it bumps `ProcessMonitor.searchFocusRequests` and `ProcessListView` watches that counter (a counter, not a flag, so repeated ⌘F re-focuses). `.searchFocused` is macOS 15+, so it goes through a `searchFocusedIfAvailable` wrapper — on 14 the menu item is inert and the field is a click away.

## Selection & termination

`Table(_:children:selection:sortOrder:)` (macOS 14+) drives multi-selection through a `Binding<Set<AppRow.ID>>` that lives on `ProcessMonitor`, so the menu bar can read the same selection the table writes. Row ids are stable across refreshes — `refresh()` intersects the selection with the ids it just built, dropping rows whose process exited.

`ProcessMonitor.terminationTargets(for:)` folds selected ids into `[TerminationTarget]` in display order: a selected group header absorbs every pid beneath it, and children already covered by a selected parent are not emitted twice.

`ProcessTerminator` chooses per target:

- Pids that resolve to an `NSRunningApplication` with a non-`.prohibited` activation policy get `terminate()` / `forceTerminate()`. That excludes helper bundles, so quitting a group sends one Quit request to the app and lets it shut its own helpers down instead of signalling each one (which reads as a crash to Chrome-style apps).
- Everything else gets `kill(pid, SIGTERM)` / `SIGKILL`. `ESRCH` (already exited) is not a failure; `EPERM` and the rest surface in an alert.

Single-target requests run immediately; multi-target requests park in `pendingTermination` and drive a `confirmationDialog` offering both Quit and Force Quit. Either path schedules a refresh 600 ms later, since processes don't exit synchronously.

## Window

`Window("App Monitor", id: "main")` with `.defaultSize(...)` computed at scene init from `NSScreen.main?.frame` (50% × 70%). Window positioning is delegated to the system; SwiftUI centers the window automatically on first launch.

`.windowToolbarStyle(.unifiedCompact)` keeps the title bar at 40 pt with the title inline beside the traffic lights. The search field is the only toolbar item, so the full-height unified bar was mostly empty space.

The search field's translucent Liquid Glass look is the macOS 26 system treatment for toolbar controls, and there is no per-control opt-out. `UIDesignRequiresCompatibility` in `Info.plist` does work on AppKit (it drops the toolbar to 38 pt and the field to 24 pt), but it reverts the *whole* app to the pre-26 design — squarer, heavier controls — and Apple removes the key in the next major Xcode. Tried and rejected; not worth the app-wide cost for one field.

## Menu bar

`AppCommands` adds Minimize (⌘M), Zoom, and Enter Full Screen (⌃⌘F) under the system Window menu, and Find (⌘F) under the system Edit menu. Hide (⌘H) and Quit (⌘Q) are provided by SwiftUI's default app menu. `CommandGroup(replacing: .newItem) {}` hides the File ▸ New item we don't need.

A `CommandMenu("Process")` holds Quit Process (⌥⌘Q) and Force Quit Process (⌥⇧⌘Q), plus Enable/Disable Full Process Access and — while approval is pending — a shortcut to `SMAppService.openSystemSettingsLoginItems()`. It takes the `ProcessMonitor` by reference, so `@Observable` tracking updates the items' enabled state as the selection and helper status change.

## Building

Requirements to build: Xcode 26+ (for the macOS 26 SDK), xcodegen (`brew install xcodegen`), Python 3.10+ for the `scripts/` helpers. Runs on macOS 14+ (Intel or Apple Silicon).

```
xcodegen generate                 # regenerate AppMonitor.xcodeproj from project.yml
xcodebuild -scheme AppMonitor build  # build into ~/Library/Developer/Xcode/DerivedData
scripts/bundle.py                 # build + lay out AppMonitor.app at target/release/bundle/
scripts/install.py --local --build   # build, then install to /Applications
scripts/deploy_releases.py x.y.z  # tag, build, bundle, and publish a GitHub release
```

The scripts are stdlib-only Python. `bundle.py` and `deploy_releases.py` share terminal/subprocess helpers in `scripts/_console.py`; `install.py` stays a single self-contained file because it is curl-piped straight into an interpreter.

`install.py` covers both install directions. With no flags it downloads the latest GitHub release (the README one-liner). `--local` installs `target/release/bundle/AppMonitor.app` instead, and `--build` runs `bundle.py` first — the dev loop for testing a change as a real installed app. Both share the same install mechanics: stop running instances, replace the bundle, strip quarantine, re-register with Launch Services. `--local` requires a checkout on disk, so it is unreachable from the curl-piped path.

`project.yml` is the source of truth for build settings, deployment target, and version. `xcodegen` regenerates `AppMonitor.xcodeproj` from it.

## Packaging

`scripts/bundle.py` drives `xcodebuild` for the Release configuration into a local `build/` derived-data path, then `ditto`s `Build/Products/Release/AppMonitor.app` to `target/release/bundle/AppMonitor.app` (the path `deploy_releases.py` expects). The Xcode build produces the executable, the embedded `AppMonitorHelper` and its LaunchDaemon plist, Info.plist (with `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` substituted via xcodebuild settings), and the compiled asset catalog (`Assets.car`) with the AppIcon ladder. Final ad-hoc signing happens via `codesign --force --deep --sign -`.

### Signing and notarization

`bundle.py` escalates to whatever the machine can do, and never fails the build for missing credentials:

| Available | Result |
|---|---|
| Developer ID cert + notary profile | signed, notarized, stapled — helper installable |
| Developer ID cert only | signed; helper inert |
| neither | ad-hoc; helper inert |

"Inert" because `SMAppService` refuses to register a LaunchDaemon from a bundle that isn't notarized, so such builds always show `—` for processes the user doesn't own.

Signing is inside-out — `Contents/MacOS/AppMonitorHelper` first, then the bundle — rather than `codesign --deep`, which is deprecated and applies the outer options blindly to nested binaries. Both get `--options runtime` and `--timestamp`; the notary service rejects submissions missing either.

`DEVELOPMENT_TEAM` in `project.yml` is `56VA234XZ8`. That is the OU field `codesign -dv` reports as `TeamIdentifier` — **not** the id inside a certificate's common name (`Apple Development: … (V8B9F9R447)`), which is the certificate's own id and is a different value. An ad-hoc signature carries no team at all, so it only appears once a real identity signs.

One-time setup for notarization:

```
xcrun notarytool store-credentials AppMonitor \
  --apple-id <apple-id> --team-id 56VA234XZ8 --password <app-specific-password>
```

Override the profile name with `APPMONITOR_NOTARY_PROFILE`; skip the (slow, network-bound) submission with `scripts/bundle.py --no-notarize`.

An **Apple Development** certificate cannot be notarized — a **Developer ID Application** certificate is required, created at developer.apple.com → Certificates.
