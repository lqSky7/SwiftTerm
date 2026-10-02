# .github/workflows — index

| Workflow | Does |
| --- | --- |
| `release.yml` | on `release: published`, builds the `.app` on `macos-26`, zips it with `ditto`, writes a `.sha256`, and uploads both onto that release with `gh release upload` |
| `build.yml` | the same build, on every push, on a pull request, or on demand, so a broken build is found on the commit that broke it |

`build.yml` exists because the app cannot always be built locally: a toolchain whose macro plugin server
fails takes `@Observable` down with it, and then the only honest way to know the tree compiles is to ask
a runner. It runs on every push, so a commit that should not spend a runner says so itself — GitHub
skips a `push` or `pull_request` run when the commit message carries `[skip ci]` (or `[ci skip]`,
`[no ci]`, `[skip actions]`, `[actions skip]`). That is the platform's behaviour, not ours; there is no
filtering code in the workflow. `workflow_dispatch` ignores it.

A macOS runner bills at ten times the rate of a Linux one, which is the whole reason `[skip ci]` is
worth using on commits that touch only `docs/` or a comment.

There is no CI for lint or the harnesses: those stay local (`./Scripts/lint.sh`, `./Scripts/run-tests.sh`),
per `AGENTS.md`.

The runner has Xcode, so `actool` compiles `app/assets/swiftTerm.icon` into the Liquid Glass
`Assets.car`; the flat fallback icon in `build-app.sh` is not the path CI takes.

The bundle is ad-hoc signed, which is enough to launch it locally but not enough to survive
Gatekeeper on a machine that downloaded it. Until there is a Developer ID, the zip is for people who
know to clear the quarantine bit.
