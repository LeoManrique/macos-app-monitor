# Technical notes

## Stack

- **Rust 2024**, single `src/main.rs`.
- **`gpui-ce`** (crates.io community fork of Zed's GPUI) for the UI. The upstream `zed-industries/zed` gpui silently fails to render text on macOS 26 due to a Metal SDK mismatch; `gpui-ce` ships shaders built against the current SDK and works standalone.
- **`sysinfo`** for enumerating processes and reading executable paths.

## Memory readings

`sysinfo`'s `process.memory()` returns RSS, which overcounts shared framework pages. To match Activity Monitor, the app calls `proc_pid_rusage(pid, RUSAGE_INFO_V4, &mut buf)` directly via FFI and reads `ri_phys_footprint`. The Rust mirror of `rusage_info_v4` must match the SDK struct byte-for-byte (35 `u64` fields + 16-byte UUID = 296 bytes) — kernel writes the full flavor size and a truncated buffer corrupts the stack.

For processes the user doesn't own, `proc_pid_rusage` returns `EPERM`; the code falls back to `sysinfo`'s RSS.

## App-bundle detection

Each process's executable path is searched for the **leftmost** `.app/` substring. For nested bundles (e.g. `/Applications/Google Chrome.app/.../Google Chrome Helper.app/...`), the leftmost match is the outermost bundle, which is the user-facing app. Processes whose exe has no `.app/` in the path become their own single-member group keyed by process name.

## Refresh loop

`ProcessMonitor::new` spawns a long-lived async task via `cx.spawn(async move |this, cx| ...)`. Each iteration awaits `cx.background_executor().timer(Duration::from_secs(2))`, then runs `this.update(cx, |this, cx| { ... cx.notify() })`. The update closure refreshes `sysinfo`, rebuilds the groups, and asks GPUI to re-render. If `this.update` returns `Err`, the entity has been dropped and the loop exits.

## UI structure

`Render::render` flattens current groups + expansion state into a `Vec<Row>` (header / process / standalone variants) and feeds it to `uniform_list` for virtualized scrolling. Expand/collapse state lives on `ProcessMonitor` as a `HashSet<SharedString>` keyed by group name, so refresh ticks that rebuild the group vector preserve which apps the user expanded.

App-header rows are `Stateful<Div>` (via `.id(...)`); their `on_mouse_down` handler captures the entity and toggles the key in `expanded`.

## Window

Computed at launch from `cx.primary_display().bounds().size`, scaled to 50% × 70%, passed via `WindowBounds::centered(size, cx)`.

## Build prerequisite

Building gpui's Metal shaders on Xcode 26 requires the Metal Toolchain component (`xcodebuild -downloadComponent MetalToolchain`, ~688 MB, one-time, persists across `cargo clean`).
