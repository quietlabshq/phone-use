public enum ReportID: UInt8, Sendable {
    case keyboard = 1
    case mouse = 2
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
    public static let axisMax: UInt16 = 32767
    public static let primaryButton: UInt32 = 1
    public static let homeButton: UInt32 = 1 << 2

    public let buttons: UInt32
    public let x: UInt16
    public let y: UInt16

    public init(buttons: UInt32, x: UInt16, y: UInt16) {
        self.buttons = buttons
        self.x = x
        self.y = y
    }

    public static let empty = MouseReport(buttons: 0, x: 0, y: 0)

    public var payload: [UInt8] {
        [
            UInt8(truncatingIfNeeded: buttons),
            UInt8(truncatingIfNeeded: buttons >> 8),
            UInt8(truncatingIfNeeded: buttons >> 16),
            UInt8(truncatingIfNeeded: buttons >> 24),
            UInt8(truncatingIfNeeded: x),
            UInt8(x >> 8),
            UInt8(truncatingIfNeeded: y),
            UInt8(y >> 8),
        ]
    }
}

public enum HIDReport: Sendable, Equatable {
    case keyboard(KeyboardReport)
    case mouse(MouseReport)

    public var id: ReportID {
        switch self {
        case .keyboard: .keyboard
        case .mouse: .mouse
        }
    }

    public var payload: [UInt8] {
        switch self {
        case .keyboard(let report): report.payload
        case .mouse(let report): report.payload
        }
    }
}

public enum HIDP {
    public static let dataInput: UInt8 = 0xA1

    public static func interruptPacket(for report: HIDReport) -> [UInt8] {
        [dataInput, report.id.rawValue] + report.payload
    }
}
