import AppKit
import SwiftUI
import ZippieUI

@main
struct ZippieApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Zippie", id: "main") {
            MainView(model: appDelegate.model)
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified(showsTitle: true))

        Settings {
            SettingsView(settings: appDelegate.model.settings)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Dock 아이콘이나 Finder의 '다음으로 열기'로 들어온 파일: 창에 놓은 것과 똑같이 처리한다.
    func application(_ application: NSApplication, open urls: [URL]) {
        model.accept(urls)
    }
}
