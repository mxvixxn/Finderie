import Foundation
import ZipCore

// 테스트용 명령줄 도구
//   zippie-cli zip [--level fast|normal|best] [--no-store] [--threads N] [--chunk BYTES] [--background] [--io auto|parallel|sequential] <utf8|cp949|mac> <out.zip> <파일...>
//   zippie-cli unzip [--threads N] <in.zip>
//   zippie-cli list <in.zip>
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

do {
    let cmd = args.isEmpty ? "" : args.removeFirst()
    takeFlags()
    switch cmd {
    case "zip" where args.count >= 3:
        options.nameEncoding = ["utf8": .windowsUTF8, "cp949": .windowsCP949, "mac": .macDefault][args[0]] ?? .windowsUTF8
        let stats = try ZipWriter.compress(args[2...].map { URL(fileURLWithPath: $0) }, to: URL(fileURLWithPath: args[1]), options: options)
        print("ok threads=\(stats.threads) sequential=\(stats.sequentialIO)")
    case "unzip" where args.count == 1:
        let r = try ZipReader.extract(URL(fileURLWithPath: args[0]), options: options)
        print("\(r.destination.path) files=\(r.fileCount) encoding=\(r.encoding.rawValue) sequential=\(r.sequentialIO)")
    case "list" where args.count == 1:
        for e in try ZipReader.entries(of: URL(fileURLWithPath: args[0])) { print("\(e.encoding.rawValue)\t\(e.name)") }
    default:
        fail("usage: zippie-cli zip [--level fast|normal|best] [--no-store] [--threads N] [--chunk BYTES] [--background] [--io auto|parallel|sequential] <utf8|cp949|mac> out.zip files... | unzip in.zip | list in.zip")
    }
} catch {
    fail("error: \(error.localizedDescription)")
}
