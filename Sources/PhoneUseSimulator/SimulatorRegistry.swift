import Foundation
import PhoneUseCore

public struct SimulatorRegistry: PhoneRegistry {
    private let axe: String
    private let runner: any ProcessRunner

    public init(axe: String = ProcessInfo.processInfo.environment["PHONE_USE_AXE"] ?? "axe",
                runner: any ProcessRunner = LiveProcessRunner()) {
        self.axe = axe
        self.runner = runner
    }

    public func discover() async -> (phones: [any Phone], hints: [String]) {
        do {
            let output = try await checkedRun(runner, axe, ["--version"])
            guard supportedVersion(String(decoding: output, as: UTF8.self)) else { throw PhoneError.toolUnavailable(axe) }
        } catch {
            return ([], ["AXe >= 1.8.0 is required (set PHONE_USE_AXE)"])
        }
        do {
            let data = try await checkedRun(runner, "xcrun", ["simctl", "list", "devices", "booted", "-j"])
            let list = try JSONDecoder().decode(DeviceList.self, from: data)
            let devices = list.devices.values.flatMap { $0 }.filter { $0.name.hasPrefix("iPhone") && $0.state == "Booted" }
                .sorted { $0.udid < $1.udid }
            guard !devices.isEmpty else { return ([], ["No booted iPhone simulator found. Boot one with: xcrun simctl boot <udid>"]) }
            var phones: [any Phone] = []
            var hints: [String] = []
            for device in devices {
                do {
                    let image = try await simulatorScreenshot(udid: device.udid, runner: runner)
                    let ui = try await checkedRun(runner, axe, ["describe-ui", "--udid", device.udid])
                    let roots = try JSONDecoder().decode([Root].self, from: ui)
                    guard let width = roots.first?.frame.width, width.isFinite, width > 0 else {
                        throw PhoneError.commandFailed("AXe returned an invalid root frame width")
                    }
                    let scale = Double(image.width) / width
                    guard scale.isFinite, scale > 0 else { throw PhoneError.commandFailed("Invalid simulator point scale") }
                    phones.append(SimulatorPhone(udid: device.udid, name: device.name,
                        screenSize: .init(width: image.width, height: image.height), pointScale: scale, axe: axe, runner: runner))
                } catch {
                    hints.append("Could not discover \(device.name) (\(device.udid)): \(error)")
                }
            }
            return (phones, hints)
        } catch {
            return ([], ["Could not list booted iPhone simulators: \(error)"])
        }
    }
}

private struct DeviceList: Decodable {
    let devices: [String: [Device]]
    struct Device: Decodable { let name: String; let udid: String; let state: String }
}
private struct Root: Decodable {
    let frame: Frame
    struct Frame: Decodable { let width: Double }
}
private func supportedVersion(_ output: String) -> Bool {
    guard let range = output.range(of: #"\b\d+\.\d+\.\d+\b"#, options: .regularExpression) else { return false }
    let parts = output[range].split(separator: ".").compactMap { Int($0) }
    guard parts.count == 3 else { return false }
    return !parts.lexicographicallyPrecedes([1, 8, 0])
}
