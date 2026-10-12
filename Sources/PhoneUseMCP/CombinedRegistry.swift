import PhoneUseCore

public struct CombinedRegistry: PhoneRegistry {
    private let registries: [any PhoneRegistry]
    public init(_ registries: [any PhoneRegistry]) { self.registries = registries }
    public func discover() async -> (phones: [any Phone], hints: [String]) {
        var phones: [any Phone] = []
        var hints: [String] = []
        for registry in registries {
            let result = await registry.discover()
            phones.append(contentsOf: result.phones)
            hints.append(contentsOf: result.hints)
        }
        return (phones, hints)
    }
}
