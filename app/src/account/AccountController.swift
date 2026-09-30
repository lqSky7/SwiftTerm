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

    static let deployed = CloudConfiguration(
        baseURL: URL(string: "https://swiftterm.shares.zrok.io")!,
        origin: "https://swiftterm.catinice.workers.dev",
    )

    static func fromBundle(_ bundle: Bundle = .main) -> CloudConfiguration {
        let base = bundle.object(forInfoDictionaryKey: "SwiftTermAPIBaseURL") as? String
        let origin = bundle.object(forInfoDictionaryKey: "SwiftTermAPIOrigin") as? String
        guard
            let base, let url = URL(string: base), url.scheme != nil,
            let origin, URL(string: origin) != nil
        else {
            return .deployed
        }
        return CloudConfiguration(baseURL: url, origin: origin)
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

    @ObservationIgnored private let api: CloudAPI
    @ObservationIgnored private let identity: DeviceIdentity
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(
        configuration: CloudConfiguration = .fromBundle(),
        identity: DeviceIdentity = DeviceIdentity()
    ) {
        self.api = CloudAPI(baseURL: configuration.baseURL, origin: configuration.origin)
        self.identity = identity
    }

    var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    var account: CloudAccountSummary? {
        if case .signedIn(let account) = state { return account }
        return nil
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
            do {
                _ = try await api.send(CloudRoutes.authenticate(accessToken: accessToken))
                let account = try await api.send(CloudRoutes.me(), as: CloudAccountSummary.self)
                guard !Task.isCancelled else { return }
                state = .signedIn(account)
                // Registering is a separate step from signing in, and its failure is not a failed
                // sign-in: the session is real either way, and a device that could not be
                // registered can be registered later.
                await registerThisDevice()
                await refreshDevices()
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

    /// Stop an in-flight sign-in. The sheet's Cancel button, and the app's own teardown.
    func cancelSignIn() {
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
        signInTask?.cancel()
        refreshTask?.cancel()
        // Best effort: a sign-out that fails because the network is gone must still sign out
        // locally, or a person on a train cannot leave.
        _ = try? await api.send(CloudRoutes.logout())
        await api.clearCookies()
        devices = []
        state = .signedOut
        lastError = nil
    }

    // MARK: - Devices

    func refreshDevices() async {
        guard isSignedIn else { return }
        do {
            let list = try await api.send(CloudRoutes.devices(), as: DeviceList.self)
            devices = list.devices
        } catch let error as CloudError {
            if error.endsTheSession {
                await api.clearCookies()
                state = .signedOut
            }
            lastError = error
        } catch {
            lastError = .malformedResponse
        }
    }

    /// Register this installation, if it is not registered already.
    ///
    /// Idempotent by construction: the credential is created once and the request id is derived from
    /// it, so a retry after a dropped response returns the device the first attempt created rather
    /// than making a second one.
    func registerThisDevice() async {
        guard isSignedIn, deviceID == nil else { return }
        do {
            let credential = try identity.credential()
            let existing = try identity.registeredDeviceID()
            isWorking = true
            defer { isWorking = false }

            let response = try await api.send(
                CloudRoutes.registerDevice(
                    label: Self.installationLabel(),
                    clientRequestID: existing ?? UUID().uuidString.lowercased(),
                    deviceToken: credential.base64,
                ),
                as: DeviceRegistration.self,
            )
            deviceID = response.deviceId
            try identity.remember(deviceID: response.deviceId)
        } catch let error as CloudError {
            lastError = error
        } catch {
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
                try? identity.forgetRegistration()
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
