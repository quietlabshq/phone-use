import Foundation

enum AppPaths {
    static let axeOverrideKey = "axePath"

    /// The AXe used for simulators: a Setup override, the copy bundled in the app,
    /// `PHONE_USE_AXE`, then Homebrew. Apps launched from Finder have no shell PATH.
    static func axe() -> String {
        if let override = UserDefaults.standard.string(forKey: axeOverrideKey), !override.isEmpty { return override }
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/axe/axe").path,
            ProcessInfo.processInfo.environment["PHONE_USE_AXE"],
            "/opt/homebrew/bin/axe", "/usr/local/bin/axe",
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "axe"
    }

    static var bundledCLI: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/phone-use")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static var installedCLI: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/phone-use")
    }
}
