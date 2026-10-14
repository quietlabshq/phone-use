import Foundation
import MCP
import PhoneUseCore

public enum MCPServer {
    public static var tools: [Tool] {
        ToolCatalog.all.map { spec in
            let properties = spec.properties.mapValues { property -> Value in
                var schema: [String: Value] = ["type": .string(property.type), "description": .string(property.description)]
                if property.type == "array" { schema["items"] = .object(["type": .string("string")]) }
                return .object(schema)
            }
            return Tool(name: spec.name, description: spec.description, inputSchema: .object([
                "type": .string("object"), "properties": .object(properties),
                "required": .array(spec.required.map(Value.string)), "additionalProperties": .bool(false),
            ]))
        }
    }
    public static func call(_ parameters: CallTool.Parameters, dispatcher: ToolDispatcher, context: InvocationContext? = nil, agent: AgentIdentity? = nil) async -> CallTool.Result {
        var arguments: [String: ToolArg] = [:]
        for (key, value) in parameters.arguments ?? [:] {
            switch value {
            case let .int(value): arguments[key] = .int(value)
            case let .string(value): arguments[key] = .string(value)
            case let .array(values):
                var strings: [String] = []
                for value in values {
                    guard case let .string(string) = value else { return failure("\(key) must contain only strings") }
                    strings.append(string)
                }
                arguments[key] = .strings(strings)
            default: return failure("Unsupported argument type for \(key); expected integer, string, or string array")
            }
        }
        switch await dispatcher.call(parameters.name, arguments, context: context, agent: agent) {
        case let .text(text): return .init(content: [.text(text: text, annotations: nil, _meta: nil)])
        case let .jpeg(data, note): return .init(content: [.image(data: data.base64EncodedString(), mimeType: "image/jpeg", annotations: nil, _meta: nil), .text(text: note, annotations: nil, _meta: nil)])
        case let .error(message): return failure(message)
        }
    }
    private static func failure(_ message: String) -> CallTool.Result { .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true) }
    public static func run(dispatcher: ToolDispatcher) async throws {
        try await serve(transport: StdioTransport(), dispatcher: dispatcher)
    }
    /// Runs one MCP session until the peer disconnects or the calling task is cancelled.
    /// The session is reported to the dispatcher as an agent named after its client.
    public static func serve(transport: any Transport, dispatcher: ToolDispatcher) async throws {
        let session = AgentSession()
        let server = Server(name: "phone-use", version: "0.1.0", capabilities: .init(tools: .init(listChanged: false)))
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
        await server.withMethodHandler(CallTool.self) { await call($0, dispatcher: dispatcher, agent: session.identity) }
        try await server.start(transport: transport) { client, _ in
            await dispatcher.agentConnected(session.connect(name: client.name))
        }
        await withTaskCancellationHandler {
            await server.waitUntilCompleted()
        } onCancel: {
            Task { await server.stop() }
        }
        if let agent = session.connected { await dispatcher.agentDisconnected(agent) }
    }
}

/// The agent behind one MCP session; its name arrives with `initialize`.
private final class AgentSession: @unchecked Sendable {
    private let lock = NSLock()
    private let id = UUID().uuidString
    private var name: String?
    var identity: AgentIdentity { lock.withLock { AgentIdentity(id: id, name: name ?? "agent") } }
    var connected: AgentIdentity? { lock.withLock { name.map { AgentIdentity(id: id, name: $0) } } }
    func connect(name: String) -> AgentIdentity {
        lock.withLock { self.name = name.isEmpty ? "agent" : name }
        return identity
    }
}
