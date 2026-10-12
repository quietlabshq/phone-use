import PhoneUseCore

public enum KeyboardDriver {
    public static func type(_ text: String, keyIntervalMs: Int = 12) throws -> [TimedReport] {
        try KeyboardMap.strokes(for: text).flatMap {
            pair(usage: $0.usage, modifiers: $0.shift ? 2 : 0, interval: keyIntervalMs)
        }
    }

    public static func key(_ key: Key, modifiers: [Modifier] = [], repeat count: Int = 1, keyIntervalMs: Int = 12) -> [TimedReport] {
        precondition((0...1000).contains(count))
        return (0..<count).flatMap { _ in
            pair(usage: KeyboardMap.usage(for: key), modifiers: KeyboardMap.modifierBits(modifiers), interval: keyIntervalMs)
        }
    }

    public static func home() -> [TimedReport] {
        let shortcuts: [(Key, [Modifier])] = [(.letter("h"), [.command]), (.escape, []), (.escape, [])]
        return shortcuts.flatMap { key, modifiers in
            pair(usage: KeyboardMap.usage(for: key), modifiers: KeyboardMap.modifierBits(modifiers),
                 interval: 12, releaseInterval: 800)
        }
    }

    private static func pair(usage: UInt8, modifiers: UInt8, interval: Int, releaseInterval: Int? = nil) -> [TimedReport] {
        precondition(interval >= 0)
        return [TimedReport(report: .keyboard(KeyboardReport(modifiers: modifiers, keys: [usage])), delayAfterMs: interval),
                TimedReport(report: .keyboard(.empty), delayAfterMs: releaseInterval ?? interval)]
    }
}
