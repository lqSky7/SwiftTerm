import Foundation

/// The one encoder the contract allows.
///
/// Sorted keys and no slash escaping, so the same logical snapshot produces the same bytes on
/// Swift, in Node and in a browser. The digest in `snapshot.begin` is taken over these bytes, which
/// is only meaningful if every peer would have produced them.
enum WireCanonicalJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try encoder().encode(value)
        } catch let error as WireError {
            throw error
        } catch let error as EncodingError {
            throw WireError.malformedFrame(reason: "cannot encode: \(describe(error))")
        }
    }

    static func string<T: Encodable>(_ value: T) throws -> String {
        let data = try encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw WireError.malformedFrame(reason: "encoded bytes are not UTF-8")
        }
        return text
    }

    static func sha256Hex<T: Encodable>(_ value: T) throws -> String {
        WireSHA256.hexDigest(try encode(value))
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= WireLimits.maxSnapshotBytes else {
            throw WireError.oversized(path: "JSON", limit: WireLimits.maxSnapshotBytes, actual: data.count)
        }
        guard String(bytes: data, encoding: .utf8) != nil, !data.contains(0) else {
            throw WireError.malformedFrame(reason: "not UTF-8 JSON")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let error as WireError {
            throw error
        } catch let error as DecodingError {
            throw translate(error)
        } catch {
            throw WireError.malformedFrame(reason: "not JSON")
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        guard let data = text.data(using: .utf8) else {
            throw WireError.malformedFrame(reason: "not UTF-8")
        }
        return try decode(type, from: data)
    }

    /// A `DecodingError` turned into a contract rejection. The message is kept to the field path
    /// and the kind of mismatch; `debugDescription` is dropped because it can echo a payload.
    private static func translate(_ error: DecodingError) -> WireError {
        switch error {
        case let .keyNotFound(key, context):
            return .missingField(path: path(context.codingPath), field: key.stringValue)
        case let .valueNotFound(_, context):
            return .invalidValue(path: path(context.codingPath), reason: "null or absent")
        case let .typeMismatch(_, context):
            return .invalidValue(
                path: path(context.codingPath), reason: "wrong JSON type")
        case let .dataCorrupted(context):
            return .malformedFrame(
                reason: context.codingPath.isEmpty
                    ? "not JSON" : "corrupt at \(path(context.codingPath))")
        @unknown default:
            return .malformedFrame(reason: "unreadable")
        }
    }

    private static func describe(_ error: EncodingError) -> String {
        switch error {
        case let .invalidValue(_, context):
            context.codingPath.isEmpty ? "invalid value" : path(context.codingPath)
        @unknown default:
            "invalid value"
        }
    }

    private static func path(_ codingPath: [CodingKey]) -> String {
        guard !codingPath.isEmpty else { return "$" }
        var result = ""
        for key in codingPath {
            if let index = key.intValue {
                result += "[\(index)]"
            } else if result.isEmpty {
                result += key.stringValue
            } else {
                result += ".\(key.stringValue)"
            }
        }
        return result
    }
}
