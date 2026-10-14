import PhoneUseMCP
import SwiftUI

/// Pause, resume, take over, or hand back a phone, depending on who controls it now.
struct ControlButtons: View {
    @Environment(AppModel.self) private var model
    let phoneID: String
    let activity: PhoneActivity?

    var body: some View {
        switch activity?.control ?? .agents {
        case .agents:
            Button("Pause Agent", systemImage: "pause.fill", action: pause)
            Button("Take Over", systemImage: "hand.raised", action: takeOver)
        case .paused:
            Button("Resume Agent", systemImage: "play.fill", action: resume)
            Button("Take Over", systemImage: "hand.raised", action: takeOver)
        case .helpRequested:
            Button("Take Over", systemImage: "hand.raised", action: takeOver)
        case .person:
            Button(activity?.lastAgent.map { "Hand Back to \($0.name)" } ?? "Hand Back",
                   systemImage: "arrow.uturn.backward", action: handBack)
        }
    }

    private func pause() { model.pause(phoneID) }
    private func resume() { model.resume(phoneID) }
    private func takeOver() { model.takeOver(phoneID) }
    private func handBack() { model.handBack(phoneID) }
}
