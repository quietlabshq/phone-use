import Foundation
import PhoneUseCapture
import PhoneUseCore
import PhoneUseHardware
import PhoneUseHID
import PhoneUseMCP
import PhoneUseSimulator

/// Builds the process-wide dispatcher. Exactly one process (the app, or an in-process
/// `serve`) should own one, while holding `ProcessOwnership`.
public enum Runtime {
    public static let transportFactory: @Sendable (PhoneConfig) -> (any HIDTransport)? = { _ in
        let host = ClassicHIDHost.shared
        Task { try? await host.startAdvertising() }
        return host
    }

    public static func dispatcher(simulator: Bool = true, hardware: Bool = true,
                                  axe: String = defaultAXe) -> ToolDispatcher {
        var registries: [any PhoneRegistry] = []
        if simulator { registries.append(SimulatorRegistry(axe: axe)) }
        if hardware { registries.append(HardwareRegistry(loadConfig: { try Config.load() }, transportFor: transportFactory)) }
        return ToolDispatcher(registry: CombinedRegistry(registries), imageEncoder: CoreGraphicsFrameJPEGEncoder())
    }

    public static var defaultAXe: String { ProcessInfo.processInfo.environment["PHONE_USE_AXE"] ?? "axe" }

    /// Advertises the Bluetooth HID service when any hardware phone is configured, so
    /// paired iPhones can reconnect before the first action.
    public static func startHIDIfConfigured() async throws {
        guard let config = try? Config.load(), !config.phones.isEmpty else { return }
        try await ClassicHIDHost.shared.startAdvertising()
    }
}
