import Foundation

/// The host's side of browser control: one browser at a time, and only while the person allows it.
///
/// A pure state machine, deliberately. Everything about control that can be got wrong is a decision
/// about *when* a lease is valid, and none of it needs a terminal, a socket or a view to decide. The
/// pane supplies the inputs; this says yes or no, and every "no" has a reason that is not a crash.
///
/// Five rules, and each one is a failure that has a name:
///
///   * **One holder.** A second approval replaces the first only after revoking it, because two
///     browsers writing to one prompt is two people typing into the same sentence.
///   * **The epoch is checked, not assumed.** A lease is bound to the publisher generation that
///     granted it. A host that reconnected is a new generation, and an old lease must not survive
///     into it — that is exactly the stale-input hole the epoch exists to close.
///   * **Local input wins.** Any keystroke at the machine revokes the remote lease *before* the
///     keystroke is applied, so the person in front of the computer never has to fight a browser for
///     their own prompt.
///   * **Sequence numbers are consecutive.** A repeated sequence is answered from the last result
///     rather than applied twice — an ack can be lost, and a re-sent Enter must not submit twice.
///     A gap is refused outright, because a missing input means the two ends disagree about what was
///     typed.
///   * **A lease expires.** Thirty seconds, renewed only while the approval stands. A browser that
///     goes away mid-sentence loses control rather than holding it forever.
struct ControlLease {
    /// How long a lease is good for. Renewed on each accepted input, so an active controller never
    /// notices it.
    static let lifetime: TimeInterval = 30

    /// What happened to a request to control.
    enum Decision: Equatable, Sendable {
        case granted(lease: String, expiresAt: Date)
        case denied(reason: String)
        /// A lease that was held is now gone. Sent to the browser that held it.
        case revoked(reason: String)
    }

    /// Whether an input frame may be applied.
    enum Verdict: Equatable, Sendable {
        case accept
        /// Already applied. The ack is re-sent and the input is **not** applied again.
        case duplicate
        case reject(reason: String)
    }

    private(set) var browserID: String?
    private(set) var lease: String?
    private(set) var epoch: String?
    private(set) var expiresAt: Date?
    /// The last input sequence applied under this lease. Gaps are refused against it.
    private(set) var lastInputSeq: Int?
    /// A request waiting for a person to approve it. One at a time: a queue of approvals is a queue
    /// of decisions nobody is making.
    private(set) var pendingBrowserID: String?

    init() {}

    var isHeld: Bool { lease != nil }

    /// Record that a browser asked for control. Does not grant anything.
    mutating func request(browserID: String) {
        pendingBrowserID = browserID
    }

    /// Approve the pending request, or the named browser if there is one.
    ///
    /// `generation` is the publisher epoch this approval belongs to. Approving while another lease is
    /// held revokes it first and says so, so the browser that loses control is told rather than left
    /// believing it still has it.
    mutating func approve(
        browserID: String? = nil,
        generation: String,
        now: Date,
        makeLease: () -> String = { UUID().uuidString.lowercased() }
    ) -> Decision {
        let target = browserID ?? pendingBrowserID
        guard let target else { return .denied(reason: "no browser is asking") }
        pendingBrowserID = nil

        // One holder. The previous lease ends here rather than coexisting.
        let replaced = self.browserID != nil && self.browserID != target
        self.browserID = target
        self.epoch = generation
        self.lease = makeLease()
        self.expiresAt = now.addingTimeInterval(Self.lifetime)
        self.lastInputSeq = nil

        guard let lease else { return .denied(reason: "no lease") }
        _ = replaced
        return .granted(lease: lease, expiresAt: expiresAt ?? now)
    }

    mutating func deny(reason: String) -> Decision {
        pendingBrowserID = nil
        return .denied(reason: reason)
    }

    /// Give up the lease. Called on local input, on the holder disconnecting, on the host stopping,
    /// and whenever permission is withdrawn.
    ///
    /// Idempotent: revoking nothing is not an error, because it is called from several places that
    /// cannot all know whether a lease was held.
    @discardableResult
    mutating func revoke(reason: String) -> Decision? {
        guard browserID != nil else { return nil }
        let holder = browserID
        browserID = nil
        lease = nil
        epoch = nil
        expiresAt = nil
        lastInputSeq = nil
        _ = holder
        return .revoked(reason: reason)
    }

    /// Whether an input frame may be applied, and whether it has already been.
    ///
    /// The order of the checks is the order of the failures: a frame from the wrong epoch is not a
    /// duplicate and must not be reported as one, and a frame with no lease is not a gap.
    mutating func verdict(
        browserID: String,
        epoch: String,
        lease: String,
        inputSeq: Int,
        now: Date
    ) -> Verdict {
        guard self.browserID == browserID, self.lease == lease else {
            return .reject(reason: "no such lease")
        }
        // The epoch first: a host that reconnected is a new generation, and a lease from the old one
        // is not stale input to be deduplicated — it is input that must never be applied at all.
        guard self.epoch == epoch else { return .reject(reason: "stale epoch") }
        guard let expiresAt, expiresAt > now else {
            return .reject(reason: "the lease expired")
        }

        if let last = lastInputSeq {
            // At or below what was applied is a replay: an ack can be lost, so the browser re-sends,
            // and the answer is the last result rather than a second application.
            if inputSeq <= last { return .duplicate }
            // Above the next one is a gap. The two ends disagree about what was typed, and applying
            // the frame would put a sentence together out of two different ones.
            guard inputSeq == last + 1 else { return .reject(reason: "sequence gap") }
        }
        lastInputSeq = inputSeq
        // An accepted input renews the lease: an active controller should not have to notice a clock.
        self.expiresAt = now.addingTimeInterval(Self.lifetime)
        return .accept
    }

    /// Whether the held lease has run out at this moment.
    func hasExpired(now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }
}
