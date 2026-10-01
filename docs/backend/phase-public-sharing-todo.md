# Public sharing phase

- [x] Inspect native, backend and website sharing contracts.
- [x] Add sealed-block local capture, selection and editable preview.
- [x] Mask common secret fixtures before preview; omit draft/cwd/image metadata.
- [x] Freeze immutable publish request and capability through lost-response retries.
- [x] Add public static snapshot option and revoke action.
- [x] Add unauthenticated static page with bounded validation and escaped text.
- [x] Align backend stored block-array contract and server validation.
- [x] Add temporary public viewer tickets with read-only socket enforcement and expiry.
- [x] Add one-action temporary public sharing from the Mac, including anonymous setup.
- [x] Add persistent Sharing setting with lazy cloud initialization and shutdown.
- [x] Gate menus, sidebar, account and sharing actions while disabled.
- [x] Test masking, sealed-only export, hostile/control strings and size bounds.
- [x] Test public read without cookies, retry identity, revoke and public control denial.
- [x] Test settings persistence and disabling live/static tasks.
- [x] Run native, website and backend checks.
- [x] Deploy backend/website and verify public static/live flows by HTTP/WebSocket.
- [x] Update indexes and phase status.
- [x] Build/install release without opening it (136).
- [x] Sign and push meaningful changes in both repositories.
- [ ] Human acceptance on installed app.

User expanded this phase to direct temporary public read-only streaming and disabling all cloud
sharing. Public static exports use the existing array storage with canonical sealed block DTOs and
plain text. No database migration is needed. A temporary live capability is held only by the relay
process; restarting it invalidates these temporary links. Live links expire after one hour or when
the host ends sharing. No public viewer receives control permission.

Validation: 44 native checks, 70 website tests/typecheck/static build, 183 backend tests/typecheck.
SwiftLint has no errors/new warnings; existing repository warnings remain. Website ESLint is absent
from package dependencies. Production page returns no-store/CSP/no-referrer/no-index. Shipped Swift
public static publish/retry and publisher startup passed cookie-free browser reads and digest/cell
snapshot verification; forged publisher/control requests denied; native revoke/stop denied new reads.
Both probe runs removed their synthetic owner rows and local credential files.

Public static content uses plain text to keep local preview edits exact and avoid stale style offsets.
Snapshots have no expiry by default and remain public until owner revocation/deletion; Account can
revoke published links later. The host also automatically ends temporary streaming after one hour.
The Settings switch applies across all app windows; cloud identity/client creation is lazy, and a
headless shipped-AppCore harness checks disabled actions, release and teardown without side effects.

Backend implementation: signed/pushed 33ba4d0. Website deployment:
79e96dab-d6f7-4267-9b61-7132b7a3bbfb. Native release 136 installed without launch.
Existing backend origin-logging worktree change was preserved and excluded from this commit.
