import ArgumentParser
import Foundation
import PhoneUseCore
import PhoneUseHardware
import PhoneUseHID
import PhoneUseMCP
import PhoneUseSimulator
import PhoneUseCapture

struct BackendOptions: ParsableArguments {
    @Flag(help: "Discover simulators (both backends when neither flag is given).") var simulator = false
    @Flag(help: "Discover configured USB hardware phones.") var hardware = false
    var usesSimulator: Bool { simulator || !hardware }
    var usesHardware: Bool { hardware || !simulator }
}
struct ActionOptions: ParsableArguments {
    @Option(help: "Phone ID from list; optional when exactly one phone is available.") var phone: String?
    @OptionGroup var backend: BackendOptions
    func call(_ name: String, _ arguments: [String: ToolArg] = [:], output: String? = nil) async throws {
        let ownership = try ProcessOwnership()
        defer { withExtendedLifetime(ownership) {} }
        var arguments = arguments
        if let phone { arguments["phone_id"] = .string(phone) }
        switch await Runtime.dispatcher(backend).call(name, arguments) {
        case let .text(message): print(message)
        case let .error(message): throw ValidationError(message)
        case let .jpeg(data, note):
            guard let output else { throw ValidationError("Screenshot requires --output") }
            try data.write(to: URL(fileURLWithPath: output), options: .atomic)
            print("Saved \(output). \(note)")
        }
    }
}
enum Runtime {
    static let transportFactory: @Sendable (PhoneConfig) -> (any HIDTransport)? = { _ in
        let host = ClassicHIDHost.shared
        Task { try? await host.startAdvertising() }
        return host
    }
    static func dispatcher(_ options: BackendOptions) -> ToolDispatcher {
        var registries: [any PhoneRegistry] = []
        if options.usesSimulator { registries.append(SimulatorRegistry()) }
        if options.usesHardware {
            do {
                let config = try Config.load()
                registries.append(HardwareRegistry(config: config, transportFor: transportFactory))
                if let phone = config.phones.first { _ = transportFactory(phone) }
            } catch { registries.append(FailedRegistry(message: "Hardware configuration: \(error)")) }
        }
        return ToolDispatcher(registry: CombinedRegistry(registries), imageEncoder: CoreGraphicsFrameJPEGEncoder())
    }
}
private struct FailedRegistry: PhoneRegistry {
    let message: String
    func discover() async -> (phones: [any Phone], hints: [String]) { ([], [message]) }
}
