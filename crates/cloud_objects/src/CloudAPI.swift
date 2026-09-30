import Foundation

/// A request, as data, before anything performs it.
///
/// Split from the client on purpose: every route is then a pure function from arguments to a method,
/// a path and a body, which is the part worth testing and the part that silently rots when a path
/// changes on the server. The client below only knows how to *send* one.
struct CloudRequest: Equatable, Sendable {
    let method: String
    let path: String
    let body: Data?
    /// Whether the request is a cookie-authenticated write, which the backend refuses without the
    /// CSRF header **and** an allowed `Origin`.
    let requiresCSRF: Bool

    init(method: String, path: String, body: Data? = nil, requiresCSRF: Bool) {
        self.method = method
        self.path = path
        self.body = body
        self.requiresCSRF = requiresCSRF
    }
}

/// The routes, as a table.
///
/// Kept in one place so the shape of the API is readable without following `URLSession` calls, and so
/// a path is spelled once. The bodies are encoded with sorted keys, which is not required by the
/// server — it validates fields, not bytes — but makes the requests comparable in a test.
enum CloudRoutes {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static func body(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Exchange a verified OIDC access token for a web session.
    ///
    /// This is the only route that carries a credential in its body rather than in a cookie, and the
    /// only one that does not require CSRF: it is what creates the session the CSRF token belongs to.
    static func authenticate(accessToken: String) -> CloudRequest {
        CloudRequest(
            method: "POST",
            path: "/auth/session",
            body: body(["access_token": accessToken]),
            requiresCSRF: false,
        )
    }

    static func logout() -> CloudRequest {
        CloudRequest(method: "POST", path: "/auth/logout", requiresCSRF: true)
    }

    static func me() -> CloudRequest {
        CloudRequest(method: "GET", path: "/me", requiresCSRF: false)
    }

    static func devices() -> CloudRequest {
        CloudRequest(method: "GET", path: "/devices", requiresCSRF: false)
    }

    /// Register this installation.
    ///
    /// The client request id makes the call idempotent: the same id with the same payload returns the
    /// device that already exists, and with a different payload is a conflict rather than a second
    /// device. The token travels in the clear exactly once — the server keeps only its digest.
    static func registerDevice(
        label: String,
        clientRequestID: String,
        deviceToken: String,
    ) -> CloudRequest {
        CloudRequest(
            method: "POST",
            path: "/devices",
            body: body([
                "label": label,
                "client_request_id": clientRequestID,
                "device_token": deviceToken,
            ]),
            requiresCSRF: true,
        )
    }

    static func revokeDevice(id: String) -> CloudRequest {
        CloudRequest(method: "DELETE", path: "/devices/\(id)", requiresCSRF: true)
    }

    /// Create a paused stream for one pane.
    ///
    /// `local_pane_id` is a **stable UUID allocated for export**, not the numeric `PaneID` the window
    /// uses. A local identity that meant something only inside one process is not an identity another
    /// machine can be told about.
    static func createStream(
        deviceID: String,
        localPaneID: String,
        clientRequestID: String,
        title: String,
    ) -> CloudRequest {
        CloudRequest(
            method: "POST",
            path: "/live",
            body: body([
                "device_id": deviceID,
                "local_pane_id": localPaneID,
                "client_request_id": clientRequestID,
                "title": title,
            ]),
            requiresCSRF: true,
        )
    }

    static func listStreams(limit: Int, before: String?) -> CloudRequest {
        var query = "?limit=\(limit)"
        if let before, let escaped = before.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics
        ) {
            query += "&before=\(escaped)"
        }
        return CloudRequest(method: "GET", path: "/live\(query)", requiresCSRF: false)
    }

    /// Mint a one-use socket ticket.
    ///
    /// The ticket is the only credential the socket presents, and it is deliberately not a session
    /// cookie: an upgrade carries no headers a browser would let us set. For a publisher the server
    /// also advances the publisher epoch here, which is why this call is the fence as well as a
    /// permission check.
    static func mintTicket(sessionID: String, role: CloudTicketRole) -> CloudRequest {
        CloudRequest(
            method: "POST",
            path: "/live/\(sessionID)/tickets",
            body: body(["role": role.rawValue]),
            requiresCSRF: true,
        )
    }

    static func endStream(id: String) -> CloudRequest {
        CloudRequest(method: "POST", path: "/live/\(id)/end", requiresCSRF: true)
    }
}

enum CloudTicketRole: String, Sendable {
    case publisher
    case viewer
}

// MARK: - Responses

struct CloudAccountSummary: Decodable, Equatable, Sendable {
    let id: String
    let displayName: String
}

struct CloudDeviceSummary: Decodable, Equatable, Sendable {
    let id: String
    let label: String
    let clientRequestId: String
    let revokedAt: String?
}

struct CloudStreamSummary: Decodable, Equatable, Sendable {
    let id: String
    let deviceId: String
    let localPaneId: String
    let title: String
    let status: String
    let publisherEpoch: String
    let createdAt: String
}

struct CloudTicket: Decodable, Equatable, Sendable {
    let ticket: String
    let role: String
    let epoch: String
}

/// The HTTP client.
///
/// An `actor` because it is shared by several independent tasks — the account model, a stream's
/// encoder, a viewer — and because isolation is what makes that sharing safe without a lock. It is
/// deliberately thin: build a request, send it, classify the answer. Every decision about *what* to
/// ask for lives in `CloudRoutes`, and every decision about what a failure means lives in
/// `CloudError`.
actor CloudAPI {
    private let baseURL: URL
    private let origin: String
    private let session: URLSession
    private let csrfCookieName: String
    private let decoder: JSONDecoder

    /// - Parameters:
    ///   - origin: sent on every write. The backend refuses a cookie-authenticated write whose
    ///     `Origin` is missing or is not on its allowlist — a rule written for browsers, where a
    ///     cookie is ambient and a forged request is the threat. A native client is not subject to
    ///     that threat, but it does have to satisfy the rule, so it declares the website's origin.
    ///     This is a wart in the contract rather than a property of it, and it is recorded in
    ///     `docs/backend/todo.md` rather than hidden here.
    init(
        baseURL: URL,
        origin: String,
        csrfCookieName: String = "swiftterm_csrf",
        session: URLSession? = nil,
    ) {
        self.baseURL = baseURL
        self.origin = origin
        self.csrfCookieName = csrfCookieName
        self.decoder = JSONDecoder()
        self.decoder.keyDecodingStrategy = .convertFromSnakeCase

        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            // The session cookie must survive a relaunch, but it must not be written to a shared
            // store: it belongs to this app's own jar, which is what `httpCookieStorage` on an
            // ephemeral configuration gives.
            configuration.httpCookieStorage = HTTPCookieStorage()
            configuration.httpCookieAcceptPolicy = .always
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = 20
            self.session = URLSession(configuration: configuration)
        }
    }

    /// Send one request and return its body, or throw a `CloudError`.
    ///
    /// A 2xx with an empty body returns empty data rather than throwing: `204` is a real answer, and
    /// treating it as a malformed response would make every successful end/revoke look like a fault.
    func send(_ request: CloudRequest) async throws -> Data {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent(request.path))
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.setValue("application/json", forHTTPHeaderField: "accept")
        if request.body != nil {
            urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        }

        if request.requiresCSRF {
            urlRequest.setValue(origin, forHTTPHeaderField: "origin")
            if let token = csrfToken() {
                urlRequest.setValue(token, forHTTPHeaderField: "x-swiftterm-csrf")
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw CloudError.from(transport: error)
        }

        guard let http = response as? HTTPURLResponse else { throw CloudError.malformedResponse }
        if (200..<300).contains(http.statusCode) { return data }
        throw CloudError.from(status: http.statusCode, body: data)
    }

    /// Send and decode, for the routes that answer with a body.
    func send<T: Decodable>(_ request: CloudRequest, as type: T.Type) async throws -> T {
        let data = try await send(request)
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw CloudError.malformedResponse
        }
    }

    /// The readable CSRF cookie, which the backend sets alongside the HttpOnly session cookie.
    ///
    /// It is not `httpOnly` precisely so a client can read it and echo it in a header; the session
    /// cookie is, and this client never needs to see it.
    private func csrfToken() -> String? {
        session.configuration.httpCookieStorage?
            .cookies?
            .first { $0.name == csrfCookieName }?
            .value
    }

    /// Forget every cookie. Called on sign-out and on a session the server says has ended, because a
    /// jar that keeps a dead session is a jar that will present it again.
    func clearCookies() {
        session.configuration.httpCookieStorage?.cookies?.forEach {
            session.configuration.httpCookieStorage?.deleteCookie($0)
        }
    }
}
