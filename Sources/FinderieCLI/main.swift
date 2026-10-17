import Foundation
import ZipCore
import ShrinkCore
import ConvertCore

// 테스트용 명령줄 도구
//   finderie-cli zip [--level fast|normal|best] [--no-store] [--threads N] [--chunk BYTES] [--background] [--io auto|parallel|sequential] <utf8|cp949|mac> <out.zip> <파일...>
//   finderie-cli unzip [--threads N] <in.zip>
//   finderie-cli list <in.zip>
//   finderie-cli scan <파일...>
//   finderie-cli prep [--in-place] [--skip names,junk,csv,heic] <파일...>
//   finderie-cli shrink [--level 0|1|2] [--in-place] [--dry] <파일...>
//   finderie-cli convert <jpg|png|heic|webp|avif|tiff> <파일...>
var args = Array(CommandLine.arguments.dropFirst())
func fail(_ msg: String) -> Never { FileHandle.standardError.write((msg + "\n").data(using: .utf8)!); exit(1) }

var options = ZipOptions()
func takeFlags() {
    while let f = args.first, f.hasPrefix("--") {
        args.removeFirst()
        switch f {
        case "--no-store": options.storeCompressedFiles = false
        case "--level": options.level = CompressionLevel(rawValue: args.removeFirst()) ?? .normal
        case "--threads": options.threads = Int(args.removeFirst()) ?? 1
        case "--chunk": options.chunkSize = Int(args.removeFirst()) ?? (1 << 20)
        case "--background": options.background = true
        case "--io": options.ioMode = IOMode(rawValue: args.removeFirst()) ?? .auto
        default: fail("unknown flag \(f)")
        }
    }
}

func printReport(_ r: SendPrep.Report) {
    print("files=\(r.fileCount) folders=\(r.folderCount) bytes=\(r.totalBytes)")
    for i in r.issues { print("\(i.kind.rawValue)\t\(i.path)\(i.after.map { "\t→ " + $0 } ?? "")\(i.note.map { "\t(" + $0 + ")" } ?? "")") }
}

do {
    let cmd = args.isEmpty ? "" : args.removeFirst()
    var mode = SendPrep.Mode.copy
    var fixes = Set(SendPrep.Fix.allCases)
    var level = Shrink.Level.medium
    var dry = false
    if cmd == "prep" || cmd == "shrink" {
        while let f = args.first, f.hasPrefix("--") {
            args.removeFirst()
            switch f {
            case "--in-place": mode = .inPlace
            case "--level": level = Shrink.Level(rawValue: Int(args.removeFirst()) ?? 1) ?? .medium
            case "--dry": dry = true
            case "--skip": for s in args.removeFirst().split(separator: ",") { fixes.remove(SendPrep.Fix(rawValue: String(s)) ?? .names) }
            default: fail("unknown flag \(f)")
            }
        }
    }
    if cmd != "convert" { takeFlags() }
    switch cmd {
    case "convert" where args.count >= 2:
        guard let format = Convert.Format(rawValue: args.removeFirst()) else { fail("unknown format") }
        let roots = args.map { URL(fileURLWithPath: $0) }
        let items = try Convert.scan(roots)
        for i in items { print("\(i.kind)\t\(i.shown)\t\(i.size)") }
        let o = try Convert.apply(items, roots: roots, to: format)
        print("made=\(o.made) same=\(o.same) before=\(o.before) after=\(o.after) failed=\(o.failed)")
        print("folder=\(o.folder?.path ?? "-")")
    case "zip" where args.count >= 3:
        options.nameEncoding = ["utf8": .windowsUTF8, "cp949": .windowsCP949, "mac": .macDefault][args[0]] ?? .windowsUTF8
        let stats = try ZipWriter.compress(args[2...].map { URL(fileURLWithPath: $0) }, to: URL(fileURLWithPath: args[1]), options: options)
        print("ok threads=\(stats.threads) sequential=\(stats.sequentialIO)")
    case "unzip" where args.count == 1:
        let r = try ZipReader.extract(URL(fileURLWithPath: args[0]), options: options)
        print("\(r.destination.path) files=\(r.fileCount) encoding=\(r.encoding.rawValue) sequential=\(r.sequentialIO)")
    case "list" where args.count == 1:
        for e in try ZipReader.entries(of: URL(fileURLWithPath: args[0])) { print("\(e.encoding.rawValue)\t\(e.name)") }
    case "scan" where !args.isEmpty:
        printReport(try SendPrep.scan(args.map { URL(fileURLWithPath: $0) }))
    case "prep" where !args.isEmpty:
        let report = try SendPrep.scan(args.map { URL(fileURLWithPath: $0) })
        printReport(report)
        let o = try SendPrep.apply(report, fixes: fixes, mode: mode)
        print("renamed=\(o.renamed) removed=\(o.removed) bom=\(o.bomAdded) converted=\(o.converted) cleaned=\(o.cleaned) trashed=\(o.trashed.count)")
        print("folder=\(o.folder?.path ?? "-")")
        for item in o.items { print("item=\(item.path)") }
    case "shrink" where !args.isEmpty:
        let report = try Shrink.scan(args.map { URL(fileURLWithPath: $0) })
        print("files=\(report.fileCount) bytes=\(report.totalBytes) estimate=\(report.estimatedTotal(kinds: Set(Shrink.Kind.allCases), level: level))")
        for i in report.items { print("\(i.kind.rawValue)\t\(i.path)\t\(i.size) → ~\(i.estimate(level))\t\(i.detail)") }
        if dry { break }
        let start = Date()
        let o = try Shrink.apply(report, kinds: Set(Shrink.Kind.allCases), level: level, mode: mode)
        print("before=\(o.before) after=\(o.after) shrunk=\(o.shrunk) kept=\(o.kept) failed=\(o.failed) trashed=\(o.trashed.count) \(String(format: "%.1fs", Date().timeIntervalSince(start)))")
        print("folder=\(o.folder?.path ?? "-")")
    default:
        fail("usage: finderie-cli zip [--level fast|normal|best] [--no-store] [--threads N] [--chunk BYTES] [--background] [--io auto|parallel|sequential] <utf8|cp949|mac> out.zip files... | unzip in.zip | list in.zip")
    }
} catch {
    fail("error: \(error.localizedDescription)")
}
