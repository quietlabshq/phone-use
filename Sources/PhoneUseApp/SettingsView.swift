import PhoneUseIPC
import SwiftUI

/// Preferences: launch at login, a custom AXe, and where agents connect.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppPaths.axeOverrideKey) private var axeOverride = ""
    @State private var choosingAXe = false

    var body: some View {
        @Bindable var setup = model.setup
        Form {
            Section {
                Toggle("Open at login", isOn: $setup.launchAtLogin)
            } footer: {
                if let error = setup.actionError {
                    SectionNote(error, color: .red)
                }
            }

            Section {
                LabeledContent("Custom AXe") {
                    HStack {
                        TextField("Custom AXe", text: $axeOverride, prompt: Text("Use bundled"))
                            .labelsHidden()
                            .font(.body.monospaced())
                        Button("Choose…", action: chooseAXe)
                    }
                }
            } header: {
                Text("Simulators")
            } footer: {
                if AppPaths.axe() != model.axePath {
                    SectionNote("Quit and reopen Phone Use to use \(AppPaths.axe().abbreviatingHome).", color: .orange)
                } else {
                    SectionNote("Leave empty to use the AXe bundled with Phone Use.")
                }
            }

            Section("Agents") {
                LabeledContent("Socket") {
                    Text(HostPaths.socket.path.abbreviatingHome)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .fileImporter(isPresented: $choosingAXe, allowedContentTypes: [.unixExecutable], onCompletion: axeChosen)
    }

    private func chooseAXe() { choosingAXe = true }

    private func axeChosen(_ result: Result<URL, any Error>) {
        if case let .success(url) = result { axeOverride = url.path }
    }
}
