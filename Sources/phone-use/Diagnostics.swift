import ArgumentParser
import Foundation
import PhoneUseCapture
import PhoneUseCore
import PhoneUseHardware
import PhoneUseHID
import PhoneUseSimulator

struct Calibrate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Measure and save pointer gains for a connected hardware phone.")
    @Option(help: "Hardware phone ID; required when multiple hardware phones are available.") var phone: String?
    mutating func run() async throws {
        let ownership = try ProcessOwnership()
        defer { withExtendedLifetime(ownership) {} }
        var config = try Config.load()
        let result = await HardwareRegistry(config: config, transportFor: Runtime.transportFactory).discover()
        let matches = result.phones.filter { phone == nil || $0.info.id == phone }
        guard matches.count == 1, let selected = matches.first as? HardwarePhone else {
            throw ValidationError((["Select exactly one hardware phone using --phone. Available: \(result.phones.map { $0.info.id }.joined(separator: ", "))"] + result.hints).joined(separator: "\n"))
        }
        guard let index = config.phones.firstIndex(where: { $0.name == selected.info.name }) else { throw ValidationError("Selected phone has no configuration") }
        let base = config.phones[index].pointer ?? PointerGains(pixelsPerCountX: 1, pixelsPerCountY: 1)
        config.phones[index].pointer = try await selected.calibrate(base: base)
        try config.save()
        print("Saved pointer calibration for \(selected.info.name) to \(Config.defaultURL.path)")
    }
}
struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check simulator, capture, configuration, and input prerequisites.")
    mutating func run() async throws {
        var problems = false
        func report(_ ok: Bool, _ message: String) { print("\(ok ? "OK" : "FIX") \(message)"); if !ok { problems = true } }
        let axe = ProcessInfo.processInfo.environment["PHONE_USE_AXE"] ?? "axe"
        do {
            let data = try await checkedRun(LiveProcessRunner(), axe, ["--version"])
            let version = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let range = version.range(of: #"\b\d+\.\d+\.\d+\b"#, options: .regularExpression)
            let parts = range.map { version[$0].split(separator: ".").compactMap { Int($0) } } ?? []
            report(parts.count == 3 && !parts.lexicographicallyPrecedes([1, 8, 0]), "AXe \(axe): \(version); requires >= 1.8.0")
        } catch { report(false, "AXe \(axe): \(error). Set PHONE_USE_AXE to AXe >= 1.8.0.") }
        do {
            let data = try await checkedRun(LiveProcessRunner(), axe, ["tap", "--help"])
            let supported = String(decoding: data, as: UTF8.self).contains("--count")
            report(supported, supported ? "AXe native multi-tap (--count)" : "AXe native multi-tap unavailable; run scripts/build-axe.sh and set PHONE_USE_AXE to .build/tools/axe/bin/axe")
        } catch { report(false, "AXe multi-tap capability: \(error)") }
        do {
            let data = try await checkedRun(LiveProcessRunner(), "xcrun", ["simctl", "list", "devices", "booted", "-j"])
            let list = try JSONDecoder().decode(BootedDevices.self, from: data)
            let names = list.devices.values.flatMap { $0 }.filter { $0.state == "Booted" && $0.name.hasPrefix("iPhone") }.map { $0.name }
            report(!names.isEmpty, "Booted iPhones: \(names.isEmpty ? "none; boot an iPhone in Simulator" : names.joined(separator: ", "))")
        } catch { report(false, "Simulator discovery: \(error)") }
        report(Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil, "Camera usage metadata in executable")
        do {
            try ScreenCaptureDevices.enable()
            let names = CaptureSource.iPhoneDevices().map { $0.localizedName }
            report(true, "USB screen capture enabled; devices: \(names.isEmpty ? "none (connect, unlock, and trust iPhone)" : names.joined(separator: ", "))")
        } catch { report(false, "USB screen capture: \(error)") }
        do {
            let config = try Config.load()
            report(true, "Configuration: \(Config.defaultURL.path), \(config.phones.count) phones")
            for phone in config.phones {
                guard let transport = Runtime.transportFactory(phone) else { report(false, "\(phone.name): input transport not installed; USB capture and Bluetooth input are separate"); continue }
                report(await transport.isHostConnected(), "\(phone.name): input transport installed, host connection")
            }
            if config.phones.isEmpty { report(false, "No hardware phones configured; input transport not installed by default") }
        } catch { report(false, "Configuration: \(error)") }
        if problems { throw ExitCode.failure }
    }
}
private struct BootedDevices: Decodable {
    let devices: [String: [Device]]
    struct Device: Decodable { let name: String; let state: String }
}
private func checkedRun(_ runner: any ProcessRunner, _ executable: String, _ arguments: [String]) async throws -> Data {
    let result = try await runner.run(executable, arguments)
    guard result.status == 0 else {
        throw PhoneError.commandFailed("\(executable) exited \(result.status): \(String(decoding: result.stderr, as: UTF8.self))")
    }
    return result.stdout
}
