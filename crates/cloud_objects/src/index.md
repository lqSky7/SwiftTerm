# cloud_objects/src — index

The export contract sources. Foundation-only, same rule as `crates/shared_session/src`.

`WireShare.swift` holds the export document and the capability rules. Two of them are worth
knowing before editing:

- A span is in UTF-16 offsets — the offsets a browser string actually uses — and spans must be
  ordered, non-overlapping, non-zero-length and inside the line.
- The directory is a display label the owner approved in the native preview. An absolute path, a
  `~` path or a `..` component is refused rather than abbreviated, because quietly turning a real
  path into a label is the implicit export the contract forbids.

The share capability is 32 random bytes in one canonical base64url spelling. The server stores
only the SHA-256, and the secret lives in the browser fragment.
