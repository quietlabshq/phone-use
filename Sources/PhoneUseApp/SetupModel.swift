import AppKit
@preconcurrency import AVFoundation
import CoreBluetooth
import Foundation
import Observation
import PhoneUseCapture
import PhoneUseCore
import PhoneUseHardware
import ServiceManagement

/// Checks and fixes everything Phone Use needs from macOS and the developer tools.
@MainActor @Observable
final class SetupModel {
    struct AXeStatus: Equatable {
        var version: String?
        var multitap = false
        var error: String?
    }

    private(set) var camera = AVCaptureDevice.authorizationStatus(for: .video)
    private(set) var bluetooth = CBManager.authorization
    private(set) var axe = AXeStatus()
    private(set) var captureDevices: [String] = []
    private(set) var configured: [PhoneConfig] = []
    private(set) var configError: String?
    private(set) var cliInstalled = false
    private(set) var loginItem = SMAppService.mainApp.status
    var actionError: String?

    @ObservationIgnored private var bluetoothProbe: CBCentralManager?

    func refresh(axePath: String) async {
        camera = AVCaptureDevice.authorizationStatus(for: .video)
        bluetooth = CBManager.authorization
        loginItem = SMAppService.mainApp.status
        cliInstalled = (try? FileManager.default.destinationOfSymbolicLink(atPath: AppPaths.installedCLI.path)) == AppPaths.bundledCLI?.path
        loadConfig()
        try? ScreenCaptureDevices.enable()
        // Devices appear shortly after enabling screen capture devices.
        for _ in 0..<10 {
            captureDevices = CaptureSource.iPhoneDevices().map(\.localizedName).sorted()
            if !captureDevices.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        axe = await Self.checkAXe(axePath)
    }

    private func loadConfig() {
        do { configured = try Config.load().phones; configError = nil }
        catch { configured = []; configError = String(describing: error) }
    }

    private static func checkAXe(_ path: String) async -> AXeStatus {
        let runner = LiveProcessRunner()
        do {
            let version = try await runner.run(path, ["--version"])
            guard version.status == 0 else { return AXeStatus(error: String(decoding: version.stderr, as: UTF8.self)) }
            let help = try await runner.run(path, ["tap", "--help"])
            return AXeStatus(version: String(decoding: version.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                             multitap: String(decoding: help.stdout, as: UTF8.self).contains("--count"))
        } catch {
            return AXeStatus(error: String(describing: error))
        }
    }

    func requestCamera() async {
        _ = await AVCaptureDevice.requestAccess(for: .video)
        camera = AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// Creating a manager is what makes macOS ask for Bluetooth access.
    func requestBluetooth() {
        bluetoothProbe = CBCentralManager()
        Task {
            for _ in 0..<50 where CBManager.authorization == .notDetermined { try? await Task.sleep(for: .milliseconds(200)) }
            bluetooth = CBManager.authorization
        }
    }

    func openPrivacySettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }

    func configure(device: String) {
        mutateConfig { $0.phones.append(PhoneConfig(name: device, captureDeviceName: device)) }
    }

    func remove(_ phone: PhoneConfig) {
        mutateConfig { $0.phones.removeAll { $0 == phone } }
    }

    private func mutateConfig(_ change: (inout Config) -> Void) {
        do {
            var config = try Config.load()
            change(&config)
            try config.save()
            actionError = nil
        } catch {
            actionError = "Could not update \(Config.defaultURL.path): \(error)"
        }
        loadConfig()
    }

    func installCLI() {
        guard let bundled = AppPaths.bundledCLI else { actionError = "This build of Phone Use does not contain the phone-use tool."; return }
        let target = AppPaths.installedCLI
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) != nil {
                try FileManager.default.removeItem(at: target)
            } else if FileManager.default.fileExists(atPath: target.path) {
                actionError = "\(target.path) already exists and is not a link. Move it aside, then install again."
                return
            }
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: bundled)
            cliInstalled = true
            actionError = nil
        } catch {
            actionError = "Could not install \(target.path): \(error.localizedDescription)"
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            actionError = nil
        } catch {
            actionError = "Could not change Launch at Login: \(error.localizedDescription)"
        }
        loginItem = SMAppService.mainApp.status
    }
}
