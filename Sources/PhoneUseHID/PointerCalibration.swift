import PhoneUseCore

public enum PointerCalibration {
    /// Absolute-pointer reports land on a 0...32767 axis, so screen-space
    /// calibration is not used. The method remains so existing CLI/config
    /// seams keep compiling.
    public static func run(send: @Sendable ([TimedReport]) async throws -> Void,
                           capture: @Sendable () async throws -> PixelFrame,
                           base: PointerGains) async throws -> PointerGains {
        try base.validate()
        _ = send
        _ = capture
        throw PhoneError.commandFailed("Absolute pointer does not need calibration")
    }
}
