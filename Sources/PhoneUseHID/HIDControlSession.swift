/// HIDP control transactions for our report-mode keyboard and absolute mouse.
public struct HIDControlSession: Sendable {
    private var keyboard = KeyboardReport.empty
    private var mouse = MouseReport.empty
    private var keyboardLEDs: UInt8 = 0

    public init() {}

    public mutating func didSend(_ report: HIDReport) {
        switch report {
        case .keyboard(let value): keyboard = value
        case .mouse(let value): mouse = value
        }
    }

    public mutating func reply(to packet: [UInt8]) -> [UInt8]? {
        guard let header = packet.first else { return nil }
        let parameter = header & 0x0F
        switch header & 0xF0 {
        case 0x10: // HID_CONTROL has no handshake response.
            return nil
        case 0x40: // GET_REPORT
            let sized = parameter & 0x08 != 0
            guard packet.count == (sized ? 4 : 2) else { return [0x04] }
            let report: [UInt8]
            switch (parameter & 0x03, packet[1]) {
            case (1, ReportID.keyboard.rawValue): report = [packet[1]] + keyboard.payload
            case (1, ReportID.mouse.rawValue): report = [packet[1]] + mouse.payload
            case (2, ReportID.keyboard.rawValue): report = [packet[1], keyboardLEDs]
            default: return [0x02] // ERR_INVALID_REPORT_ID
            }
            let size = sized ? Int(packet[2]) | (Int(packet[3]) << 8) : report.count
            return [0xA0 | (parameter & 0x03)] + report.prefix(size)
        case 0x50: // SET_REPORT: the descriptor exposes keyboard LED output only.
            guard parameter & 0x03 == 2 else { return [0x03] }
            guard packet.count == 3 else { return [0x04] }
            guard packet[1] == ReportID.keyboard.rawValue else { return [0x02] }
            keyboardLEDs = packet[2] & 0x1F
            return [0x00]
        case 0x60: // GET_PROTOCOL
            return packet.count == 1 ? [0xA0, 0x01] : [0x04]
        case 0x70: // SET_PROTOCOL: absolute pointer requires report mode.
            guard packet.count == 1 else { return [0x04] }
            return parameter & 1 == 1 ? [0x00] : [0x03]
        case 0x80: // GET_IDLE
            return packet.count == 1 ? [0xA0, 0x00] : [0x04]
        case 0x90: // SET_IDLE
            guard packet.count == 2 else { return [0x04] }
            return packet[1] == 0 ? [0x00] : [0x03]
        case 0xA0: // Output DATA is unacknowledged.
            if parameter & 0x03 == 2, packet.count == 3, packet[1] == ReportID.keyboard.rawValue {
                keyboardLEDs = packet[2] & 0x1F
            }
            return nil
        case 0x00: return nil
        default: return [0x03] // ERR_UNSUPPORTED_REQUEST
        }
    }
}
