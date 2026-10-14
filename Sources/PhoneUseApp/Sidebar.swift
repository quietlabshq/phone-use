import PhoneUseIPC
import SwiftUI

/// The Wall, Setup, and every phone, with the MCP server's state at the bottom.
struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: Route?

    var body: some View {
        List(selection: $selection) {
            Label("Wall", systemImage: "square.grid.2x2")
                .badge(model.devices.count)
                .tag(Route.wall)
            Label("Setup", systemImage: "checklist")
                .badge(model.setupProgress.total - model.setupProgress.done)
                .tag(Route.setup)
            Section("Devices") {
                ForEach(model.devices) { device in
                    DeviceRow(device: device)
                        .tag(Route.device(device.id))
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            ServerStatus()
        }
    }
}

private struct DeviceRow: View {
    @Environment(AppModel.self) private var model
    let device: Device

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let status = model.status(of: device, at: context.date)
            Label {
                Text(device.name)
            } icon: {
                StatusDot(status: status)
            }
            .help("\(status.filter.label) · \(device.transport)")
        }
    }
}

private struct ServerStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(title)
            } icon: {
                StatusDot(color: color, pulsing: model.hostState == .starting)
            }
            Text("^[\(model.agents.count) agent](inflect: true) connected")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .help(HostPaths.socket.path)
    }

    private var title: String {
        switch model.hostState {
        case .starting: "Starting MCP server"
        case .serving: "MCP server running"
        case .failed: "Not serving agents"
        }
    }

    private var color: Color {
        switch model.hostState {
        case .starting: .orange
        case .serving: .green
        case .failed: .red
        }
    }
}
