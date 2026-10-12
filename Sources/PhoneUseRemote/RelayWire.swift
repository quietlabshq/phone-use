import CryptoKit
import Foundation
import MCP
import PhoneUseMCP

public enum RelayWireError: Error, Sendable { case invalidFrame, expired, tooLarge }

public struct RelayDispatch: Sendable {
    public let generation: String
    public let dispatchID: String
    public let requestID: String
    public let request: RemoteHTTPRequest
    /// Seconds remaining at parse time; add to the local continuous clock immediately.
    public let deadlineInterval: TimeInterval
}

private struct RelayHeader: Codable, Sendable {
    let name: String
    let value: String
    init(_ name: String, _ value: String) { self.name = name; self.value = value }
    init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        name = try values.decode(String.self)
        value = try values.decode(String.self)
        guard values.isAtEnd else { throw RelayWireError.invalidFrame }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.unkeyedContainer()
        try values.encode(name); try values.encode(value)
    }
}

private struct IncomingDispatch: Decodable {
    let v: Int
    let type: String
    let generation: String
    let dispatchID: String
    let requestID: String
    let deadline: Int64
    let method: String
    let path: String
    let headers: [RelayHeader]
    let body: String
}

private struct Connected: Decodable { let v: Int; let type: String; let generation: String }
private struct Catalog: Encodable { let version: String; let hash: String; let tools: [Tool] }
private struct Hello: Encodable { let v = 1; let type = "hello"; let generation: String; let revision = 1; let credentials: [RelayCredentialSnapshot]; let catalog: Catalog }
private struct CredentialsFrame: Encodable { let v = 1; let type = "credentials"; let generation: String; let revision: Int; let credentials: [RelayCredentialSnapshot] }
private struct ResultStart: Encodable { let v = 1; let type = "result_start"; let generation: String; let dispatchID: String; let requestID: String; let status: Int; let headers: [RelayHeader] }
private struct ResultChunk: Encodable { let v = 1; let type = "result_chunk"; let generation: String; let dispatchID: String; let requestID: String; let sequence: Int; let body: String }
private struct ResultEnd: Encodable { let v = 1; let type = "result_end"; let generation: String; let dispatchID: String; let requestID: String }
private struct Failure: Encodable { let v = 1; let type = "failure"; let generation: String; let dispatchID: String; let requestID: String; let outcome: String }

public enum RelayWire {
    public static let frameLimit = 384 * 1024
    public static let chunkLimit = 192 * 1024
    private static func encoder() -> JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder }
    private static func frame<T: Encodable>(_ value: T) throws -> Data {
        let data = try encoder().encode(value)
        guard data.count <= frameLimit else { throw RelayWireError.tooLarge }
        return data
    }
    private static func validUUID(_ value: String) -> Bool {
        value.utf8.count == 36 && UUID(uuidString: value) != nil && value.utf8.enumerated().allSatisfy { index, byte in
            [8, 13, 18, 23].contains(index) ? byte == 45 : (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }
    private static func validHeader(_ header: RelayHeader) -> Bool {
        let permitted = "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8
        return !header.name.isEmpty && header.name.utf8.allSatisfy { permitted.contains($0) } && !header.value.utf8.contains(where: { $0 == 0 || $0 == 10 || $0 == 13 })
    }
    public static func connectedGeneration(_ raw: Data) throws -> String {
        guard raw.count <= frameLimit, let frame = try? JSONDecoder().decode(Connected.self, from: raw), frame.v == 1, frame.type == "connected", validUUID(frame.generation) else { throw RelayWireError.invalidFrame }
        return frame.generation
    }
    public static func parseDispatch(_ raw: Data, generation: String, nowMilliseconds: Int64) throws -> RelayDispatch {
        guard raw.count <= frameLimit, let frame = try? JSONDecoder().decode(IncomingDispatch.self, from: raw),
              frame.v == 1, frame.type == "dispatch", frame.generation == generation,
              validUUID(frame.dispatchID), validUUID(frame.requestID),
              (frame.method == "POST" && (frame.path == "/mcp" || frame.path == "/leases/release")) || (frame.method == "DELETE" && frame.path == "/mcp"),
              frame.headers.count <= 128, frame.headers.allSatisfy(validHeader),
              (try? encoder().encode(frame.headers).count) ?? Int.max <= 16 * 1024,
              let body = Data(base64Encoded: frame.body), body.base64EncodedString() == frame.body else { throw RelayWireError.invalidFrame }
        guard body.count <= 256 * 1024 else { throw RelayWireError.tooLarge }
        guard frame.deadline > nowMilliseconds else { throw RelayWireError.expired }
        let remaining = min(120, Double(frame.deadline - nowMilliseconds) / 1_000)
        return RelayDispatch(generation: generation, dispatchID: frame.dispatchID, requestID: frame.requestID,
                             request: .init(method: frame.method, path: frame.path, headers: frame.headers.map { ($0.name, $0.value) }, body: body), deadlineInterval: remaining)
    }
    public static func hello(generation: String, credentials: [RelayCredentialSnapshot]) throws -> Data {
        let tools = MCPServer.tools
        let data = try encoder().encode(tools)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return try frame(Hello(generation: generation, credentials: credentials, catalog: Catalog(version: "phone-use-0.1.0", hash: hash, tools: tools)))
    }
    public static func credentials(generation: String, revision: Int, credentials: [RelayCredentialSnapshot]) throws -> Data {
        try frame(CredentialsFrame(generation: generation, revision: revision, credentials: credentials))
    }
    public static func failure(for dispatch: RelayDispatch, outcome: String) throws -> Data {
        guard outcome == "not_started" || outcome == "unknown" else { throw RelayWireError.invalidFrame }
        return try frame(Failure(generation: dispatch.generation, dispatchID: dispatch.dispatchID, requestID: dispatch.requestID, outcome: outcome))
    }
    public static func rejectedDispatch(_ raw: Data, generation: String, outcome: String) throws -> Data {
        guard let incoming = try? JSONDecoder().decode(IncomingDispatch.self, from: raw),
              incoming.generation == generation, validUUID(incoming.dispatchID), validUUID(incoming.requestID),
              outcome == "not_started" || outcome == "unknown" else { throw RelayWireError.invalidFrame }
        return try frame(Failure(generation: generation, dispatchID: incoming.dispatchID, requestID: incoming.requestID, outcome: outcome))
    }
    public static func resultFrames(for dispatch: RelayDispatch, response: RemoteHTTPResponse) throws -> [Data] {
        var frames = [try resultStart(for: dispatch, response: response)]
        var sequence = 0
        for offset in stride(from: 0, to: response.body.count, by: chunkLimit) {
            let chunk = response.body[offset..<min(offset + chunkLimit, response.body.count)]
            frames.append(try resultChunk(for: dispatch, sequence: sequence, body: chunk))
            sequence += 1
        }
        frames.append(try resultEnd(for: dispatch))
        return frames
    }
    public static func resultStart(for dispatch: RelayDispatch, response: RemoteHTTPResponse) throws -> Data {
        let headers = response.headers.sorted { $0.key < $1.key }.map(RelayHeader.init)
        return try frame(ResultStart(generation: dispatch.generation, dispatchID: dispatch.dispatchID, requestID: dispatch.requestID, status: response.status, headers: headers))
    }
    public static func resultChunk(for dispatch: RelayDispatch, sequence: Int, body: Data.SubSequence) throws -> Data {
        guard body.count <= chunkLimit else { throw RelayWireError.tooLarge }
        return try frame(ResultChunk(generation: dispatch.generation, dispatchID: dispatch.dispatchID, requestID: dispatch.requestID, sequence: sequence, body: body.base64EncodedString()))
    }
    public static func resultEnd(for dispatch: RelayDispatch) throws -> Data {
        try frame(ResultEnd(generation: dispatch.generation, dispatchID: dispatch.dispatchID, requestID: dispatch.requestID))
    }
}
