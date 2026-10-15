import AppKit
import SwiftUI
import FinderieUI

@main
struct FinderieApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Finderie", id: "main") {
            MainView(model: appDelegate.model)
                // SwiftUI는 finderie:// 주소를 대리자가 아니라 여기로만 보낸다
                .onOpenURL { appDelegate.handleLink($0) }
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
    private lazy var services = ServiceProvider(model: model)

    func applicationWillFinishLaunching(_ notification: Notification) {
        // 서비스는 앱이 막 켜질 때 바로 불릴 수 있어서, 창보다 먼저 연결해 둔다
        NSApp.servicesProvider = services
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSUpdateDynamicServices()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Dock 아이콘이나 Finder의 '다음으로 열기'로 들어온 파일: 창에 놓은 것과 똑같이 처리한다.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty { model.accept(files) }
    }

    /// 창이 받은 주소. SwiftUI는 창이 있으면 파일 열기도 여기로 보낸다.
    /// Finder 확장에서 온 finderie:// 주소는 FinderLink로 비밀 값을 확인한 뒤 처리한다.
    func handleLink(_ url: URL) {
        if url.isFileURL {
            model.accept([url])
            return
        }
        guard let (action, items) = FinderLink.parse(url) else { return }
        NSApp.activate(ignoringOtherApps: true)
        switch action {
        case .compress: model.compressNow(items)
        case .extract: model.extractNow(items)
        }
    }
}
