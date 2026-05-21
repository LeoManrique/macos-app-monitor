# macos-app-monitor

Simple alternative for macOS Activity Monitor, grouping processes by `.app` to visualize how much memory would be reclaimed by quitting a specific app. Built in SwiftUI.

## Install

```
curl -fsSL https://raw.githubusercontent.com/LeoManrique/macos-app-monitor/master/scripts/install.sh | bash
```

Installs the latest release to `/Applications/AppMonitor.app`. The bundle is ad-hoc signed (no Apple Developer Program membership behind it), so the install script strips the Gatekeeper quarantine attribute on your behalf.

## Docs

- [DESIGN.md](./DESIGN.md) — what the UI does and why
- [TECHNICAL.md](./TECHNICAL.md) — how it's implemented
