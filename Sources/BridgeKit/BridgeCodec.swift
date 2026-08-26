import Foundation

/// The one JSON dialect spoken across the App Group.
///
/// Both sides construct their coders here so a date or key-strategy change can
/// never land on one side of the bridge only.
public enum BridgeCodec {

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Full-precision, timezone-free, and identical on every platform —
        // ISO-8601 would silently drop sub-second detail.
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    /// Wraps `payload` in a current-version envelope and encodes it.
    public static func encode<Payload: Codable & Sendable>(_ payload: Payload) throws -> Data {
        do {
            return try makeEncoder().encode(BridgeEnvelope(payload: payload))
        } catch {
            throw BridgeError.encodeFailed(String(describing: error))
        }
    }

    /// Decodes an envelope, rejecting protocol versions this build predates.
    ///
    /// The version check runs before the payload decode so a future writer
    /// produces `unsupportedSchema` ("open Vocal to finish updating") rather
    /// than a confusing key-missing error.
    public static func decode<Payload: Codable & Sendable>(
        _ type: Payload.Type,
        from data: Data
    ) throws -> Payload {
        let decoder = makeDecoder()
        let version: Int
        do {
            version = try decoder.decode(SchemaProbe.self, from: data).schemaVersion
        } catch {
            throw BridgeError.decodeFailed("missing schemaVersion: \(error)")
        }
        let supported = BridgeSchema.minimumSupported...BridgeSchema.current
        guard supported.contains(version) else {
            throw BridgeError.unsupportedSchema(found: version, supported: supported)
        }
        do {
            return try decoder.decode(BridgeEnvelope<Payload>.self, from: data).payload
        } catch {
            throw BridgeError.decodeFailed(String(describing: error))
        }
    }

    /// Reads only the version stamp, so the check never depends on the payload
    /// still being decodable.
    private struct SchemaProbe: Decodable {
        let schemaVersion: Int
    }
}
