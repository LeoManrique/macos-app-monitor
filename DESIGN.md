# Functional design

## Goal

Answer one question quickly: *"how much memory would I get back if I quit this app?"*

Activity Monitor lists processes individually; reclaiming memory by quitting Chrome means mentally summing 20+ helper rows. This tool groups them.

## Window

Opens centered at 50% × 70% of the primary display. Dark theme. Single view, no tabs.

## Columns

| Column | Meaning |
|---|---|
| PID | Process id, or `> N` / `v N` chevron + child count on app group headers |
| Name | Process executable name, or app bundle name on group headers |
| Memory | Per-process memory, or summed total on group headers |

## Grouping rules

- Each process is mapped to its enclosing `.app` bundle (if any).
- Processes sharing the same outermost `.app` are one group:
  - All Chrome helpers + main Chrome → "Google Chrome".
  - All Code helpers + Electron → "Visual Studio Code".
- Processes outside any `.app` (CLI tools, daemons) are their own single-member group, displayed flat.

## Rows

- **Multi-process app group**: collapsed by default. Single clickable row showing total memory. Click toggles expansion; children render indented underneath.
- **Single-process group**: rendered as one flat row — no header chrome.

## Sort & refresh

- Groups sorted by total memory, descending. Children within a group sorted the same way.
- Auto-refreshes every 2 seconds. Expand/collapse state survives refreshes.

## Memory metric

Reports each process's `phys_footprint` — the same number Activity Monitor's "Memory" column shows. This excludes shared/clean pages and credits compressed memory, so the total is what would actually be freed on quit. Falls back to resident-set size only for processes the kernel won't let us inspect.

Values shown in MB up to 1024 MB, then GB.
