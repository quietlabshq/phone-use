public enum Modifier: String, Sendable, Codable, CaseIterable {
    case control, shift, option, command
}

public enum Key: Hashable, Sendable {
    case enter, escape, backspace, tab, space, up, down, left, right
    case letter(Character)

    public init?(name: String) {
        switch name {
        case "enter": self = .enter
        case "escape": self = .escape
        case "backspace": self = .backspace
        case "tab": self = .tab
        case "space": self = .space
        case "arrow_up": self = .up
        case "arrow_down": self = .down
        case "arrow_left": self = .left
        case "arrow_right": self = .right
        default:
            guard name.utf8.count == 1, let byte = name.utf8.first, (97...122).contains(byte),
                  let character = name.first else { return nil }
            self = .letter(character)
        }
    }

    /// The name `init(name:)` accepts.
    public var name: String {
        switch self {
        case .enter: "enter"
        case .escape: "escape"
        case .backspace: "backspace"
        case .tab: "tab"
        case .space: "space"
        case .up: "arrow_up"
        case .down: "arrow_down"
        case .left: "arrow_left"
        case .right: "arrow_right"
        case let .letter(character): String(character)
        }
    }
}

public enum PhoneAction: Sendable, Equatable {
    case home
    case tap(PixelPoint, count: Int)
    case longPress(PixelPoint, milliseconds: Int)
    case swipe(from: PixelPoint, to: PixelPoint, milliseconds: Int)
    case typeText(String)
    case key(Key, modifiers: [Modifier], repeat: Int)
}
