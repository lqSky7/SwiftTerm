# Live stream access repair

- [x] Inspect production request logs without computer use.
- [x] Trace browser 401 before sign-in and 404 after separate anonymous sign-in.
- [x] Retain initial snapshot until the publisher socket and ticket epoch exist.
- [x] Send authentication before output, with required opening hello.
- [x] Serialize socket draining and cancel startup when sharing stops.
- [x] Show startup transport failures in the sharing sheet.
- [x] Add native recipient-bound invitation creation using existing B4 routes.
- [x] Show browser account ID, sign-in requirement, invitation redemption and ended state.
- [x] Preserve invitation fragments across sign-in and reject external return URLs.
- [x] Pass complete 42-check native suite including publisher transport regression.
- [x] Pass website typecheck, 67 tests and static build.
- [x] Verify production denial before grant, wrong-recipient denial, redemption and WebSocket snapshot forwarding through Worker.
- [x] Remove both temporary production probe identities and dependent rows.
- [x] Deploy website (d56074d0-8632-4b4a-b6e2-d32583b65c5a).
- [x] Build/install release 134 without launching; compiler warnings zero.
- [x] Update affected indexes.
- [x] Sign and push repair commit.
- [ ] Human test sharing from the installed app.

The share link identifies a stream; access remains bound to the owner account or a redeemed B4
invitation. Anonymous sign-in on two devices creates different accounts. The browser shows its ID;
the host pastes it in Share → Invite a Browser and sends the generated invitation link. Controller
permission still requires the host to approve the request to type. No backend code or schema changed.
Native export B5A remains outside this repair.

Website ESLint could not run because eslint is absent from its installed/package dependencies.
Typecheck, tests and Next static build passed. SwiftLint completed with pre-existing warnings.
