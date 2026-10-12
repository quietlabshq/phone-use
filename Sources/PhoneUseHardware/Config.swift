import Foundation
import PhoneUseCore
import PhoneUseHID

public struct PhoneConfig: Codable, Sendable, Equatable {
    public var name: String
    public var captureDeviceName: String
    public var pointer: PointerGains?
    public init(name: String, captureDeviceName: String, pointer: PointerGains? = nil) {
        self.name = name; self.captureDeviceName = captureDeviceName; self.pointer = pointer
    }
}
public struct Config: Codable, Sendable, Equatable {
    public var phones: [PhoneConfig]
    public init(phones: [PhoneConfig] = []) { self.phones = phones }
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/phone-use/config.json")
    }
    public func validate() throws {
        var names = Set<String>()
        var captureNames = Set<String>()
        for phone in phones {
            guard !phone.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !phone.captureDeviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  names.insert(phone.name).inserted, captureNames.insert(phone.captureDeviceName).inserted else {
                throw PhoneError.commandFailed("Config requires unique, nonempty phone names and nonempty capture device names")
            }
            try phone.pointer?.validate()
        }
    }
    public static func load(from url: URL = defaultURL) throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
        let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
        try config.validate()
        return config
    }
    public func save(to url: URL = defaultURL) throws {
        try validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
