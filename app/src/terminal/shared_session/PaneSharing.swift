import Foundation
import Observation

/// One pane's sharing: the capture, the publisher, and the host's side of browser control.
///
/// This is the piece that was missing between the model and the wire. It owns four things and each
/// has a reason to be here rather than somewhere else:
///
///   * **The capture, on the main actor.** It reads the session's blocks and hands the publisher a
///     value type. Nothing here encodes, hashes or sends.
///   * **The lease.** Whether a browser may type is a question about the person in front of the
///     machine, so it is answered here, next to the pane, and not by the relay.
///   * **The routing decision.** A prompt action goes to the editor; a raw action goes to the PTY.
///     This type decides *which*, and the pane supplies the mechanism through the closures below —
///     because the editor is a view and this type has no business knowing that.
///   * **Nothing about the shell.** It cannot start, stop, resize or read a PTY except to write an
///     approved input, which is the whole point of putting the lease next to the thing it guards.
@MainActor
@Observable
final class PaneSharing {
    /// What the pane has to do to apply an approved input. Supplied by the pane, because the editor
    /// and the raw path live in layers this type must not reach into.
    struct Mechanisms {
        /// Put text into the prompt editor, as if it had been typed. Returns false when there is no
        /// editor to put it in — a raw program, for instance.
        var insertText: (String) -> Bool = { _ in false }
        /// Translate a logical key and write it to the shell.
        var sendKey: (WireInputKey, [WireModifier]) -> Bool = { _, _ in false }
        /// Undo or redo in the prompt editor.
        var editHistory: (Bool) -> Bool = { _ in false }
    }

    private(set) var publisher: StreamPublisher?
    private(set) var lease = ControlLease()
    /// True while a browser is asking and no person has answered. The pane shows this.
    ///
    /// A flag rather than the requester's identity, because there is no identity to hold: the
    /// contract's `control.request` carries none. See `holderID`.
    private(set) var hasPendingRequest = false
    /// True when the host is sharing this pane at all.
    private(set) var isSharing = false

    @ObservationIgnored private let identity: PaneExportIdentity
    @ObservationIgnored private let exporter = PaneExporter()
    @ObservationIgnored private var mechanisms = Mechanisms()
    @ObservationIgnored private weak var session: TerminalSession?

    init(identity: PaneExportIdentity = PaneExportIdentity()) {
        self.identity = identity
    }

    var viewerCount: Int {
        if case .live(let viewers) = publisher?.state { return viewers }
        return 0
    }

    var canControl: Bool { lease.isHeld }

    /// The identity the host attributes an input to.
    ///
    /// The contract's `control.request` carries no requester identity, and that is deliberate: it
    /// says the requester cannot name another client, so there is no field in which to try. The host
    /// therefore has no browser id to key a lease on, and the relay supplies the missing half — it
    /// permits one outstanding request and forwards `input` only from the connection it granted,
    /// which is what makes "one holder" true rather than merely intended.
    ///
    /// What the host *can* check is the generation, so that is what the lease is keyed on. It is the
    /// only identity the frames carry, and it is the one that matters: a lease must not survive into
    /// a generation that did not issue it.
    private var holderID: String { lease.browserID ?? "" }

    // MARK: - Start and stop

    /// The one explicit action that starts sharing. Nothing runs before it.
    func start(
        session: TerminalSession,
        account: AccountController,
        api: CloudAPI,
        socketBaseURL: URL,
        origin: String,
        title: String,
        publicReadSecret: String? = nil,
        mechanisms: Mechanisms
    ) {
        guard !isSharing, let deviceID = account.deviceID else { return }
        self.session = session
        self.mechanisms = mechanisms

        let publisher = StreamPublisher(
            api: api,
            identity: identity,
            deviceID: deviceID,
            socketBaseURL: socketBaseURL,
            origin: origin,
            publicReadSecret: publicReadSecret)
        publisher.delegate = self
        self.publisher = publisher
        isSharing = true

        publisher.start(title: title)
        // The opening snapshot is captured here, on the main actor, and handed over as a value. The
        // publisher does everything after this off it.
        if let snapshot = capture() {
            publisher.publish(snapshot)
        }
    }

    /// Stop sharing. Safe from a pane close, a shell exit, a sign-out and app teardown.
    func stop() {
        guard isSharing else { return }

        // **The revocation happens before the publisher is dropped.** The obvious order — stop, then
        // clear, then revoke — reads a `nil` publisher and silently sends nothing, which leaves a
        // browser holding control of a pane nobody is publishing. The lease has to be given back on
        // the socket that is still open, because after `stop()` there is no socket to give it back on.
        if let epoch = lease.epoch, let token = lease.lease {
            publisher?.revokeControl(epoch: epoch, lease: token, reason: .ended)
        }
        // The lease goes with the stream. A browser that kept control of a pane nobody is sharing
        // would be holding a capability to write to a terminal that has no publisher.
        lease.revoke(reason: "sharing stopped")
        hasPendingRequest = false

        publisher?.stop()
        publisher?.delegate = nil
        publisher = nil
        isSharing = false
        session = nil
    }

    /// Capture the pane's current state as a value.
    ///
    /// Bounded and consistent by construction: it reads the session's blocks once and returns, so
    /// there is no window in which the shell can move a grid underneath it.
    func capture() -> WireSnapshot? {
        guard let session, let publisher else { return nil }
        let epoch = publisher.epoch ?? "1"
        return exporter.snapshot(
            paneID: identity.uuid,
            blocks: session.blocks,
            size: session.size,
            alternateScreen: session.isAlternateScreen,
            editor: .hidden,
            epoch: epoch,
            seq: publisher.nextSeq(),
            pinnedBlockID: session.blocks.last?.id.rawValue)
    }

    /// Capture and publish. Called by the pane when its model changed, and by nothing else.
    func publishCapture() {
        guard let publisher, let snapshot = capture() else { return }
        publisher.publish(snapshot)
    }

    // MARK: - Control

    /// A person approved the browser that asked.
    func approveControl() {
        guard let publisher, let epoch = publisher.epoch else { return }
        let decision = lease.approve(generation: epoch, now: Date())
        hasPendingRequest = false
        guard case .granted(let token, let expires) = decision else { return }
        publisher.grantControl(epoch: epoch, lease: token, expiresAt: expires)
    }

    func denyControl() {
        guard let publisher, let epoch = publisher.epoch else { return }
        _ = lease.deny(reason: "denied")
        hasPendingRequest = false
        publisher.denyControl(epoch: epoch)
    }

    /// Give up the lease.
    ///
    /// `localInput` is the one that matters: every keystroke at the machine calls this *before* the
    /// keystroke is applied, so nobody ever has to fight a browser for their own prompt.
    func revokeControl(reason: WireRevokeReason) {
        guard let publisher, let epoch = lease.epoch, let token = lease.lease else { return }
        guard lease.revoke(reason: reason.rawValue) != nil else { return }
        publisher.revokeControl(epoch: epoch, lease: token, reason: reason)
    }

    // MARK: - Applying an approved input

    /// Apply one input frame, and answer it.
    ///
    /// The order is the whole design: the lease decides **first**, and only an accepted frame reaches
    /// the pane. An ack says the input was admitted to the editor or the write queue — never that a
    /// command ran, and never that it finished, because the host cannot know either.
    private func apply(_ input: WireInputFrame) {
        guard let publisher, let epoch = publisher.epoch else { return }
        let seq = Int(input.inputSeq) ?? 0

        switch lease.verdict(
            browserID: holderID,
            epoch: input.epoch,
            lease: input.controlLease,
            inputSeq: seq,
            now: Date()
        ) {
        case .reject(let reason):
            publisher.ackInput(
                epoch: epoch, lease: input.controlLease, inputSeq: input.inputSeq,
                status: .rejected, code: Self.code(for: reason))
            return
        case .duplicate:
            // Already applied. The ack is re-sent and the input is **not** applied again — a
            // re-sent Enter must not submit twice.
            publisher.ackInput(
                epoch: epoch, lease: input.controlLease, inputSeq: input.inputSeq, status: .applied)
            return
        case .accept:
            break
        }

        let applied = route(input.operation)
        publisher.ackInput(
            epoch: epoch, lease: input.controlLease, inputSeq: input.inputSeq,
            status: applied ? .applied : .rejected,
            code: applied ? nil : .invalidFrame)
    }

    /// Which path an operation takes.
    ///
    /// The split is by **operation**, not by mode: text, paste and undo/redo are edits, and a logical
    /// key is input the terminal translates. Sending a paste down the raw path would push a whole line
    /// into a program that is not reading one.
    ///
    /// Where an edit *lands* is the mechanism's decision rather than this one's, and deliberately:
    /// whether a prompt is showing is a fact about the view, and the surface already answers it for a
    /// local keystroke. Answering it twice would be two places for the answer to drift.
    private func route(_ operation: WireInputOperation) -> Bool {
        switch operation {
        case .text(let text), .paste(let text):
            // An empty paste is not an edit, and reporting it as one would ack an input that did
            // nothing.
            guard !text.isEmpty else { return false }
            return mechanisms.insertText(text)
        case .undo:
            return mechanisms.editHistory(false)
        case .redo:
            return mechanisms.editHistory(true)
        case .key(let key, let modifiers):
            return mechanisms.sendKey(key, modifiers)
        }
    }

    private static func code(for reason: String) -> WireErrorCode {
        switch reason {
        case "stale epoch": return .staleEpoch
        // An expired lease and a superseded one are the same answer to a browser: this lease is not
        // usable. The distinction matters to the host's logs, not to the frame.
        case "the lease expired": return .staleLease
        case "sequence gap": return .inputGap
        default: return .unauthorized
        }
    }
}

extension PaneSharing: StreamControlDelegate {
    func publisher(_ publisher: StreamPublisher, didReceiveControlRequestFor generation: String) {
        // Recorded and shown, not granted. Approving a browser because it asked is the same as having
        // no approval at all.
        //
        // The generation is the only identity the frame carries, and it is what the lease is keyed
        // on. See `holderID` for why there is nothing else to key it on.
        lease.request(browserID: generation)
        hasPendingRequest = true
    }

    func publisher(_ publisher: StreamPublisher, didReceive input: WireInputFrame) {
        apply(input)
    }
}
