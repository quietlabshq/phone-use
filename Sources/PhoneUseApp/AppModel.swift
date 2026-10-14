import Foundation
import Observation
import PhoneUseCore
import PhoneUseHardware
import PhoneUseIPC
import PhoneUseMCP
import PhoneUseRuntime

/// One discovered phone, as listed in the sidebar.
struct PhoneEntry: Identifiable, Equatable {
    let info: PhoneInfo
    let phone: any Phone
    var id: String { info.id }
    static func == (lhs: PhoneEntry, rhs: PhoneEntry) -> Bool { lhs.info == rhs.info }
}

/// Owns local phone access for the whole Mac session: process ownership, the shared
/// dispatcher, and the socket agents and the CLI connect through.
@MainActor @Observable
final class AppModel {
    enum HostState: Equatable {
        case starting
        case serving
        case failed(String)
    }

    private(set) var hostState = HostState.starting
    private(set) var phones: [PhoneEntry] = []
    private(set) var hints: [String] = []
    private(set) var refreshing = false
    private(set) var hidStatus: HIDHostStatus?
    let axePath = AppPaths.axe()

    @ObservationIgnored private var ownership: ProcessOwnership?
    @ObservationIgnored private var listener: HostListener?
    @ObservationIgnored private(set) var dispatcher: ToolDispatcher?
    @ObservationIgnored private var sessions: [String: PhoneSession] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

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
        do {
            listener = try HostListener(socket: HostPaths.socket, dispatcher: dispatcher)
            hostState = .serving
        } catch {
            hostState = .failed("Could not serve \(HostPaths.socket.path): \(error)")
        }
        Task { try? await Runtime.startHIDIfConfigured() }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func stop() async {
        refreshTask?.cancel()
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
        hidStatus = await ClassicHIDHost.shared.status()
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
}
