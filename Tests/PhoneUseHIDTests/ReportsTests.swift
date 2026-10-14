import Testing
@testable import PhoneUseHID

struct ReportsTests {
    @Test func keyboardPadsUnusedKeySlots() {
        let report = KeyboardReport(modifiers: 2, keys: [4, 5])
        #expect(report.payload == [2, 0, 4, 5, 0, 0, 0, 0])
        #expect(KeyboardReport.empty.payload == Array(repeating: 0, count: 8))
        #expect(KeyboardReport(modifiers: 0, keys: [4, 5, 6, 7, 8, 9]).payload == [0, 0, 4, 5, 6, 7, 8, 9])
    }

    @Test func mouseEncodesAbsoluteCoordinatesAnd32Buttons() {
        #expect(
            MouseReport(buttons: 1, x: 0x1234, y: 0x7FFF).payload
                == [1, 0, 0, 0, 0x34, 0x12, 0xFF, 0x7F]
        )
        #expect(
            MouseReport(buttons: MouseReport.homeButton, x: 0, y: 0).payload
                == [4, 0, 0, 0, 0, 0, 0, 0]
        )
        #expect(MouseReport.empty.payload == Array(repeating: 0, count: 8))
    }

    @Test func reportsExposeTheirIDAndPayload() {
        let keyboard = HIDReport.keyboard(.empty)
        let mouse = HIDReport.mouse(MouseReport(buttons: 1, x: 0x1234, y: 0x7FFF))
        #expect(keyboard.id == .keyboard)
        #expect(mouse.id == .mouse)
        #expect(keyboard.id.rawValue == 1)
        #expect(mouse.id.rawValue == 2)
        #expect(keyboard.payload == KeyboardReport.empty.payload)
        #expect(mouse.payload == [1, 0, 0, 0, 0x34, 0x12, 0xFF, 0x7F])
    }

    @Test func interruptPacketsPrefixHIDPInputHeader() {
        let mouse = HIDReport.mouse(MouseReport(buttons: 1, x: 10, y: 20))
        #expect(HIDP.interruptPacket(for: mouse) == [0xA1, 2] + mouse.payload)
        #expect(HIDP.interruptPacket(for: .keyboard(.empty)) == [0xA1, 1] + KeyboardReport.empty.payload)
    }
}
