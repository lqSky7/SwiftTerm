import Foundation
import Synchronization

@main
struct SignInTest {
    static func main() async {
        let harness = Harness("sign-in-test")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthProtocol.self]
        let auth = SupabaseAuth(url: URL(string: "https://auth.example")!, anonKey: "public",
                                session: URLSession(configuration: configuration))
        AuthProtocol.reply.withLock { $0 = (200, "{\"external\":{\"anonymous_users\":true}}") }
        harness.expect(await auth.anonymousAvailable(), "server enables anonymous option")
        AuthProtocol.reply.withLock { $0 = (200, "{\"external\":{\"anonymous_users\":false}}") }
        harness.expect(await !auth.anonymousAvailable(), "server disables anonymous option")
        AuthProtocol.reply.withLock { $0 = (503, "{}") }
        harness.expect(await !auth.anonymousAvailable(), "failed settings request hides option")
        AuthProtocol.reply.withLock { $0 = (200, "{\"access_token\":\"token\",\"refresh_token\":\"refresh\"}") }
        do {
            let granted = try await auth.signInAnonymously()
            harness.equal(granted.accessToken, "token", "anonymous token decoded")
            harness.equal(granted.refreshToken, "refresh", "refresh credential decoded")
            let request = AuthProtocol.request.withLock { $0 }
            harness.equal(request?.url?.path, "/auth/v1/signup", "anonymous endpoint")
            harness.equal(request?.value(forHTTPHeaderField: "apikey"), "public", "public client key")
            harness.equal(request?.httpMethod, "POST", "anonymous grant uses POST")
        } catch { harness.expect(false, "anonymous grant failed: \(error)") }
        AuthProtocol.reply.withLock { $0 = (403, "{}") }
        do {
            _ = try await auth.signInAnonymously()
            harness.expect(false, "disabled anonymous sign-in must fail")
        } catch { harness.expect(true, "disabled grant refused") }
        await offline(harness)
        harness.finish()
    }

    @MainActor private static func offline(_ harness: Harness) async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthProtocol.self]
        let api = CloudAPI(baseURL: URL(string: "https://api.example")!, origin: "https://site.example",
                           session: URLSession(configuration: configuration))
        let account = AccountController(api: api)
        harness.expect(!account.isSignedIn && !account.isAuthenticating, "new controller stays offline")
        account.cancelSignIn()
        harness.expect(!account.isSignedIn, "cancel is safe before authentication")
        AuthProtocol.request.withLock { $0 = nil }
        account.signIn(accessToken: "cancelled")
        account.cancelSignIn()
        await Task.yield()
        harness.equal(account.state, .signedOut, "cancelled exchange cannot sign in later")
        harness.expect(AuthProtocol.request.withLock { $0 == nil }, "cancel before start performs no request")
    }
}

private final class AuthProtocol: URLProtocol, @unchecked Sendable {
    static let reply = Mutex((200, "{}"))
    static let request = Mutex<URLRequest?>(nil)
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.request.withLock { $0 = request }
        let (status, json) = Self.reply.withLock { $0 }
        guard let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                            httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
