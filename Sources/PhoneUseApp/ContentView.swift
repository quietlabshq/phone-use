import PhoneUseCore
import SwiftUI

enum SidebarItem: Hashable {
    case phone(String)
    case setup
}

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Phones") {
                    ForEach(model.phones) { entry in
                        Label(entry.info.name, systemImage: entry.info.kind == .hardware ? "iphone" : "iphone.gen3.radiowaves.left.and.right")
                            .tag(SidebarItem.phone(entry.id))
                    }
                    if model.phones.isEmpty {
                        Text(model.refreshing ? "Looking for phones..." : "No phones found")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Label("Setup", systemImage: "checklist").tag(SidebarItem.setup)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .safeAreaInset(edge: .bottom) { HostStatusBar() }
        } detail: {
            switch selection {
            case let .phone(id):
                if let entry = model.phones.first(where: { $0.id == id }) {
                    PhoneDetailView(entry: entry, session: model.session(for: entry)).id(entry.id)
                } else {
                    ContentUnavailableView("Phone disconnected", systemImage: "iphone.slash",
                                           description: Text("It will reappear here when it is available again."))
                }
            case .setup:
                SetupView()
            case nil:
                ContentUnavailableView("Select a phone", systemImage: "iphone",
                                       description: Text(model.phones.isEmpty ? "Boot a simulator or connect an iPhone, then see Setup." : "Choose a phone in the sidebar to see it live."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(model.refreshing)
                    .help("Discover phones again")
            }
        }
        .onChange(of: model.phones) { _, phones in
            if selection == nil, let first = phones.first { selection = .phone(first.id) }
        }
        .onAppear {
            if case .failed = model.hostState { selection = .setup }
        }
    }
}

private struct HostStatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            switch model.hostState {
            case .starting:
                ProgressView().controlSize(.small)
                Text("Starting")
            case .serving:
                Image(systemName: "circle.fill").foregroundStyle(.green).font(.system(size: 7))
                Text("Serving agents")
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Not serving, see Setup")
            }
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct PhoneDetailView: View {
    let entry: PhoneEntry
    let session: PhoneSession
    @State private var appName = ""
    @State private var showingOpenApp = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                LiveScreen(session: session)
                if session.image == nil {
                    VStack(spacing: 8) {
                        if let error = session.streamError {
                            Image(systemName: "exclamationmark.triangle").font(.title)
                            Text(error).multilineTextAlignment(.center).textSelection(.enabled)
                        } else {
                            ProgressView()
                            Text("Waiting for the screen...")
                        }
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(32)
                    .allowsHitTesting(false)
                }
            }
            .frame(minWidth: 280, minHeight: 400)
            StatusFooter(entry: entry, session: session)
        }
        .navigationTitle(entry.info.name)
        .navigationSubtitle(entry.info.kind == .hardware ? "iPhone" : "Simulator")
        .onAppear { session.start() }
        .onDisappear { session.stop() }
        .toolbar {
            ToolbarItemGroup {
                Button { session.home() } label: { Label("Home", systemImage: "house") }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                    .help("Go to the Home Screen (Shift-Command-H)")
                Button { showingOpenApp = true } label: { Label("Open App", systemImage: "square.grid.2x2") }
                    .keyboardShortcut("o", modifiers: [.command])
                    .help("Open an app through Spotlight (Command-O)")
                    .popover(isPresented: $showingOpenApp, arrowEdge: .bottom) {
                        HStack {
                            TextField("App name", text: $appName)
                                .frame(width: 200)
                                .onSubmit(openApp)
                            Button("Open", action: openApp).disabled(appName.isEmpty)
                        }
                        .padding()
                    }
            }
        }
    }

    private func openApp() {
        let name = appName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        session.openApp(name)
        showingOpenApp = false
        appName = ""
    }
}

private struct StatusFooter: View {
    let entry: PhoneEntry
    let session: PhoneSession

    var body: some View {
        HStack(spacing: 12) {
            if let image = session.image {
                Text("\(image.width)x\(image.height)").monospacedDigit()
                Text("\(session.framesPerSecond, specifier: "%.0f") fps").monospacedDigit()
            }
            if entry.info.kind == .hardware {
                switch session.inputConnected {
                case true?: Label("Bluetooth input connected", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.green)
                case false?: Label("Bluetooth input not connected", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.orange)
                case nil: EmptyView()
                }
            }
            if session.pendingInputs > 0 { ProgressView().controlSize(.small) }
            if let error = session.inputError {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).lineLimit(1).help(error)
            }
            Spacer()
            Text("Click to tap, hold to long press, drag to swipe, type to send keys")
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
