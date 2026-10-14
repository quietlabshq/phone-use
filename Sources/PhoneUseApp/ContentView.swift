import SwiftUI

enum Route: Hashable {
    case wall
    case device(String)
    case setup
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Route? = .wall

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        } detail: {
            Detail(selection: $selection)
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            if case .failed = model.hostState { selection = .setup }
        }
    }
}

private struct Detail: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: Route?

    var body: some View {
        switch selection ?? .wall {
        case .wall:
            WallView(selection: $selection)
        case .setup:
            SetupView()
        case let .device(id):
            if let entry = model.phones.first(where: { $0.id == id }) {
                DeviceView(entry: entry, session: model.session(for: entry)).id(entry.id)
            } else {
                Disconnected(name: model.devices.first { $0.id == id }?.name, selection: $selection)
            }
        }
    }
}

private struct Disconnected: View {
    let name: String?
    @Binding var selection: Route?

    var body: some View {
        ContentUnavailableView {
            Label("Phone Disconnected", systemImage: "iphone.slash")
        } description: {
            Text("Plug in the iPhone and unlock it. It appears on the Wall again once its screen is available.")
        } actions: {
            Button("Open Setup", action: openSetup)
        }
        .navigationTitle(name ?? "Phone")
    }

    private func openSetup() { selection = .setup }
}
