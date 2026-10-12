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
}

public enum PhoneAction: Sendable, Equatable {
    case home
    case tap(PixelPoint, count: Int)
    case longPress(PixelPoint, milliseconds: Int)
    case swipe(from: PixelPoint, to: PixelPoint, milliseconds: Int)
    case typeText(String)
    case key(Key, modifiers: [Modifier], repeat: Int)
}
