import Foundation

public enum BridgeCodec {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    public static func encodeEnvelope(_ envelope: BridgeEnvelope) throws -> Data {
        try encoder.encode(envelope)
    }

    public static func decodeEnvelope(_ data: Data) throws -> BridgeEnvelope {
        try decoder.decode(BridgeEnvelope.self, from: data)
    }

    public static func encodeResponse(_ response: BridgeResponse) throws -> Data {
        try encoder.encode(response)
    }

    public static func decodeResponse(_ data: Data) throws -> BridgeResponse {
        try decoder.decode(BridgeResponse.self, from: data)
    }

    public static func readJSONObject(from data: Data) -> [String: Any]? {
        guard !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public static func jsonString(for object: some Encodable) -> String? {
        guard let data = try? encoder.encode(AnyEncodable(object)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

private struct AnyEncodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void

    init<T: Encodable>(_ wrapped: T) {
        encodeImpl = wrapped.encode(to:)
    }

    func encode(to encoder: Encoder) throws {
        try encodeImpl(encoder)
    }
}
