import PhoneUseCore
import PhoneUseMCP
import SwiftUI

/// One phone on the Wall: a live thumbnail, who is driving, and what they are doing.
struct DeviceCard: View {
    @Environment(AppModel.self) private var model
    let device: Device
    let status: PhoneStatus
    let now: Date
    @Binding var selection: Route?

    var body: some View {
        let activity = model.activity[device.id]
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                StatusDot(status: status)
                Text(device.name).font(.headline).lineLimit(1)
                Spacer(minLength: 4)
                Text(device.transport).font(.caption.monospaced()).foregroundStyle(.secondary)
            }

            Button(action: open) {
                CardScreen(device: device, activity: activity, showAgent: status.breathes, now: now)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(device.name)")

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title).foregroundStyle(titleColor).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Elapsed.format(from: status.since(activity), to: now)).monospacedDigit().foregroundStyle(.secondary)
                }
                Text(subtitle(activity)).foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.subheadline)

            if case .needsYou = status {
                Button(action: takeOver) {
                    Label("Take Over", systemImage: "hand.raised").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(10)
        .background(.fill.quaternary, in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(ring) }
        .contextMenu {
            Button(device.entry == nil ? "Open Setup" : "Open", action: open)
            if device.entry != nil {
                Divider()
                ControlButtons(phoneID: device.id, activity: activity)
            }
        }
    }

    private func open() {
        selection = device.entry == nil ? .setup : .device(device.id)
    }

    private func takeOver() {
        model.takeOver(device.id)
        open()
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
        case .driving, .needsYou, .person, .offline: status.color
        case .paused, .idle: .primary
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
        case .driving: .orange.opacity(0.5)
        case .needsYou: .blue
        case .person: .blue.opacity(0.5)
        case .offline: .red.opacity(0.4)
        case .paused, .idle: .clear
        }
    }
}

/// The card's screen: a passive live thumbnail, or a placeholder for a phone that is not connected.
private struct CardScreen: View {
    @Environment(AppModel.self) private var model
    let device: Device
    let activity: PhoneActivity?
    let showAgent: Bool
    let now: Date

    var body: some View {
        let size = device.entry?.info.screenSize ?? PixelSize(width: 1206, height: 2622)
        ZStack {
            if let entry = device.entry {
                CardLiveScreen(session: model.session(for: entry), activity: activity, showAgent: showAgent, now: now)
            } else {
                Label("No Screen Feed", systemImage: "cable.connector")
                    .labelStyle(.verticalIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .aspectRatio(CGFloat(size.width) / CGFloat(size.height), contentMode: .fit)
        .background(.black, in: .rect(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.separator) }
        .contentShape(.rect(cornerRadius: 14))
    }
}

private struct CardLiveScreen: View {
    let session: PhoneSession
    let activity: PhoneActivity?
    let showAgent: Bool
    let now: Date

    var body: some View {
        LiveScreen(session: session, interactive: false, cornerRadius: 14)
            .overlay {
                if session.image == nil {
                    Group {
                        if session.streamError != nil {
                            Label("No Live View", systemImage: "exclamationmark.triangle")
                                .labelStyle(.verticalIcon)
                                .font(.caption)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .help(session.streamError ?? "")
                }
            }
            .overlay { if showAgent { AgentTouch(session: session, activity: activity, now: now, size: 34, label: false) } }
            .overlay(alignment: .bottom) {
                if showAgent, let call = activity?.latestAgentCall {
                    Label("\(call.tool) \(call.arguments)", systemImage: "cursorarrow")
                        .lineLimit(1)
                        .font(.caption.monospaced())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.black.opacity(0.75), in: .rect(cornerRadius: 8))
                        .padding(6)
                }
            }
            .onAppear { session.attach() }
            .onDisappear { session.detach() }
    }
}

/// An icon above its title, for placeholders inside small screens.
private struct VerticalIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 6) {
            configuration.icon.imageScale(.large)
            configuration.title
        }
    }
}

private extension LabelStyle where Self == VerticalIconLabelStyle {
    static var verticalIcon: VerticalIconLabelStyle { VerticalIconLabelStyle() }
}
