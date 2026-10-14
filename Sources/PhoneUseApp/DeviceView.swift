import AppKit
import PhoneUseCore
import PhoneUseMCP
import SwiftUI
import UniformTypeIdentifiers

/// One phone up close: drive it, take it over from an agent, and see what the agent did.
struct DeviceView: View {
    @Environment(AppModel.self) private var model
    let entry: PhoneEntry
    let session: PhoneSession
    @Binding var route: Route

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let activity = model.activity[entry.id]
            let status = PhoneStatus(activity: activity, online: true, now: context.date)
            VStack(spacing: 0) {
                header(activity: activity, status: status)
                Hairline(color: Theme.headerLine)
                HStack(spacing: 0) {
                    Stage(entry: entry, session: session, activity: activity, status: status, now: context.date)
                        .frame(maxWidth: .infinity)
                    Rectangle().fill(Theme.headerLine).frame(width: 1)
                    Inspector(entry: entry, session: session, activity: activity)
                        .frame(width: 360)
                }
            }
        }
        .onAppear { session.attach() }
        .onDisappear { session.detach() }
    }

    private func header(activity: PhoneActivity?, status: PhoneStatus) -> some View {
        let hardware = entry.info.kind == .hardware
        let input = model.inputConnected[entry.id]
        return HStack(spacing: 20) {
            Button { route = .wall } label: {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
                    .frame(width: 32, height: 32)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.frame))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("[", modifiers: .command)
            .help("Back to Wall (Command-[)")
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.info.name).font(Theme.font(22, .semibold)).kerning(-0.4)
                HStack(spacing: 6) {
                    Tag(text: hardware ? "iPhone" : "Simulator")
                    Tag(text: hardware ? "USB screen" : "Simulator screen", dot: session.image != nil ? Theme.green : session.streamError != nil ? Theme.red : Theme.idle)
                    if hardware {
                        Tag(text: "Bluetooth input", dot: input == true ? Theme.green : input == false ? Theme.red : Theme.idle)
                    }
                }
            }
            Spacer()
            switch activity?.control ?? .agents {
            case .agents:
                Button { model.pause(entry.id) } label: { Label("Pause agent", systemImage: "pause.fill") }
                    .buttonStyle(ThemeButtonStyle(height: 34))
                takeOverButton
            case .paused:
                Button { model.resume(entry.id) } label: { Label("Resume agent", systemImage: "play.fill") }
                    .buttonStyle(ThemeButtonStyle(height: 34))
                takeOverButton
            case .helpRequested:
                takeOverButton
            case .person:
                Button { model.handBack(entry.id) } label: {
                    Label(activity?.lastAgent.map { "Hand back to \($0.name)" } ?? "Hand back", systemImage: "cursorarrow")
                }
                .buttonStyle(ThemeButtonStyle(kind: .amber, height: 34))
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 40)
        .padding(.bottom, 18)
    }

    private var takeOverButton: some View {
        Button { model.takeOver(entry.id) } label: { Label("Take over", systemImage: "hand.raised") }
            .buttonStyle(ThemeButtonStyle(kind: .blue, height: 34))
    }
}

private struct Stage: View {
    @Environment(AppModel.self) private var model
    let entry: PhoneEntry
    let session: PhoneSession
    let activity: PhoneActivity?
    let status: PhoneStatus
    let now: Date
    @AppStorage("showAgentTouches") private var showTouches = true
    @State private var appName = ""
    @State private var showingOpenApp = false

    var body: some View {
        VStack(spacing: 16) {
            banner
            phone.frame(maxHeight: .infinity)
            toolbar
            Text(stats).font(Theme.mono(11)).foregroundStyle(Theme.quaternary).lineLimit(1)
                .help(session.inputError ?? session.streamError ?? "")
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 24)
    }

    private var banner: some View {
        let (color, title, detail) = bannerContent
        return HStack(spacing: 10) {
            Dot(color: color, size: 8, breathing: status.breathes)
            Text(title).font(Theme.font(13, .medium)).foregroundStyle(color == Theme.idle ? Theme.secondary : color)
            Text(detail).foregroundStyle(Theme.tertiary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(color.opacity(color == Theme.idle ? 0.12 : 0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(color == Theme.idle ? 0.5 : 0.35)))
    }

    private var bannerContent: (Color, String, String) {
        let elapsed = Elapsed.format(from: status.since(activity), to: now)
        switch status {
        case let .driving(agent):
            return (Theme.amber, "\(agent.name) is driving", [activity?.task?.title, elapsed].compactMap { $0 }.joined(separator: " · "))
        case let .needsYou(reason, agent):
            return (Theme.blue, "\(agent.name) needs you", "\(reason) · Take over, fix it, then hand back.")
        case .person:
            return (Theme.blue, "You have control", "Agent actions fail until you hand back. Screenshots still work.")
        case .paused:
            return (Theme.tertiary, "Agents paused", "Agents can only take screenshots until you resume.")
        case .idle, .offline:
            return (Theme.idle, "No agent attached", "Click to tap, hold to long press, drag to swipe, type to send keys.")
        }
    }

    private var phone: some View {
        let size = session.image.map { PixelSize(width: $0.width, height: $0.height) } ?? entry.info.screenSize
        return LiveScreen(session: session, cornerRadius: 36)
            .overlay {
                if session.image == nil {
                    VStack(spacing: 8) {
                        if let error = session.streamError {
                            Image(systemName: "exclamationmark.triangle").font(.title2)
                            Text(error).font(Theme.font(12)).multilineTextAlignment(.center).textSelection(.enabled)
                        } else {
                            ProgressView().controlSize(.small)
                            Text("Waiting for the screen...").font(Theme.font(12))
                        }
                    }
                    .foregroundStyle(Theme.tertiary)
                    .padding(28)
                    .allowsHitTesting(false)
                }
            }
            .overlay { if showTouches { AgentTouch(session: session, activity: activity, now: now) } }
            .aspectRatio(CGFloat(size.width) / CGFloat(size.height), contentMode: .fit)
            .padding(1)
            .background(Theme.frame, in: RoundedRectangle(cornerRadius: 37))
            .padding(8)
            .background(Theme.control, in: RoundedRectangle(cornerRadius: 45))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 30)
            .frame(maxWidth: 420)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            ToolButton(icon: "house", help: "Home (Shift-Command-H)") { session.home() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            ToolButton(icon: "square.grid.2x2", help: "Open an app through Spotlight (Command-O)") { showingOpenApp = true }
                .keyboardShortcut("o", modifiers: .command)
                .popover(isPresented: $showingOpenApp, arrowEdge: .bottom) {
                    HStack {
                        TextField("App name", text: $appName).frame(width: 200).onSubmit(openApp)
                        Button("Open", action: openApp).disabled(appName.isEmpty)
                    }
                    .padding()
                }
            Rectangle().fill(Theme.frame).frame(width: 1, height: 28).padding(.horizontal, 2)
            ToolButton(icon: "camera", help: "Save a screenshot") { saveScreenshot() }
                .disabled(session.image == nil)
            ToolButton(icon: "scope", help: showTouches ? "Hide agent touches" : "Show agent touches", active: showTouches) { showTouches.toggle() }
        }
        .padding(5)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(hex: 0x26282D)))
    }

    private var stats: String {
        var parts: [String] = []
        if let image = session.image { parts.append("\(image.width)×\(image.height)") }
        parts.append(String(format: "%.0f fps", session.framesPerSecond))
        if session.pendingInputs > 0 { parts.append("sending \(session.pendingInputs)") }
        if let error = session.inputError { parts.append(error) }
        return parts.joined(separator: " · ")
    }

    private func openApp() {
        let name = appName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        session.openApp(name)
        showingOpenApp = false
        appName = ""
    }

    private func saveScreenshot() {
        guard let image = session.image else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(entry.info.name) \(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))).png"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}

private struct ToolButton: View {
    let icon: String
    let help: String
    var active = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 16))
                .foregroundStyle(active ? Theme.amber : Theme.secondary)
                .frame(width: 44, height: 44)
                .background(active || hovering ? Theme.segment : .clear, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct Inspector: View {
    @Environment(AppModel.self) private var model
    let entry: PhoneEntry
    let session: PhoneSession
    let activity: PhoneActivity?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Activity").font(Theme.font(14, .semibold))
                        Text(activitySummary).font(Theme.font(12)).foregroundStyle(Theme.tertiary).lineLimit(1)
                    }
                    if let calls = activity?.calls, !calls.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(calls.prefix(40)) { record in CallRow(record: record) }
                        }
                    } else {
                        Text("Agent tool calls and your input on this phone appear here.")
                            .font(Theme.font(12)).foregroundStyle(Theme.quaternary)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Connection").font(Theme.font(14, .semibold))
                    Panel {
                        ConnectionRow(ok: session.image != nil, key: "Screen", value: screenValue)
                        Hairline()
                        ConnectionRow(ok: inputOK, key: "Input", value: inputValue)
                        Hairline()
                        ConnectionRow(ok: activity?.lastAgent != nil, key: "MCP client", value: activity?.lastAgent?.name ?? "None yet")
                    }
                    if entry.info.kind == .hardware {
                        Text("The iPhone sees an ordinary Bluetooth keyboard and pointer. No app, profile, or developer mode is installed on it.")
                            .font(Theme.font(12)).foregroundStyle(Theme.quaternary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(22)
        }
    }

    private var activitySummary: String {
        guard let calls = activity?.calls, let oldest = calls.last else { return "" }
        let agents = Set(calls.compactMap { if case let .agent(agent) = $0.source { agent.name } else { nil } }).sorted()
        let count = calls.count >= PhoneActivity.historyLimit ? "Last \(calls.count) calls" : "\(calls.count) call\(calls.count == 1 ? "" : "s")"
        return ([agents.joined(separator: ", ")].filter { !$0.isEmpty } + ["\(count) since \(oldest.started.formatted(date: .omitted, time: .shortened))"])
            .joined(separator: " · ")
    }

    private var screenValue: String {
        let fps = String(format: "%.0f fps", session.framesPerSecond)
        return entry.info.kind == .hardware ? "USB capture · \(fps)" : "Simulator · \(fps)"
    }
    private var inputOK: Bool { entry.info.kind == .simulator || model.inputConnected[entry.id] == true }
    private var inputValue: String {
        guard entry.info.kind == .hardware else { return "AXe" }
        return model.inputConnected[entry.id] == true ? "Bluetooth HID" : "Bluetooth not connected"
    }
}

private struct CallRow: View {
    let record: ToolCallRecord

    var body: some View {
        let running = record.outcome == .running
        let person = record.source == .person
        HStack(alignment: .top, spacing: 10) {
            Text(record.started.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)))
                .font(Theme.mono(11)).foregroundStyle(Theme.quaternary).frame(width: 58, alignment: .leading).padding(.top, 1)
            Dot(color: running ? (person ? Theme.blue : Theme.amber) : record.failed ? Theme.red.opacity(0.7) : person ? Theme.blue.opacity(0.6) : Theme.quietDot,
                size: 8, breathing: running)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                (Text(record.tool).foregroundStyle(running ? Theme.text : Theme.secondary)
                    + Text(record.arguments.isEmpty ? "" : " \(record.arguments)").foregroundStyle(Theme.tertiary))
                    .font(Theme.mono(12)).lineLimit(2)
                Text(result).font(Theme.font(11.5)).foregroundStyle(record.failed ? Theme.redText.opacity(0.85) : Theme.quaternary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(running ? (person ? Theme.blue.opacity(0.08) : Theme.amber.opacity(0.09)) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }


    private var result: String {
        let who = record.source == .person ? "You · " : ""
        switch record.outcome {
        case .running: return who + "Running…"
        case let .succeeded(detail): return who + detail
        case let .failed(message): return who + message.replacingOccurrences(of: "Command failed: ", with: "")
        }
    }
}

private struct ConnectionRow: View {
    let ok: Bool
    let key: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark" : "exclamationmark.circle")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(ok ? Theme.green : Theme.amber)
                .frame(width: 14)
            Text(key)
            Spacer()
            Text(value).font(Theme.font(12)).foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}
