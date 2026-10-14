import PhoneUseCore
import PhoneUseIPC
import SwiftUI

enum Route: Hashable {
    case wall
    case device(String)
    case setup
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var route = Route.wall

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(route: $route)
            Rectangle().fill(Color(hex: 0x222428)).frame(width: 1)
            Group {
                switch route {
                case .wall:
                    WallView(route: $route)
                case let .device(id):
                    if let entry = model.phones.first(where: { $0.id == id }) {
                        DeviceView(entry: entry, session: model.session(for: entry), route: $route).id(entry.id)
                    } else {
                        Disconnected(route: $route)
                    }
                case .setup:
                    SetupView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
        .foregroundStyle(Theme.text)
        .font(Theme.font(13))
        .ignoresSafeArea()
        .onAppear {
            if case .failed = model.hostState { route = .setup }
        }
    }
}

private struct Disconnected: View {
    @Binding var route: Route

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "iphone.slash").font(.system(size: 34, weight: .light)).foregroundStyle(Theme.tertiary)
            Text("Phone disconnected").font(Theme.font(16, .semibold))
            Text("It will reappear on the Wall when it is available again.").foregroundStyle(Theme.tertiary)
            Button("Back to Wall") { route = .wall }.buttonStyle(ThemeButtonStyle())
        }
    }
}

private struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var route: Route

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7).fill(Theme.amber).frame(width: 26, height: 26)
                    .overlay(Image(systemName: "iphone").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.amberInk))
                Text("Phone Use").font(Theme.font(14, .semibold))
            }
            .padding(.horizontal, 8)

            VStack(spacing: 2) {
                NavRow(icon: "square.grid.2x2", title: "Wall", selected: route == .wall) { route = .wall } trailing: {
                    Text("\(model.devices.count)").font(Theme.mono(11)).foregroundStyle(Theme.tertiary)
                }
                NavRow(icon: "checklist", title: "Setup", selected: route == .setup) { route = .setup } trailing: {
                    let todo = model.setupProgress.total - model.setupProgress.done
                    if todo > 0 {
                        Text("\(todo)").font(Theme.font(11, .semibold)).foregroundStyle(Theme.amberInk)
                            .padding(.horizontal, 7).padding(.vertical, 1)
                            .background(Theme.amber, in: Capsule())
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("DEVICES").font(Theme.font(11, .medium)).kerning(0.5).foregroundStyle(Theme.quaternary)
                    .padding(.horizontal, 10).padding(.bottom, 6)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 2) {
                        ForEach(model.devices) { device in
                            let status = model.status(of: device, at: context.date)
                            NavRow(dot: status, title: device.name, selected: route == .device(device.id)) {
                                route = device.entry == nil ? .setup : .device(device.id)
                            } trailing: {
                                Text(device.transport).font(Theme.mono(10)).foregroundStyle(Theme.quaternary)
                            }
                        }
                    }
                }
                Button { route = .setup } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 16)
                        Text("Add a device")
                        Spacer()
                    }
                    .foregroundStyle(Theme.tertiary)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
            ServerCard()
        }
        .padding(.top, 44)
        .padding(.horizontal, 12)
        .padding(.bottom, 16)
        .frame(width: 232)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
    }
}

private struct NavRow<Trailing: View>: View {
    var icon: String?
    var dot: PhoneStatus?
    let title: String
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var trailing: Trailing
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 13)).frame(width: 16)
                } else if let dot {
                    Dot(color: dot.color, breathing: dot.breathes)
                }
                Text(title).lineLimit(1).truncationMode(.tail)
                    .font(Theme.font(13, icon != nil && selected ? .medium : .regular))
                Spacer(minLength: 4)
                trailing
            }
            .foregroundStyle(selected ? Theme.text : Theme.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, icon != nil ? 8 : 7)
            .background(selected ? Theme.selected : hovering ? Theme.selected.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct ServerCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                switch model.hostState {
                case .starting: Dot(color: Theme.amber, breathing: true); Text("Starting MCP server").font(Theme.font(13, .medium))
                case .serving: Dot(color: Theme.green); Text("MCP server running").font(Theme.font(13, .medium))
                case .failed: Dot(color: Theme.red); Text("Not serving agents").font(Theme.font(13, .medium))
                }
            }
            Text(model.agents.count == 1 ? "1 agent connected" : "\(model.agents.count) agents connected")
                .font(Theme.font(12)).foregroundStyle(Theme.tertiary)
            Text(HostPaths.socket.path.abbreviatingHome)
                .font(Theme.mono(10.5)).foregroundStyle(Theme.quaternary).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
    }
}

extension PhoneStatus {
    var color: Color {
        switch self {
        case .driving: Theme.amber
        case .needsYou, .person: Theme.blue
        case .paused: Theme.tertiary
        case .idle: Theme.idle
        case .offline: Theme.red
        }
    }
    var breathes: Bool { if case .driving = self { true } else { false } }
}

extension String {
    var abbreviatingHome: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return hasPrefix(home) ? "~" + dropFirst(home.count) : self
    }
}
