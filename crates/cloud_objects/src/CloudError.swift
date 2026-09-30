import Foundation

/// Every way a cloud call can fail, as a closed set.
///
/// The backend answers a refusal with an allowlisted code and never with a message — the reason
/// stays in its log, because a message derived from a request is a message that can echo a
/// credential back. So the client does the same thing the website does: it switches on the code and
/// produces a sentence from a table, and an unknown code becomes the generic sentence rather than
/// being shown.
///
/// A cloud failure is never fatal to the terminal. Every case here is something the app can be
/// offline about, which is the whole reason the local experience does not depend on any of it.
enum CloudError: Error, Equatable, Sendable {
    /// The request never reached a server, or the connection dropped. Not a refusal.
    case offline
    /// The task was cancelled — a sign-out, a closed window, or a second attempt superseding this
    /// one. Distinct from a failure because it is not one.
    case cancelled
    /// The server refused, with the status that carried the refusal and its allowlisted code.
    case refused(status: Int, code: String)
    /// The server answered with something that is not the shape the contract describes. Treated as a
    /// refusal rather than trusted, because a client that guesses at a malformed body is a client
    /// that will one day guess wrong.
    case malformedResponse

    /// The allowlisted code, which is what any caller should switch on.
    var code: String {
        switch self {
        case .offline: return "offline"
        case .cancelled: return "cancelled"
        case .refused(_, let code): return code
        case .malformedResponse: return "malformed_response"
        }
    }

    /// A sentence safe to show a person, derived only from the code.
    var messageForUser: String {
        switch code {
        case "offline":
            return "Could not reach the server. Your terminal keeps working."
        case "cancelled":
            return "Cancelled."
        case "unauthorized", "session_ended":
            return "Your session has ended. Sign in again."
        case "rate_limited":
            return "Too many attempts. Wait a moment and try again."
        case "capacity":
            return "That request was too large."
        case "stale_lease":
            return "Another publisher already holds this stream."
        default:
            return "Something went wrong. Try again."
        }
    }

    /// Whether the stored session is finished and the person has to sign in again.
    ///
    /// Separate from `messageForUser` because the *action* differs: an expired session means clearing
    /// the cookie jar and showing the sign-in state, while a rate limit means doing nothing at all.
    var endsTheSession: Bool {
        code == "unauthorized" || code == "session_ended"
    }

    /// Build a refusal from a status and a body, or `nil` when the body is not one.
    ///
    /// The backend's error body is exactly `{"error":"<code>"}`. Anything else — HTML from a proxy, an
    /// empty body, a different key — is not a refusal this client understands, and inventing a code
    /// for it would be worse than saying so.
    static func from(status: Int, body: Data) -> CloudError {
        guard
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let code = object["error"] as? String,
            !code.isEmpty
        else {
            return .malformedResponse
        }
        return .refused(status: status, code: code)
    }

    /// Classify a `URLSession` failure. Cancellation is not an error in this app, so it is separated
    /// here rather than being folded into `offline` and reported to the person as a network problem.
    static func from(transport error: Error) -> CloudError {
        if error is CancellationError { return .cancelled }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return .cancelled
        }
        return .offline
    }
}
