import Foundation

/// Finder 확장(ZippieFinder.appex)이 보낸 zippie://compress?token=…&path=… 주소를 해석한다.
/// 확장이 자기 샌드박스 컨테이너에 저장해 둔 비밀 값과 맞을 때만 받아들인다.
/// 그래서 웹사이트 같은 다른 곳이 이 주소를 열어도 아무 일도 일어나지 않는다.
enum FinderLink {
    enum Action { case compress, extract }

    static let scheme = "zippie"
    private static let extensionID = "com.mxvixxn.zippie.finder"

    static func parse(_ url: URL) -> (Action, [URL])? {
        guard url.scheme == scheme,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let action: Action
        switch comps.host {
        case "compress": action = .compress
        case "extract": action = .extract
        default: return nil
        }
        let items = comps.queryItems ?? []
        guard let token = items.first(where: { $0.name == "token" })?.value, isValid(token) else { return nil }
        let paths = items.filter { $0.name == "path" }.compactMap(\.value)
        let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        return urls.isEmpty ? nil : (action, urls)
    }

    private static func isValid(_ token: String) -> Bool {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(extensionID)/Data/Library/Application Support/Zippie/finder-token")
        guard let expected = try? String(contentsOf: file, encoding: .utf8), expected.count >= 32 else { return false }
        // 길이가 같을 때 끝까지 비교 (앞부분만 보고 빨리 끝나지 않게)
        let a = Array(token.utf8), b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
