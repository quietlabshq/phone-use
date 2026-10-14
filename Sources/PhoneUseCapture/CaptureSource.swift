@preconcurrency import AVFoundation
import CoreMediaIO
import CoreImage
import Foundation
import PhoneUseCore

public enum ScreenCaptureDevices {
    public static func enable() throws {
        var address = CMIOObjectPropertyAddress(mSelector: UInt32(kCMIOHardwarePropertyAllowScreenCaptureDevices),
                                               mScope: UInt32(kCMIOObjectPropertyScopeGlobal), mElement: UInt32(kCMIOObjectPropertyElementMain))
        var value: UInt32 = 1
        let status = CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil,
                                              UInt32(MemoryLayout.size(ofValue: value)), &value)
        guard status == 0 else { throw PhoneError.commandFailed("Could not enable USB screen capture (CoreMediaIO \(status))") }
    }
}

/// Continuous frames for a live view. Streams keep only the newest frame so a slow
/// consumer never falls behind the device.
public protocol LiveFrameSource: Sendable {
    func liveFrames() async throws -> AsyncStream<CGImage>
}

final class FrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var image: CGImage?
    private var subscribers: [UUID: AsyncStream<CGImage>.Continuation] = [:]
    var version: UInt64 { lock.withLock { generation } }
    var subscriberCount: Int { lock.withLock { subscribers.count } }
    func publish(_ image: CGImage) {
        let targets = lock.withLock { () -> [AsyncStream<CGImage>.Continuation] in
            self.image = image; generation &+= 1
            return Array(subscribers.values)
        }
        for target in targets { target.yield(image) }
    }
    func frame(after version: UInt64) -> CGImage? { lock.withLock { generation != version ? image : nil } }
    func subscribe() -> AsyncStream<CGImage> {
        let (stream, continuation) = AsyncStream.makeStream(of: CGImage.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        continuation.onTermination = { [weak self] _ in self?.lock.withLock { _ = self?.subscribers.removeValue(forKey: id) } }
        let current = lock.withLock { subscribers[id] = continuation; return image }
        if let current { continuation.yield(current) }
        return stream
    }
}

public final class CaptureSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "phone-use.capture.session")
    private let frames = FrameStore()
    private let context = CIContext()
    private let output = AVCaptureVideoDataOutput()

    public static func iPhoneDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified).devices
    }
    public init(device: AVCaptureDevice) throws {
        super.init()
        // AVCaptureDeviceInput can trigger TCC. Refuse early if the embedding executable lacks metadata.
        guard Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil else {
            throw PhoneError.commandFailed("Camera usage metadata missing. Run Phone Use.app or the packaged phone-use executable.")
        }
        try Self.checkAuthorization(AVCaptureDevice.authorizationStatus(for: .video))
        try queue.sync {
            let input: AVCaptureDeviceInput
            do {
                input = try AVCaptureDeviceInput(device: device)
            } catch {
                throw PhoneError.commandFailed("Could not open iPhone capture. Unlock the iPhone and trust this Mac; enable Phone Use in System Settings > Privacy & Security > Camera. Details: \(error.localizedDescription)")
            }
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            guard session.canAddInput(input), session.canAddOutput(output) else {
                throw PhoneError.commandFailed("Cannot capture this iPhone. Unlock it and trust this Mac.")
            }
            session.addInput(input)
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "phone-use.capture.frames"))
            session.addOutput(output)
        }
    }
    static func checkAuthorization(_ status: AVAuthorizationStatus) throws {
        if status == .denied || status == .restricted {
            throw PhoneError.commandFailed("Camera access denied. Enable Phone Use in System Settings > Privacy & Security > Camera.")
        }
    }
    private func start() async throws {
        let authorization = AVCaptureDevice.authorizationStatus(for: .video)
        try Self.checkAuthorization(authorization)
        if authorization == .notDetermined {
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                throw PhoneError.commandFailed("Camera access denied. Enable Phone Use in System Settings > Privacy & Security > Camera.")
            }
        }
        queue.async { [self] in if !session.isRunning { session.startRunning() } }
    }
    /// Every captured frame, starting with the most recent one.
    public func frameStream() async throws -> AsyncStream<CGImage> {
        let stream = frames.subscribe()
        try await start()
        return stream
    }
    public func latestFrame(timeoutMs: Int = 3000) async throws -> CGImage {
        guard timeoutMs > 0 else { throw PhoneError.commandFailed("Capture timeout must be positive") }
        let version = frames.version
        try await start()
        let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let image = frames.frame(after: version) { return image }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PhoneError.commandFailed("Timed out waiting for a fresh iPhone frame. Unlock the iPhone, trust this Mac, and reconnect USB.")
    }
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        if let cgImage = context.createCGImage(image, from: image.extent) { frames.publish(cgImage) }
    }
    deinit {
        let session = session
        let output = output
        queue.async {
            output.setSampleBufferDelegate(nil, queue: nil)
            if session.isRunning { session.stopRunning() }
        }
    }
}
