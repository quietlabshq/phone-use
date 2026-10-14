import PhoneUseCore
import PhoneUseMCP
import SwiftUI

/// The phone's connection checks and recent tool calls.
struct DeviceInspector: View {
    @Environment(AppModel.self) private var model
    let entry: PhoneEntry
    let session: PhoneSession
    let activity: PhoneActivity?

    var body: some View {
        Form {
            Section {
                ConnectionRow(ok: session.image != nil, title: "Screen", value: screenValue)
                ConnectionRow(ok: inputOK, title: "Input", value: inputValue)
                ConnectionRow(ok: activity?.lastAgent != nil, title: "MCP client", value: activity?.lastAgent?.name ?? "None yet")
            } header: {
                Text("Connection")
            } footer: {
                if entry.info.kind == .hardware {
                    SectionNote("The iPhone sees an ordinary Bluetooth keyboard and pointer. No app, profile, or developer mode is installed on it.")
                }
            }

            Section {
                if let calls = activity?.calls, !calls.isEmpty {
                    ForEach(calls.prefix(40)) { record in
                        CallRow(record: record)
                    }
                } else {
                    Text("Agent tool calls and your input on this phone appear here.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Activity")
            } footer: {
                SectionNote(activitySummary)
            }
        }
        .formStyle(.grouped)
    }

    private var activitySummary: String {
        guard let calls = activity?.calls, let oldest = calls.last else { return "" }
        let agents = Set(calls.compactMap { if case let .agent(agent) = $0.source { agent.name } else { nil } }).sorted()
        let count = calls.count >= PhoneActivity.historyLimit ? "Last \(calls.count) calls" : "\(calls.count) call\(calls.count == 1 ? "" : "s")"
        return ([agents.formatted()].filter { !$0.isEmpty } + ["\(count) since \(oldest.started.formatted(date: .omitted, time: .shortened))"])
            .joined(separator: " · ")
    }

    private var fps: String { "\(session.framesPerSecond.formatted(.number.precision(.fractionLength(0)))) fps" }
    private var screenValue: String { entry.info.kind == .hardware ? "USB capture · \(fps)" : "Simulator · \(fps)" }
    private var inputOK: Bool { entry.info.kind == .simulator || model.inputConnected[entry.id] == true }
    private var inputValue: String {
        guard entry.info.kind == .hardware else { return "AXe" }
        return model.inputConnected[entry.id] == true ? "Bluetooth HID" : "Bluetooth not connected"
    }
}

private struct ConnectionRow: View {
    let ok: Bool
    let title: String
    let value: String

    var body: some View {
        LabeledContent {
            Text(value)
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(ok ? .green : .orange)
                    .accessibilityLabel(ok ? "Connected" : "Not connected")
            }
        }
    }
}

private struct CallRow: View {
    let record: ToolCallRecord

    var body: some View {
        let running = record.outcome == .running
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusDot(color: dotColor, pulsing: running)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Text(record.tool).foregroundStyle(.primary)) \(Text(record.arguments).foregroundStyle(.secondary))")
                    .font(.callout.monospaced())
                    .lineLimit(2)
                Text(result)
                    .font(.caption)
                    .foregroundStyle(record.failed ? .red : .secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            Text(record.started, format: .dateTime.hour().minute().second())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var dotColor: Color {
        let person = record.source == .person
        if record.outcome == .running { return person ? .blue : .orange }
        if record.failed { return .red }
        return person ? .blue : .gray
    }

    private var result: String {
        let who = record.source == .person ? "You · " : ""
        return switch record.outcome {
        case .running: who + "Running…"
        case let .succeeded(detail): who + detail
        case let .failed(message): who + message.replacing("Command failed: ", with: "")
        }
    }
}
