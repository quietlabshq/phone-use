@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import PhoneUseCapture
import PhoneUseCore
import PhoneUseHID

struct CaptureCandidate: Sendable {
    let id: String
    let name: String
    let size: PixelSize
    let capture: @Sendable () async throws -> CGImage
    var frames: (@Sendable () async throws -> AsyncStream<CGImage>)? = nil
}

public struct HardwareRegistry: PhoneRegistry {
    private let state: RegistryState
    public init(config: Config, transportFor: @escaping @Sendable (PhoneConfig) -> (any HIDTransport)? = { _ in nil }) {
        self.init(loadConfig: { config }, transportFor: transportFor)
    }
    /// Reloads the configuration on every discovery, so newly configured phones appear
    /// without restarting the process.
    public init(loadConfig: @escaping @Sendable () throws -> Config, transportFor: @escaping @Sendable (PhoneConfig) -> (any HIDTransport)? = { _ in nil }) {
        state = RegistryState(loadConfig: loadConfig, transportFor: transportFor, candidates: Self.liveCandidates)
    }
    init(config: Config, candidates: @escaping @Sendable () async throws -> [CaptureCandidate]) {
        self.init(loadConfig: { config }, candidates: candidates)
    }
    init(loadConfig: @escaping @Sendable () throws -> Config, candidates: @escaping @Sendable () async throws -> [CaptureCandidate]) {
        state = RegistryState(loadConfig: loadConfig, transportFor: { _ in nil }, candidates: candidates)
    }
    public func discover() async -> (phones: [any Phone], hints: [String]) { await state.discover() }

    private static func liveCandidates() async throws -> [CaptureCandidate] {
        try ScreenCaptureDevices.enable()
        let deadline = ContinuousClock.now + .seconds(2)
        var devices = CaptureSource.iPhoneDevices()
        while devices.isEmpty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            devices = CaptureSource.iPhoneDevices()
        }
        return devices.map { device in
            let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            let lazy = LazyCapture(device: device)
            return CaptureCandidate(id: device.uniqueID, name: device.localizedName,
                                    size: PixelSize(width: max(1, Int(dimensions.width)), height: max(1, Int(dimensions.height))),
                                    capture: { try await lazy.frame() }, frames: { try await lazy.frames() })
        }
    }
}

private actor LazyCapture {
    let device: AVCaptureDevice
    var source: CaptureSource?
    init(device: AVCaptureDevice) { self.device = device }
    func frame() async throws -> CGImage {
        if source == nil { source = try CaptureSource(device: device) }
        return try await source!.latestFrame()
    }
    func frames() async throws -> AsyncStream<CGImage> {
        if source == nil { source = try CaptureSource(device: device) }
        return try await source!.frameStream()
    }
}

private actor RegistryState {
    let loadConfig: @Sendable () throws -> Config
    let transportFor: @Sendable (PhoneConfig) -> (any HIDTransport)?
    let candidates: @Sendable () async throws -> [CaptureCandidate]
    var cached: [String: (config: PhoneConfig, phone: HardwarePhone)] = [:]
    init(loadConfig: @escaping @Sendable () throws -> Config, transportFor: @escaping @Sendable (PhoneConfig) -> (any HIDTransport)?,
         candidates: @escaping @Sendable () async throws -> [CaptureCandidate]) {
        self.loadConfig = loadConfig; self.transportFor = transportFor; self.candidates = candidates
    }
    func discover() async -> (phones: [any Phone], hints: [String]) {
        do {
            let config = try loadConfig()
            try config.validate()
            let available = try await candidates()
            var phones: [any Phone] = []
            var hints: [String] = []
            var retained: [String: (config: PhoneConfig, phone: HardwarePhone)] = [:]
            for configured in config.phones {
                let matches = available.filter { $0.name == configured.captureDeviceName }
                guard matches.count == 1, let device = matches.first else {
                    hints.append(matches.isEmpty ? "\(configured.name): USB capture device '\(configured.captureDeviceName)' is missing. Unlock, trust, and connect the iPhone." : "\(configured.name): multiple USB devices match '\(configured.captureDeviceName)'. Give each iPhone a unique name.")
                    continue
                }
                let id = "hardware:\(device.id)"
                // Reuse only an unchanged phone: it keeps capture and pointer state across discoveries.
                let reusable = cached[id].flatMap { $0.config == configured ? $0.phone : nil }
                let phone = reusable ?? HardwarePhone(info: PhoneInfo(id: id, name: configured.name, kind: .hardware, screenSize: device.size), capture: device.capture,
                                                      frames: device.frames, transport: transportFor(configured) ?? UnavailableTransport(), gains: configured.pointer)
                retained[id] = (configured, phone)
                phones.append(phone)
            }
            for device in available where !config.phones.contains(where: { $0.captureDeviceName == device.name }) {
                hints.append("USB device '\(device.name)' is unconfigured. Add its captureDeviceName to \(Config.defaultURL.path).")
            }
            cached = retained
            return (phones, hints)
        } catch {
            return ([], [String(describing: error)])
        }
    }
}
