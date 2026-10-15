import AppKit
import SwiftUI
import ZipCore
import ZippieUI

// 화면 상태를 PNG로 그린다. 실제 작업(압축, 풀기, 오류)은 진짜로 실행해서 그 결과를 그린다.
//   zippie-snap <출력 폴더> <작업 폴더>
// 작업 폴더에 필요한 것: "여행 사진 2026/" 폴더, "회의 자료_최종.zip"(Windows CP949),
//                        "계약서 스캔본.zip"(손상), "급여명세.zip"(암호)

let args = CommandLine.arguments
guard args.count == 3 else {
    print("usage: zippie-snap <out-dir> <work-dir>")
    exit(1)
}
let outDir = URL(fileURLWithPath: args[1])
let work = URL(fileURLWithPath: args[2])

@MainActor
func spin(_ seconds: Double) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

@MainActor
func waitIdle(_ model: AppModel, timeout: Double = 60) {
    let end = Date().addingTimeInterval(timeout)
    spin(0.2)
    while SnapshotSupport.isBusy(model) && Date() < end { spin(0.05) }
    spin(0.3)
}

@MainActor
func render(_ name: String, width: CGFloat? = nil, _ makeView: () -> some View) {
    for (scheme, suffix) in [(ColorScheme.light, "light"), (.dark, "dark")] {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
        let root = makeView()
            .environment(\.colorScheme, scheme)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        host.appearance = appearance
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 10, height: 10),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        var size = host.fittingSize
        if let width { size.width = width }
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        spin(0.4)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
        host.cacheDisplay(in: host.bounds, to: rep)
        let file = outDir.appendingPathComponent("\(name)-\(suffix).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
        print("saved \(file.lastPathComponent) \(Int(size.width))x\(Int(size.height))")
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    let folder = work.appendingPathComponent("여행 사진 2026")
    let windowsZip = work.appendingPathComponent("회의 자료_최종.zip")
    let brokenZip = work.appendingPathComponent("계약서 스캔본.zip")
    let lockedZip = work.appendingPathComponent("급여명세.zip")

    // 이 도구의 설정은 앱(com.mxvixxn.zippie)과 다른 저장소에 저장돼서 실제 앱 설정을 건드리지 않는다
    let defaults = UserDefaults.standard
    defaults.removeObject(forKey: "skipPreview")

    // 1. 기다림
    let idle = AppModel(loadsHistory: false)
    SnapshotSupport.addHistory(idle, name: "여행 사진 2025.zip", isCompress: true, detail: "압축 · 1.4 GB",
                               path: windowsZip.path, minutesAgo: 3)
    SnapshotSupport.addHistory(idle, name: "회의 자료_최종", isCompress: false, detail: "풀기 · 12개 파일 · 한글 이름 복원(CP949)",
                               path: folder.path, minutesAgo: 60 * 26)
    render("1-idle") { MainView(model: idle) }

    // 2. 끌고 들어옴
    SnapshotSupport.setDragging(idle, isExtract: false, summary: "폴더 1개 · 파일 236개 · 1.9 GB")
    render("2-dragging") { MainView(model: idle) }

    // 3. 미리보기 (실제 Windows CP949 ZIP을 읽는다)
    let preview = AppModel(loadsHistory: false)
    SnapshotSupport.showPreview(preview, zip: windowsZip)
    waitIdle(preview)
    render("3-preview") { MainView(model: preview) }

    // 4. 작업 중 (예시 값)
    let working = AppModel(loadsHistory: false)
    SnapshotSupport.addRunningExample(working, folder: folder, zip: windowsZip)
    render("4-working") { MainView(model: working) }

    // 5. 완료 (실제로 풀고 압축한다)
    let done = AppModel(loadsHistory: false)
    done.settings.skipPreview = true
    done.accept([windowsZip])
    waitIdle(done)
    done.accept([folder])
    waitIdle(done)
    render("5-done") { MainView(model: done) }

    // 6. 오류 (실제로 암호 ZIP과 손상된 ZIP을 풀어 본다)
    let failed = AppModel(loadsHistory: false)
    failed.accept([lockedZip])
    waitIdle(failed)
    failed.accept([brokenZip])
    waitIdle(failed)
    render("6-error") { MainView(model: failed) }
    done.settings.skipPreview = false

    // 설정 창
    render("7-settings") { SettingsView(settings: AppSettings()) }

    for (label, model) in [("done", done), ("error", failed)] {
        for line in SnapshotSupport.describe(model) { print("[\(label)] \(line)") }
    }
}
