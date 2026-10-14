import AppKit
import AVFoundation
import CoreBluetooth
import PhoneUseHardware
import PhoneUseHID
import SwiftUI

/// A checklist of everything Phone Use needs, with the fix next to each item.
struct SetupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            ProgressSection()
            ProblemsSection()
            PermissionsSection()
            ForEach(model.setup.configured, id: \.captureDeviceName) { phone in
                ConfiguredPhoneSection(phone: phone)
            }
            AddPhoneSection()
            SimulatorsSection()
            AgentsSection()
            if !model.hints.isEmpty {
                Section("Discovery Hints") {
                    ForEach(model.hints, id: \.self) { hint in
                        Text(hint).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Setup")
        .toolbar {
            Button("Check Again", systemImage: "arrow.clockwise", action: checkAgain)
                .keyboardShortcut("r")
                .help("Check everything again (⌘R)")
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async { await model.setup.refresh(axePath: model.axePath) }

    private func checkAgain() {
        Task {
            await refresh()
            await model.refresh()
        }
    }
}

private struct ProgressSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let progress = model.setupProgress
        let todo = progress.total - progress.done
        Section {
            ProgressView(value: Double(progress.done), total: Double(max(1, progress.total))) {
                Text(todo == 0 ? "Everything is ready" : "\(todo) to do")
            } currentValueLabel: {
                Text("\(progress.done) of \(progress.total) ready")
            }
            .tint(.green)
        }
    }
}

private struct ProblemsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let messages = [hostFailure, model.setup.actionError, model.setup.configError.map { "Configuration: \($0)" }].compactMap { $0 }
        if !messages.isEmpty {
            Section {
                ForEach(messages, id: \.self) { message in
                    Label {
                        Text(message).textSelection(.enabled)
                    } icon: {
                        CheckMark(state: .problem)
                    }
                }
            }
        }
    }

    private var hostFailure: String? {
        if case let .failed(message) = model.hostState { "Not serving agents. \(message)" } else { nil }
    }
}

private struct PermissionsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let setup = model.setup
        Section {
            CheckRow(state: setup.camera == .authorized ? .done : setup.camera == .notDetermined ? .todo : .problem,
                     title: "Camera Access",
                     detail: "Lets Phone Use read the screen of iPhones plugged in over USB.\(note(setup.camera))") {
                switch setup.camera {
                case .authorized: Text("Allowed").foregroundStyle(.secondary)
                case .notDetermined: Button("Allow…", action: requestCamera)
                default: Button("Open System Settings…", action: openCameraSettings)
                }
            }
            CheckRow(state: setup.bluetooth == .allowedAlways ? .done : setup.bluetooth == .notDetermined ? .todo : .problem,
                     title: "Bluetooth",
                     detail: "Acts as a keyboard and pointer for paired iPhones.\(note(setup.bluetooth))") {
                switch setup.bluetooth {
                case .allowedAlways: Text("Allowed").foregroundStyle(.secondary)
                case .notDetermined: Button("Allow…", action: setup.requestBluetooth)
                default: Button("Open System Settings…", action: openBluetoothSettings)
                }
            }
        } header: {
            Text("This Mac")
        }
    }

    private func requestCamera() { Task { await model.setup.requestCamera() } }
    private func openCameraSettings() { model.setup.openPrivacySettings("Privacy_Camera") }
    private func openBluetoothSettings() { model.setup.openPrivacySettings("Privacy_Bluetooth") }

    private func note(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .restricted: " Restricted by a profile."
        case .denied: " Denied; allow it in System Settings."
        default: ""
        }
    }

    private func note(_ status: CBManagerAuthorization) -> String {
        switch status {
        case .restricted: " Restricted by a profile."
        case .denied: " Denied; allow it in System Settings."
        default: ""
        }
    }
}

/// A configured iPhone with its screen, input, and AssistiveTouch checks.
private struct ConfiguredPhoneSection: View {
    @Environment(AppModel.self) private var model
    let phone: PhoneConfig
    @State private var confirmingRemoval = false

    var body: some View {
        let screen = model.setup.captureDevices.contains(phone.captureDeviceName)
        let input = model.inputConnected(for: phone)
        Section {
            CheckRow(state: screen ? .done : .problem, title: "Screen over USB",
                     detail: screen ? "Capturing “\(phone.captureDeviceName)”." : "Plug in, unlock, and tap Trust. Still missing? Replug the cable.")
            CheckRow(state: input == true ? .done : .problem, title: "Input over Bluetooth",
                     detail: input == true ? "Paired as “\(HIDSDPRecord.serviceName)”." : "On the iPhone: Settings › Bluetooth › \(HIDSDPRecord.serviceName).")
            CheckRow(state: .info, title: "AssistiveTouch",
                     detail: "Must be on for pointer taps: Settings › Accessibility › Touch › AssistiveTouch.")
        } header: {
            HStack {
                Label(phone.name, systemImage: "iphone")
                Text(!screen ? "Screen not connected" : input != true ? "Input not connected" : "Ready")
                    .foregroundStyle(!screen ? .red : input != true ? .orange : .green)
                Spacer()
                Button("Remove…", action: confirmRemoval)
                    .buttonStyle(.link)
            }
        }
        .confirmationDialog("Remove \(phone.name)?", isPresented: $confirmingRemoval) {
            Button("Remove", role: .destructive, action: remove)
        } message: {
            Text("Agents can no longer use this iPhone. You can add it again while it is plugged in.")
        }
    }

    private func confirmRemoval() { confirmingRemoval = true }

    private func remove() {
        model.setup.remove(phone)
        Task { await model.refresh() }
    }
}

/// Plugged-in iPhones that are not added yet, and how to pair a new one.
private struct AddPhoneSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let setup = model.setup
        let unconfigured = setup.captureDevices.filter { device in !setup.configured.contains { $0.captureDeviceName == device } }
        Section {
            ForEach(unconfigured, id: \.self) { device in
                CheckRow(state: .todo, title: device, detail: "Connected over USB but not added yet. Agents cannot use it until you add it.") {
                    Button("Add") { add(device) }
                }
            }
            LabeledContent {
                Text(hidStatus).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            } label: {
                Label {
                    Text("Bluetooth input")
                } icon: {
                    StatusDot(color: hidColor, pulsing: model.hidStatus?.advertising == true && model.hidStatus?.connected != true)
                }
            }
            Step(number: 1, title: "Pair over Bluetooth", detail: "On the iPhone: Settings › Bluetooth › \(HIDSDPRecord.serviceName).")
            Step(number: 2, title: "Turn on AssistiveTouch", detail: "Settings › Accessibility › Touch › AssistiveTouch.")
            Step(number: 3, title: "Plug in the cable", detail: "Unlock the phone, tap Trust when asked, then click Add.")
        } header: {
            Text("Add an iPhone")
        } footer: {
            SectionNote("Screen over USB, input over Bluetooth. Nothing is installed on the phone.")
        }
    }

    private func add(_ device: String) {
        model.setup.configure(device: device)
        Task { await model.refresh() }
    }

    private var hidColor: Color {
        guard let status = model.hidStatus else { return .gray }
        if status.error != nil { return .red }
        return status.connected ? .green : status.advertising ? .blue : .gray
    }

    private var hidStatus: String {
        guard let status = model.hidStatus else { return "Checking Bluetooth…" }
        if let error = status.error { return error }
        if status.connected { return "An iPhone is connected to “\(HIDSDPRecord.serviceName)”" }
        if status.advertising { return "Advertising as “\(HIDSDPRecord.serviceName)”" }
        return "Starts once an iPhone is added"
    }

    private struct Step: View {
        let number: Int
        let title: String
        let detail: String

        var body: some View {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "\(number).circle")
                    .foregroundStyle(.blue)
            }
        }
    }
}

private struct SimulatorsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let setup = model.setup
        Section {
            CheckRow(state: setup.axe.error != nil ? .problem : setup.axe.version == nil ? .todo : setup.axeReady ? .done : .problem,
                     title: "AXe", titleDetail: setup.axe.version, detail: axeDetail) {
                SettingsLink {
                    Text("Change…")
                }
            }
        } header: {
            Text("Simulators")
        } footer: {
            SectionNote("Booted simulators show up on the Wall automatically.")
        }
    }

    private var axeDetail: String {
        let setup = model.setup
        if let error = setup.axe.error { return "\(model.axePath.abbreviatingHome): \(error)" }
        guard setup.axe.version != nil else { return "Checking \(model.axePath.abbreviatingHome)…" }
        let source = model.axePath.hasPrefix(Bundle.main.bundlePath) ? "Bundled" : model.axePath.abbreviatingHome
        return setup.axe.multitap ? "\(source) · native double and triple taps"
            : "\(source) · double and triple taps need the patched build from scripts/build-axe.sh"
    }
}

private struct AgentsSection: View {
    @Environment(AppModel.self) private var model
    @State private var snippet = Snippet.claudeCode

    var body: some View {
        let setup = model.setup
        Section {
            Picker("Connect with", selection: $snippet) {
                ForEach(Snippet.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            SnippetRow(text: snippet.text(cli: cliPath))
            CheckRow(state: setup.cliInstalled ? .done : .todo, title: "Command-line tool",
                     detail: setup.cliInstalled ? "Installed at \(AppPaths.installedCLI.path.abbreviatingHome)."
                        : "Links phone-use into \(AppPaths.installedCLI.deletingLastPathComponent().path.abbreviatingHome) so shells and agents can run it.") {
                if !setup.cliInstalled, AppPaths.bundledCLI != nil {
                    Button("Install", action: setup.installCLI)
                }
            }
        } header: {
            Text("Agents")
        } footer: {
            SectionNote("Point any MCP client at Phone Use.")
        }
    }

    private var cliPath: String {
        model.setup.cliInstalled ? AppPaths.installedCLI.path : (AppPaths.bundledCLI?.path ?? "phone-use")
    }
}

private struct SnippetRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top) {
            Text(text)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Copy", systemImage: "doc.on.doc", action: copy)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private enum Snippet: CaseIterable, Hashable {
    case claudeCode, json

    var label: String { self == .claudeCode ? "Claude Code" : "JSON config" }

    func text(cli: String) -> String {
        switch self {
        case .claudeCode:
            "claude mcp add --transport stdio phone-use -- \"\(cli)\" mcp"
        case .json:
            """
            {
              "mcpServers": {
                "phone-use": {
                  "command": "\(cli)",
                  "args": ["mcp"]
                }
              }
            }
            """
        }
    }
}
