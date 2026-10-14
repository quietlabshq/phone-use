import Foundation
import Observation
import PhoneUseCore
import PhoneUseHardware
import PhoneUseIPC
import PhoneUseMCP
import PhoneUseRuntime

/// One discovered phone.
struct PhoneEntry: Identifiable, Equatable {
    let info: PhoneInfo
    let phone: any Phone
    var id: String { info.id }
    static func == (lhs: PhoneEntry, rhs: PhoneEntry) -> Bool { lhs.info == rhs.info }
}

/// A phone on the Wall and in the sidebar: discovered, or configured but not connected.
struct Device: Identifiable, Equatable {
    let id: String
    let name: String
    let kind: PhoneKind
    let entry: PhoneEntry?
    var transport: String { kind == .hardware ? "USB·BT" : "SIM" }
}

/// Owns local phone access for the whole Mac session: process ownership, the shared
/// dispatcher, the socket agents and the CLI connect through, and what agents are doing.
@MainActor @Observable
final class AppModel {
    enum HostState: Equatable {
        case starting
        case serving
        case failed(String)
    }

    private(set) var hostState = HostState.starting
    private(set) var phones: [PhoneEntry] = []
    private(set) var offline: [PhoneConfig] = []
    private(set) var hints: [String] = []
    private(set) var refreshing = false
    private(set) var hidStatus: HIDHostStatus?
    private(set) var inputConnected: [String: Bool] = [:]
    private(set) var activity: [String: PhoneActivity] = [:]
    private(set) var agents: [String: AgentIdentity] = [:]
    let setup = SetupModel()
    let axePath = AppPaths.axe()

    @ObservationIgnored private var ownership: ProcessOwnership?
    @ObservationIgnored private var listener: HostListener?
    @ObservationIgnored private(set) var dispatcher: ToolDispatcher?
    @ObservationIgnored private var sessions: [String: PhoneSession] = [:]
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    var devices: [Device] {
        phones.map { Device(id: $0.id, name: $0.info.name, kind: $0.info.kind, entry: $0) }
            + offline.map { Device(id: "offline:\($0.name)", name: $0.name, kind: .hardware, entry: nil) }
    }

    func status(of device: Device, at now: Date) -> PhoneStatus {
        PhoneStatus(activity: activity[device.id], online: device.entry != nil, now: now)
    }

    var anyPaused: Bool { activity.values.contains { $0.control == .paused } }
    var needsYouCount: Int { activity.values.count { if case .helpRequested = $0.control { true } else { false } } }

    func start() {
        guard hostState == .starting, dispatcher == nil else { return }
        do {
            ownership = try ProcessOwnership()
        } catch {
            hostState = .failed("\(error)\nQuit any phone-use serve process, then relaunch Phone Use.")
            return
        }
        let dispatcher = Runtime.dispatcher(axe: axePath)
        self.dispatcher = dispatcher
        tasks.append(Task { [weak self] in
            for await event in dispatcher.events { self?.apply(event) }
        })
        do {
            listener = try HostListener(socket: HostPaths.socket, dispatcher: dispatcher)
            hostState = .serving
        } catch {
            hostState = .failed("Could not serve \(HostPaths.socket.path): \(error)")
        }
        tasks.append(Task { try? await Runtime.startHIDIfConfigured() })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(15))
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollInput()
                try? await Task.sleep(for: .seconds(2))
            }
        })
        Task { await setup.refresh(axePath: axePath) }
    }

    func stop() async {
        for task in tasks { task.cancel() }
        for session in sessions.values { session.close() }
        listener?.stop()
        await dispatcher?.shutdown()
        ownership = nil
    }

    func refresh() async {
        guard let dispatcher, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        if let result = try? await dispatcher.phones(refresh: true) {
            let entries = result.phones.map { PhoneEntry(info: $0.info, phone: $0) }
                .sorted { ($0.info.kind.rawValue, $0.info.name) < ($1.info.kind.rawValue, $1.info.name) }
            if entries != phones { phones = entries }
            if result.hints != hints { hints = result.hints }
            for (id, session) in sessions where !entries.contains(where: { $0.id == id }) {
                session.close()
                sessions.removeValue(forKey: id)
            }
            for entry in entries { sessions[entry.id]?.update(phone: entry.phone) }
        }
        let configured = (try? Config.load().phones) ?? []
        let missing = configured.filter { config in !phones.contains { $0.info.kind == .hardware && $0.info.name == config.name } }
        if missing != offline { offline = missing }
    }

    private func pollInput() async {
        var connected: [String: Bool] = [:]
        for entry in phones {
            guard let hardware = entry.phone as? HardwarePhone else { continue }
            connected[entry.id] = await hardware.isInputConnected()
        }
        if connected != inputConnected { inputConnected = connected }
        let status = await ClassicHIDHost.shared.status()
        if status != hidStatus { hidStatus = status }
    }

    func session(for entry: PhoneEntry) -> PhoneSession {
        if let existing = sessions[entry.id] { return existing }
        let session = PhoneSession(entry: entry, model: self)
        sessions[entry.id] = session
        return session
    }

    func run(_ command: DirectCommand, on phoneID: String) async throws {
        guard let dispatcher else { throw PhoneError.commandFailed("Phone Use is not serving phones") }
        try await dispatcher.run(command, phoneID: phoneID)
    }

    // MARK: Control

    func pause(_ phoneID: String) { control { await $0.pause(phoneID: phoneID) } }
    func resume(_ phoneID: String) { control { await $0.resume(phoneID: phoneID) } }
    func takeOver(_ phoneID: String) { control { await $0.takeOver(phoneID: phoneID) } }
    func handBack(_ phoneID: String) { control { await $0.handBack(phoneID: phoneID) } }
    func pauseAll() { let ids = phones.map(\.id); control { for id in ids { await $0.pause(phoneID: id) } } }
    func resumeAll() { let ids = phones.map(\.id); control { for id in ids { await $0.resume(phoneID: id) } } }

    /// Runs before each manual input, so a person and an agent never take turns unknowingly.
    func prepareManualInput(on phoneID: String) async {
        guard let dispatcher, activity[phoneID]?.manualInputTakesOver(at: Date()) == true else { return }
        await dispatcher.takeOver(phoneID: phoneID)
    }

    private func control(_ change: @escaping @Sendable (ToolDispatcher) async -> Void) {
        guard let dispatcher else { return }
        Task { await change(dispatcher) }
    }

    private func apply(_ event: DispatcherEvent) {
        switch event {
        case let .call(record):
            activity[record.phoneID, default: PhoneActivity()].record(record)
        case let .control(phoneID, control):
            activity[phoneID, default: PhoneActivity()].control = control
            activity[phoneID]?.controlSince = Date()
        case let .task(phoneID, task):
            activity[phoneID, default: PhoneActivity()].task = task
        case let .agentConnected(agent):
            agents[agent.id] = agent
        case let .agentDisconnected(agent):
            agents.removeValue(forKey: agent.id)
            for id in activity.keys { activity[id]?.agentLeft(agent) }
        }
    }
}
