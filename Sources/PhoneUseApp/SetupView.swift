import AppKit
import AVFoundation
import CoreBluetooth
import PhoneUseHardware
import PhoneUseHID
import PhoneUseIPC
import ServiceManagement
import SwiftUI

/// A checklist of everything Phone Use needs, with the fix next to each item.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @State private var axeOverride = UserDefaults.standard.string(forKey: AppPaths.axeOverrideKey) ?? ""
    @State private var snippet = Snippet.claudeCode

    private var setup: SetupModel { model.setup }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                header
                problems
                section("This Mac", "What Phone Use needs from macOS") { permissions }
                section("iPhones", "Screen over USB, input over Bluetooth. Nothing is installed on the phone.") { iPhones }
                section("Simulators", "Booted simulators show up on the Wall automatically.") { simulators }
                section("Agents", "Point any MCP client at Phone Use.") { agents }
                if !model.hints.isEmpty {
                    section("Discovery hints", "What the last search for phones found") {
                        Panel {
                            ForEach(Array(model.hints.enumerated()), id: \.offset) { index, hint in
                                if index > 0 { Hairline() }
                                Text(hint).font(Theme.font(12)).foregroundStyle(Theme.tertiary).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 12)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 820)
            .padding(.horizontal, 28)
            .padding(.top, 40)
            .padding(.bottom, 64)
            .frame(maxWidth: .infinity)
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async { await setup.refresh(axePath: model.axePath) }

    private var header: some View {
        let progress = model.setupProgress
        let todo = progress.total - progress.done
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Setup").font(Theme.font(26, .semibold)).kerning(-0.5)
                Spacer()
                Button { Task { await refresh(); await model.refresh() } } label: { Label("Check again", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(ThemeButtonStyle(kind: .quiet, height: 30))
            }
            HStack(spacing: 14) {
                GeometryReader { geometry in
                    Capsule().fill(Theme.selected)
                        .overlay(alignment: .leading) {
                            Capsule().fill(Theme.green)
                                .frame(width: geometry.size.width * CGFloat(progress.done) / CGFloat(max(1, progress.total)))
                        }
                }
                .frame(height: 6)
                Text(todo == 0 ? "All \(progress.total) ready" : "\(progress.done) of \(progress.total) ready · \(todo) to do")
                    .font(Theme.font(12.5)).foregroundStyle(Theme.secondary).fixedSize()
            }
        }
    }

    @ViewBuilder private var problems: some View {
        let messages = [hostFailure, setup.actionError, setup.configError.map { "Configuration: \($0)" }].compactMap { $0 }
        if !messages.isEmpty {
            Panel {
                ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
                    if index > 0 { Hairline() }
                    HStack(alignment: .top, spacing: 14) {
                        CheckMark(state: .problem)
                        Text(message).font(Theme.font(12)).foregroundStyle(Theme.secondary).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                }
            }
        }
    }

    private var hostFailure: String? {
        if case let .failed(message) = model.hostState { "Not serving agents. \(message)" } else { nil }
    }

    // MARK: This Mac

    private var permissions: some View {
        Panel {
            CheckRow(state: setup.camera == .authorized ? .done : setup.camera == .notDetermined ? .todo : .problem,
                     title: "Camera access", detail: "Lets Phone Use read the screen of iPhones plugged in over USB.\(note(setup.camera))") {
                switch setup.camera {
                case .authorized: Text("Allowed").font(Theme.font(12)).foregroundStyle(Theme.quaternary)
                case .notDetermined: Button("Allow…") { Task { await setup.requestCamera() } }.buttonStyle(ThemeButtonStyle(kind: .primary))
                default: Button("Open Settings") { setup.openPrivacySettings("Privacy_Camera") }.buttonStyle(ThemeButtonStyle(kind: .primary))
                }
            }
            Hairline()
            CheckRow(state: setup.bluetooth == .allowedAlways ? .done : setup.bluetooth == .notDetermined ? .todo : .problem,
                     title: "Bluetooth", detail: "Acts as a keyboard and pointer for paired iPhones.\(note(setup.bluetooth))") {
                switch setup.bluetooth {
                case .allowedAlways: Text("Allowed").font(Theme.font(12)).foregroundStyle(Theme.quaternary)
                case .notDetermined: Button("Allow…") { setup.requestBluetooth() }.buttonStyle(ThemeButtonStyle(kind: .primary))
                default: Button("Open Settings") { setup.openPrivacySettings("Privacy_Bluetooth") }.buttonStyle(ThemeButtonStyle(kind: .primary))
                }
            }
        }
    }

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

    // MARK: iPhones

    @ViewBuilder private var iPhones: some View {
        ForEach(setup.configured, id: \.captureDeviceName) { phone in ConfiguredPhone(phone: phone) }
        let unconfigured = setup.captureDevices.filter { device in !setup.configured.contains { $0.captureDeviceName == device } }
        if !unconfigured.isEmpty {
            Panel {
                ForEach(Array(unconfigured.enumerated()), id: \.element) { index, device in
                    if index > 0 { Hairline() }
                    CheckRow(state: .todo, title: device, detail: "Connected over USB, not added yet. Agents cannot use it until you add it.") {
                        Button("Add") { setup.configure(device: device); refreshPhones() }.buttonStyle(ThemeButtonStyle(kind: .primary))
                    }
                }
            }
        }
        AddPhone()
    }

    private func refreshPhones() { Task { await model.refresh() } }

    // MARK: Simulators

    private var simulators: some View {
        Panel {
            CheckRow(state: setup.axe.error != nil ? .problem : setup.axe.version == nil ? .todo : setup.axeReady ? .done : .problem,
                     title: "AXe", titleDetail: setup.axe.version, detail: axeDetail) { EmptyView() }
            Hairline()
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    Text("Custom AXe path").foregroundStyle(Theme.secondary).fixedSize()
                    TextField("", text: $axeOverride, prompt: Text("Use bundled").foregroundStyle(Theme.quaternary))
                        .textFieldStyle(.plain)
                        .font(Theme.mono(12))
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(Theme.well, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.outline))
                        .onSubmit { UserDefaults.standard.set(axeOverride, forKey: AppPaths.axeOverrideKey) }
                }
                if AppPaths.axe() != model.axePath {
                    Text("Quit and reopen Phone Use to use \(AppPaths.axe().abbreviatingHome).").font(Theme.font(12)).foregroundStyle(Theme.amber)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    private var axeDetail: String {
        if let error = setup.axe.error { return "\(model.axePath.abbreviatingHome): \(error)" }
        guard setup.axe.version != nil else { return "Checking \(model.axePath.abbreviatingHome)..." }
        let source = model.axePath.hasPrefix(Bundle.main.bundlePath) ? "Bundled" : model.axePath.abbreviatingHome
        return setup.axe.multitap ? "\(source) · native double and triple taps"
            : "\(source) · double and triple taps need the patched build from scripts/build-axe.sh"
    }

    // MARK: Agents

    private var agents: some View {
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Connect an agent").font(Theme.font(13, .medium))
                    Spacer()
                    Segmented(options: Snippet.allCases.map { ($0, $0.label) }, selection: $snippet)
                }
                let text = snippet.text(cli: cliPath)
                ZStack(alignment: .topTrailing) {
                    Text(text).font(Theme.mono(12)).foregroundStyle(Theme.codeText).lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 14).padding(.leading, 14).padding(.trailing, 96)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                        .buttonStyle(ThemeButtonStyle(height: 30))
                        .padding(10)
                }
                .background(Theme.code, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(hex: 0x222428)))
            }
            .padding(16)
            Hairline()
            CheckRow(state: setup.cliInstalled ? .done : .todo, title: "Command-line tool",
                     detail: setup.cliInstalled ? "Installed at \(AppPaths.installedCLI.path.abbreviatingHome)."
                        : "Links phone-use into \(AppPaths.installedCLI.deletingLastPathComponent().path.abbreviatingHome) so shells and agents can run it.") {
                if !setup.cliInstalled, AppPaths.bundledCLI != nil {
                    Button("Install") { setup.installCLI() }.buttonStyle(ThemeButtonStyle(kind: .primary))
                }
            }
            Hairline()
            HStack {
                Text("Open at login").font(Theme.font(13, .medium))
                Spacer()
                Toggle("Open at login", isOn: Binding(get: { setup.loginItem == .enabled }, set: { setup.setLaunchAtLogin($0) }))
                    .toggleStyle(ThemeToggleStyle())
                    .labelsHidden()
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            Hairline()
            HStack {
                Text("Socket").font(Theme.font(12)).foregroundStyle(Theme.tertiary)
                Spacer()
                Text(HostPaths.socket.path.abbreviatingHome).font(Theme.mono(11.5)).foregroundStyle(Theme.secondary).textSelection(.enabled)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    private var cliPath: String {
        setup.cliInstalled ? AppPaths.installedCLI.path : (AppPaths.bundledCLI?.path ?? "phone-use")
    }

    private func section<Content: View>(_ title: String, _ detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(title).font(Theme.font(15, .semibold))
                Text(detail).font(Theme.font(12)).foregroundStyle(Theme.quaternary)
            }
            content()
        }
    }
}

private enum Snippet: String, CaseIterable, Hashable {
    case claudeCode, json
    var label: String { self == .claudeCode ? "Claude Code" : "JSON config" }
    func text(cli: String) -> String {
        switch self {
        case .claudeCode:
            return "claude mcp add --transport stdio phone-use -- \"\(cli)\" mcp"
        case .json:
            return """
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

/// A configured iPhone with its screen, input, and AssistiveTouch checks.
private struct ConfiguredPhone: View {
    @Environment(AppModel.self) private var model
    let phone: PhoneConfig

    var body: some View {
        let screen = model.setup.captureDevices.contains(phone.captureDeviceName)
        let input = model.inputConnected(for: phone)
        Panel {
            HStack(spacing: 12) {
                Image(systemName: "iphone").font(.system(size: 16)).foregroundStyle(Theme.secondary)
                Text(phone.name).font(Theme.font(14, .semibold))
                if !screen {
                    Tag(text: "Screen not connected", color: Theme.redText, border: Theme.red.opacity(0.4))
                } else if input != true {
                    Tag(text: "Input not connected", color: Theme.amber, border: Theme.amber.opacity(0.4))
                } else {
                    Tag(text: "Ready", color: Theme.green, border: Theme.green.opacity(0.4))
                }
                Spacer()
                Button("Remove") { model.setup.remove(phone); Task { await model.refresh() } }
                    .buttonStyle(ThemeButtonStyle(kind: .quiet, height: 30))
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            Hairline()
            HStack(alignment: .top, spacing: 0) {
                Item(state: screen ? .done : .problem, title: "Screen · USB",
                     detail: screen ? "Capturing “\(phone.captureDeviceName)”" : "Plug in, unlock, and tap Trust. Still missing? Replug the cable.")
                Item(state: input == true ? .done : .problem, title: "Input · Bluetooth",
                     detail: input == true ? "Paired as “\(HIDSDPRecord.serviceName)”" : "On the iPhone: Settings › Bluetooth › \(HIDSDPRecord.serviceName).")
                Item(state: .info, title: "AssistiveTouch",
                     detail: "Must be on for pointer taps: Settings › Accessibility › Touch › AssistiveTouch.")
            }
        }
    }

    private struct Item: View {
        let state: CheckMark.State
        let title: String
        let detail: String

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                CheckMark(state: state, size: 16).padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Theme.font(13, .medium))
                    Text(detail).font(Theme.font(12)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// How to pair a new iPhone, with the Bluetooth HID host's live state.
private struct AddPhone: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Dot(color: dotColor, size: 8, breathing: model.hidStatus?.advertising == true && model.hidStatus?.connected != true)
                Text("Add an iPhone").font(Theme.font(13, .semibold))
                Text(status).font(Theme.font(12)).foregroundStyle(Theme.tertiary).lineLimit(2)
            }
            HStack(alignment: .top, spacing: 10) {
                Step(number: "01", title: "Pair over Bluetooth", detail: "On the iPhone: Settings › Bluetooth › \(HIDSDPRecord.serviceName).")
                Step(number: "02", title: "Turn on AssistiveTouch", detail: "Settings › Accessibility › Touch › AssistiveTouch.")
                Step(number: "03", title: "Plug in the cable", detail: "Unlock the phone, tap Trust when asked, then click Add above.")
            }
        }
        .padding(16)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(hex: 0x34363C), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    private var dotColor: Color {
        guard let status = model.hidStatus else { return Theme.idle }
        if status.error != nil { return Theme.red }
        return status.connected ? Theme.green : status.advertising ? Theme.blue : Theme.idle
    }

    private var status: String {
        guard let status = model.hidStatus else { return "Checking Bluetooth..." }
        if let error = status.error { return error }
        if status.connected { return "An iPhone is connected to “\(HIDSDPRecord.serviceName)”" }
        if status.advertising { return "Advertising as “\(HIDSDPRecord.serviceName)”, looking for a new phone" }
        return "Bluetooth input starts once an iPhone is added"
    }

    private struct Step: View {
        let number: String
        let title: String
        let detail: String

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(number).font(Theme.mono(11)).foregroundStyle(Theme.blue)
                Text(title).font(Theme.font(13, .medium))
                Text(detail).font(Theme.font(12)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// A checklist row: state, title and detail, and an optional action.
private struct CheckRow<Action: View>: View {
    let state: CheckMark.State
    let title: String
    var titleDetail: String?
    let detail: String
    @ViewBuilder var action: Action

    var body: some View {
        HStack(spacing: 14) {
            CheckMark(state: state)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title).font(Theme.font(13, .medium))
                    if let titleDetail { Text(titleDetail).font(Theme.mono(11.5)).foregroundStyle(Theme.tertiary) }
                }
                Text(detail).font(Theme.font(12)).foregroundStyle(Theme.tertiary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            action
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }
}
