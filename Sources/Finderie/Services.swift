import AppKit
import FinderieUI

/// Finder 우클릭 → 빠른 동작(서비스)의 "Windows로 보낼 준비", "Finderie로 압축 / 풀기"를 받는다.
/// 메뉴 이름과 메시지 이름은 Info.plist의 NSServices(build.sh)와 짝이다.
@MainActor
final class ServiceProvider: NSObject {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    @objc func prepareFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = Self.fileURLs(in: pboard)
        guard !urls.isEmpty else { error.pointee = "준비할 파일을 찾지 못했어요."; return }
        bringToFront()
        model.prepareNow(urls)
    }

    @objc func compressFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = Self.fileURLs(in: pboard)
        guard !urls.isEmpty else { error.pointee = "압축할 파일을 찾지 못했어요."; return }
        bringToFront()
        model.compressNow(urls)
    }

    @objc func extractFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = Self.fileURLs(in: pboard).filter { $0.pathExtension.lowercased() == "zip" }
        guard !urls.isEmpty else { error.pointee = "풀 ZIP 파일을 찾지 못했어요."; return }
        bringToFront()
        model.extractNow(urls)
    }

    private static func fileURLs(in pboard: NSPasteboard) -> [URL] {
        (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// 진행 카드와 완료 카드가 보이도록 Finderie 창을 앞으로 가져온다.
    private func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }
}
