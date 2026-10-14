// swift-tools-version: 6.1
import PackageDescription
import Foundation

let dependencies: [Package.Dependency]
let targets: [Target]
#if os(Linux)
dependencies = [
    .package(path: "Vendor/swift-sdk"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
]
targets = [
    .target(name: "PhoneUseCore"),
    .target(name: "PhoneUseHID", dependencies: ["PhoneUseCore"]),
    .target(name: "PhoneUseMCP", dependencies: ["PhoneUseCore", .product(name: "MCP", package: "swift-sdk")]),
    .executableTarget(name: "phone-use", dependencies: [
        "PhoneUseCore", "PhoneUseHID", "PhoneUseMCP",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
    ], path: "Sources/phone-use-linux", resources: [.copy("fake-screenshot.jpg")]),
    .testTarget(name: "PhoneUseCoreTests", dependencies: ["PhoneUseCore"], sources: [
        "GeometryTests.swift", "KeyboardMapTests.swift", "MacrosTests.swift",
        "LiveInputTests.swift", "MonotonicClockTests.swift", "PixelFrameTests.swift", "ProcessOwnershipTests.swift", "ProcessRunnerTests.swift",
    ]),
    .testTarget(name: "PhoneUseHIDTests", dependencies: ["PhoneUseHID"]),
    .testTarget(name: "PhoneUseMCPTests", dependencies: ["PhoneUseMCP"]),
]
#else
dependencies = [
    .package(path: "Vendor/swift-sdk"),
    .package(url: "https://github.com/apple/swift-nio.git", exact: "2.103.0"),
    .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
]
targets = [
    .target(name: "PhoneUseCore"),
    .target(name: "PhoneUseRemote", dependencies: ["PhoneUseMCP", .product(name: "NIOCore", package: "swift-nio"), .product(name: "NIOPosix", package: "swift-nio"), .product(name: "NIOHTTP1", package: "swift-nio")]),
    .target(name: "PhoneUseHID", dependencies: ["PhoneUseCore"]),
    .target(name: "PhoneUseCapture", dependencies: ["PhoneUseCore"]),
    .target(name: "PhoneUseSimulator", dependencies: ["PhoneUseCore", "PhoneUseCapture"]),
    .target(name: "PhoneUseHardware", dependencies: ["PhoneUseCore", "PhoneUseHID", "PhoneUseCapture"]),
    .target(name: "PhoneUseMCP", dependencies: ["PhoneUseCore", .product(name: "MCP", package: "swift-sdk")]),
    .target(name: "PhoneUseRuntime", dependencies: ["PhoneUseCore", "PhoneUseHID", "PhoneUseCapture", "PhoneUseSimulator", "PhoneUseHardware", "PhoneUseMCP"]),
    .target(name: "PhoneUseIPC", dependencies: ["PhoneUseMCP", .product(name: "MCP", package: "swift-sdk"), .product(name: "Logging", package: "swift-log")]),
    .executableTarget(name: "phone-use", dependencies: [
        "PhoneUseCore", "PhoneUseHID", "PhoneUseCapture", "PhoneUseIPC", "PhoneUseRuntime",
        "PhoneUseSimulator", "PhoneUseHardware", "PhoneUseMCP", "PhoneUseRemote",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "MCP", package: "swift-sdk"),
    ], exclude: ["Info.plist"], linkerSettings: [.unsafeFlags([
        "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker",
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Sources/phone-use/Info.plist").path,
    ])]),
    .testTarget(name: "PhoneUseCaptureTests", dependencies: ["PhoneUseCapture", "PhoneUseCore"]),
    .testTarget(name: "PhoneUseCoreTests", dependencies: ["PhoneUseCore"]),
    .testTarget(name: "PhoneUseRemoteTests", dependencies: ["PhoneUseRemote", "PhoneUseCapture", .product(name: "NIOWebSocket", package: "swift-nio")]),
    .testTarget(name: "PhoneUseHIDTests", dependencies: ["PhoneUseHID"]),
    .testTarget(name: "PhoneUseSimulatorTests", dependencies: ["PhoneUseSimulator", "PhoneUseCapture"]),
    .testTarget(name: "PhoneUseMCPTests", dependencies: ["PhoneUseMCP"]),
    .testTarget(name: "PhoneUseHardwareTests", dependencies: ["PhoneUseHardware"]),
    .testTarget(name: "PhoneUseIPCTests", dependencies: ["PhoneUseIPC", "PhoneUseMCP", .product(name: "MCP", package: "swift-sdk")]),
]
#endif

let package = Package(
    name: "phone-use",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "phone-use", targets: ["phone-use"])],
    dependencies: dependencies,
    targets: targets
)
