# app/src/updates — index

| File | Holds |
| --- | --- |
| `UpdateController.swift` | `UpdateController` (the check, download, verify, install and restart) and `UpdateError` |

The update source is this repository's own GitHub releases — the ones `.github/workflows/release.yml`
publishes — matched by the `swiftTerm-<version>.zip` and `.sha256` assets it attaches.

**Nothing runs until the Updates settings page calls `check()`.** No timer, no check at launch, no
stored state. That is the same rule `AccountController` follows, and it is what keeps "an app that
makes no requests until asked" a property of the structure rather than of a flag.

The install path: `ditto -x -k` into a temp directory → verify SHA-256 against the release's published
`.sha256` → move the unpacked bundle to `.swiftTerm-incoming.app` beside the target → move the running
bundle to `.swiftTerm-previous.app` → move the new one into place → delete the previous. Both moves are
renames on one volume, and the old build is put back if the last one fails.

A running bundle can be moved aside — the process keeps the copy it opened — which is why this ends in
a **restart** rather than a relaunch. `restart()` hands `open` to a shell that outlives the process and
waits for the pid to disappear.

The page itself is `UpdatesSettingsView` in `../workspace/SettingsView.swift`; `AppCore` owns the one
`UpdateController`.

`canInstall` is false for a bare executable (`swift run`, `.build`), and the page says so instead of
failing halfway through.
