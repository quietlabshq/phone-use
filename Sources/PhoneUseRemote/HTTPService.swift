import Foundation
import MCP
import PhoneUseMCP
import PhoneUseCore

public struct RemoteHTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [(String, String)]
    public let body: Data
    public init(method: String, path: String, headers: [(String, String)], body: Data = Data()) {
        self.method = method; self.path = path; self.headers = headers; self.body = body
    }
}
public struct RemoteHTTPResponse: Sendable {
    public let status: Int
    public var headers: [String: String]
    public let body: Data
    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }
}

/// Shared by HTTP and relay adapters. Disconnecting an adapter does not cancel an invocation.
public actor HTTPService {
    private struct Session {
        let credentialID: String
        let version: String
        var initialized = false
        var touched: TimeInterval
        var tasks: [String: Task<RemoteHTTPResponse, Never>] = [:]
    }
    private let credentials: CredentialStore
    private let dispatcher: ToolDispatcher
    private var allowedHosts: Set<String>
    private let allowedOrigins: Set<String>
    private let clock: @Sendable () -> TimeInterval
    private let idleTimeout: TimeInterval
    private let requestTimeout: TimeInterval
    private let maximumResponseBytes: Int
    private var sessions: [String: Session] = [:]
    private var active = 0
    private var stopped = false
    public init(credentials: CredentialStore, dispatcher: ToolDispatcher, allowedHosts: Set<String>, allowedOrigins: Set<String> = [], idleTimeout: TimeInterval = 900, requestTimeout: TimeInterval = 120, maximumResponseBytes: Int = 8388608, clock: @escaping @Sendable () -> TimeInterval = { MonotonicClock.now }) {
        self.credentials = credentials; self.dispatcher = dispatcher
        self.allowedHosts = allowedHosts; self.allowedOrigins = allowedOrigins
        self.maximumResponseBytes = min(8388608, max(512, maximumResponseBytes))
        self.idleTimeout = idleTimeout; self.requestTimeout = requestTimeout; self.clock = clock
    }
    var activeRequestCount: Int { active }
    var isStopped: Bool { stopped }
    public func allowHost(_ authority: String) { allowedHosts.insert(authority.lowercased()) }
    public func handle(_ request: RemoteHTTPRequest, deadline: TimeInterval? = nil) async -> RemoteHTTPResponse {
        guard !stopped else { return .init(status: 503) }
        if let deadline {
            guard deadline.isFinite else { return .init(status: 400) }
            if deadline <= clock() { return .init(status: 408) }
        }
        guard request.body.count <= 262144 else { return .init(status: 413) }
        guard request.headers.count <= 64, request.headers.reduce(0, { $0 + $1.0.utf8.count + $1.1.utf8.count + 4 }) <= 16384 else { return .init(status: 431) }
        var headers: [String: String] = [:]
        for (name, value) in request.headers {
            let key = name.lowercased()
            guard headers[key] == nil, !value.contains("\r"), !value.contains("\n") else { return .init(status: 400) }
            headers[key] = value
        }
        guard let host = headers["host"], allowedHosts.contains(host.lowercased()), Self.validAuthority(host) else { return .init(status: 403) }
        if let origin = headers["origin"] {
            guard allowedOrigins.contains(origin), let url = URLComponents(string: origin),
                  ["http", "https"].contains(url.scheme), url.host != nil, url.user == nil, url.password == nil,
                  url.path.isEmpty, url.query == nil, url.fragment == nil else { return .init(status: 403) }
        }
        if let version = headers["mcp-protocol-version"], !Version.supported.contains(version) { return .init(status: 400) }
        guard let authorization = headers["authorization"], authorization.hasPrefix("Bearer "),
              let credential = try? credentials.authenticate(String(authorization.dropFirst(7))) else {
            return .init(status: 401, headers: ["www-authenticate": "Bearer"])
        }
        expireSessions()
        guard request.path == "/mcp" || request.path == "/leases/release" else { return .init(status: 404) }
        let sessionID = headers["mcp-session-id"]
        if let sessionID {
            guard let session = sessions[sessionID], session.credentialID == credential.id else { return .init(status: 404) }
            guard headers["mcp-protocol-version"] == session.version else { return .init(status: 400) }
            sessions[sessionID]?.touched = clock()
        }
        if request.method == "DELETE", request.path == "/mcp", let sessionID {
            guard sessions[sessionID]?.tasks.isEmpty == true else { return .init(status: 409) }
            sessions.removeValue(forKey: sessionID)
            let invocation = context(credential.id, sessionID)
            for phoneID in credential.phoneIDs { try? await dispatcher.releaseControl(phoneID: phoneID, context: invocation) }
            return .init(status: 204)
        }
        guard request.method == "POST" else { return .init(status: 405, headers: ["allow": "POST, DELETE"]) }
        guard headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else { return .init(status: 415) }
        guard Self.accepts(headers["accept"], "application/json"), Self.accepts(headers["accept"], "text/event-stream") else { return .init(status: 406) }
        guard let object = try? JSONDecoder().decode([String: Value].self, from: request.body) else { return .init(status: 400) }
        if request.path == "/leases/release" {
            guard let sessionID, case let .string(phoneID)? = object["phone_id"] else { return .init(status: 400) }
            do { try await dispatcher.releaseControl(phoneID: phoneID, context: context(credential.id, sessionID)); return .init(status: 204) }
            catch { return .init(status: 409) }
        }
        guard object["jsonrpc"] == .string("2.0"), case let .string(method)? = object["method"], object.keys.allSatisfy({ ["jsonrpc", "id", "method", "params"].contains($0) }) else { return .init(status: 400) }
        let id = object["id"]
        let key: String?
        switch id {
        case let .string(value): key = "s:" + value
        case let .int(value): key = "n:\(value)"
        case nil: key = nil
        default: return .init(status: 400)
        }
        let params = object["params"] ?? .object([:])
        guard case .object = params else { return .init(status: 400) }
        if method == "initialize" {
            guard sessionID == nil, let id, sessions.count < 64,
                  let parameters: Initialize.Parameters = decode(params) else { return .init(status: sessions.count >= 64 ? 503 : 400) }
            let version = Version.supported.contains(parameters.protocolVersion) ? parameters.protocolVersion : Version.latest
            let sid = UUID().uuidString
            sessions[sid] = Session(credentialID: credential.id, version: version, touched: clock())
            let result = Initialize.Result(protocolVersion: version, capabilities: .init(tools: .init(listChanged: false)), serverInfo: .init(name: "phone-use", version: "0.1.0"))
            var response = Self.result(id, result, limit: maximumResponseBytes)
            response.headers["mcp-session-id"] = sid
            return response
        }
        guard let sessionID else { return .init(status: 400) }
        if id == nil {
            if method == "notifications/initialized" { sessions[sessionID]?.initialized = true }
            if method == "notifications/cancelled", case let .object(values) = params {
                let cancelKey: String?
                switch values["requestId"] {
                case let .string(value): cancelKey = "s:" + value
                case let .int(value): cancelKey = "n:\(value)"
                default: cancelKey = nil
                }
                guard let cancelKey else { return .init(status: 400) }
                sessions[sessionID]?.tasks[cancelKey]?.cancel()
            }
            return .init(status: 202)
        }
        guard let id, let key, sessions[sessionID]?.initialized == true else { return .init(status: 400) }
        guard sessions[sessionID]?.tasks[key] == nil else { return .init(status: 409) }
        guard active < 32 else { return .init(status: 503, headers: ["retry-after": "1"]) }
        let invocation = context(credential.id, sessionID, deadline: deadline)
        let dispatcher = self.dispatcher
        let task = Task<RemoteHTTPResponse, Never> {
            switch method {
            case "ping": return Self.result(id, [String: String](), limit: maximumResponseBytes)
            case "tools/list": return Self.result(id, ListTools.Result(tools: MCPServer.tools), limit: maximumResponseBytes)
            case "tools/call":
                guard let parameters: CallTool.Parameters = self.decode(params) else { return Self.error(id, -32602, "Invalid tool parameters") }
                return Self.result(id, await MCPServer.call(parameters, dispatcher: dispatcher, context: invocation), limit: maximumResponseBytes)
            default: return Self.error(id, -32601, "Method not found")
            }
        }
        active += 1
        sessions[sessionID]?.tasks[key] = task
        let timeout = Task { try? await Task.sleep(for: .seconds(max(0, (invocation.deadline ?? clock()) - clock()))); if !Task.isCancelled { task.cancel() } }
        let response = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        timeout.cancel()
        active -= 1
        sessions[sessionID]?.tasks.removeValue(forKey: key)
        sessions[sessionID]?.touched = clock()
        return response
    }
    public func shutdown() async {
        stopped = true
        let tasks = sessions.values.flatMap { $0.tasks.values }
        for task in tasks { task.cancel() }
        for task in tasks { _ = await task.value }
        sessions.removeAll()
        await dispatcher.shutdown()
    }
    private func expireSessions() {
        let now = clock()
        sessions = sessions.filter { !$0.value.tasks.isEmpty || now - $0.value.touched < idleTimeout }
    }
    private func context(_ credentialID: String, _ sessionID: String, deadline: TimeInterval? = nil) -> InvocationContext {
        let store = credentials
        return InvocationContext(credentialID: credentialID, sessionID: sessionID, deadline: min(deadline ?? .infinity, clock() + requestTimeout)) { try store.authorize(credentialID: credentialID) }
    }
    private nonisolated func decode<T: Decodable>(_ value: Value) -> T? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    private static func validAuthority(_ authority: String) -> Bool {
        let permitted = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._:[]")
        guard !authority.isEmpty, authority.unicodeScalars.allSatisfy({ permitted.contains($0) }),
              let url = URLComponents(string: "http://" + authority), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.path.isEmpty, url.query == nil, url.fragment == nil else { return false }
        return url.port.map { (1...65535).contains($0) } ?? true
    }
    private static func accepts(_ header: String?, _ type: String) -> Bool {
        header?.split(separator: ",").contains { $0.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == type } == true
    }
    private static func result<T: Encodable>(_ id: Value, _ result: T, limit: Int) -> RemoteHTTPResponse {
        guard let data = try? JSONEncoder().encode(result), let value = try? JSONDecoder().decode(Value.self, from: data), let body = try? JSONEncoder().encode(["jsonrpc": Value.string("2.0"), "id": id, "result": value]) else { return .init(status: 500) }
        guard body.count <= limit else { return error(id, -32603, "Response exceeds server limit; outcome may be unknown") }
        return .init(status: 200, headers: ["content-type": "application/json", "cache-control": "no-store"], body: body)
    }
    private static func error(_ id: Value, _ code: Int, _ message: String) -> RemoteHTTPResponse {
        let body = try! JSONEncoder().encode(["jsonrpc": Value.string("2.0"), "id": id, "error": .object(["code": .int(code), "message": .string(message)])])
        return .init(status: 200, headers: ["content-type": "application/json", "cache-control": "no-store"], body: body)
    }
}
