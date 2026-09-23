# swiftTerm

A native macOS terminal that takes the *product* ideas from Warp and implements them on Apple's own
stack — AppKit, SwiftUI, CoreText — with no third-party dependencies.

Targets macOS 26+ only, Swift 6 language mode. See [`docs/phases.md`](docs/phases.md) for the plan
and [`docs/phase-1.md`](docs/phase-1.md) for what Phase 1 is.

```bash
./Scripts/run-tests.sh     # the standalone harnesses
./Scripts/lint.sh          # swiftlint + the pure-model gate
./Scripts/run.sh           # build, install to /Applications, launch
```
