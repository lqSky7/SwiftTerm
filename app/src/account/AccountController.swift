import Foundation
import Observation

/// Where the cloud lives, and what this client calls itself.
///
/// Read from the bundle so a debug build can be pointed at a local backend without editing code —
/// `Info.plist` keys `SwiftTermAPIBaseURL` and `SwiftTermAPIOrigin`, both optional. The defaults are
/// the deployed pair, because a build that has been configured by nobody should still work.
struct CloudConfiguration: Sendable {
    let baseURL: URL
    let origin: String
    /// Where an access token comes from.
    ///
    /// The Supabase project has **no OAuth provider configured**, so there is no redirect target to
    /// send a browser to — the same divergence the website records. Supabase Auth issues the token
    /// and `POST /auth/session` exchanges it, and because the exchange endpoint is the one a redirect
    /// callback would use, configuring a provider later changes only where the token comes from.
    let supabaseURL: URL?
    /// The publishable client key. Safe to embed: it authorises the *client*, and every row is
    /// still scoped by row-level security and by the backend's own verification of the token's
    /// signature.
    let supabaseAnonKey: String?

    /// Whether a release build may offer the paste-a-token path.
    ///
    /// **Off unless a build turns it on, and it exists because it was on for everybody.** The path
    /// is how the token exchange gets tested before an email template or a provider exists, and its
    /// only audience is whoever is building the thing — but a shipped build was showing a
    /// credential-paste field to whoever opened the window, which is not a thing a product does. It
    /// is behind an Info.plist flag now: absent means off, so the default is the honest one and
    /// nobody has to remember to remove it before shipping.
    let allowsTokenSignIn: Bool

    static let deployed = CloudConfiguration(
        baseURL: URL(string: "https://swiftterm.shares.zrok.io")!,
        origin: "https://swiftterm.catinice.workers.dev",
        supabaseURL: nil,
        supabaseAnonKey: nil,
        allowsTokenSignIn: false,
    )

    static func fromBundle(_ bundle: Bundle = .main) -> CloudConfiguration {
        let base = bundle.object(forInfoDictionaryKey: "SwiftTermAPIBaseURL") as? String
        let origin = bundle.object(forInfoDictionaryKey: "SwiftTermAPIOrigin") as? String
        let supabase = bundle.object(forInfoDictionaryKey: "SwiftTermSupabaseURL") as? String
        let anonKey = bundle.object(forInfoDictionaryKey: "SwiftTermSupabaseAnonKey") as? String
        // Absent is false. A flag that had to be set to *disable* the escape hatch would be a flag
        // somebody ships without setting.
        let allowToken = bundle.object(forInfoDictionaryKey: "SwiftTermAllowTokenSignIn") as? Bool

        guard
            let base, let url = URL(string: base), url.scheme != nil,
            let origin, URL(string: origin) != nil
        else {
            return .deployed
        }
        // Supabase is optional rather than required: a build without it has no sign-in at all, which
        // is what the sheet says rather than showing a field nobody can fill in.
        let supabaseURL = supabase.flatMap { URL(string: $0) }.flatMap { $0.scheme == nil ? nil : $0 }
        return CloudConfiguration(
            baseURL: url,
            origin: origin,
            supabaseURL: supabaseURL,
            supabaseAnonKey: anonKey?.isEmpty == true ? nil : anonKey,
            allowsTokenSignIn: allowToken ?? false)
    }

    var canSignInWithPassword: Bool {
        supabaseURL != nil && supabaseAnonKey != nil
    }

    /// Where the relay's sockets live. Derived rather than configured separately: the socket is on
    /// the same origin as the API, and a second setting is a second thing that can disagree.
    var socketBaseURL: URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components?.path = ""
        components?.query = nil
        return components?.url ?? baseURL
    }
}

/// The account, as the window sees it.
///
/// Two rules shape everything here:
///
///   * **Signed out means no cloud work at all.** Nothing in this type runs until someone asks it
///     to. A terminal with no account performs no request, starts no task and holds no timer — which
///     is what the handoff means by "an offline terminal with zero cloud work", and it is a property
///     of the structure rather than of a flag someone remembers to check.
///   * **Cloud state never reaches terminal state.** Sign-out and device revocation clear the
///     account, the cookie jar and the Keychain record. They do not touch a pane, a block, a scroll
///     position or a shell. A person signing out of a website should not lose the terminal they are
///     reading.
@MainActor
@Observable
final class AccountController {
    enum State: Equatable {
        case signedOut
        case signingIn
        case signedIn(CloudAccountSummary)
        case failed(CloudError)
    }

    private(set) var state: State = .signedOut
    private(set) var devices: [CloudDeviceSummary] = []
    /// The server's id for this installation, once it has been registered.
    private(set) var deviceID: String?
    /// True while a request is in flight, so a button can say so and a second press can be ignored.
    private(set) var isWorking = false
    /// The last failure, for the account page to show. Cleared by the next attempt.
    private(set) var lastError: CloudError?

    /// Internal rather than private so a stream can use the same session the account signed in with.
    /// Two clients would mean two cookie jars, and the second one would not be signed in.
    @ObservationIgnored let api: CloudAPI
    @ObservationIgnored private let identity: DeviceIdentity
    /// Kept so the sign-in flow can reach Supabase without a second copy of the configuration.
    @ObservationIgnored let configuration: CloudConfiguration
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var authenticationTask: Task<Void, Never>?

    init(
        configuration: CloudConfiguration = .fromBundle(),
        identity: DeviceIdentity = DeviceIdentity(),
        api: CloudAPI? = nil
    ) {
        self.api = api ?? CloudAPI(baseURL: configuration.baseURL, origin: configuration.origin)
        self.identity = identity
        self.configuration = configuration
    }

    var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    var account: CloudAccountSummary? {
        if case .signedIn(let account) = state { return account }
        return nil
    }

    var isAuthenticating: Bool {
        if case .signingIn = state { return true }
        return isWorking
    }

    func signIn(email: String, password: String) {
        cancelSignIn()
        state = .signingIn
        lastError = nil
        authenticationTask = Task {
            await SignInFlow(configuration: configuration, controller: self)
                .signIn(email: email, password: password)
        }
    }

    func restoreSignIn() {
        guard !isSignedIn, !isAuthenticating, configuration.canSignInWithPassword,
            (try? KeychainSecretStore().read(account: "supabase-refresh-token")) != nil else { return }
        state = .signingIn
        lastError = nil
        authenticationTask = Task {
            await SignInFlow(configuration: configuration, controller: self).renewIfPossible()
        }
    }

    func prepareForSharing() async -> Bool {
        if !isSignedIn {
            restoreSignIn()
            await authenticationTask?.value
            await signInTask?.value
        }
        guard !Task.isCancelled else { return false }
        if !isSignedIn {
            signInAnonymously()
            await authenticationTask?.value
            await signInTask?.value
        }
        guard !Task.isCancelled, isSignedIn else { return false }
        if deviceID == nil { await registerThisDevice() }
        return deviceID != nil && !Task.isCancelled
    }

    func signInAnonymously() {
        guard let url = configuration.supabaseURL, let key = configuration.supabaseAnonKey else { return }
        cancelSignIn()
        state = .signingIn
        lastError = nil
        authenticationTask = Task {
            do {
                let granted = try await SupabaseAuth(url: url, anonKey: key).signInAnonymously()
                try Task.checkCancellation()
                if let refresh = granted.refreshToken {
                    try KeychainSecretStore().write(Data(refresh.utf8), account: "supabase-refresh-token")
                }
                signIn(accessToken: granted.accessToken)
            } catch {
                guard !Task.isCancelled else { return }
                report(error as? CloudError ?? CloudError.from(transport: error))
            }
        }
    }

    // MARK: - Signing in

    /// Exchange a verified access token for a session.
    ///
    /// A task, held, and cancellable. Every reason matters: a person who closes the sheet while the
    /// request is in flight should not have a session appear afterwards; a second attempt must
    /// supersede the first rather than race it; and a sign-out during a sign-in has to win.
    func signIn(accessToken: String) {
        signInTask?.cancel()
        state = .signingIn
        lastError = nil

        signInTask = Task { [api] in
            guard !Task.isCancelled else { return }
            do {
                _ = try await api.send(CloudRoutes.authenticate(accessToken: accessToken))
                let account = try await api.send(CloudRoutes.me(), as: CloudAccountSummary.self)
                guard !Task.isCancelled else { return }
                state = .signedIn(account)
                // Registering is a separate step from signing in, and its failure is not a failed
                // sign-in: the session is real either way, and a device that could not be
                // registered can be registered later.
                await refreshDevices()
                await registerThisDevice()
            } catch let error as CloudError {
                guard !Task.isCancelled else { return }
                if error == .cancelled { return }
                state = error.endsTheSession ? .signedOut : .failed(error)
                lastError = error
                if error.endsTheSession { await api.clearCookies() }
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(.malformedResponse)
            }
        }
    }

    /// Record a failure that happened outside this type.
    ///
    /// The sign-in flow obtains a token before this controller is involved, and its failures — a
    /// rejected password, an unreachable issuer — are still the account's failures. Rather than
    /// duplicate the state machine there, it reports here.
    func report(_ error: CloudError) {
        lastError = error
        if error.endsTheSession {
            state = .signedOut
        } else if case .signedIn = state {
            // A failure while signed in does not unsign the person; it is shown and dismissed.
        } else {
            state = .failed(error)
        }
    }

    /// Stop an in-flight sign-in. The sheet's Cancel button, and the app's own teardown.
    func cancelSignIn() {
        authenticationTask?.cancel()
        authenticationTask = nil
        signInTask?.cancel()
        signInTask = nil
        if case .signingIn = state { state = .signedOut }
    }

    // MARK: - Signing out

    /// Revoke this browser session and forget it locally.
    ///
    /// The device credential is deliberately **kept**. It is this installation's secret, not the
    /// session's, and it is what lets a later sign-in find the same device rather than registering a
    /// second one. `revokeDevice` is the call that ends the credential's authority, and it is a
    /// separate, explicit act.
    func signOut() async {
        cancelSignIn()
        SignInFlow(configuration: configuration, controller: self).forgetRefreshToken()
        state = .signedOut
        devices = []
        deviceID = nil
        isWorking = true
        defer { isWorking = false }
        // Best effort: a sign-out that fails because the network is gone must still sign out
        // locally, or a person on a train cannot leave.
        _ = try? await api.send(CloudRoutes.logout())
        await api.clearCookies()
        devices = []
        deviceID = nil
        state = .signedOut
        lastError = nil
    }

    func invite(sessionID: String, recipientID: String, permission: String) async throws -> CloudInvitation {
        guard isSignedIn, UUID(uuidString: recipientID) != nil,
            ["viewer", "controller"].contains(permission) else { throw CloudError.malformedResponse }
        return try await api.send(
            CloudRoutes.invite(sessionID: sessionID, recipientID: recipientID.lowercased(), permission: permission),
            as: CloudInvitation.self)
    }

    private(set) var publicShares: [CloudShareSummary] = []

    func refreshShares() async {
        guard let id = account?.id else { return }
        do {
            let result = try await api.send(CloudRoutes.shares(), as: CloudShareList.self)
            guard !Task.isCancelled, account?.id == id else { return }
            publicShares = result.shares.filter { $0.revokedAt == nil }
        } catch { lastError = error as? CloudError ?? .malformedResponse }
    }

    func revokeStaticShare(_ id: String) async {
        guard isSignedIn else { return }
        do {
            _ = try await api.send(CloudRoutes.revokeShare(id: id))
            await refreshShares()
        } catch { lastError = error as? CloudError ?? .malformedResponse }
    }

    // MARK: - Devices

    func refreshDevices() async {
        guard let ownerID = account?.id else { return }
        do {
            let list = try await api.send(CloudRoutes.devices(), as: DeviceList.self)
            guard !Task.isCancelled, account?.id == ownerID else { return }
            devices = list.devices
        } catch let error as CloudError {
            guard !Task.isCancelled, account?.id == ownerID else { return }
            if error.endsTheSession {
                await api.clearCookies()
                state = .signedOut
            }
            lastError = error
        } catch {
            guard !Task.isCancelled, account?.id == ownerID else { return }
            lastError = .malformedResponse
        }
    }

    /// Register this installation, if it is not registered already.
    ///
    /// Idempotent by construction: the credential is created once and the request id is derived from
    /// it, so a retry after a dropped response returns the device the first attempt created rather
    /// than making a second one.
    func registerThisDevice() async {
        guard let account, deviceID == nil else { return }
        let identity = identity.forAccount(account.id)
        do {
            let existing = try identity.registeredDeviceID()
            if let existing {
                let list = try await api.send(CloudRoutes.devices(), as: DeviceList.self)
                guard !Task.isCancelled, self.account?.id == account.id else { return }
                if let device = list.devices.first(where: { $0.id == existing && $0.revokedAt == nil }) {
                    deviceID = device.id
                    return
                }
                try identity.destroyCredential()
            }
            let credential = try identity.credential()
            isWorking = true
            defer { isWorking = false }

            let response = try await api.send(
                CloudRoutes.registerDevice(
                    label: Self.installationLabel(),
                    clientRequestID: try identity.registrationRequestID(),
                    deviceToken: credential.base64,
                ),
                as: DeviceRegistration.self,
            )
            guard !Task.isCancelled, self.account?.id == account.id else { return }
            deviceID = response.deviceId
            try identity.remember(deviceID: response.deviceId)
        } catch let error as CloudError {
            guard !Task.isCancelled, self.account?.id == account.id else { return }
            lastError = error
        } catch {
            guard !Task.isCancelled, self.account?.id == account.id else { return }
            lastError = .malformedResponse
        }
    }

    /// Revoke a device. Revoking **this** installation also forgets its registration locally, so the
    /// next sign-in registers it again rather than presenting a credential the server has forgotten.
    func revokeDevice(id: String) async {
        do {
            _ = try await api.send(CloudRoutes.revokeDevice(id: id))
            if id == deviceID {
                deviceID = nil
                if let account { try identity.forAccount(account.id).destroyCredential() }
            }
            await refreshDevices()
        } catch let error as CloudError {
            lastError = error
        } catch {
            lastError = .malformedResponse
        }
    }

    /// A label a person will recognise in a device list. The computer's name, not its identity — the
    /// name is a label, and the credential is what authenticates.
    private static func installationLabel() -> String {
        Host.current().localizedName ?? "Mac"
    }
}

// MARK: - Response envelopes

private struct DeviceList: Decodable, Sendable {
    let devices: [CloudDeviceSummary]
}

private struct DeviceRegistration: Decodable, Sendable {
    let deviceId: String
    let created: Bool
}
