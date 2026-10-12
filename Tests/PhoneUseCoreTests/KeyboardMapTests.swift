import Testing
@testable import PhoneUseCore

@Test func mapsAsciiLettersDigitsAndWhitespace() throws {
    let strokes = try KeyboardMap.strokes(for: "Hi! 0\n\t")
    #expect(strokes == [
        KeyStroke(usage: 0x0B, shift: true),
        KeyStroke(usage: 0x0C, shift: false),
        KeyStroke(usage: 0x1E, shift: true),
        KeyStroke(usage: 0x2C, shift: false),
        KeyStroke(usage: 0x27, shift: false),
        KeyStroke(usage: 0x28, shift: false),
        KeyStroke(usage: 0x2B, shift: false),
    ])
}

@Test func mapsAllPrintableAsciiCharacters() throws {
    let text = String((32...126).compactMap { UnicodeScalar($0).map(Character.init) })
    #expect(try KeyboardMap.strokes(for: text).count == 95)
}

@Test func mapsPunctuationToUsKeyboardUsages() throws {
    let text = "-_=+[{]}\\|;:'\"`~,<.>/?1234567890!@#$%^&*()"
    let expected: [(UInt8, Bool)] = [
        (0x2D, false), (0x2D, true), (0x2E, false), (0x2E, true),
        (0x2F, false), (0x2F, true), (0x30, false), (0x30, true),
        (0x31, false), (0x31, true), (0x33, false), (0x33, true),
        (0x34, false), (0x34, true), (0x35, false), (0x35, true),
        (0x36, false), (0x36, true), (0x37, false), (0x37, true),
        (0x38, false), (0x38, true),
        (0x1E, false), (0x1F, false), (0x20, false), (0x21, false),
        (0x22, false), (0x23, false), (0x24, false), (0x25, false),
        (0x26, false), (0x27, false),
        (0x1E, true), (0x1F, true), (0x20, true), (0x21, true),
        (0x22, true), (0x23, true), (0x24, true), (0x25, true),
        (0x26, true), (0x27, true),
    ]
    #expect(try KeyboardMap.strokes(for: text) == expected.map { KeyStroke(usage: $0.0, shift: $0.1) })
}

@Test func reportsEveryUnsupportedCharacter() {
    #expect(throws: PhoneError.unsupportedCharacters("é👍")) {
        try KeyboardMap.strokes(for: "café 👍")
    }
}

@Test func mapsNamedKeysAndModifiers() {
    #expect(KeyboardMap.usage(for: .enter) == 0x28)
    #expect(KeyboardMap.usage(for: .escape) == 0x29)
    #expect(KeyboardMap.usage(for: .backspace) == 0x2A)
    #expect(KeyboardMap.usage(for: .tab) == 0x2B)
    #expect(KeyboardMap.usage(for: .space) == 0x2C)
    #expect(KeyboardMap.usage(for: .right) == 0x4F)
    #expect(KeyboardMap.usage(for: .left) == 0x50)
    #expect(KeyboardMap.usage(for: .down) == 0x51)
    #expect(KeyboardMap.usage(for: .up) == 0x52)
    #expect(KeyboardMap.usage(for: .letter("h")) == 0x0B)
    #expect(KeyboardMap.modifierBits([.command, .shift]) == 0x0A)
    #expect(KeyboardMap.modifierBits([.control, .shift, .option, .command]) == 0x0F)
    #expect(KeyboardMap.modifierUsage(.control) == 224)
    #expect(KeyboardMap.modifierUsage(.shift) == 225)
    #expect(KeyboardMap.modifierUsage(.option) == 226)
    #expect(KeyboardMap.modifierUsage(.command) == 227)
}
