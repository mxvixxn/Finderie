import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// "Windows로 보낼 준비": 압축하지 않고 파일 자체를 Windows에서 문제없게 고친다.
///
/// 1. scan으로 고칠 것(이름, Mac 숨김 파일, CSV 인코딩, HEIC 사진)과 확인할 것(Mac 전용 파일, 긴 경로)을 찾는다.
/// 2. apply로 복사본을 만들거나 원본을 고친다.
///
/// 파일을 만들거나 이름을 바꿀 때는 Foundation 대신 POSIX 함수를 쓴다. Foundation은 경로를 넘길 때
/// 한글을 자모로 풀어(NFD) 저장해 버려서, 고친 이름이 다시 깨지기 때문이다.
public enum SendPrep {
    /// 켜고 끌 수 있는 고치기 묶음
    public enum Fix: String, CaseIterable, Identifiable, Sendable {
        case names, junk, csv, heic
        public var id: String { rawValue }
    }

    public enum IssueKind: String, Sendable {
        // 이름 (Fix.names)
        case decomposed, forbiddenChars, reservedName, trailingDotSpace, duplicateName
        // 나머지 고치기
        case junk, csvWithoutBOM, heic
        // 확인만 할 것
        case macOnlyDocument, macShortcut, macApp, macInstaller, alias, symlink, longPath

        public var fix: Fix? {
            switch self {
            case .decomposed, .forbiddenChars, .reservedName, .trailingDotSpace, .duplicateName: return .names
            case .junk: return .junk
            case .csvWithoutBOM: return .csv
            case .heic: return .heic
            default: return nil
            }
        }
    }

    public struct Issue: Identifiable, Sendable {
        public let id = UUID()
        public let kind: IssueKind
        /// 고른 항목 기준 상대 경로 (Finder에 보이는 모양)
        public let path: String
        /// 고친 뒤 이름 (이름 문제, HEIC일 때)
        public let after: String?
    }

    public enum Mode: String, CaseIterable, Identifiable, Sendable {
        /// "Windows로 보낼 파일" 폴더에 고친 복사본을 만든다
        case copy
        /// 원본의 이름을 바꾸고, 지운 것은 휴지통으로 옮긴다
        case inPlace
        public var id: String { rawValue }
    }

    public struct Outcome: Sendable {
        /// 고친 뒤의 항목들 (복사본이면 새 폴더 안의 항목)
        public let items: [URL]
        /// 복사본을 담은 폴더 (원본 고치기면 nil)
        public let folder: URL?
        public var renamed = 0
        public var removed = 0
        public var bomAdded = 0
        public var converted = 0
        public var trashed: [URL] = []
    }

    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// 검사 결과. 실제로 고칠 때 다시 훑지 않도록 파일 나무를 함께 들고 있다.
    public final class Report: @unchecked Sendable {
        public let roots: [URL]
        public let issues: [Issue]
        public let fileCount: Int
        public let folderCount: Int
        public let totalBytes: UInt64
        let tree: [Node]

        init(roots: [URL], issues: [Issue], fileCount: Int, folderCount: Int, totalBytes: UInt64, tree: [Node]) {
            self.roots = roots
            self.issues = issues
            self.fileCount = fileCount
            self.folderCount = folderCount
            self.totalBytes = totalBytes
            self.tree = tree
        }

        public func issues(for fix: Fix) -> [Issue] { issues.filter { $0.kind.fix == fix } }
        public var warnings: [Issue] { issues.filter { $0.kind.fix == nil } }
        public var fixable: Set<Fix> { Set(issues.compactMap(\.kind.fix)) }
    }

    // MARK: - 파일 나무

    final class Node {
        let path: String
        let name: String
        let isDirectory: Bool
        let isPackage: Bool
        let isSymlink: Bool
        let isAlias: Bool
        let size: UInt64
        var children: [Node] = []
        var isJunk = false
        var csvNeedsBOM = false
        var isHEIC = false

        init(path: String, name: String, isDirectory: Bool, isPackage: Bool, isSymlink: Bool, isAlias: Bool, size: UInt64) {
            self.path = path
            self.name = name
            self.isDirectory = isDirectory
            self.isPackage = isPackage
            self.isSymlink = isSymlink
            self.isAlias = isAlias
            self.size = size
        }

        /// 안으로 들어가서 하나하나 고치는 폴더인지 (앱 같은 패키지는 통째로 다룬다)
        var walksInside: Bool { isDirectory && !isPackage && !isSymlink }
    }

    // MARK: - 검사

    public static func scan(_ urls: [URL], cancel: CancelToken? = nil) throws -> Report {
        var files = 0, folders = 0
        var bytes: UInt64 = 0

        func load(_ path: String, name: String) throws -> Node {
            if cancel?.isCancelled == true { throw ZipError.cancelled }
            // 종류와 크기는 lstat으로 본다. URL은 한글을 자모로 풀어 경로가 길어지면(1024바이트 넘게) 실패한다.
            var st = stat()
            guard lstat(path, &st) == 0 else {
                throw Failure(message: "파일을 읽지 못했어요: \(display(name))")
            }
            let kind = st.st_mode & S_IFMT
            let isSymlink = kind == S_IFLNK
            let isDir = kind == S_IFDIR
            let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey, .isAliasFileKey])
            let node = Node(path: path, name: name, isDirectory: isDir, isPackage: isDir && (v?.isPackage ?? false),
                            isSymlink: isSymlink, isAlias: kind == S_IFREG && (v?.isAliasFile ?? false),
                            size: kind == S_IFREG ? UInt64(st.st_size) : 0)
            node.isJunk = MacJunk.isJunk(component: name)
            if node.walksInside {
                folders += 1
                if !node.isJunk {
                    let names = POSIX.list(path)
                    node.children = try names.sorted().map { try load(path + "/" + $0, name: $0) }
                }
            } else if !node.isJunk {
                files += 1
                bytes += node.size
                let ext = (name as NSString).pathExtension.lowercased()
                if ext == "heic" || ext == "heif" { node.isHEIC = true }
                if ext == "csv" || ext == "tsv" { node.csvNeedsBOM = needsBOM(path) }
            }
            return node
        }

        // URL은 이름을 자모로 풀어 돌려주므로, 디스크에 저장된 실제 이름을 폴더 목록에서 찾아 쓴다
        let tree = try urls.map { url -> Node in
            let parent = url.deletingLastPathComponent().path
            let shown = url.lastPathComponent
            let stored = POSIX.list(parent).first { $0 == shown } ?? shown
            return try load(parent == "/" ? "/" + stored : parent + "/" + stored, name: stored)
        }
        var issues: [Issue] = []
        for root in tree {
            collect(root, parentDisplay: "", siblings: nil, into: &issues)
        }
        // 맨 위 항목끼리도 이름이 겹치면 안 된다 (같은 폴더에 담기니까)
        let rootPlan = plan(tree, fixes: Set(Fix.allCases))
        for root in tree where rootPlan[ObjectIdentifier(root)]?.duplicate == true {
            issues.append(Issue(kind: .duplicateName, path: display(root.name), after: rootPlan[ObjectIdentifier(root)]?.name))
        }
        return Report(roots: urls, issues: issues, fileCount: files, folderCount: folders, totalBytes: bytes, tree: tree)
    }

    private static func collect(_ node: Node, parentDisplay: String, siblings: [ObjectIdentifier: Planned]?, into issues: inout [Issue]) {
        let shown = parentDisplay.isEmpty ? display(node.name) : parentDisplay + "/" + display(node.name)
        if node.isJunk {
            issues.append(Issue(kind: .junk, path: shown, after: nil))
            return
        }
        let fixed = fixName(node.name, convertHEIC: node.isHEIC)
        let planned = siblings?[ObjectIdentifier(node)]
        let finalName = planned?.name ?? fixed.name
        for kind in fixed.kinds {
            issues.append(Issue(kind: kind, path: shown, after: display(finalName)))
        }
        if planned?.duplicate == true {
            issues.append(Issue(kind: .duplicateName, path: shown, after: display(finalName)))
        }
        if node.isHEIC { issues.append(Issue(kind: .heic, path: shown, after: display(finalName))) }
        if node.csvNeedsBOM { issues.append(Issue(kind: .csvWithoutBOM, path: shown, after: nil)) }

        if let warning = warningKind(node) { issues.append(Issue(kind: warning, path: shown, after: nil)) }
        // Windows 기본 경로 길이 260자. 받는 사람의 "C:\Users\이름\Downloads\" 몫으로 50자를 남겨 둔다.
        let finalPath = (parentDisplay.isEmpty ? "" : parentDisplay + "/") + display(finalName)
        if finalPath.utf16.count > 210 && !node.walksInside {
            issues.append(Issue(kind: .longPath, path: shown, after: nil))
        }

        if node.walksInside {
            let childPlan = plan(node.children, fixes: Set(Fix.allCases))
            for child in node.children {
                collect(child, parentDisplay: finalPath, siblings: childPlan, into: &issues)
            }
        }
    }

    private static func warningKind(_ node: Node) -> IssueKind? {
        if node.isSymlink { return .symlink }
        if node.isAlias { return .alias }
        switch (node.name as NSString).pathExtension.lowercased() {
        case "pages", "numbers", "key": return .macOnlyDocument
        case "webloc", "inetloc", "fileloc": return .macShortcut
        case "app": return .macApp
        case "dmg", "pkg", "mpkg": return .macInstaller
        default: return nil
        }
    }

    /// UTF-8인데 BOM이 없고 한글 같은 비ASCII 글자가 있으면 Windows Excel이 깨뜨린다.
    /// 이미 CP949(EUC-KR)인 파일은 한국어 Windows Excel이 잘 열어서 그대로 둔다.
    static func needsBOM(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let limit = 8 << 20
        guard var data = try? handle.read(upToCount: limit) else { return false }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) || data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return false
        }
        guard data.contains(where: { $0 >= 0x80 }) else { return false }
        if data.count == limit {
            // 잘린 끝의 반쪽 글자는 빼고 본다
            var cut = 0
            while cut < 3, let last = data.last, last & 0xC0 == 0x80 { data.removeLast(); cut += 1 }
            if let last = data.last, last >= 0xC0 { data.removeLast() }
        }
        return String(data: data, encoding: .utf8) != nil
    }

    // MARK: - 이름 고치기

    private static let reserved: Set<String> = {
        var s: Set<String> = ["CON", "PRN", "AUX", "NUL"]
        for i in 1...9 { s.insert("COM\(i)"); s.insert("LPT\(i)") }
        return s
    }()

    /// Windows에서 못 쓰는 글자를 비슷한 글자로. (Mac 이름의 ':'는 Finder에서 '/'로 보이는 글자다)
    private static let replacements: [Character: String] = [
        ":": "-", "\\": "-", "|": "-", "*": "_", "?": "", "\"": "'", "<": "(", ">": ")",
    ]

    static func fixName(_ name: String, convertHEIC: Bool) -> (name: String, kinds: [IssueKind]) {
        var kinds: [IssueKind] = []
        var result = name.precomposedStringWithCanonicalMapping
        if Array(result.utf8) != Array(name.utf8) { kinds.append(.decomposed) }

        var cleaned = ""
        var changed = false
        for ch in result {
            if let r = replacements[ch] {
                cleaned += r
                changed = true
            } else if ch.unicodeScalars.allSatisfy({ $0.value < 0x20 || $0.value == 0x7F }) {
                changed = true
            } else {
                cleaned.append(ch)
            }
        }
        if changed {
            kinds.append(.forbiddenChars)
            result = cleaned
        }

        var trimmed = result
        while let last = trimmed.last, last == " " || last == "." { trimmed.removeLast() }
        if trimmed != result {
            kinds.append(.trailingDotSpace)
            result = trimmed
        }
        if result.isEmpty || result.allSatisfy({ $0 == "." || $0 == " " }) { result = "이름 없음" }

        let stem = String(result.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        if reserved.contains(stem.trimmingCharacters(in: .whitespaces).uppercased()) {
            kinds.append(.reservedName)
            result = stem + "_" + result.dropFirst(stem.count)
        }

        if convertHEIC {
            result = (result as NSString).deletingPathExtension + ".jpg"
        }
        return (result, kinds)
    }

    struct Planned {
        let name: String
        let duplicate: Bool
    }

    /// 한 폴더 안 항목들의 최종 이름. Windows는 대소문자를 가리지 않아서 "Report.txt"와 "report.txt"가 겹친다.
    /// 바뀌지 않는 이름이 먼저 자리를 잡고, 겹치면 " (2)"를 붙인다.
    static func plan(_ nodes: [Node], fixes: Set<Fix>) -> [ObjectIdentifier: Planned] {
        var taken = Set<String>()
        var out: [ObjectIdentifier: Planned] = [:]
        let live = nodes.filter { !($0.isJunk && fixes.contains(.junk)) }
        let wanted = live.map { node -> (Node, String) in
            let fixed = fixName(node.name, convertHEIC: node.isHEIC && fixes.contains(.heic))
            let name = fixes.contains(.names) ? fixed.name : (node.isHEIC && fixes.contains(.heic) ? (node.name as NSString).deletingPathExtension + ".jpg" : node.name)
            return (node, name)
        }
        let ordered = wanted.filter { !differs($0.1, $0.0.name) } + wanted.filter { differs($0.1, $0.0.name) }
        for (node, name) in ordered {
            var candidate = name
            var duplicate = false
            // 이름 고치기를 꺼도 HEIC → JPG 때문에 겹칠 수 있어서 늘 확인한다
            var n = 2
            while taken.contains(key(candidate)) {
                duplicate = true
                let ext = (name as NSString).pathExtension
                let base = node.walksInside || ext.isEmpty ? name : (name as NSString).deletingPathExtension
                candidate = node.walksInside || ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
                n += 1
            }
            taken.insert(key(candidate))
            out[ObjectIdentifier(node)] = Planned(name: candidate, duplicate: duplicate)
        }
        return out
    }

    /// Swift의 ==는 자모가 풀린 한글과 붙은 한글을 같다고 본다. 이름은 바이트로 비교해야 한다.
    static func differs(_ a: String, _ b: String) -> Bool { Array(a.utf8) != Array(b.utf8) }

    private static func key(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }

    /// Finder에 보이는 모양 (저장된 ':'는 '/'로 보인다)
    static func display(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.replacingOccurrences(of: ":", with: "/")
    }

    // MARK: - 고치기

    public typealias Progress = @Sendable (_ fraction: Double, _ name: String) -> Void

    public static func apply(_ report: Report, fixes: Set<Fix>, mode: Mode,
                             progress: Progress? = nil, cancel: CancelToken? = nil) throws -> Outcome {
        let total = max(1, report.fileCount)
        var done = 0
        func step(_ node: Node) throws {
            if cancel?.isCancelled == true { throw ZipError.cancelled }
            done += 1
            if done % 16 == 0 || done == total { progress?(Double(min(done, total)) / Double(total), display(node.name)) }
        }

        switch mode {
        case .copy:
            let parent = report.roots[0].deletingLastPathComponent().path
            let folder = uniquePath(in: parent, name: "Windows로 보낼 파일")
            try POSIX.mkdir(folder)
            var outcome = Outcome(items: [], folder: URL(fileURLWithPath: folder))
            let rootPlan = plan(report.tree, fixes: fixes)
            var items: [URL] = []
            for root in report.tree {
                guard let p = rootPlan[ObjectIdentifier(root)] else { continue }
                let dst = folder + "/" + p.name
                try copy(root, to: dst, fixes: fixes, outcome: &outcome, step: step)
                if differs(p.name, root.name) { outcome.renamed += 1 }
                items.append(URL(fileURLWithPath: dst))
            }
            return Outcome(items: items, folder: outcome.folder, renamed: outcome.renamed, removed: outcome.removed,
                           bomAdded: outcome.bomAdded, converted: outcome.converted, trashed: [])

        case .inPlace:
            var outcome = Outcome(items: [], folder: nil)
            // 맨 위 항목은 저마다 다른 폴더에 있을 수 있어서 폴더별로 이름을 정한다
            let byParent = Dictionary(grouping: report.tree) { ($0.path as NSString).deletingLastPathComponent }
            var finalPaths: [ObjectIdentifier: String] = [:]
            for (parent, nodes) in byParent {
                let p = plan(nodes, fixes: fixes)
                for node in nodes {
                    if let path = try fixInPlace(node, parent: parent, planned: p[ObjectIdentifier(node)],
                                                 fixes: fixes, outcome: &outcome, step: step) {
                        finalPaths[ObjectIdentifier(node)] = path
                    }
                }
            }
            let items = report.tree.compactMap { finalPaths[ObjectIdentifier($0)] }.map { URL(fileURLWithPath: $0) }
            return Outcome(items: items, folder: nil, renamed: outcome.renamed, removed: outcome.removed,
                           bomAdded: outcome.bomAdded, converted: outcome.converted, trashed: outcome.trashed)
        }
    }

    private static func copy(_ node: Node, to dst: String, fixes: Set<Fix>, outcome: inout Outcome,
                             step: (Node) throws -> Void) throws {
        if node.walksInside {
            try POSIX.mkdir(dst)
            let p = plan(node.children, fixes: fixes)
            for child in node.children {
                guard let planned = p[ObjectIdentifier(child)] else {
                    outcome.removed += 1
                    continue
                }
                if differs(planned.name, child.name) { outcome.renamed += 1 }
                try copy(child, to: dst + "/" + planned.name, fixes: fixes, outcome: &outcome, step: step)
            }
            return
        }
        try step(node)
        if node.isHEIC && fixes.contains(.heic) {
            try convertToJPEG(node.path, to: dst)
            outcome.converted += 1
        } else if node.csvNeedsBOM && fixes.contains(.csv) {
            try POSIX.copy(node.path, dst, recursive: false)
            try prependBOM(dst)
            outcome.bomAdded += 1
        } else {
            try POSIX.copy(node.path, dst, recursive: node.isPackage)
        }
    }

    /// 아래부터 고쳐 올라온다 (폴더 이름을 먼저 바꾸면 안쪽 경로가 달라지니까). 남은 항목의 최종 경로를 돌려준다.
    private static func fixInPlace(_ node: Node, parent: String, planned: Planned?, fixes: Set<Fix>,
                                   outcome: inout Outcome, step: (Node) throws -> Void) throws -> String? {
        guard let planned else {
            // Mac 숨김 파일: 휴지통으로
            var trashed: NSURL?
            try FileManager.default.trashItem(at: URL(fileURLWithPath: node.path), resultingItemURL: &trashed)
            if let t = trashed as URL? { outcome.trashed.append(t) }
            outcome.removed += 1
            return nil
        }
        var current = node.path
        if node.walksInside {
            let p = plan(node.children, fixes: fixes)
            for child in node.children {
                _ = try fixInPlace(child, parent: node.path, planned: p[ObjectIdentifier(child)], fixes: fixes,
                                   outcome: &outcome, step: step)
            }
        } else {
            try step(node)
            if node.isHEIC && fixes.contains(.heic) {
                let jpg = freePath(parent + "/" + planned.name, except: nil)
                try convertToJPEG(node.path, to: jpg)
                var trashed: NSURL?
                try FileManager.default.trashItem(at: URL(fileURLWithPath: node.path), resultingItemURL: &trashed)
                if let t = trashed as URL? { outcome.trashed.append(t) }
                outcome.converted += 1
                return jpg
            }
            if node.csvNeedsBOM && fixes.contains(.csv) {
                try prependBOM(current)
                outcome.bomAdded += 1
            }
        }
        if differs(planned.name, node.name) {
            let target = freePath(parent + "/" + planned.name, except: current)
            try POSIX.rename(current, target)
            current = target
            outcome.renamed += 1
        }
        return current
    }

    /// path가 비어 있으면 그대로, 다른 파일이 있으면 " 2", " 3"을 붙인다.
    /// except는 지금 이름을 바꾸려는 그 파일이다 (자모만 다른 같은 이름은 같은 파일로 보이니까).
    private static func freePath(_ path: String, except: String?) -> String {
        func occupied(_ p: String) -> Bool {
            guard let ino = POSIX.inode(p) else { return false }
            if let except, let mine = POSIX.inode(except), mine == ino { return false }
            return true
        }
        guard occupied(path) else { return path }
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var n = 2
        while true {
            let candidate = dir + "/" + (ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if !occupied(candidate) { return candidate }
            n += 1
        }
    }

    private static func uniquePath(in dir: String, name: String) -> String {
        var candidate = dir + "/" + name
        var n = 2
        while POSIX.inode(candidate) != nil {
            candidate = dir + "/\(name) \(n)"
            n += 1
        }
        return candidate
    }

    /// HEIC → JPG. 사진 정보(촬영 날짜, 방향 등)는 그대로 옮긴다.
    static func convertToJPEG(_ src: String, to dst: String) throws {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: src) as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw Failure(message: "사진을 읽지 못했어요: \(display((src as NSString).lastPathComponent))")
        }
        // ImageIO도 경로를 자모로 풀어 쓰므로, 영문 임시 이름으로 만든 뒤 POSIX로 옮긴다
        let dir = (dst as NSString).deletingLastPathComponent
        let tmp = dir + "/.finderie-\(UUID().uuidString).jpg"
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: tmp) as CFURL,
                                                         UTType.jpeg.identifier as CFString, 1, nil) else {
            throw Failure(message: "JPG 파일을 만들지 못했어요.")
        }
        let props = [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        CGImageDestinationAddImageFromSource(dest, source, 0, props)
        guard CGImageDestinationFinalize(dest) else {
            unlink(tmp)
            throw Failure(message: "사진을 JPG로 바꾸지 못했어요: \(display((src as NSString).lastPathComponent))")
        }
        do { try POSIX.rename(tmp, dst) } catch { unlink(tmp); throw error }
    }

    /// 맨 앞에 UTF-8 BOM(EF BB BF)을 붙인다. 같은 폴더의 임시 파일에 쓴 뒤 바꿔치기한다.
    static func prependBOM(_ path: String) throws {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw Failure(message: "파일을 읽지 못했어요: \(display((path as NSString).lastPathComponent))")
        }
        let tmp = (path as NSString).deletingLastPathComponent + "/.finderie-\(UUID().uuidString).tmp"
        try POSIX.write(Data([0xEF, 0xBB, 0xBF]) + data, to: tmp)
        var st = stat()
        if lstat(path, &st) == 0 { chmod(tmp, st.st_mode & 0o7777) }
        do { try POSIX.rename(tmp, path) } catch { unlink(tmp); throw error }
    }
}

/// 이름을 받은 그대로(한글 NFC 그대로) 디스크에 쓰는 얇은 POSIX 포장
enum POSIX {
    static func fail(_ what: String, _ path: String) -> SendPrep.Failure {
        let reason = String(cString: strerror(errno))
        return SendPrep.Failure(message: "\(what) 못했어요: \(SendPrep.display((path as NSString).lastPathComponent)) (\(reason))")
    }

    static func mkdir(_ path: String) throws {
        if Darwin.mkdir(path, 0o755) != 0 { throw fail("폴더를 만들지", path) }
    }

    static func rename(_ from: String, _ to: String) throws {
        if Darwin.rename(from, to) != 0 { throw fail("이름을 바꾸지", from) }
    }

    static func copy(_ from: String, _ to: String, recursive: Bool) throws {
        var flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE | COPYFILE_NOFOLLOW_SRC | COPYFILE_EXCL)
        if recursive { flags |= copyfile_flags_t(COPYFILE_RECURSIVE) }
        if copyfile(from, to, nil, flags) != 0 { throw fail("복사하지", from) }
    }

    static func write(_ data: Data, to path: String) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard fd >= 0 else { throw fail("파일을 쓰지", path) }
        defer { close(fd) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 { if errno == EINTR { continue }; throw fail("파일을 쓰지", path) }
                offset += n
            }
        }
    }

    /// 폴더 안 이름들을 디스크에 저장된 그대로. (FileManager는 "._"로 시작하는 파일을 숨겨서 직접 읽는다)
    static func list(_ path: String) -> [String] {
        guard let dir = opendir(path) else { return [] }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    static func inode(_ path: String) -> ino_t? {
        var st = stat()
        return lstat(path, &st) == 0 ? st.st_ino : nil
    }
}
