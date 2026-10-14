import PhoneUseCore
import SwiftUI

/// Marks where an agent last touched the screen, with a ping while the action is fresh.
struct AgentTouch: View {
    let session: PhoneSession
    let activity: PhoneActivity?
    let now: Date
    var size: CGFloat = 48
    var label = true

    var body: some View {
        GeometryReader { geometry in
            if let record = activity?.recentTouch(at: now), let point = record.touches.last, let image = session.image {
                let x = Double(point.x) / Double(image.width) * geometry.size.width
                let y = Double(point.y) / Double(image.height) * geometry.size.height
                ZStack {
                    PingRing(size: size).id(record.id)
                    Circle().fill(.orange).frame(width: size / 3, height: size / 3)
                        .overlay { Circle().stroke(.orange.opacity(0.3), lineWidth: 4).padding(-2) }
                }
                .position(x: x, y: y)
                if label {
                    Text("\(point.x), \(point.y)")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .glassEffect(in: .capsule)
                        .position(x: min(geometry.size.width - 40, x + 48), y: max(12, y - 26))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

private struct PingRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let size: CGFloat
    @State private var expanded = false

    var body: some View {
        Circle().stroke(.orange, lineWidth: 2).frame(width: size, height: size)
            .scaleEffect(expanded && !reduceMotion ? 1.9 : 0.5)
            .opacity(expanded ? 0 : 0.95)
            .onAppear { withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { expanded = true } }
    }
}
