import Foundation
import Security

/// A device credential: 256 random bits, generated **once on this machine** and never derived from
/// anything about it.
///
/// The contract is explicit that a native credential is a random secret the client generates, and
/// that only its digest is stored server-side. The reason the local machine's identity must not be
/// used is not privacy for its own sake: a credential derived from a hostname or a hardware id is a
/// credential that a second machine can guess, and one that changes when the hardware does.
struct DeviceCredential: Equatable, Sendable {
    /// Exactly the 32 bytes the backend requires. Its route refuses any other length.
    static let byteCount = 32

    let token: Data

    /// Canonical **standard** base64, with padding.
    ///
    /// Not base64url: the registration route compares the re-encoded value against what arrived and
    /// refuses anything that is not the one spelling, so a second encoding would be rejected rather
    /// than normalised.
    var base64: String { token.base64EncodedString() }

    /// A fresh credential. `SecRandomCopyBytes` rather than `Int.random`, because the latter is not
    /// promised to be unpredictable.
    static func generate() -> DeviceCredential? {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { return nil }
        return DeviceCredential(token: Data(bytes))
    }
}

/// Where a secret lives.
///
/// A protocol so the account model can be exercised without a Keychain, and so the only code that
/// touches `SecItem*` is one small type that does nothing else.
protocol SecretStore: Sendable {
    func read(account: String) throws -> Data?
    func write(_ secret: Data, account: String) throws
    func delete(account: String) throws
}

/// The Keychain, and only the Keychain.
///
/// Not `UserDefaults`, which is a plist in the container that anything with filesystem access can
/// read, and not the local profile: the handoff's rule that the OS profile is not a cloud identity
/// is what this type exists to keep. `ThisDeviceOnly` and `AfterFirstUnlock` because the credential
/// belongs to this installation and to no backup or second machine.
struct KeychainSecretStore: SecretStore {
    /// Namespaced so it cannot collide with another app's items, and so a future migration can find
    /// exactly its own.
    let service: String

    init(service: String = "app.swiftterm.cloud") {
        self.service = service
    }

    func read(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CloudError.offline
        }
        return data
    }

    func write(_ secret: Data, account: String) throws {
        // Add, then update on a duplicate. `SecItemAdd` is the only call that can set the
        // accessibility class, so an existing item is replaced rather than updated in place — an
        // item written by an older build with weaker accessibility must not survive.
        try delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: secret,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw CloudError.offline }
    }

    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CloudError.offline
        }
    }
}

/// The device's credential, and whether the server has been told about it.
///
/// Two facts, kept apart on purpose. The token is created locally the first time it is needed; the
/// *registration* is what binds it to an account, and it can only happen once someone is signed in.
/// A token with no registration is not a half-registered device — it is a credential waiting for an
/// account, which is exactly the state an offline first launch is in.
struct DeviceIdentity: Sendable {
    static let tokenAccount = "device-token"
    static let registeredDeviceAccount = "registered-device-id"

    let store: SecretStore
    private let ownerID: String?

    init(store: SecretStore = KeychainSecretStore(), ownerID: String? = nil) {
        self.store = store
        self.ownerID = ownerID
    }

    func forAccount(_ ownerID: String) -> DeviceIdentity {
        DeviceIdentity(store: store, ownerID: ownerID)
    }

    private func key(_ name: String) -> String {
        ownerID.map { "\(name):\($0)" } ?? name
    }

    func registrationRequestID() throws -> String {
        let account = key("device-registration-request")
        if let data = try store.read(account: account), let id = String(data: data, encoding: .utf8) {
            return id
        }
        let id = UUID().uuidString.lowercased()
        try store.write(Data(id.utf8), account: account)
        return id
    }

    /// The credential for this installation, creating it on first use.
    ///
    /// Idempotent: a second call returns the credential the first one stored, so a retry after a
    /// failure cannot leave two credentials where one device belongs.
    func credential() throws -> DeviceCredential {
        if let existing = try store.read(account: key(Self.tokenAccount)) {
            // A stored value of the wrong length is not usable and cannot be repaired by guessing,
            // so it is replaced. This is the only path that overwrites a credential, and it happens
            // before any registration has been attempted with it.
            if existing.count == DeviceCredential.byteCount {
                return DeviceCredential(token: existing)
            }
            try store.delete(account: key(Self.tokenAccount))
        }
        guard let fresh = DeviceCredential.generate() else {
            throw CloudError.offline
        }
        try store.write(fresh.token, account: key(Self.tokenAccount))
        return fresh
    }

    /// The device id the server assigned, if this credential has been registered.
    func registeredDeviceID() throws -> String? {
        guard let data = try store.read(account: key(Self.registeredDeviceAccount)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func remember(deviceID: String) throws {
        guard let data = deviceID.data(using: .utf8) else { throw CloudError.malformedResponse }
        try store.write(data, account: key(Self.registeredDeviceAccount))
    }

    /// Forget the registration but keep the credential.
    ///
    /// Revoking a device removes the server's record of it; the local secret is still this
    /// installation's secret, and generating a new one on every revoke would make the Keychain item
    /// churn for no reason. Deleting the credential is a separate, deliberate act.
    func forgetRegistration() throws {
        try store.delete(account: key(Self.registeredDeviceAccount))
    }

    /// Delete the credential itself. Sign-out does **not** do this — see `forgetRegistration`.
    func destroyCredential() throws {
        try store.delete(account: key(Self.tokenAccount))
        try store.delete(account: key(Self.registeredDeviceAccount))
        try store.delete(account: key("device-registration-request"))
    }
}
