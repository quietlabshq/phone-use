import AppKit
import SwiftUI

@main
struct PhoneUseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Phone Use", id: "main") {
            ContentView()
                .environment(delegate.model)
                .frame(minWidth: 720, minHeight: 560)
        }
        .defaultSize(width: 960, height: 820)

        MenuBarExtra("Phone Use", systemImage: "iphone") {
            MenuBarContent().environment(delegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    // Agents keep working with the window closed; the menu bar item stays.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch model.hostState {
        case .starting: Text("Starting...")
        case .serving: Text("Serving agents, \(model.phones.count) phone\(model.phones.count == 1 ? "" : "s")")
        case .failed: Text("Not serving agents")
        }
        ForEach(model.phones) { entry in Text(entry.info.name) }
        Divider()
        Button("Open Phone Use") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("Quit Phone Use") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
