public enum Macros {
    public static func home(on phone: any Phone, sleeper: any Sleeper) async throws {
        try await phone.perform(.home)
        try await sleeper.sleep(milliseconds: 800)
    }

    public static func openApp(_ name: String, on phone: any Phone, sleeper: any Sleeper) async throws {
        _ = try KeyboardMap.strokes(for: name)
        try await home(on: phone, sleeper: sleeper)
        try await phone.perform(.key(.space, modifiers: [.command], repeat: 1))
        try await sleeper.sleep(milliseconds: 800)
        try await phone.perform(.typeText(name))
        try await sleeper.sleep(milliseconds: 800)
        try await phone.perform(.key(.enter, modifiers: [], repeat: 1))
        try await sleeper.sleep(milliseconds: 800)
    }
}
