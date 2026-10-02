# .github/workflows — index

| Workflow | Does |
| --- | --- |
| `release.yml` | on `release: published`, builds the `.app` on `macos-26`, zips it with `ditto`, writes a `.sha256`, and uploads both onto that release with `gh release upload` |

There is no CI-on-push workflow: lint and the harnesses stay local (`./Scripts/lint.sh`,
`./Scripts/run-tests.sh`), per `AGENTS.md`.

The runner has Xcode, so `actool` compiles `app/assets/swiftTerm.icon` into the Liquid Glass
`Assets.car`; the flat fallback icon in `build-app.sh` is not the path CI takes.

The bundle is ad-hoc signed, which is enough to launch it locally but not enough to survive
Gatekeeper on a machine that downloaded it. Until there is a Developer ID, the zip is for people who
know to clear the quarantine bit.
