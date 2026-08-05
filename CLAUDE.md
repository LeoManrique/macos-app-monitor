# CLAUDE.md

## Always fetch current docs before writing code

Before making non-trivial changes in this repo, pull current documentation via the **context7** MCP server or `WebFetch` against developer.apple.com. Built-in knowledge lags Apple's SDK churn.

- **Latest Swift version** (strict concurrency). Resolve `swift` on context7 and fetch docs for whatever API you're touching — actor isolation, `Sendable` conformance, and the `Observable` macro have evolved each major release.
- **Latest SwiftUI / AppKit / Darwin libproc** (latest macOS SDK). Always:
  1. Identify the precise type/function you're using (`Table`, `KeyPathComparator`, `proc_pid_rusage`, `NSWorkspace`, etc.).
  2. Fetch its current docs before writing code that depends on its signature or behavior.

  Apple's APIs change subtly between SDK versions, and macOS-26-only behaviors (e.g. the `.inset(alternatesRowBackgrounds:)` table style) are not in older training data. Do not guess Apple APIs from memory.

Skip the lookup only for trivial edits (renames, comment-only changes, etc.).

Suggest to upgrade libraries to user when available. Wait for their approval to proceed with the upgrade.

## Stack pointers

- SwiftUI app generated via **xcodegen** from `project.yml`. Source under `AppMonitor/`.
- Target: macOS 26+ Apple Silicon.
- See `TECHNICAL.md` for the project layout, sampling model, refresh loop, and packaging story.
- See `DESIGN.md` for the grouping semantics ("how much memory would I reclaim by quitting this app?").

## Keep docs in sync with code

After any major change, update the doc(s) that describe what changed. Don't defer this — stale docs are worse than missing ones.

- **`README.md`** — update when build/run instructions, requirements, or the one-line description change.
- **`DESIGN.md`** — update when user-visible behavior changes: window size, columns, grouping rules, row layout, sort order, refresh cadence, the memory metric shown.
- **`TECHNICAL.md`** — update when implementation details change: project layout, sampling primitives, refresh-loop shape, render structure, build prerequisites.
- **`ROADMAP.md`** — move items from "Next" to "Done" when shipped; add new items as they come up. Don't mark them as Done until user tests the feature and reports them as completed.

Never repeat information between them and keep them concise.

# Visual testing

Do not perform screenshots, ask user for visual feedback if needed.
