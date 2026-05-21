# CLAUDE.md

## Always fetch current docs before writing code

Before making non-trivial changes in this repo, pull current documentation via the **context7** MCP server. Built-in knowledge lags both of these.

- **Rust 1.95** (2024 edition). Resolve `rust` / `std` on context7 and fetch docs for whatever API you're touching — async traits, lifetime rules, and stdlib additions have moved.
- **gpui-ce** (crates.io community fork — NOT `zed-industries/zed`). Always:
  1. Resolve the latest `gpui-ce` version on crates.io.
  2. Fetch its context7 docs before writing any GPUI code.

  The API surface differs from upstream `gpui` and changes between minor versions. Do not guess GPUI APIs from upstream Zed source or from memory — look them up each time.

Skip the lookup only for trivial edits (renames, comment-only changes, etc.).

## Stack pointers

- Single binary, `src/main.rs`. Target: macOS 26+ Apple Silicon.
- See `TECHNICAL.md` for the gpui-ce rationale, the `proc_pid_rusage` FFI layout, and the refresh-loop shape.
- See `DESIGN.md` for the grouping semantics ("how much memory would I reclaim by quitting this app?").

## Keep docs in sync with code

After any major change, update the doc(s) that describe what changed. Don't defer this — stale docs are worse than missing ones.

- **`README.md`** — update when build/run instructions, requirements, or the one-line description change.
- **`DESIGN.md`** — update when user-visible behavior changes: window size, columns, grouping rules, row layout, sort order, refresh cadence, the memory metric shown.
- **`TECHNICAL.md`** — update when implementation details change: dependency choices, FFI structs, refresh-loop shape, render structure, build prerequisites.
- **`ROADMAP.md`** — move items from "Next" to "Done" when shipped; add new items as they come up. Don't mark them as Done until user tests the feature and reports them as completed.

Never repeat information between them and keep them concise.