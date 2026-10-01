import Foundation

/// Where an access token comes from.
///
/// The Supabase project has **no OAuth provider configured**, so there is no authorization endpoint
/// to send a browser to and no redirect to come back from — the same divergence the website records
/// in `website/src/auth/client.ts`. What works, and what the website does, is a password grant
/// against Supabase Auth followed by an exchange at `POST /auth/session`, where the backend verifies
/// the token's signature against the issuer's JWKS.
///
/// That is deliberately the same exchange endpoint a redirect callback would use, so configuring a
/// provider later changes this file and nothing else.
actor SupabaseAuth {
    private let url: URL
    private let anonKey: String
    private let session: URLSession

    init(url: URL, anonKey: String, session: URLSession = .shared) {
        self.url = url
        self.anonKey = anonKey
        self.session = session
    }

    /// What a successful grant returns. The access token is short-lived — an hour — which is why the
    /// refresh token is kept: a session that could not be renewed would silently expire mid-stream.
    struct Granted: Decodable, Sendable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int?

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    func signIn(email: String, password: String) async throws -> Granted {
        try await grant(["grant_type": "password", "email": email, "password": password])
    }

    func anonymousAvailable() async -> Bool {
        var request = URLRequest(url: url.appendingPathComponent("auth/v1/settings"))
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        guard let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            let settings = try? JSONDecoder().decode(Settings.self, from: data) else { return false }
        return settings.external.anonymousUsers == true
    }

    private struct Settings: Decodable {
        let external: External
        struct External: Decodable {
            let anonymousUsers: Bool?
            enum CodingKeys: String, CodingKey { case anonymousUsers = "anonymous_users" }
        }
    }

    func signInAnonymously() async throws -> Granted {
        var request = URLRequest(url: url.appendingPathComponent("auth/v1/signup"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudError.refused(status: http.statusCode, code: "credentials_rejected")
        }
        return try JSONDecoder().decode(Granted.self, from: data)
    }

    func refresh(refreshToken: String) async throws -> Granted {
        try await grant(["grant_type": "refresh_token", "refresh_token": refreshToken])
    }

    private func grant(_ body: [String: String]) async throws -> Granted {
        var request = URLRequest(url: url.appendingPathComponent("auth/v1/token"))
        // The grant type is a query parameter, not a body field, and it is the whole difference
        // between the two calls above.
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "grant_type", value: body["grant_type"])]
        if let composed = components?.url { request.url = composed }

        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: body.filter { $0.key != "grant_type" })

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CloudError.from(transport: error)
        }
        guard let http = response as? HTTPURLResponse else { throw CloudError.malformedResponse }

        if !(200..<300).contains(http.statusCode) {
            // Deliberately one answer for every rejection. Telling "no such account" apart from
            // "wrong password" is how an account-enumeration oracle gets built, and the website
            // makes the same choice for the same reason.
            throw CloudError.refused(status: http.statusCode, code: "credentials_rejected")
        }
        do {
            return try JSONDecoder().decode(Granted.self, from: data)
        } catch {
            throw CloudError.malformedResponse
        }
    }
}

/// Drives sign-in end to end: a password grant, then the exchange that turns the token into a
/// session the backend knows.
///
/// Kept apart from `AccountController` because the two have different jobs. The controller owns what
/// the window shows and holds the cancellable task; this owns how a token is obtained, and it is the
/// piece that will be replaced when a redirect provider is configured.
@MainActor
struct SignInFlow {
    let configuration: CloudConfiguration
    let controller: AccountController

    var isAvailable: Bool { configuration.canSignInWithPassword }

    /// Sign in with a password.
    ///
    /// The refresh token is kept before the session is created, not after: a session that exists but
    /// cannot be renewed is a session that expires mid-stream with no way back.
    func signIn(email: String, password: String) async {
        guard let url = configuration.supabaseURL, let key = configuration.supabaseAnonKey else {
            return
        }
        let auth = SupabaseAuth(url: url, anonKey: key)
        do {
            let granted = try await auth.signIn(email: email, password: password)
            try Task.checkCancellation()
            if let refreshToken = granted.refreshToken {
                try KeychainSecretStore().write(
                    Data(refreshToken.utf8), account: Self.refreshTokenAccount)
            }
            controller.signIn(accessToken: granted.accessToken)
        } catch let error as CloudError {
            guard !Task.isCancelled else { return }
            controller.report(error)
        } catch {
            guard !Task.isCancelled else { return }
            controller.report(.malformedResponse)
        }
    }

    /// Exchange an access token that came from somewhere else — a test harness, or an operator
    /// pasting one. The website offers the same escape hatch when Supabase is not configured.
    func signIn(accessToken: String) {
        controller.signIn(accessToken: accessToken)
    }

    /// Renew the session before it expires.
    ///
    /// Not called on a timer: the token is valid for an hour and the app has no reason to hold a
    /// wake-up for that. It is called when the backend says the session has ended, which is the
    /// moment a renewal is actually worth attempting.
    func renewIfPossible() async {
        guard let url = configuration.supabaseURL, let key = configuration.supabaseAnonKey else {
            return
        }
        let store = KeychainSecretStore()
        guard let data = try? store.read(account: Self.refreshTokenAccount),
            let refreshToken = String(data: data, encoding: .utf8)
        else {
            return
        }
        let auth = SupabaseAuth(url: url, anonKey: key)
        do {
            let granted = try await auth.refresh(refreshToken: refreshToken)
            try Task.checkCancellation()
            if let rotated = granted.refreshToken {
                try store.write(Data(rotated.utf8), account: Self.refreshTokenAccount)
            }
            controller.signIn(accessToken: granted.accessToken)
        } catch {
            guard !Task.isCancelled else { return }
            controller.report(error as? CloudError ?? CloudError.from(transport: error))
        }
    }

    /// Forget the refresh token. Sign-out calls this; the device credential is a separate thing and
    /// is deliberately not touched.
    func forgetRefreshToken() {
        try? KeychainSecretStore().delete(account: Self.refreshTokenAccount)
    }

    private static let refreshTokenAccount = "supabase-refresh-token"
}
