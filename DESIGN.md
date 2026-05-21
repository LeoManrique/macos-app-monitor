# Functional design

## Goal

Answer one question quickly: *"how much memory would I get back if I quit this app?"*

Activity Monitor lists processes individually; reclaiming memory by quitting Chrome means mentally summing 20+ helper rows. This tool groups them.

## Window

Opens centered at 50% × 70% of the primary display. Dark theme. Single view, no tabs.

## Columns

| Column | Meaning |
|---|---|
| PID | Process id, or `▸` / `▾` disclosure triangle on app group headers |
| Process Name | Process executable name, or app bundle name on group headers. Reserves a 16 px icon gutter so names align across rows whether or not an icon is shown |
| % CPU | Per-process CPU usage as reported by the kernel (can exceed 100% on multi-core), or summed total on group headers |
| Memory | Per-process memory, or summed total on group headers |

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
- Rows for `.app` bundles show the app's icon (16×16) before the name. Bundles whose icon only ships via `Assets.car` have no icon (see TECHNICAL.md). Rows without an icon still reserve the 16 px slot, so all names line up.

## Status bar

A footer strip across the bottom shows aggregate system stats:

- **Memory**: used / total (GB)
- **CPU**: system-wide CPU % (sum normalized across cores)
- **Disk free**: free / total of the root volume (GB)

The stats refresh on the same 2-second tick as the process list.

## Sort & refresh

- Default sort: Memory, descending. Children within a group always share the parent's sort.
- Click any column header to sort by that column. Clicking the active column flips direction. The header shows ` ▾` (desc) / ` ▴` (asc) next to the active label.
- Per-column default directions on first click: PID and Process Name ascending; % CPU and Memory descending.
- When sorting groups by PID, the group is ranked by its lowest-PID process.
- Auto-refreshes every 2 seconds. Expand/collapse state and the active sort survive refreshes.

## Memory metric

Reports each process's `phys_footprint` — the same number Activity Monitor's "Memory" column shows. This excludes shared/clean pages and credits compressed memory, so the total is what would actually be freed on quit. Falls back to resident-set size only for processes the kernel won't let us inspect.

Values shown in MB up to 1024 MB, then GB.
