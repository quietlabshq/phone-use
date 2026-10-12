public enum ReportID: UInt8, Sendable {
    case keyboard = 1
    case mouse = 2
    case consumer = 3
}

public struct KeyboardReport: Sendable, Equatable {
    public let modifiers: UInt8
    public let keys: [UInt8]

    public init(modifiers: UInt8, keys: [UInt8]) {
        precondition(keys.count <= 6, "Keyboard reports support at most six keys")
        self.modifiers = modifiers
        self.keys = keys
    }

    public static let empty = KeyboardReport(modifiers: 0, keys: [])

    public var payload: [UInt8] {
        [modifiers, 0] + keys + Array(repeating: 0, count: 6 - keys.count)
    }
}

public struct MouseReport: Sendable, Equatable {
    public let buttons: UInt8
    public let dx: Int8
    public let dy: Int8
    public let wheel: Int8

    public init(buttons: UInt8, dx: Int8, dy: Int8, wheel: Int8) {
        self.buttons = buttons
        self.dx = dx
        self.dy = dy
        self.wheel = wheel
    }

    public var payload: [UInt8] {
        [buttons, UInt8(bitPattern: dx), UInt8(bitPattern: dy), UInt8(bitPattern: wheel)]
    }
}

public struct ConsumerReport: Sendable, Equatable {
    public let usage: UInt16

    public init(usage: UInt16) {
        self.usage = usage
    }

    public var payload: [UInt8] {
        [UInt8(truncatingIfNeeded: usage), UInt8(usage >> 8)]
    }
}

public enum HIDReport: Sendable, Equatable {
    case keyboard(KeyboardReport)
    case mouse(MouseReport)
    case consumer(ConsumerReport)

    public var id: ReportID {
        switch self {
        case .keyboard: .keyboard
        case .mouse: .mouse
        case .consumer: .consumer
        }
    }

    public var payload: [UInt8] {
        switch self {
        case .keyboard(let report): report.payload
        case .mouse(let report): report.payload
        case .consumer(let report): report.payload
        }
    }
}
