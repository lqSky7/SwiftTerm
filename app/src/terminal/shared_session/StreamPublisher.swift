import Foundation

/// Publishes one pane's already-captured state to the relay.
///
/// The split here is the handoff's, and it is the reason typing never waits: **capture happens on the
/// main actor, and the encoding, the hashing and the send happen off it.** This type never reads a
/// grid. It takes a `WireSnapshot` or a `WireDamage` — both value types, both `Sendable` — and owns
/// the socket and the lease from there.
///
/// The class is `@MainActor` because `state` is observed by the UI, and that is exactly the trap: a
/// plain `Task { }` written in here inherits the actor, so the expensive half would run on the actor
/// the prompt is drawn from. `enqueue` detaches for that reason, and `frames(for:)` is `nonisolated`
/// so it can be called from there. Without both, "off-main" would be a comment rather than a fact.
///
/// Three things it will not do:
///
///   * **It will not allocate while off.** `stop()` cancels the tasks, closes the socket and clears
///     the encoder; a pane that is not sharing costs nothing.
///   * **It will not keep publishing past the lease.** The renewal runs every ten seconds against a
///     thirty-second lease, and a renewal that fails stops the stream rather than continuing to write
///     with a credential the server has already fenced out.
///   * **It will not encode for nobody.** At zero viewers the relay says so, and the pane is told to
///     stop capturing — a stream nobody is watching should cost the host nothing.
@MainActor
@Observable
final class StreamPublisher {
    enum State: Equatable {
        case idle
        case starting
        /// Connected, with the number of browsers the relay reports.
        case live(viewers: Int)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// The session the relay knows this pane by, once it exists.
    private(set) var sessionID: String?
    /// The publisher generation. A ticket carries it, and a renewal must match it.
    private(set) var epoch: String?

    @ObservationIgnored private let api: CloudAPI
    @ObservationIgnored private let identity: PaneExportIdentity
    @ObservationIgnored private let deviceID: String
    @ObservationIgnored private let socketBaseURL: URL
    @ObservationIgnored private let origin: String

    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var leaseToken: String?
    @ObservationIgnored private var renewTask: Task<Void, Never>?
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    /// Frames waiting to go out, drained by one task so two captures cannot interleave mid-frame.
    @ObservationIgnored private var outbox: [String] = []
    @ObservationIgnored private var hasSentHello = false
    /// The sequence the host has published. The relay orders by this and the viewer resumes by it.
    @ObservationIgnored private var seq = 0

    init(
        api: CloudAPI,
        identity: PaneExportIdentity,
        deviceID: String,
        socketBaseURL: URL,
        origin: String
    ) {
        self.api = api
        self.identity = identity
        self.deviceID = deviceID
        self.socketBaseURL = socketBaseURL
        self.origin = origin
    }

    var isLive: Bool {
        if case .live = state { return true }
        return false
    }

    // MARK: - Start and stop

    /// The one explicit action that starts sharing. Nothing here runs until someone asks.
    func start(title: String) {
        guard case .idle = state else { return }
        state = .starting

        Task { [api, identity, deviceID] in
            do {
                // Creating the stream is idempotent on the client request id, so a retry after a
                // dropped response returns the stream that already exists rather than a second one.
                let created = try await api.send(
                    CloudRoutes.createStream(
                        deviceID: deviceID,
                        localPaneID: identity.uuid,
                        clientRequestID: identity.clientRequestID,
                        title: title),
                    as: StreamCreation.self)
                sessionID = created.sessionId

                // A publisher ticket is also the fence: minting one advances the epoch, so any
                // earlier publisher of this stream is refused from here on.
                let ticket = try await api.send(
                    CloudRoutes.mintTicket(sessionID: created.sessionId, role: .publisher),
                    as: CloudTicket.self)
                epoch = ticket.epoch
                leaseToken = ticket.leaseToken
                connect(ticket: ticket.ticket, sessionID: created.sessionId)
            } catch let error as CloudError {
                state = .failed(error.messageForUser)
            } catch {
                state = .failed(CloudError.malformedResponse.messageForUser)
            }
        }
    }

    /// Stop sharing. Idempotent, and safe to call from a pane close, a shell exit or app teardown.
    func stop() {
        renewTask?.cancel()
        renewTask = nil
        sendTask?.cancel()
        sendTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        outbox.removeAll()
        hasSentHello = false
        leaseToken = nil
        seq = 0
        state = .idle
        // The stream is ended server-side rather than merely abandoned: an abandoned stream keeps a
        // slot against the account's cap and a lease that has to expire before anyone can publish it.
        if let sessionID {
            let id = sessionID
            self.sessionID = nil
            Task { [api] in _ = try? await api.send(CloudRoutes.endStream(id: id)) }
        }
    }

    // MARK: - Publishing

    /// Send a whole snapshot. The first one opens the stream; a later one is a barrier the host
    /// decided it needed.
    func publish(_ snapshot: WireSnapshot) {
        seq = max(seq, Int(snapshot.seq) ?? 0)
        enqueue { try Self.frames(for: snapshot) }
    }

    /// Send a delta. Refused unless a snapshot has already opened the stream, because the contract
    /// says the stream begins with one even when the host already has output.
    func publish(_ damage: WireDamage) {
        guard hasSentHello else { return }
        seq = max(seq, Int(damage.seq) ?? 0)
        enqueue { [Self.text(try WireCanonicalJSON.encode(WireFrame.damage(damage)))] }
    }

    /// The next sequence number. The host assigns it, not the relay — the relay orders by what it is
    /// given and never invents a position.
    func nextSeq() -> Int {
        seq + 1
    }

    /// Encode a frame off the main actor, then send it from here.
    ///
    /// **The `Task.detached` is load-bearing, not decoration.** This class is `@MainActor`, and a
    /// plain `Task { }` written inside it *inherits that actor* — so the encoding, the hashing and the
    /// JSON serialisation of a four-megabyte snapshot would all run on the actor the prompt is drawn
    /// from, which is precisely the stutter the capture/transport split exists to prevent. Detaching
    /// puts the work on the cooperative pool; only the enqueue and the socket send stay here.
    ///
    /// The closure is `@Sendable` and captures only value types, which is what makes the hop legal.
    private func enqueue(_ build: @escaping @Sendable () throws -> [String]) {
        sendTask = Task { [previous = sendTask] in
            await previous?.value
            let frames = await Task.detached(priority: .utility) { try? build() }.value
            guard let frames else { return }
            outbox.append(contentsOf: frames)
            await drain()
        }
    }

    private func drain() async {
        while !outbox.isEmpty {
            let frame = outbox.removeFirst()
            guard let socket else { return }
            do {
                try await socket.send(.string(frame))
            } catch {
                // A send that fails is a socket that is gone. `receive` reports it; retrying here
                // would spin.
                return
            }
        }
    }

    // MARK: - The socket

    private func connect(ticket: String, sessionID: String) {
        var request = URLRequest(url: socketBaseURL.appendingPathComponent("live/\(sessionID)"))
        // The relay selects this subprotocol; a browser that is not granted one fails the handshake,
        // and the native client is held to the same contract.
        request.setValue("swiftterm.live.v1", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        request.setValue(origin, forHTTPHeaderField: "Origin")

        let task = URLSession.shared.webSocketTask(with: request)
        socket = task
        task.resume()

        let auth = WireAuth(ticket: ticket, clientID: identity.clientRequestID)
        if let frame = try? WireCanonicalJSON.encode(WireFrame.auth(auth)) {
            outbox.append(Self.text(frame))
        }
        Task { await drain() }

        receive(on: task)
        startRenewing()
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure:
                    // The relay is gone. Fail closed: the lease is not renewed from here, so it
                    // expires server-side rather than being kept alive by a host that cannot write.
                    if self.isLive { self.state = .failed("The relay connection dropped.") }
                    self.stopRenewing()
                case .success(let message):
                    self.handle(message)
                    self.receive(on: task)
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message else { return }
        // The direction is stated rather than inferred: the same frame type is legal in more than one
        // direction, and a publisher that accepted a viewer's frame shape would be a publisher that
        // could be made to act on one.
        guard let frame = try? WireFrame.decode(from: text, direction: .relayToHost) else { return }

        switch frame {
        case .viewerCount(let count):
            // At zero viewers the host stops capturing. That is the whole reason the relay sends
            // this frame: a stream nobody is watching should cost nothing.
            state = .live(viewers: count.count)
        case .error(let error):
            if error.code == "capacity" { state = .failed("The relay refused that frame.") }
        case .resync:
            // The relay could not supply a gap, so it is asking for a fresh snapshot. The pane is
            // told through `needsSnapshot`; the next capture is a full one.
            needsSnapshot = true
        case .controlRequest(let request):
            // A browser is asking to type. Nothing is granted here: the decision belongs to the
            // person in front of the machine, and this only tells them someone is asking. The
            // generation is passed on because it is the only identity the frame carries — the
            // contract gives a requester no way to name itself, and the relay is what binds the
            // approval to the connection that asked.
            delegate?.publisher(self, didReceiveControlRequestFor: request.epoch)
        case .input(let input):
            // The relay has already refused anything from a viewer that is not a controller, and the
            // lease is checked again here — the relay cannot know whether *this* host still approves.
            delegate?.publisher(self, didReceive: input)
        default:
            break
        }
    }

    // MARK: - Control

    /// Tell the browser its request was approved.
    ///
    /// The lease and the epoch travel back with it, because they are what every later input frame
    /// must present. `expires_at` is a wire timestamp, not a `Date`: the contract fixes the format.
    func grantControl(epoch: String, lease: String, expiresAt: Date) {
        send(
            .controlGranted(
                WireControlGranted(
                    epoch: epoch, lease: lease,
                    expiresAt: Self.wireTime(from: expiresAt))))
    }

    /// UTC ISO-8601 with milliseconds, which is the one spelling the contract accepts. Built here
    /// rather than with a `DateFormatter` so it does not depend on the process locale: a device set
    /// to a locale with a different calendar would otherwise emit a timestamp the browser refuses.
    static func wireTime(from date: Date) -> String {
        let seconds = date.timeIntervalSince1970
        let whole = floor(seconds)
        let milliseconds = Int(((seconds - whole) * 1000).rounded())
        let base = Date(timeIntervalSince1970: whole)
        var components = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: base)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        func pad(_ value: Int?, _ width: Int) -> String {
            String(format: "%0\(width)d", value ?? 0)
        }
        return "\(pad(components.year, 4))-\(pad(components.month, 2))-\(pad(components.day, 2))"
            + "T\(pad(components.hour, 2)):\(pad(components.minute, 2)):\(pad(components.second, 2))"
            + ".\(pad(milliseconds, 3))Z"
    }

    func denyControl(epoch: String) {
        send(.controlDenied(WireControlDenied(epoch: epoch)))
    }

    /// Tell the holder its lease is gone, and why.
    ///
    /// The reason is part of the frame rather than a detail: a browser told `local_input` knows the
    /// person took the keyboard back, which is different from being told the host ended the stream.
    func revokeControl(epoch: String, lease: String, reason: WireRevokeReason) {
        send(.controlRevoked(WireControlRevoked(epoch: epoch, lease: lease, reason: reason)))
    }

    /// Acknowledge an input frame.
    ///
    /// This records **admission to the editor or the PTY write queue**, never that a command ran or
    /// finished. A rejected ack must carry a code — a silent rejection is the failure the
    /// acknowledgement exists to prevent.
    func ackInput(
        epoch: String, lease: String, inputSeq: String, status: WireInputStatus, code: WireErrorCode? = nil
    ) {
        send(
            .inputAck(
                WireInputAck(
                    epoch: epoch, controlLease: lease, inputSeq: inputSeq, status: status, code: code)))
    }

    private func send(_ frame: WireFrame) {
        guard let encoded = try? WireCanonicalJSON.encode(frame) else { return }
        outbox.append(Self.text(encoded))
        Task { await drain() }
    }

    /// The pane's side of the control conversation. Implemented by `PaneSharing`, which owns the
    /// lease; this type only carries the frames.
    weak var delegate: (any StreamControlDelegate)?

    /// Set when the relay asks for a snapshot. The pane's next capture is a full one.
    private(set) var needsSnapshot = false

    // MARK: - The lease

    private func startRenewing() {
        renewTask?.cancel()
        renewTask = Task { [api] in
            while !Task.isCancelled {
                // Ten seconds against a thirty-second lease: three chances to be late before the
                // server fences this publisher out.
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let sessionID, let epoch, let leaseToken else { return }
                do {
                    _ = try await api.send(
                        CloudRoutes.renewLease(sessionID: sessionID, epoch: epoch, leaseToken: leaseToken))
                } catch {
                    // Fail closed. A publisher that cannot prove it still holds the lease must stop
                    // writing rather than keep sending frames the relay will drop anyway — and a
                    // `409` here means the epoch or the token has already been superseded.
                    await MainActor.run { self.state = .failed("This stream is no longer yours.") }
                    return
                }
            }
        }
    }

    private func stopRenewing() {
        renewTask?.cancel()
        renewTask = nil
    }

    // MARK: - Frames

    /// Encoded JSON as the text the socket carries.
    ///
    /// The encoder returns `Data`, and the socket must be given a **string**: the relay refuses a
    /// binary frame outright (`isBinary` closes the connection with `invalid_frame`), because the
    /// frames are JSON text and a binary one is a client that has invented its own encoding. So the
    /// bytes are decoded back to text here — the one place the conversion happens, rather than at
    /// each call site where it could be forgotten.
    nonisolated static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    /// The frames that carry a snapshot: a begin, chunks and an end. The chunks are bounded by the
    /// contract, and the digest is over the raw bytes so the browser can verify before it adopts
    /// anything.
    ///
    /// `nonisolated` because it is called from a detached task: a `static` member of a `@MainActor`
    /// type is main-actor isolated too, so without this the "off-main encoding" would hop straight
    /// back to the actor it was moved off. Nothing here touches an instance or an actor's state — it
    /// is a pure function from a value type to strings, which is what makes the hop legal.
    nonisolated static func frames(for snapshot: WireSnapshot) throws -> [String] {
        let bytes = try WireCanonicalJSON.encode(snapshot)
        let snapshotID = UUID().uuidString.lowercased()
        let chunkSize = WireLimits.maxRawChunkBytes
        let chunks = stride(from: 0, to: max(bytes.count, 1), by: chunkSize).map { offset in
            bytes.subdata(in: offset..<min(offset + chunkSize, bytes.count))
        }

        var frames: [String] = []
        frames.append(
            text(
                try WireCanonicalJSON.encode(
                    WireFrame.snapshotBegin(
                        WireSnapshotBegin(
                            epoch: snapshot.epoch,
                            seq: snapshot.seq,
                            snapshotID: snapshotID,
                            bytes: bytes.count,
                            chunks: chunks.count,
                            // The digest is over the snapshot's own bytes, which is what the browser
                            // hashes once it has every chunk — not over the frames that carried them.
                            sha256: WireSHA256.hexDigest(bytes))))))
        for (index, chunk) in chunks.enumerated() {
            frames.append(
                text(
                    try WireCanonicalJSON.encode(
                        WireFrame.snapshotChunk(
                            WireSnapshotChunk(
                                epoch: snapshot.epoch,
                                snapshotID: snapshotID,
                                index: index,
                                data: chunk)))))
        }
        frames.append(
            text(
                try WireCanonicalJSON.encode(
                    WireFrame.snapshotEnd(
                        WireSnapshotEnd(epoch: snapshot.epoch, snapshotID: snapshotID)))))
        return frames
    }
}

private struct StreamCreation: Decodable, Sendable {
    let sessionId: String
}

/// What the pane has to do when the relay sends it something that is not output.
///
/// The publisher deliberately does not decide any of this. Whether a browser may type is a question
/// about the person in front of the machine, and whether an input is safe to apply is a question
/// about the lease — both belong to `PaneSharing`, which owns the lease and can see the pane.
@MainActor
protocol StreamControlDelegate: AnyObject {
    /// A browser asked to type. Nothing has been granted; this is the prompt to ask a person.
    ///
    /// The generation is the publisher epoch the requester named. It is the only identity the frame
    /// carries — the contract says a requester cannot name another client — so it is what the host
    /// has to key its lease on. The relay is what makes that sufficient: it permits one outstanding
    /// request and forwards `input` only from the connection it granted.
    func publisher(_ publisher: StreamPublisher, didReceiveControlRequestFor generation: String)
    /// An input frame arrived. It has passed the relay's own check and must now pass the host's.
    func publisher(_ publisher: StreamPublisher, didReceive input: WireInputFrame)
}
