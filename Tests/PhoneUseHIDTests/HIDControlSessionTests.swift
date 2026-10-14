import Testing
@testable import PhoneUseHID

@Test func reportModeSetupIsAcknowledged() {
    var session = HIDControlSession()
    #expect(session.reply(to: [0x71]) == [0x00])
    #expect(session.reply(to: [0x60]) == [0xA0, 0x01])
    #expect(session.reply(to: [0x70]) == [0x03])
    #expect(session.reply(to: [0x71, 0]) == [0x04])
}

@Test func controlReportsReflectLastInputAndKeyboardOutput() {
    var session = HIDControlSession()
    let mouse = MouseReport(buttons: 1, x: 123, y: 456)
    session.didSend(.mouse(mouse))
    #expect(session.reply(to: [0x41, 2]) == [0xA1, 2] + mouse.payload)
    #expect(session.reply(to: [0x49, 2, 3, 0]) == [0xA1, 2, 1, 0])
    #expect(session.reply(to: [0x52, 1, 2]) == [0x00])
    #expect(session.reply(to: [0x42, 1]) == [0xA2, 1, 2])
    #expect(session.reply(to: [0xA2, 1, 1]) == nil)
    #expect(session.reply(to: [0x42, 1]) == [0xA2, 1, 1])
}

@Test func invalidControlRequestsReturnErrorsInsteadOfTimingOut() {
    var session = HIDControlSession()
    #expect(session.reply(to: [0x41]) == [0x04])
    #expect(session.reply(to: [0x41, 99]) == [0x02])
    #expect(session.reply(to: [0x52, 1]) == [0x04])
    #expect(session.reply(to: [0xF0]) == [0x03])
    #expect(session.reply(to: [0x13]) == nil)
    #expect(session.reply(to: []) == nil)
}
