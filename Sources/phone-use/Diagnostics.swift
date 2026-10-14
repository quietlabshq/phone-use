import ArgumentParser
import Darwin
import Foundation
import PhoneUseHID
import PhoneUseIPC

struct Calibrate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Absolute HID pointer does not need calibration; prints pairing instructions.")
    mutating func run() async throws {
        print("Absolute HID pointer is in use; calibration is not required. Pair the iPhone with '\(HIDSDPRecord.serviceName)' and map AssistiveTouch additional button 3 to Home.")
    }
}

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check that Phone Use.app is serving phones and show its discovery hints.")
    mutating func run() async throws {
        let socket: Int32
        do {
            socket = try await HostClient.connect()
        } catch {
            print("FIX \(error)")
            throw ExitCode.failure
        }
        close(socket)
        print("OK Phone Use.app is serving \(HostPaths.socket.path)")
        print("Open Phone Use.app > Setup for Camera, Bluetooth, AXe, and USB device checks.")
        try await AppTool.call("list_phones")
    }
}
