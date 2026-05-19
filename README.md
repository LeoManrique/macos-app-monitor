# macos-app-monitor

A minimal GPUI alternative for macOS Activity Monitor's memory view, with processes grouped by `app` to visualize how much memory would be reclaimed by quitting an app.

## Requirements

- macOS 26 (Apple Silicon)
- Rust (stable, 2024 edition)
- Xcode + Metal Toolchain

## Run

```
cargo run --release
```

## Docs

- [DESIGN.md](./DESIGN.md) — what the UI does and why
- [TECHNICAL.md](./TECHNICAL.md) — how it's implemented
