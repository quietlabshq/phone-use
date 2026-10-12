import Testing
@testable import PhoneUseCore

@Test func continuousSecondsNeverMoveBackwards() {
    let first = MonotonicClock.now
    let second = MonotonicClock.now
    #expect(first >= 0)
    #expect(second >= first)
}
