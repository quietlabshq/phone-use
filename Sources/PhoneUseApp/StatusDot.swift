import SwiftUI

/// A small colored dot that pulses while something is in progress.
struct StatusDot: View {
    let color: Color
    var pulsing = false

    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 8))
            .foregroundStyle(color)
            .symbolEffect(.pulse, isActive: pulsing)
            .accessibilityHidden(true)
    }
}

extension StatusDot {
    init(status: PhoneStatus) {
        self.init(color: status.color, pulsing: status.breathes)
    }
}

extension PhoneStatus {
    var color: Color {
        switch self {
        case .driving: .orange
        case .needsYou, .person: .blue
        case .paused: .secondary
        case .idle: .gray
        case .offline: .red
        }
    }

    var breathes: Bool { if case .driving = self { true } else { false } }
}
