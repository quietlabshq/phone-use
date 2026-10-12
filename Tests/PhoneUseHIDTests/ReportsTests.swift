import Testing
@testable import PhoneUseHID

struct ReportsTests {
    @Test func keyboardPadsUnusedKeySlots() {
        let report = KeyboardReport(modifiers: 2, keys: [4, 5])
        #expect(report.payload == [2, 0, 4, 5, 0, 0, 0, 0])
        #expect(KeyboardReport.empty.payload == Array(repeating: 0, count: 8))
        #expect(KeyboardReport(modifiers: 0, keys: [4, 5, 6, 7, 8, 9]).payload == [0, 0, 4, 5, 6, 7, 8, 9])
    }

    @Test func mouseEncodesSignedMovement() {
        #expect(MouseReport(buttons: 1, dx: -5, dy: 127, wheel: 0).payload == [1, 0xFB, 0x7F, 0])
    }

    @Test func consumerUsesLittleEndian() {
        #expect(ConsumerReport(usage: 0x0223).payload == [0x23, 0x02])
    }

    @Test func reportsExposeTheirIDAndPayload() {
        let keyboard = HIDReport.keyboard(.empty)
        let mouse = HIDReport.mouse(MouseReport(buttons: 1, dx: -5, dy: 127, wheel: 0))
        let consumer = HIDReport.consumer(ConsumerReport(usage: 0x0223))
        #expect(keyboard.id == .keyboard)
        #expect(mouse.id == .mouse)
        #expect(consumer.id == .consumer)
        #expect(keyboard.id.rawValue == 1)
        #expect(mouse.id.rawValue == 2)
        #expect(consumer.id.rawValue == 3)
        #expect(keyboard.payload == KeyboardReport.empty.payload)
        #expect(mouse.payload == [1, 0xFB, 0x7F, 0])
        #expect(consumer.payload == [0x23, 0x02])
    }
}
