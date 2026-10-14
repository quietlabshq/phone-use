import AppKit
import AVFoundation
import CoreBluetooth
import PhoneUseHardware
import PhoneUseHID
import PhoneUseIPC
import ServiceManagement
import SwiftUI

struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var setup = SetupModel()
    @State private var axeOverride = UserDefaults.standard.string(forKey: AppPaths.axeOverrideKey) ?? ""

    var body: some View {
        Form {
            if case let .failed(message) = model.hostState {
                Section {
                    StatusRow(ok: false, title: "Not serving agents", detail: message)
                }
            }
            if let error = setup.actionError {
                Section { StatusRow(ok: false, title: "Something went wrong", detail: error) }
            }

            Section("Permissions") {
                StatusRow(ok: setup.camera == .authorized, title: "Camera",
                          detail: "Reads the screen of USB-connected iPhones. \(describe(setup.camera))") {
                    if setup.camera == .notDetermined {
                        Button("Allow...") { Task { await setup.requestCamera() } }
                    } else if setup.camera != .authorized {
                        Button("Open Settings") { setup.openPrivacySettings("Privacy_Camera") }
                    }
                }
                StatusRow(ok: setup.bluetooth == .allowedAlways, title: "Bluetooth",
                          detail: "Acts as a keyboard and mouse for paired iPhones. \(describe(setup.bluetooth))") {
                    if setup.bluetooth == .notDetermined {
                        Button("Allow...") { setup.requestBluetooth() }
                    } else if setup.bluetooth != .allowedAlways {
                        Button("Open Settings") { setup.openPrivacySettings("Privacy_Bluetooth") }
                    }
                }
            }

            Section("Physical iPhones") {
                if let status = model.hidStatus {
                    StatusRow(ok: status.connected, title: "Bluetooth HID",
                              detail: status.error ?? (status.connected
                                ? "An iPhone is connected to \(HIDSDPRecord.serviceName)."
                                : status.advertising
                                    ? "Advertising as \(HIDSDPRecord.serviceName). On the iPhone, open Settings > Bluetooth and connect to it, then turn on AssistiveTouch."
                                    : "Starts once an iPhone is configured below."))
                }
                if setup.captureDevices.isEmpty {
                    StatusRow(ok: false, title: "No USB iPhone screens",
                              detail: "Connect the iPhone with a cable, unlock it, and trust this Mac. If it still does not appear, unplug and reconnect it.")
                }
                ForEach(setup.captureDevices, id: \.self) { device in
                    let configured = setup.configured.first { $0.captureDeviceName == device }
                    StatusRow(ok: configured != nil, title: device,
                              detail: configured != nil ? "Configured as \(configured!.name)." : "Not configured yet. Agents cannot use it until you add it.") {
                        if let configured {
                            Button("Remove") { setup.remove(configured); refreshPhones() }
                        } else {
                            Button("Add") { setup.configure(device: device); refreshPhones() }
                        }
                    }
                }
                ForEach(setup.configured.filter { !setup.captureDevices.contains($0.captureDeviceName) }, id: \.captureDeviceName) { phone in
                    StatusRow(ok: false, title: phone.name, detail: "Configured, but its USB screen '\(phone.captureDeviceName)' is not connected.") {
                        Button("Remove") { setup.remove(phone); refreshPhones() }
                    }
                }
                if let error = setup.configError {
                    StatusRow(ok: false, title: "Configuration", detail: error)
                }
            }

            Section("Simulators") {
                StatusRow(ok: setup.axe.version != nil && setup.axe.multitap, title: "AXe",
                          detail: axeDetail)
                TextField("AXe path override", text: $axeOverride, prompt: Text(model.axePath))
                    .onSubmit { UserDefaults.standard.set(axeOverride, forKey: AppPaths.axeOverrideKey) }
                if AppPaths.axe() != model.axePath {
                    Text("Quit and reopen Phone Use to use \(AppPaths.axe()).").foregroundStyle(.secondary)
                }
            }

            Section("Agents") {
                StatusRow(ok: setup.cliInstalled, title: "Command-line tool",
                          detail: setup.cliInstalled ? "Installed at \(AppPaths.installedCLI.path)." : "Link phone-use into \(AppPaths.installedCLI.deletingLastPathComponent().path) so agents and shells can run it.") {
                    if !setup.cliInstalled, AppPaths.bundledCLI != nil { Button("Install") { setup.installCLI() } }
                }
                LabeledContent("MCP server") {
                    HStack {
                        Text(mcpCommand).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(mcpCommand, forType: .string)
                        }
                    }
                }
                LabeledContent("Socket", value: HostPaths.socket.path)
                Toggle("Launch at login", isOn: Binding(
                    get: { setup.loginItem == .enabled },
                    set: { setup.setLaunchAtLogin($0) }))
            }

            if !model.hints.isEmpty {
                Section("Discovery hints") {
                    ForEach(model.hints, id: \.self) { Text($0).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Setup")
        .toolbar {
            Button { Task { await setup.refresh(axePath: model.axePath) } } label: { Label("Check again", systemImage: "arrow.triangle.2.circlepath") }
        }
        .task { await setup.refresh(axePath: model.axePath) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await setup.refresh(axePath: model.axePath) }
        }
    }

    private var mcpCommand: String {
        "\(setup.cliInstalled ? AppPaths.installedCLI.path : (AppPaths.bundledCLI?.path ?? "phone-use")) mcp"
    }

    private var axeDetail: String {
        if let error = setup.axe.error { return "\(model.axePath): \(error)" }
        guard let version = setup.axe.version else { return "Checking \(model.axePath)..." }
        return setup.axe.multitap
            ? "\(version) at \(model.axePath), with native double and triple taps."
            : "\(version) at \(model.axePath). Double and triple taps need the patched build from scripts/build-axe.sh."
    }

    private func refreshPhones() { Task { await model.refresh() } }

    private func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: "Allowed."
        case .notDetermined: "Not requested yet."
        case .denied: "Denied in System Settings."
        case .restricted: "Restricted by a profile."
        @unknown default: "Unknown."
        }
    }

    private func describe(_ status: CBManagerAuthorization) -> String {
        switch status {
        case .allowedAlways: "Allowed."
        case .notDetermined: "Not requested yet."
        case .denied: "Denied in System Settings."
        case .restricted: "Restricted by a profile."
        @unknown default: "Unknown."
        }
    }
}

private struct StatusRow<Actions: View>: View {
    let ok: Bool
    let title: String
    let detail: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            actions()
        }
    }
}

extension StatusRow where Actions == EmptyView {
    init(ok: Bool, title: String, detail: String) {
        self.init(ok: ok, title: title, detail: detail) { EmptyView() }
    }
}
