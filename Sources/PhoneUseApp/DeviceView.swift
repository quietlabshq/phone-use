import AppKit
import PhoneUseCore
import PhoneUseMCP
import SwiftUI

/// One phone up close: drive it, take it over from an agent, and see what the agent did.
struct DeviceView: View {
    @Environment(AppModel.self) private var model
    let entry: PhoneEntry
    let session: PhoneSession
    @AppStorage("showDeviceInspector") private var showingInspector = true
    @AppStorage("showAgentTouches") private var showTouches = true
    @State private var showingOpenApp = false
    @State private var screenshot: PNGDocument?
    @State private var exportingScreenshot = false
    @State private var exportError: String?
    @State private var showingExportError = false

    var body: some View {
        let activity = model.activity[entry.id]
        TimelineView(.periodic(from: .now, by: 1)) { context in
            DeviceStage(entry: entry, session: session, activity: activity, now: context.date, showTouches: showTouches)
        }
        .navigationTitle(entry.info.name)
        .navigationSubtitle(entry.info.kind == .hardware ? "iPhone" : "Simulator")
        .inspector(isPresented: $showingInspector) {
            DeviceInspector(entry: entry, session: session, activity: activity)
                .inspectorColumnWidth(min: 280, ideal: 340, max: 480)
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Home", systemImage: "house", action: session.home)
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                    .help("Home (⇧⌘H)")
                Button("Open App", systemImage: "square.grid.2x2", action: showOpenApp)
                    .keyboardShortcut("o")
                    .help("Open an app through Spotlight (⌘O)")
                    .popover(isPresented: $showingOpenApp, arrowEdge: .bottom) {
                        OpenAppForm(session: session, isPresented: $showingOpenApp)
                    }
            }
            ToolbarSpacer(.fixed)
            ToolbarItemGroup {
                Button("Save Screenshot", systemImage: "camera", action: saveScreenshot)
                    .keyboardShortcut("s")
                    .help("Save a screenshot (⌘S)")
                    .disabled(session.image == nil)
                Toggle("Show Agent Touches", systemImage: "scope", isOn: $showTouches)
                    .help("Show where agents touch the screen")
            }
            ToolbarSpacer(.fixed)
            ToolbarItemGroup {
                ControlButtons(phoneID: entry.id, activity: activity)
                    .labelStyle(.titleAndIcon)
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button("Inspector", systemImage: "sidebar.trailing", action: toggleInspector)
                    .help("Show or hide activity and connection details")
            }
        }
        .fileExporter(isPresented: $exportingScreenshot, document: screenshot, contentType: .png,
                      defaultFilename: screenshotName, onCompletion: screenshotSaved)
        .alert("Could Not Save the Screenshot", isPresented: $showingExportError, presenting: exportError) { _ in
        } message: { error in
            Text(error)
        }
        .onAppear { session.attach() }
        .onDisappear { session.detach() }
    }

    private var screenshotName: String {
        "\(entry.info.name) \(Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))).png"
    }

    private func showOpenApp() { showingOpenApp = true }
    private func toggleInspector() { showingInspector.toggle() }

    private func saveScreenshot() {
        guard let image = session.image,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        screenshot = PNGDocument(data: data)
        exportingScreenshot = true
    }

    private func screenshotSaved(_ result: Result<URL, any Error>) {
        if case let .failure(error) = result {
            exportError = error.localizedDescription
            showingExportError = true
        }
    }
}

/// The interactive phone with a status banner above it and stream details below.
private struct DeviceStage: View {
    let entry: PhoneEntry
    let session: PhoneSession
    let activity: PhoneActivity?
    let now: Date
    let showTouches: Bool

    var body: some View {
        VStack(spacing: 16) {
            StatusBanner(status: PhoneStatus(activity: activity, online: true, now: now), activity: activity, now: now)
            PhoneScreen(entry: entry, session: session, activity: activity, now: now, showTouches: showTouches)
                .frame(maxHeight: .infinity)
            Text(stats)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(session.inputError ?? session.streamError ?? "")
        }
        .padding()
    }

    private var stats: String {
        var parts: [String] = []
        if let image = session.image { parts.append("\(image.width)×\(image.height)") }
        parts.append("\(session.framesPerSecond.formatted(.number.precision(.fractionLength(0)))) fps")
        if session.pendingInputs > 0 { parts.append("sending \(session.pendingInputs)") }
        if let error = session.inputError { parts.append(error) }
        return parts.joined(separator: " · ")
    }
}

private struct StatusBanner: View {
    let status: PhoneStatus
    let activity: PhoneActivity?
    let now: Date

    var body: some View {
        let (title, detail) = content
        HStack(spacing: 10) {
            StatusDot(status: status)
            Text(title).bold().foregroundStyle(status.color == .gray ? .primary : status.color)
            Text(detail).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(status.color.opacity(0.1), in: .rect(cornerRadius: 8))
        .frame(maxWidth: 640)
    }

    private var content: (String, String) {
        let elapsed = Elapsed.format(from: status.since(activity), to: now)
        return switch status {
        case let .driving(agent):
            ("\(agent.name) is driving", [activity?.task?.title, elapsed].compactMap { $0 }.joined(separator: " · "))
        case let .needsYou(reason, agent):
            ("\(agent.name) needs you", "\(reason) · Take over, fix it, then hand back.")
        case .person:
            ("You have control", "Agent actions fail until you hand back. Screenshots still work.")
        case .paused:
            ("Agents paused", "Agents can only take screenshots until you resume.")
        case .idle, .offline:
            ("No agent attached", "Click to tap, hold to long press, drag to swipe, type to send keys.")
        }
    }
}

/// The live screen in a phone-shaped bezel.
private struct PhoneScreen: View {
    let entry: PhoneEntry
    let session: PhoneSession
    let activity: PhoneActivity?
    let now: Date
    let showTouches: Bool

    var body: some View {
        let size = session.image.map { PixelSize(width: $0.width, height: $0.height) } ?? entry.info.screenSize
        LiveScreen(session: session, cornerRadius: 36)
            .overlay {
                if session.image == nil {
                    VStack(spacing: 8) {
                        if let error = session.streamError {
                            Image(systemName: "exclamationmark.triangle").imageScale(.large)
                            Text(error).font(.callout).multilineTextAlignment(.center).textSelection(.enabled)
                        } else {
                            ProgressView().controlSize(.small)
                            Text("Waiting for the screen…").font(.callout)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .padding(28)
                    .allowsHitTesting(false)
                }
            }
            .overlay { if showTouches { AgentTouch(session: session, activity: activity, now: now) } }
            .aspectRatio(CGFloat(size.width) / CGFloat(size.height), contentMode: .fit)
            .padding(8)
            .background(.black, in: .rect(cornerRadius: 44))
            .overlay { RoundedRectangle(cornerRadius: 44).strokeBorder(.gray.opacity(0.5), lineWidth: 2) }
            .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
            .frame(maxWidth: 420)
    }
}

private struct OpenAppForm: View {
    let session: PhoneSession
    @Binding var isPresented: Bool
    @State private var appName = ""

    var body: some View {
        HStack {
            TextField("App Name", text: $appName)
                .frame(width: 200)
                .onSubmit(open)
            Button("Open", action: open)
                .keyboardShortcut(.defaultAction)
                .disabled(appName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding()
    }

    private func open() {
        let name = appName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        session.openApp(name)
        isPresented = false
    }
}
