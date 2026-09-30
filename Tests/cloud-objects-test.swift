import Foundation

/// Tests the cloud client's pure half: the route table, the failure vocabulary, the device
/// credential, and the headers a write must carry.
///
/// It never touches the network. A stub `URLProtocol` stands in for the server, which is what lets
/// the most breakable part — that a write sends both an `Origin` and the CSRF header, and that a
/// read sends neither — be asserted rather than hoped for.
@main
enum CloudObjectsTest {
    static func main() async {
        let harness = Harness("cloud-objects-test")

        routes(harness)
        failures(harness)
        credentials(harness)
        identity(harness)
        await headers(harness)
        await refusals(harness)

        harness.finish()
    }

    // MARK: - The route table

    private static func routes(_ harness: Harness) {
        let authenticate = CloudRoutes.authenticate(accessToken: "tok")
        harness.equal(authenticate.method, "POST", "auth is a POST")
        harness.equal(authenticate.path, "/auth/session", "auth path")
        harness.expect(
            !authenticate.requiresCSRF,
            "auth creates the session the CSRF token belongs to, so it cannot require one")

        harness.equal(CloudRoutes.me().path, "/me", "me path")
        harness.equal(CloudRoutes.devices().path, "/devices", "devices path")

        let registration = CloudRoutes.registerDevice(
            label: "Studio Mac", clientRequestID: "rid", deviceToken: "dG9rZW4=")
        harness.equal(registration.method, "POST", "registration is a POST")
        harness.equal(registration.path, "/devices", "registration path")
        harness.expect(registration.requiresCSRF, "a write requires CSRF")
        let registrationBody = decode(registration.body)
        harness.equal(registrationBody["label"] as? String, "Studio Mac", "label is sent")
        harness.equal(
            registrationBody["client_request_id"] as? String, "rid",
            "the request id is what makes a retry idempotent")

        harness.equal(
            CloudRoutes.revokeDevice(id: "abc").path, "/devices/abc", "revoke is by id in the path")

        let create = CloudRoutes.createStream(
            deviceID: "dev", localPaneID: "pane", clientRequestID: "req", title: "shell")
        harness.equal(create.path, "/live", "create path")
        let createBody = decode(create.body)
        harness.equal(createBody["device_id"] as? String, "dev", "device is sent")
        harness.equal(
            createBody["local_pane_id"] as? String, "pane",
            "the stable export UUID, not a numeric PaneID")

        harness.equal(
            CloudRoutes.mintTicket(sessionID: "s", role: .publisher).path, "/live/s/tickets",
            "ticket path")
        harness.equal(
            decode(CloudRoutes.mintTicket(sessionID: "s", role: .viewer).body)["role"] as? String,
            "viewer", "the role is sent")
        harness.equal(CloudRoutes.endStream(id: "s").path, "/live/s/end", "end path")

        // A cursor is one opaque value, so it is escaped rather than interpolated raw.
        let paged = CloudRoutes.listStreams(limit: 25, before: "2026-01-01T00:00:00.000Z|abc")
        harness.expect(
            paged.path.hasPrefix("/live?limit=25&before=") && !paged.path.contains("|"),
            "a cursor is percent-escaped")
        harness.equal(
            CloudRoutes.listStreams(limit: 50, before: nil).path, "/live?limit=50",
            "no cursor means no parameter")
    }

    // MARK: - Failures

    private static func failures(_ harness: Harness) {
        let refused = CloudError.from(status: 409, body: Data(#"{"error":"stale_lease"}"#.utf8))
        harness.equal(refused.code, "stale_lease", "the allowlisted code is read from the body")
        harness.expect(
            refused.messageForUser.contains("publisher"),
            "a known code gets a sentence written for it")

        // A proxy's HTML, an empty body, or a different key are all "not a refusal this client
        // understands", and inventing a code for them would be worse than saying so.
        harness.equal(
            CloudError.from(status: 502, body: Data("<html>".utf8)).code, "malformed_response",
            "an HTML body is not a refusal")
        harness.equal(
            CloudError.from(status: 500, body: Data()).code, "malformed_response",
            "an empty body is not a refusal")

        harness.equal(
            CloudError.from(status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8)).code,
            "unauthorized", "a session refusal keeps its code")
        harness.expect(
            CloudError.from(status: 401, body: Data(#"{"error":"session_ended"}"#.utf8))
                .endsTheSession,
            "an ended session means signing in again")
        harness.expect(
            !CloudError.from(status: 429, body: Data(#"{"error":"rate_limited"}"#.utf8))
                .endsTheSession,
            "a rate limit does not end the session")
        harness.expect(
            !CloudError.offline.endsTheSession,
            "being offline is not a session that ended")

        // Cancellation is not a failure. Folding it into `offline` would report a person's own
        // Cancel press as a network problem.
        harness.equal(CloudError.from(transport: CancellationError()).code, "cancelled", "cancel is cancel")
        harness.equal(
            CloudError.from(transport: URLError(.notConnectedToInternet)).code, "offline",
            "a transport failure is offline")

        harness.equal(CloudError.offline.code, "offline", "offline code")
        harness.equal(
            CloudError.malformedResponse.code, "malformed_response", "malformed code")
    }

    // MARK: - The device credential

    private static func credentials(_ harness: Harness) {
        guard let credential = DeviceCredential.generate() else {
            harness.expect(false, "the system random source is available")
            return
        }
        harness.equal(credential.token.count, 32, "a credential is 256 bits")
        // Canonical standard base64 with padding: 32 bytes is 44 characters ending in `=`. The
        // registration route re-encodes and compares, so a second spelling would be refused.
        harness.equal(credential.base64.count, 44, "canonical base64 length")
        harness.expect(credential.base64.hasSuffix("="), "canonical base64 is padded")

        let other = DeviceCredential.generate()
        harness.expect(
            other?.token != credential.token,
            "two credentials differ, which is what makes it a credential")
    }

    // MARK: - The device identity

    private static func identity(_ harness: Harness) {
        let store = MemorySecretStore()
        let identity = DeviceIdentity(store: store)

        do {
            let first = try identity.credential()
            let second = try identity.credential()
            harness.equal(second, first, "the credential is created once and then returned")
            harness.equal(store.writes, 1, "and written once")

            harness.equal(try identity.registeredDeviceID(), nil, "nothing is registered at first")
            try identity.remember(deviceID: "device-1")
            harness.equal(
                try identity.registeredDeviceID(), "device-1", "the server's id is remembered")

            // Revoking forgets the registration but keeps the credential: it is this installation's
            // secret, and churning it on every revoke would be a new Keychain item for no reason.
            try identity.forgetRegistration()
            harness.equal(try identity.registeredDeviceID(), nil, "revoking forgets the registration")
            harness.equal(
                try identity.credential(), first, "and keeps the credential")

            try identity.destroyCredential()
            harness.equal(try identity.registeredDeviceID(), nil, "destroy clears the registration")
        } catch {
            harness.expect(false, "the in-memory store never throws: \(error)")
        }

        // A stored value of the wrong length cannot be repaired by guessing, so it is replaced —
        // and only before anything has been registered with it.
        let damaged = MemorySecretStore()
        damaged.seed(Data(repeating: 1, count: 7), account: DeviceIdentity.tokenAccount)
        let repaired = DeviceIdentity(store: damaged)
        do {
            harness.equal(
                try repaired.credential().token.count, 32,
                "a credential of the wrong length is replaced rather than used")
        } catch {
            harness.expect(false, "replacing a damaged credential does not throw: \(error)")
        }
    }

    // MARK: - Headers

    private static func headers(_ harness: Harness) async {
        StubProtocol.reset()
        let api = CloudAPI(
            baseURL: URL(string: "https://api.example.com")!,
            origin: "https://swiftterm.catinice.workers.dev",
            session: stubbedSession(),
        )

        // A write: both halves of the CSRF rule, which is what the backend demands.
        _ = try? await api.send(CloudRoutes.mintTicket(sessionID: "s", role: .viewer))
        let write = StubProtocol.last
        harness.equal(write?.method, "POST", "the method is sent")
        harness.equal(
            write?.origin, "https://swiftterm.catinice.workers.dev",
            "a write declares an allowed Origin, which the backend requires")
        harness.equal(write?.path, "/live/s/tickets", "the path is joined onto the base")

        // A read carries neither, because neither is meaningful without a cookie-authenticated write.
        _ = try? await api.send(CloudRoutes.me())
        let read = StubProtocol.last
        harness.equal(read?.method, "GET", "a read is a GET")
        harness.equal(read?.origin, nil, "a read sends no Origin")
        harness.equal(read?.body, nil, "a read has no body")
    }

    // MARK: - Refusals over the wire

    private static func refusals(_ harness: Harness) async {
        StubProtocol.reset()
        let api = CloudAPI(
            baseURL: URL(string: "https://api.example.com")!,
            origin: "https://swiftterm.catinice.workers.dev",
            session: stubbedSession(),
        )

        StubProtocol.respond(status: 401, body: Data(#"{"error":"session_ended"}"#.utf8))
        do {
            _ = try await api.send(CloudRoutes.me())
            harness.expect(false, "a 401 throws")
        } catch let error as CloudError {
            harness.equal(error.code, "session_ended", "the refusal code survives the round trip")
        } catch {
            harness.expect(false, "a refusal is a CloudError")
        }

        // `204` is a real answer, not a malformed one. Treating it as an error would make every
        // successful end and revoke look like a fault.
        StubProtocol.respond(status: 204, body: Data())
        do {
            let data = try await api.send(CloudRoutes.endStream(id: "s"))
            harness.equal(data.count, 0, "a 204 succeeds with an empty body")
        } catch {
            harness.expect(false, "a 204 does not throw: \(error)")
        }

        StubProtocol.respond(status: 200, body: Data("not json".utf8))
        do {
            _ = try await api.send(CloudRoutes.me(), as: CloudAccountSummary.self)
            harness.expect(false, "a body that is not the shape throws")
        } catch let error as CloudError {
            harness.equal(
                error.code, "malformed_response",
                "a body this client cannot decode is refused rather than guessed at")
        } catch {
            harness.expect(false, "a decode failure is a CloudError")
        }
    }

    // MARK: - Helpers

    private static func decode(_ data: Data?) -> [String: Any] {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func stubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// A Keychain without a Keychain, so the account model's rules can be exercised in a harness.
private final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private(set) var writes = 0

    func seed(_ data: Data, account: String) {
        lock.lock()
        defer { lock.unlock() }
        values[account] = data
    }

    func read(account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[account]
    }

    func write(_ secret: Data, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[account] = secret
        writes += 1
    }

    func delete(account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: account)
    }
}

/// Stands in for the server so the headers a request carries can be asserted without a network.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Recorded {
        let method: String
        let path: String
        let origin: String?
        let body: Data?
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var _last: Recorded?
    private nonisolated(unsafe) static var _status = 200
    private nonisolated(unsafe) static var _body = Data()

    static var last: Recorded? {
        lock.lock()
        defer { lock.unlock() }
        return _last
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        _last = nil
        _status = 200
        _body = Data()
    }

    static func respond(status: Int, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        _status = status
        _body = body
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        // `URLProtocol` hands a body as a stream when the request came from `httpBody`, so the bytes
        // are read here rather than assumed absent.
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let size = 4096
            var buffer = [UInt8](repeating: 0, count: size)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            body = data
        }
        Self._last = Recorded(
            method: request.httpMethod ?? "",
            path: request.url?.path ?? "",
            origin: request.value(forHTTPHeaderField: "origin"),
            body: body,
        )
        let status = Self._status
        let payload = Self._body
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !payload.isEmpty {
            client?.urlProtocol(self, didLoad: payload)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
