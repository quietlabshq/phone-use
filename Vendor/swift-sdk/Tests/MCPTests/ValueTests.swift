import Foundation
import Testing

@testable import MCP

@Suite("Value JSON strings")
struct ValueTests {
    @Test(arguments: ["data:text/html,<p>x</p>", "data:,hello%20world", "data:text/plain;base64,SGk=", "data:", "data:text/plain;base64,!"])
    func stringsRemainLiteral(text: String) throws {
        let encoded = try JSONEncoder().encode(text)
        let value = try JSONDecoder().decode(Value.self, from: encoded)
        #expect(value == .string(text))
        #expect(try JSONDecoder().decode(String.self, from: JSONEncoder().encode(value)) == text)
    }

    @Test func explicitDataStillEncodesAsDataURL() throws {
        let data = Value.data(mimeType: "text/plain", Data("Hi".utf8))
        let encoded = try JSONEncoder().encode(data)
        #expect(try JSONDecoder().decode(String.self, from: encoded) == "data:text/plain;base64,SGk=")
        #expect(try JSONDecoder().decode(Value.self, from: encoded) == .string("data:text/plain;base64,SGk="))
    }
}
