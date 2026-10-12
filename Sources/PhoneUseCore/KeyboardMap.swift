public struct KeyStroke: Equatable, Sendable {
    public let usage: UInt8
    public let shift: Bool

    public init(usage: UInt8, shift: Bool) {
        self.usage = usage
        self.shift = shift
    }
}

public enum KeyboardMap {
    public static func strokes(for text: String) throws -> [KeyStroke] {
        var strokes: [KeyStroke] = []
        var unsupported = ""
        for character in text {
            if let stroke = stroke(for: character) {
                strokes.append(stroke)
            } else {
                unsupported.append(character)
            }
        }
        guard unsupported.isEmpty else { throw PhoneError.unsupportedCharacters(unsupported) }
        return strokes
    }

    public static func usage(for key: Key) -> UInt8 {
        switch key {
        case .enter: return 0x28
        case .escape: return 0x29
        case .backspace: return 0x2A
        case .tab: return 0x2B
        case .space: return 0x2C
        case .right: return 0x4F
        case .left: return 0x50
        case .down: return 0x51
        case .up: return 0x52
        case let .letter(character):
            guard let byte = character.asciiValue, (97...122).contains(byte) else {
                preconditionFailure("Key.letter requires a lowercase ASCII letter")
            }
            return byte - 97 + 0x04
        }
    }

    public static func modifierBits(_ modifiers: [Modifier]) -> UInt8 {
        modifiers.reduce(0) { $0 | (1 << (modifierUsage($1) - 224)) }
    }

    public static func modifierUsage(_ modifier: Modifier) -> UInt8 {
        switch modifier {
        case .control: 224
        case .shift: 225
        case .option: 226
        case .command: 227
        }
    }

    private static func stroke(for character: Character) -> KeyStroke? {
        guard let byte = character.asciiValue else { return nil }
        switch byte {
        case 97...122: return KeyStroke(usage: byte - 97 + 0x04, shift: false)
        case 65...90: return KeyStroke(usage: byte - 65 + 0x04, shift: true)
        case 49...57: return KeyStroke(usage: byte - 49 + 0x1E, shift: false)
        case 48: return KeyStroke(usage: 0x27, shift: false)
        case 10: return KeyStroke(usage: 0x28, shift: false)
        case 9: return KeyStroke(usage: 0x2B, shift: false)
        case 32: return KeyStroke(usage: 0x2C, shift: false)
        case 45, 95: return KeyStroke(usage: 0x2D, shift: byte == 95)
        case 61, 43: return KeyStroke(usage: 0x2E, shift: byte == 43)
        case 91, 123: return KeyStroke(usage: 0x2F, shift: byte == 123)
        case 93, 125: return KeyStroke(usage: 0x30, shift: byte == 125)
        case 92, 124: return KeyStroke(usage: 0x31, shift: byte == 124)
        case 59, 58: return KeyStroke(usage: 0x33, shift: byte == 58)
        case 39, 34: return KeyStroke(usage: 0x34, shift: byte == 34)
        case 96, 126: return KeyStroke(usage: 0x35, shift: byte == 126)
        case 44, 60: return KeyStroke(usage: 0x36, shift: byte == 60)
        case 46, 62: return KeyStroke(usage: 0x37, shift: byte == 62)
        case 47, 63: return KeyStroke(usage: 0x38, shift: byte == 63)
        case 33: return KeyStroke(usage: 0x1E, shift: true)
        case 64: return KeyStroke(usage: 0x1F, shift: true)
        case 35: return KeyStroke(usage: 0x20, shift: true)
        case 36: return KeyStroke(usage: 0x21, shift: true)
        case 37: return KeyStroke(usage: 0x22, shift: true)
        case 94: return KeyStroke(usage: 0x23, shift: true)
        case 38: return KeyStroke(usage: 0x24, shift: true)
        case 42: return KeyStroke(usage: 0x25, shift: true)
        case 40: return KeyStroke(usage: 0x26, shift: true)
        case 41: return KeyStroke(usage: 0x27, shift: true)
        default: return nil
        }
    }
}

private extension Character {
    var asciiValue: UInt8? {
        let bytes = Array(utf8)
        return bytes.count == 1 ? bytes[0] : nil
    }
}
