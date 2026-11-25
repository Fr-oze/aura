import SwiftUI
import AppKit

@main
struct AuraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // `Aura --selftest` : vérifie la logique pure et s'arrête, sans ouvrir de fenêtre.
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(AppState.shared.settings)
                .environmentObject(AppState.shared.store)
                .environmentObject(AppState.shared.audio)
                .environmentObject(AppState.shared.serverStatus)
                .environmentObject(AppState.shared.echo)
                .environmentObject(AppState.shared.notices)
        } label: {
            MenuBarIcon()
                .environmentObject(AppState.shared.store)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.shutdown()
    }
}
