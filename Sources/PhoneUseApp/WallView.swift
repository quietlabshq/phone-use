import SwiftUI

/// Every phone at once, with who is driving each one.
struct WallView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: Route?
    @AppStorage("wallColumns") private var columns = 4
    @State private var filter = PhoneStatus.Filter.all

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let devices = model.devices
            WallContent(
                devices: devices,
                statuses: Dictionary(uniqueKeysWithValues: devices.map { ($0.id, model.status(of: $0, at: context.date)) }),
                now: context.date,
                columns: columns,
                filter: $filter,
                selection: $selection
            )
        }
        .navigationTitle("Wall")
        .toolbar {
            ToolbarItem {
                Menu("Columns", systemImage: "rectangle.split.3x1") {
                    Picker("Columns", selection: $columns) {
                        ForEach([3, 4, 6, 8], id: \.self) { count in
                            Text("^[\(count) column](inflect: true)").tag(count)
                        }
                    }
                    .pickerStyle(.inline)
                }
                .help("Columns")
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button(model.anyPaused ? "Resume All Agents" : "Pause All Agents",
                       systemImage: model.anyPaused ? "play.fill" : "pause.fill",
                       action: togglePauseAll)
                    .labelStyle(.titleAndIcon)
                    .disabled(model.phones.isEmpty)
            }
        }
    }

    private func togglePauseAll() {
        if model.anyPaused { model.resumeAll() } else { model.pauseAll() }
    }
}

private struct WallContent: View {
    let devices: [Device]
    let statuses: [String: PhoneStatus]
    let now: Date
    let columns: Int
    @Binding var filter: PhoneStatus.Filter
    @Binding var selection: Route?

    var body: some View {
        let shown = devices.filter { filter == .all || statuses[$0.id]?.filter == filter }
        Group {
            if devices.isEmpty {
                ContentUnavailableView {
                    Label("No Phones", systemImage: "iphone")
                } description: {
                    Text("Boot a simulator, or connect an iPhone and add it in Setup.")
                } actions: {
                    Button("Open Setup", action: openSetup)
                }
            } else if shown.isEmpty {
                ContentUnavailableView {
                    Label("No Matching Phones", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("No phone is “\(filter.label)” right now.")
                } actions: {
                    Button("Show All", action: showAll)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 120), spacing: spacing, alignment: .top), count: columns),
                              spacing: spacing) {
                        ForEach(shown) { device in
                            DeviceCard(device: device, status: statuses[device.id] ?? .idle, now: now, selection: $selection)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationSubtitle(summary)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Menu("Filter", systemImage: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill") {
                    Picker("Show", selection: $filter) {
                        ForEach(PhoneStatus.Filter.allCases, id: \.self) { option in
                            Text("\(option.label) (\(count(option)))").tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                }
                .help("Filter by status")
            }
        }
    }

    private var spacing: CGFloat { columns >= 8 ? 8 : 16 }

    private func count(_ option: PhoneStatus.Filter) -> Int {
        option == .all ? devices.count : statuses.values.count { $0.filter == option }
    }

    private var summary: String {
        let driving = count(.driving), needs = count(.needsYou)
        var parts = ["\(devices.count) device\(devices.count == 1 ? "" : "s")", "\(driving) agent\(driving == 1 ? "" : "s") driving"]
        if needs > 0 { parts.append("\(needs) need\(needs == 1 ? "s" : "") you") }
        return parts.joined(separator: " · ")
    }

    private func openSetup() { selection = .setup }
    private func showAll() { filter = .all }
}
