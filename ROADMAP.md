# Roadmap

## Done

- [x] List processes with memory usage matching Activity Monitor (`phys_footprint`)
- [x] Group by `.app` bundle, show reclaimable-on-quit totals
- [x] Expand / collapse multi-process groups
- [x] Auto-refresh every 2 s, sorted by memory
- [x] Centered 50% × 70% window
- [x] MacOS native shortcuts (e.g. Cmd+Q)
- [x] Activity-Monitor-aligned styling: zebra rows, disclosure triangles, refined palette
- [x] CPU column (per process and per group)
- [x] Click column headers to change sort
- [x] General stats (total memory / CPU / disk usage)
- [x] App icons next to group names
- [x] Ship as an ad-hoc-signed `.app` bundle (via `scripts/bundle.py` + GitHub Releases)
- [x] Migrate to SwiftUI (resident memory now lower than Apple's Activity Monitor)
- [x] Row selection (single + multi) and right-click "Quit" / "Force Quit"
- [x] Fix per-app CPU accuracy: `ri_user_time` is mach ticks, not nanoseconds — every reading was 41.67× low on Apple Silicon
- [x] Report `% CPU` as a share of the machine so the column reconciles with the footer total
- [x] Render `—` for processes macOS won't let us inspect, instead of a misleading `0.0`
- [x] Search / filter box

## Next

- [ ] Verify: root helper (Process ▸ Enable Full Process Access…) — needs a Developer-ID-signed, notarized build; untestable ad-hoc
- [ ] Create a **Developer ID Application** certificate — the only missing piece for the helper (the Apple Development cert in the keychain cannot be notarized); `scripts/bundle.py` signs + notarizes automatically once it exists
- [ ] Memory-over-time sparkline per app
- [ ] Light theme + system-appearance follow
- [ ] Disk usage statistic (as in load)
- [ ] Silence the SwiftUI `Table` reentrant-NSTableView-delegate warning
