# MCP Swift SDK provenance

Vendored from https://github.com/modelcontextprotocol/swift-sdk at version 0.12.1,
revision `a0ae212ebf6eab5f754c3129608bc5557637e605`.

Included: upstream Package.swift, Sources, Tests, and LICENSE. Build artifacts and
Git metadata are excluded. The upstream license is retained in LICENSE.

Local changes:

- Normalize em dashes in Swift comments and one test display name to plain hyphens.

- Decode every JSON string as `Value.string`, including data URLs. Eager data URL
  decoding changed literal tool arguments before typed handlers received them.
  Explicit `Value.data` encoding and the opt-in Data URL parsing helpers remain
  unchanged. `Tests/MCPTests/ValueTests.swift` covers this wire contract; the
  application's MCP tests cover exact text dispatch and original length limits.

Keep local patches small and review them against this pinned revision when updating.
