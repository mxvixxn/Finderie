import Cocoa
import FinderSync

/// Finder 우클릭 메뉴 맨 위에 "Windows로 보낼 준비", "용량 줄이기", "압축 / 풀기"를 넣는 Finder 확장.
///
/// 확장은 샌드박스 안에서 돌아서 파일을 직접 만지지 않는다. 고른 파일 경로를 finderie:// 주소로
/// Finderie 앱에 넘기기만 한다. 다른 곳(웹사이트 등)이 이 주소를 흉내 내지 못하도록, 확장만 아는
/// 비밀 값(token)을 자기 컨테이너에 저장해 두고 주소에 함께 실어 보낸다. 앱은 그 파일을 읽어 맞춰 본다.
final class FinderSync: FIFinderSync {
    private lazy var token: String = Self.loadOrCreateToken()

    override init() {
        super.init()
        // 모든 위치의 파일에 메뉴를 보여 준다
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
        _ = token
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems else { return nil }
        let selected = FIFinderSyncController.default().selectedItemURLs() ?? []
        guard !selected.isEmpty else { return nil }

        // Finder 메뉴에는 'Finderie' 한 줄만 두고, 할 일은 그 안의 하위 메뉴에 모은다
        let actions = NSMenu(title: "Finderie")
        actions.addItem(withTitle: "Windows로 보낼 준비", action: #selector(prepare(_:)), keyEquivalent: "")
        actions.addItem(withTitle: "용량 줄이기", action: #selector(shrink(_:)), keyEquivalent: "")
        actions.addItem(withTitle: "압축", action: #selector(compress(_:)), keyEquivalent: "")
        if selected.allSatisfy({ $0.pathExtension.lowercased() == "zip" }) {
            actions.addItem(withTitle: "풀기", action: #selector(extract(_:)), keyEquivalent: "")
        }

        let root = NSMenuItem(title: "Finderie", action: nil, keyEquivalent: "")
        root.image = Self.appIcon
        root.submenu = actions
        let menu = NSMenu(title: "")
        menu.addItem(root)
        return menu
    }

    /// 메뉴 항목 옆의 Finderie 아이콘 (다른 앱 메뉴처럼 앱 로고를 보여 준다)
    private static let appIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 16, height: 16)
        return image
    }()

    @objc private func prepare(_ sender: AnyObject?) { send("prepare") }
    @objc private func shrink(_ sender: AnyObject?) { send("shrink") }
    @objc private func compress(_ sender: AnyObject?) { send("compress") }
    @objc private func extract(_ sender: AnyObject?) { send("extract") }

    private func send(_ action: String) {
        guard let items = FIFinderSyncController.default().selectedItemURLs(), !items.isEmpty else { return }
        var c = URLComponents()
        c.scheme = "finderie"
        c.host = action
        c.queryItems = [URLQueryItem(name: "token", value: token)] + items.map { URLQueryItem(name: "path", value: $0.path) }
        if let url = c.url { NSWorkspace.shared.open(url) }
    }

    /// 확장 컨테이너 안(~/Library/Containers/com.mxvixxn.finderie.finder/…)에 비밀 값을 만들어 둔다.
    private static func loadOrCreateToken() -> String {
        let fm = FileManager.default
        guard let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Finderie", isDirectory: true) else { return "" }
        let file = dir.appendingPathComponent("finder-token")
        if let existing = try? String(contentsOf: file, encoding: .utf8), existing.count >= 32 {
            return existing
        }
        let fresh = (0..<4).map { _ in UUID().uuidString.replacingOccurrences(of: "-", with: "") }.joined()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fresh.write(to: file, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return fresh
    }
}
