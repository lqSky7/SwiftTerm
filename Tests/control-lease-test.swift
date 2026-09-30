import Foundation

/// Tests the host's control-lease state machine.
///
/// Every case here is a way control can go wrong with a name: two browsers holding it, a lease
/// surviving a reconnect, a local keystroke losing a race with a remote one, a re-sent Enter
/// submitting twice, and a gap being applied as if it were consecutive.
@main
enum ControlLeaseTest {
    static func main() {
        let harness = Harness("control-lease-test")

        approval(harness)
        replacement(harness)
        epoch(harness)
        sequence(harness)
        expiry(harness)
        localInput(harness)

        harness.finish()
    }

    private static let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// A lease held by `browser`, granted at `t0` under epoch 1.
    private static func held(browser: String = "browser-a") -> (ControlLease, String) {
        var lease = ControlLease()
        lease.request(browserID: browser)
        guard case .granted(let token, _) = lease.approve(generation: "1", now: t0, makeLease: { "L1" })
        else { return (lease, "") }
        return (lease, token)
    }

    private static func approval(_ harness: Harness) {
        var lease = ControlLease()
        harness.expect(!lease.isHeld, "nothing is held before anyone asks")

        // Asking is not having. A request that granted control would make the approval a formality.
        lease.request(browserID: "browser-a")
        harness.expect(!lease.isHeld, "a request does not grant control")

        guard case .granted(let token, let expires) = lease.approve(generation: "1", now: t0, makeLease: { "L1" })
        else {
            harness.expect(false, "an approval grants")
            return
        }
        harness.equal(token, "L1", "the lease is the one that was minted")
        harness.equal(expires, t0.addingTimeInterval(30), "and it expires in thirty seconds")
        harness.expect(lease.isHeld, "the lease is held")
    }

    private static func replacement(_ harness: Harness) {
        var lease = ControlLease()
        lease.request(browserID: "browser-a")
        _ = lease.approve(generation: "1", now: t0, makeLease: { "L1" })
        lease.request(browserID: "browser-b")
        guard case .granted(let second, _) = lease.approve(generation: "1", now: t0, makeLease: { "L2" })
        else {
            harness.expect(false, "a second browser can be approved")
            return
        }

        // One holder, and the first browser's lease is gone rather than coexisting: two browsers
        // writing to one prompt is two people typing into the same sentence.
        harness.equal(second, "L2", "the new lease is the one installed")
        harness.equal(
            lease.verdict(browserID: "browser-a", epoch: "1", lease: "L1", inputSeq: 1, now: t0),
            .reject(reason: "no such lease"),
            "the replaced browser can no longer type")
        harness.equal(
            lease.verdict(browserID: "browser-b", epoch: "1", lease: "L2", inputSeq: 1, now: t0),
            .accept, "and the new one can")
    }

    private static func epoch(_ harness: Harness) {
        var (lease, token) = held()
        // A host that reconnected is a new publisher generation. The old lease is not stale input to
        // be deduplicated — it is input that must never be applied at all.
        harness.equal(
            lease.verdict(browserID: "browser-a", epoch: "2", lease: token, inputSeq: 1, now: t0),
            .reject(reason: "stale epoch"),
            "a lease from another generation is refused")
        harness.expect(lease.isHeld, "and refusing it does not drop the current lease")
    }

    private static func sequence(_ harness: Harness) {
        var (lease, token) = held()
        func type(_ n: Int, at time: Date = t0) -> ControlLease.Verdict {
            lease.verdict(browserID: "browser-a", epoch: "1", lease: token, inputSeq: n, now: time)
        }

        harness.equal(type(1), .accept, "the first input is accepted")
        harness.equal(type(2), .accept, "the next sequence is accepted")

        // An ack can be lost, so a re-send is expected. It must be answered from the last result and
        // **not applied again** — a re-sent Enter must not submit twice.
        harness.equal(type(2), .duplicate, "a repeated sequence is a duplicate")
        harness.equal(type(1), .duplicate, "and so is an older one that was already applied")

        // A gap means the two ends disagree about what was typed.
        harness.equal(type(5), .reject(reason: "sequence gap"), "a gap is refused")
        harness.equal(type(3), .accept, "and the next consecutive one still applies")

        // A frame from the wrong browser is not a gap or a duplicate; it is not this lease.
        harness.equal(
            lease.verdict(browserID: "browser-b", epoch: "1", lease: token, inputSeq: 4, now: t0),
            .reject(reason: "no such lease"),
            "another browser cannot type with a stolen lease token")
    }

    private static func expiry(_ harness: Harness) {
        var (lease, token) = held()
        let justBefore = t0.addingTimeInterval(29)
        let after = t0.addingTimeInterval(31)

        harness.expect(!lease.hasExpired(now: justBefore), "the lease is live before it expires")
        harness.expect(lease.hasExpired(now: after), "and expired after")

        harness.equal(
            lease.verdict(browserID: "browser-a", epoch: "1", lease: token, inputSeq: 1, now: after),
            .reject(reason: "the lease expired"),
            "an expired lease refuses input")

        // An accepted input renews it, so an active controller never has to notice a clock.
        var (renewed, renewedToken) = held()
        harness.equal(
            renewed.verdict(
                browserID: "browser-a", epoch: "1", lease: renewedToken, inputSeq: 1, now: justBefore),
            .accept, "input before expiry is accepted")
        harness.expect(
            !renewed.hasExpired(now: t0.addingTimeInterval(50)),
            "and it renewed the lease by another thirty seconds")
    }

    private static func localInput(_ harness: Harness) {
        var (lease, token) = held()
        guard case .revoked(let reason) = lease.revoke(reason: "local input") else {
            harness.expect(false, "revoking a held lease reports it")
            return
        }
        harness.equal(reason, "local input", "the reason travels so the browser can be told")
        harness.expect(!lease.isHeld, "the lease is gone")

        // The person at the machine wins, and the browser is told rather than left believing it
        // still has control.
        harness.equal(
            lease.verdict(browserID: "browser-a", epoch: "1", lease: token, inputSeq: 1, now: t0),
            .reject(reason: "no such lease"),
            "a revoked lease cannot type")

        // Idempotent, because it is called from several places that cannot all know whether a lease
        // was held.
        harness.expect(lease.revoke(reason: "again") == nil, "revoking nothing reports nothing")

        var empty = ControlLease()
        harness.equal(empty.deny(reason: "no").reason, "no", "a denial carries its reason")
        harness.expect(!empty.isHeld, "and grants nothing")
    }
}

private extension ControlLease.Decision {
    var reason: String {
        switch self {
        case .denied(let reason), .revoked(let reason): return reason
        case .granted: return ""
        }
    }
}
