# Functional design

## Goal

Answer one question quickly: *"how much memory would I get back if I quit this app?"*

Activity Monitor lists processes individually; reclaiming memory by quitting Chrome means mentally summing 20+ helper rows. This tool groups them.

## Window

Opens centered at 50% × 70% of the primary display. Dark theme. Single view, no tabs.

The title bar is compact: one short row holding the traffic lights, the app name, and the search field — no separate toolbar band above the table.

## Columns

| Column | Meaning |
|---|---|
| PID | Process id, or `▸` / `▾` disclosure triangle on app group headers |
| Process Name | Process executable name, or app bundle name on group headers. Reserves a 16 px icon gutter so names align across rows whether or not an icon is shown |
| % CPU | Share of the **whole machine** the process is using, or summed total on group headers. The column adds up to the footer's CPU figure |
| Memory | Per-process memory, or summed total on group headers |

Either cell reads `—` when macOS refuses us that process's counters — see *Full process access* below. A dash means "not measured", never "idle".

## Grouping rules

- Each process is mapped to its enclosing `.app` bundle (if any).
- Processes sharing the same outermost `.app` are one group:
  - All Chrome helpers + main Chrome → "Google Chrome".
  - All Code helpers + Electron → "Visual Studio Code".
- Processes outside any `.app` (CLI tools, daemons) are their own single-member group, displayed flat.

## Rows

- **App group**: collapsed by default. Single clickable row showing the app name, icon, and totals. Click toggles expansion; children render indented underneath.
  - Always used for multi-process `.app` bundles.
  - Also used for single-process `.app` bundles when the process's own name differs from the bundle name (e.g. `LeoSync.app` running only `leosyncd` — the group header shows "LeoSync" with the app icon; expanding reveals the real process name).
- **Flat row**: no header chrome. Used when:
  - The process is outside any `.app` (CLI tools, daemons).
  - A single-process `.app` bundle whose process name exactly matches the bundle name (e.g. `LeoSync.app` running just `LeoSync`).
- Rows for `.app` bundles show the app's icon (16×16) before the name. Icons come from `NSWorkspace.shared.icon(forFile:)`, which handles `Info.plist`, `.icns`, `Assets.car`, and Electron-app quirks transparently. Rows without an icon still reserve the 16 px slot, so all names line up.

## Search

A search field sits in the window's toolbar; **Edit ▸ Find** (⌘F) jumps to it, Escape clears it.

- Typing filters the list live — no waiting for the next refresh tick — and the filter survives refreshes.
- A group is kept when its own name matches **or** any process inside it does, so searching `chrome` and searching a helper's name both surface Google Chrome. Matching ignores case and accents.
- A query that's purely digits also matches that exact PID.
- Kept groups keep **all** their children and their real totals. The header still answers "how much would I reclaim by quitting this?", and quitting it means the same thing filtered or not — it never quits just the part that matched.
- Rows hidden by the filter drop out of the selection.
- A filter that matches nothing shows "No Results" in place of the table. The footer stays system-wide either way — it describes the machine, not the filter.

## Selection & quitting

- Click a row to select it; ⌘-click and ⇧-click extend the selection across group headers and child processes alike. A selection survives refreshes; rows whose process has exited drop out of it.
- Right-click a row for **Quit** / **Force Quit**. Right-clicking outside the current selection retargets the menu to the clicked row, as elsewhere on macOS.
- The same two actions live under the **Process** menu — ⌥⌘Q quit, ⌥⇧⌘Q force quit — and are disabled with nothing selected.
- Quitting a group header quits the whole app, not one helper: every process under the header is included. When the group contains a real app, the request goes to the app itself so it can tear down its own helpers; otherwise each process is signalled directly (`SIGTERM`, or `SIGKILL` when forced).
- Acting on a single row takes effect immediately, however many processes it covers. Selections spanning **two or more rows** ask for confirmation first, listing what's about to close, with both Quit and Force Quit offered.
- Anything that refuses to die is reported in an alert — most often a process owned by another user, which requires privileges the app doesn't have. Processes that had already exited are not reported.

## Status bar

A footer strip across the bottom shows aggregate system stats:

- **Memory**: used / total (GB)
- **CPU**: system-wide CPU %, 100% meaning every core saturated
- **Swap**: swap in use
- **Disk free**: free / total of the root volume (GB)

The stats refresh on the same 2-second tick as the process list.

## CPU metric

`% CPU` is a share of the whole machine, so the rows reconcile with the footer total: a process pinning one core of a 12-core Mac reads `8.3`, and the column sums to roughly the footer figure.

This differs from Activity Monitor and `top`, which report a share of *one core* — there the same process reads `100`, a saturated 4-thread build reads `400`, and the column sums to nothing meaningful. Making the two numbers reconcile was the explicit goal; parity with Activity Monitor was traded away for it.

Rows can still sum to slightly under the footer, because the footer counts CPU burned by processes we may not be able to attribute (see below).

## Full process access

`proc_pid_rusage` returns EPERM for any process the user doesn't own — roughly 250 of 800 on a normal desktop, and they include the heaviest consumers (`WindowServer`, `kernel_task`). Unprivileged, the app can attribute only about half the machine's CPU, and those rows show `—`.

**Process ▸ Enable Full Process Access…** installs a small root helper that samples on the app's behalf, after which every process reports real numbers and the column reconciles with the footer. macOS gates this behind an approval in System Settings ▸ General ▸ Login Items, and the menu offers a shortcut there while approval is pending.

Installing is always the user's choice — the app never registers the helper on its own. Without it everything still works; some rows just read `—`. The helper is only installable in a notarized build, so local development builds always run in the `—` mode.

## Sort & refresh

- Default sort: Memory, descending. Children within a group always share the parent's sort.
- Click any column header to sort by that column. Clicking the active column flips direction. The header shows ` ▾` (desc) / ` ▴` (asc) next to the active label.
- Per-column default directions on first click: PID and Process Name ascending; % CPU and Memory descending.
- When sorting groups by PID, the group is ranked by its lowest-PID process.
- Auto-refreshes every 2 seconds. Expand/collapse state and the active sort survive refreshes.

## Memory metric

Reports each process's `phys_footprint` — the same number Activity Monitor's "Memory" column shows. This excludes shared/clean pages and credits compressed memory, so the total is what would actually be freed on quit. Processes the kernel won't let us inspect read `—` rather than a misleading `0`.

Values shown in MB up to 1024 MB, then GB.
