import Foundation
import MCP
import Testing
import PhoneUseCore
@testable import PhoneUseMCP

private actor WireRegistry: PhoneRegistry {
    var discoveries = 0
    func discover() async -> (phones: [any Phone], hints: [String]) { discoveries += 1; return ([], ["discovery hint"]) }
}
@Test func wireRejectsUnsupportedValuesBeforeDiscovery() async {
    let registry = WireRegistry()
    let dispatcher = ToolDispatcher(registry: registry)
    for value: Value in [.null, .bool(true), .double(1.5), .object([:]), .array([.string("shift"), .int(1)])] {
        let result = await MCPServer.call(.init(name: "press_key", arguments: ["key": .string("a"), "modifiers": value]), dispatcher: dispatcher)
        #expect(result.isError == true)
    }
    #expect(await registry.discoveries == 0)
}
@Test func wireSchemaDescribesStringArrayAndRejectsExtraProperties() {
    #expect(MCPServer.tools.count == 9)
    for tool in MCPServer.tools {
        #expect(tool.inputSchema.objectValue?["additionalProperties"] == .bool(false))
    }
    let key = MCPServer.tools.first { $0.name == "press_key" }!
    let modifiers = key.inputSchema.objectValue?["properties"]?.objectValue?["modifiers"]
    #expect(modifiers?.objectValue?["items"] == .object(["type": .string("string")]))
}
@Test func wireReturnsDiscoveryHintsAsText() async {
    let result = await MCPServer.call(.init(name: "list_phones"), dispatcher: ToolDispatcher(registry: WireRegistry()))
    #expect(result.isError != true)
    guard case let .text(text, _, _) = result.content.first else { Issue.record("Expected text content"); return }
    #expect(text.contains("discovery hint"))
}
@Test func combinedRegistryPreservesAllHints() async {
    let result = await CombinedRegistry([WireRegistry(), WireRegistry()]).discover()
    #expect(result.hints == ["discovery hint", "discovery hint"])
}

private actor TextPhone: Phone {
    nonisolated let info = PhoneInfo(id: "text", name: "Text", kind: .simulator, screenSize: .init(width: 100, height: 100))
    var actions: [PhoneAction] = []
    func perform(_ action: PhoneAction) async throws { actions.append(action) }
    func screenshot() async throws -> PixelFrame { throw PhoneError.commandFailed("Unused screenshot") }
}
private struct TextRegistry: PhoneRegistry {
    let phone: TextPhone
    func discover() async -> (phones: [any Phone], hints: [String]) { ([phone], []) }
}
private struct WireNoSleep: Sleeper { func sleep(milliseconds: Int) async throws {} }

// Match the server's untyped JSON decoding and re-encoding before typed dispatch.
private func wireTextParameters(_ text: Value) throws -> CallTool.Parameters {
    let wire = try JSONEncoder().encode(CallTool.Parameters(name: "type_text", arguments: ["text": text]))
    let untyped = try JSONDecoder().decode(Value.self, from: wire)
    return try JSONDecoder().decode(CallTool.Parameters.self, from: JSONEncoder().encode(untyped))
}

@Test(arguments: ["data:text/html,<p>x</p>", "data:,hello%20world", "data:text/plain;base64,SGk=", "data:", "data:text/plain;base64,!"])
func wirePreservesLiteralText(text: String) async throws {
    let phone = TextPhone()
    let parameters = try wireTextParameters(.string(text))
    let result = await MCPServer.call(parameters, dispatcher: ToolDispatcher(registry: TextRegistry(phone: phone), sleeper: WireNoSleep()))
    #expect(result.isError != true)
    #expect(await phone.actions == [.typeText(text)])
}

@Test func wireTextLimitUsesOriginalStringLength() async throws {
    let phone = TextPhone()
    let dispatcher = ToolDispatcher(registry: TextRegistry(phone: phone), sleeper: WireNoSleep())
    let accepted = "data:," + String(repeating: "%20", count: 31) + "x"
    #expect(accepted.utf8.count == 100)
    let result = await MCPServer.call(try wireTextParameters(.string(accepted)), dispatcher: dispatcher)
    #expect(result.isError != true)
    let rejected = await MCPServer.call(try wireTextParameters(.string(accepted + "x")), dispatcher: dispatcher)
    #expect(rejected.isError == true)
    #expect(await phone.actions == [.typeText(accepted)])
}

@Test func wireTextRejectsNonStrings() async throws {
    let registry = WireRegistry()
    let dispatcher = ToolDispatcher(registry: registry)
    for value: Value in [.bool(true), .object([:]), .array([.string("hello")])] {
        let result = await MCPServer.call(try wireTextParameters(value), dispatcher: dispatcher)
        #expect(result.isError == true)
    }
    let synthetic = await MCPServer.call(.init(name: "type_text", arguments: ["text": .data(Data("Hi".utf8))]), dispatcher: dispatcher)
    #expect(synthetic.isError == true)
    #expect(await registry.discoveries == 0)
}
