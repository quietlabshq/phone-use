public enum PhoneKind: String, Sendable, Codable {
    case simulator, hardware
}

public struct PhoneInfo: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let kind: PhoneKind
    public let screenSize: PixelSize

    public init(id: String, name: String, kind: PhoneKind, screenSize: PixelSize) {
        self.id = id
        self.name = name
        self.kind = kind
        self.screenSize = screenSize
    }
}

public enum PhoneError: Error, Equatable, CustomStringConvertible {
    case outOfBounds(PixelPoint, PixelSize)
    case unsupportedCharacters(String)
    case inputNotConnected(String)
    case toolUnavailable(String)
    case commandFailed(String)
    case phoneNotFound(String)
    case invalidFrame(String)

    public var description: String {
        switch self {
        case let .outOfBounds(point, size):
            "Point (\(point.x), \(point.y)) is outside the screenshot. Valid x: 0-\(size.width - 1), y: 0-\(size.height - 1)."
        case let .unsupportedCharacters(characters):
            "Unsupported characters: \(characters). Only US-ASCII input is supported."
        case let .inputNotConnected(message):
            "Input device not connected: \(message)"
        case let .toolUnavailable(message):
            "Tool unavailable: \(message)"
        case let .commandFailed(message):
            "Command failed: \(message)"
        case let .phoneNotFound(id):
            "Phone not found: \(id)"
        case let .invalidFrame(message):
            "Invalid screenshot frame: \(message)"
        }
    }
}

public protocol Phone: Sendable {
    var info: PhoneInfo { get }
    func screenshot() async throws -> PixelFrame
    func perform(_ action: PhoneAction) async throws
}

public protocol PhoneRegistry: Sendable {
    func discover() async -> (phones: [any Phone], hints: [String])
}
