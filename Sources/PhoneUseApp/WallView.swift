import PhoneUseCore
import PhoneUseMCP
import SwiftUI

/// Every phone at once, with who is driving each one.
struct WallView: View {
    @Environment(AppModel.self) private var model
    @Binding var route: Route
    @AppStorage("wallColumns") private var columns = 4
    @State private var filter = PhoneStatus.Filter.all

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let devices = model.devices
            let statuses = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, model.status(of: $0, at: now)) })
            let shown = devices.filter { filter == .all || statuses[$0.id]?.filter == filter }
            VStack(spacing: 0) {
                header(devices: devices, statuses: statuses)
                Hairline(color: Theme.headerLine)
                if devices.isEmpty {
                    EmptyWall(route: $route)
                } else {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 120), spacing: gap, alignment: .top), count: columns),
                                  alignment: .leading, spacing: gap) {
                            ForEach(shown) { device in
                                DeviceCard(device: device, status: statuses[device.id] ?? .idle, now: now, route: $route)
                            }
                        }
                        .padding(.horizontal, 28)
                        .padding(.top, 22)
                        .padding(.bottom, 40)
                    }
                }
            }
        }
    }

    private var gap: CGFloat { columns >= 8 ? 10 : 16 }

    @ViewBuilder private var pauseButton: some View {
        if model.anyPaused {
            Button { model.resumeAll() } label: { Label("Resume all agents", systemImage: "play.fill") }
                .buttonStyle(ThemeButtonStyle())
                .fixedSize()
        } else {
            Button { model.pauseAll() } label: { Label("Pause all agents", systemImage: "pause.fill") }
                .buttonStyle(ThemeButtonStyle())
                .fixedSize()
                .disabled(model.phones.isEmpty)
        }
    }

    private func header(devices: [Device], statuses: [String: PhoneStatus]) -> some View {
        let counts = Dictionary(grouping: statuses.values, by: \.filter).mapValues(\.count)
        let driving = counts[.driving] ?? 0, needs = counts[.needsYou] ?? 0
        var summary = "\(devices.count) device\(devices.count == 1 ? "" : "s") · \(driving) agent\(driving == 1 ? "" : "s") driving"
        if needs > 0 { summary += " · \(needs) need\(needs == 1 ? "s" : "") you" }
        let title = VStack(alignment: .leading, spacing: 2) {
            Text("Wall").font(Theme.font(22, .semibold)).kerning(-0.4)
            Text(summary).foregroundStyle(Theme.tertiary)
        }
        .fixedSize()
        let filters = HStack(spacing: 6) {
            ForEach(PhoneStatus.Filter.allCases.filter { $0 == .all || counts[$0, default: 0] > 0 }, id: \.self) { option in
                FilterChip(filter: option, count: option == .all ? devices.count : counts[option, default: 0], selected: filter == option) {
                    filter = option
                }
            }
        }
        .fixedSize()
        .onChange(of: counts[filter, default: 0]) { _, count in if count == 0 { filter = .all } }
        let columnPicker = HStack(spacing: 10) {
            Text("Columns").font(Theme.font(12)).foregroundStyle(Theme.tertiary)
            Segmented(options: [3, 4, 6, 8].map { ($0, "\($0)") }, selection: $columns, mono: true)
        }
        .fixedSize()
        // One row when it fits, as in the design; otherwise controls move under the title.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 24) { title; Spacer(minLength: 0); filters; columnPicker; pauseButton }
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 24) { title; Spacer(minLength: 0); pauseButton }
                HStack(spacing: 24) { filters; Spacer(minLength: 0); columnPicker }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 40)
        .padding(.bottom, 18)
    }
}

private struct FilterChip: View {
    let filter: PhoneStatus.Filter
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Dot(color: dotColor, size: 6)
                Text(filter.label).font(Theme.font(12, .medium))
                Text("\(count)").font(Theme.mono(11)).opacity(0.75)
            }
            .foregroundStyle(selected ? Color(hex: 0x121316) : Theme.secondary)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(selected ? Theme.text : Theme.card, in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Theme.text : Theme.frame))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var dotColor: Color {
        switch filter {
        case .all: selected ? Color(hex: 0x121316) : Theme.text
        case .driving: Theme.amber
        case .needsYou, .person: Theme.blue
        case .paused: Theme.tertiary
        case .idle: Theme.idle
        case .offline: Theme.red
        }
    }
}

private struct EmptyWall: View {
    @Binding var route: Route

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "iphone").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.tertiary)
            Text("No phones yet").font(Theme.font(16, .semibold))
            Text("Boot a simulator, or connect an iPhone and add it in Setup.").foregroundStyle(Theme.tertiary)
            Button("Open Setup") { route = .setup }.buttonStyle(ThemeButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DeviceCard: View {
    @Environment(AppModel.self) private var model
    let device: Device
    let status: PhoneStatus
    let now: Date
    @Binding var route: Route

    var body: some View {
        let activity = model.activity[device.id]
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Dot(color: status.color, size: 8, breathing: status.breathes)
                Text(device.name).font(Theme.font(13, .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(device.transport).font(Theme.mono(10)).foregroundStyle(Theme.tertiary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.outline))
            }
            .padding(.horizontal, 2).padding(.top, 2)

            screen(activity)
                .contentShape(Rectangle())
                .onTapGesture { open() }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(Theme.font(13, .medium)).foregroundStyle(titleColor).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Elapsed.format(from: status.since(activity), to: now)).font(Theme.mono(11)).foregroundStyle(Theme.quaternary)
                }
                Text(subtitle(activity)).font(Theme.font(12)).foregroundStyle(Theme.tertiary).lineLimit(1)
                if case .needsYou = status {
                    Button { model.takeOver(device.id); open() } label: {
                        Label("Take over", systemImage: "hand.raised").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ThemeButtonStyle(kind: .blue))
                    .padding(.top, 6)
                }
            }
            .padding(.horizontal, 2).padding(.bottom, 2)
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ring))
    }

    @ViewBuilder private func screen(_ activity: PhoneActivity?) -> some View {
        let size = device.entry?.info.screenSize ?? PixelSize(width: 1206, height: 2622)
        ZStack {
            if let entry = device.entry {
                CardScreen(session: model.session(for: entry), activity: activity, showAgent: status.breathes, now: now)
            } else {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.strongOutline, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .padding(6)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "cable.connector").font(.system(size: 22, weight: .light))
                            Text("No screen feed").font(Theme.font(11))
                        }
                        .foregroundStyle(Theme.tertiary)
                    }
            }
        }
        .aspectRatio(CGFloat(size.width) / CGFloat(size.height), contentMode: .fit)
        .background(Theme.code, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.frame))
    }

    private func open() {
        if device.entry != nil { route = .device(device.id) } else { route = .setup }
    }

    private var title: String {
        switch status {
        case let .driving(agent): agent.name
        case let .needsYou(_, agent): "Needs you · \(agent.name)"
        case .person: "You're driving"
        case .paused: "Paused"
        case .idle: "Idle"
        case .offline: "Disconnected"
        }
    }

    private var titleColor: Color {
        switch status {
        case .driving: Theme.amber
        case .needsYou, .person: Theme.blue
        case .paused, .idle: Theme.secondary
        case .offline: Theme.redText
        }
    }

    private func subtitle(_ activity: PhoneActivity?) -> String {
        switch status {
        case .driving: activity?.task?.title ?? "No task set"
        case let .needsYou(reason, _): reason
        case .person: "Agents wait until you hand back"
        case .paused: activity?.task?.title ?? "Agents can only take screenshots"
        case .idle: "No agent attached"
        case .offline: "USB screen not connected"
        }
    }

    private var ring: Color {
        switch status {
        case .driving: Theme.amber.opacity(0.38)
        case .needsYou: Theme.blue.opacity(0.7)
        case .person: Theme.blue.opacity(0.4)
        case .paused, .idle: Theme.line
        case .offline: Theme.red.opacity(0.35)
        }
    }
}

/// A passive live thumbnail with the agent's latest touch and action.
private struct CardScreen: View {
    let session: PhoneSession
    let activity: PhoneActivity?
    let showAgent: Bool
    let now: Date

    var body: some View {
        LiveScreen(session: session, interactive: false, cornerRadius: 16)
            .overlay {
                if session.image == nil {
                    VStack(spacing: 6) {
                        if session.streamError != nil {
                            Image(systemName: "exclamationmark.triangle").font(.system(size: 18))
                            Text("No live view").font(Theme.font(11))
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .foregroundStyle(Theme.tertiary)
                    .help(session.streamError ?? "")
                }
            }
            .overlay { if showAgent { AgentTouch(session: session, activity: activity, now: now, size: 34, label: false) } }
            .overlay(alignment: .bottom) {
                if showAgent, let call = activity?.latestAgentCall {
                    HStack(spacing: 6) {
                        Image(systemName: "cursorarrow").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.amber)
                        Text("\(call.tool) \(call.arguments)").lineLimit(1).truncationMode(.tail)
                    }
                    .font(Theme.mono(10.5))
                    .foregroundStyle(Theme.caption)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: 0x0E0F11, opacity: 0.88), in: RoundedRectangle(cornerRadius: 8))
                    .padding(7)
                }
            }
            .onAppear { session.attach() }
            .onDisappear { session.detach() }
    }
}

/// Marks where an agent last touched the screen, with a ping while the action is fresh.
struct AgentTouch: View {
    let session: PhoneSession
    let activity: PhoneActivity?
    let now: Date
    var size: CGFloat = 48
    var label = true

    var body: some View {
        GeometryReader { geometry in
            if let record = activity?.recentTouch(at: now), let point = record.touches.last, let image = imageSize {
                let x = CGFloat(point.x) / CGFloat(image.width) * geometry.size.width
                let y = CGFloat(point.y) / CGFloat(image.height) * geometry.size.height
                ZStack {
                    PingRing(size: size).id(record.id)
                    Circle().fill(Theme.amber).frame(width: size / 3, height: size / 3)
                        .overlay(Circle().stroke(Theme.amber.opacity(0.3), lineWidth: 4).padding(-2))
                }
                .position(x: x, y: y)
                if label {
                    Text("\(point.x), \(point.y)").font(Theme.mono(10)).foregroundStyle(Theme.caption)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color(hex: 0x0E0F11, opacity: 0.9), in: RoundedRectangle(cornerRadius: 6))
                        .position(x: min(geometry.size.width - 40, x + 48), y: max(12, y - 26))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var imageSize: PixelSize? {
        if let image = session.image { return PixelSize(width: image.width, height: image.height) }
        return nil
    }
}

private struct PingRing: View {
    let size: CGFloat
    @State private var expanded = false

    var body: some View {
        Circle().stroke(Theme.amber, lineWidth: 2).frame(width: size, height: size)
            .scaleEffect(expanded ? 1.9 : 0.5)
            .opacity(expanded ? 0 : 0.95)
            .onAppear { withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { expanded = true } }
    }
}
