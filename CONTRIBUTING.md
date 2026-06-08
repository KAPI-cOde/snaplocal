# Contributing to SnapLocal

SnapLocal is a small project and welcomes contributions, especially from people working in non-profit or low-resource environments where the tool is most useful.

## Design constraints

Any change should satisfy these before being merged:

1. **Fully local** — no network calls, no external APIs, no telemetry
2. **No dependencies** — only Apple frameworks; do not add Swift Package dependencies
3. **macOS-native** — use ScreenCaptureKit, Vision, SwiftUI rather than third-party equivalents

## Getting started

```bash
git clone https://github.com/your-org/SnapLocal.git
cd SnapLocal
swift build -c debug --product SnapLocal   # compile
bash build-app.sh                          # build .app bundle
open .build/debug/SnapLocal.app
```

Run tests:

```bash
swift test
```

## Submitting changes

1. Fork the repository and create a branch from `main`
2. Make your change; keep commits focused
3. Run `swift build` and `swift test` before opening a PR
4. Open a pull request describing what changed and why

## Reporting issues

Open a GitHub issue. Include macOS version, steps to reproduce, and what you expected vs. what happened.
