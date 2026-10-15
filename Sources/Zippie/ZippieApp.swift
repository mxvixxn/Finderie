import AppKit
import SwiftUI

@main
struct ZippieApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Zippie", id: "main") {
            ContentView()
                .environmentObject(appDelegate.worker)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let worker = Worker()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Dock 아이콘이나 Finder의 '다음으로 열기'로 들어온 파일: .zip은 풀고, 나머지는 압축.
    func application(_ application: NSApplication, open urls: [URL]) {
        worker.handleOpened(urls)
    }
}
