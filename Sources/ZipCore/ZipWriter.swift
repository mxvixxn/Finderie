import Foundation

/// 파일/폴더를 ZIP으로 압축한다. 한글 파일 이름 인코딩을 옵션으로 고를 수 있다.
public enum ZipWriter {
    private struct Source {
        let url: URL
        let name: String // 압축 파일 안의 경로. 폴더는 "/"로 끝남
        let isDirectory: Bool
        let size: UInt64
        let modified: Date
        let mode: UInt16
    }

    private struct CentralRecord {
        let nameBytes: [UInt8]
        let extra: Data
        let flags: UInt16
        let method: UInt16
        let dosTime: UInt16
        let dosDate: UInt16
        let crc: UInt32
        let compressedSize: UInt64
        let size: UInt64
        let externalAttributes: UInt32
        let localOffset: UInt64
        /// 로컬 헤더에 Zip64 정보를 넣었는지 (그랬다면 중앙 목록에도 크기를 Zip64로 적는다)
        let local64: Bool
    }

    private static let utf8Flag: UInt16 = 1 << 11
    private static let maxUInt32 = UInt64(UInt32.max)
    /// 이보다 큰 파일은 처음부터 Zip64 헤더로 쓴다. 압축하다 아주 조금 커지는 경우까지 대비해 4GB보다 1MB 작게 잡는다.
    private static let zip64FileThreshold: UInt64 = 0xFFF0_0000
    /// 조각 색인이 보조 필드(최대 64KB)에 들어가도록 파일당 조각 수를 이 정도로 제한한다.
    private static let maxIndexedChunks: UInt64 = 15_000

    /// 파일마다 쓸 조각 크기. 아주 큰 파일은 조각을 키워 색인이 보조 필드에 들어가게 한다.
    private static func chunkSize(for size: UInt64, base: UInt64) -> UInt64 {
        guard size > base * maxIndexedChunks else { return base }
        let needed = (size + maxIndexedChunks - 1) / maxIndexedChunks
        let unit: UInt64 = 64 * 1024
        return (needed + unit - 1) / unit * unit
    }

    /// 여러 항목을 압축할 때 쓸 기본 출력 경로("이름.zip", 겹치면 "이름 2.zip").
    public static func suggestedOutputURL(for items: [URL]) -> URL {
        let first = items[0]
        let dir = first.deletingLastPathComponent()
        let base: String
        if items.count == 1 {
            let isDir = (try? first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            base = isDir ? first.lastPathComponent : first.deletingPathExtension().lastPathComponent
        } else {
            base = "압축파일"
        }
        return uniqueURL(in: dir, base: base, ext: "zip")
    }

    static func uniqueURL(in dir: URL, base: String, ext: String) -> URL {
        let fm = FileManager.default
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var candidate = dir.appendingPathComponent(base + suffix)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(n)\(suffix)")
            n += 1
        }
        return candidate
    }

    // MARK: - 압축

    @discardableResult
    public static func compress(
        _ items: [URL],
        to output: URL,
        options: ZipOptions,
        progress: ProgressHandler? = nil
    ) throws -> ZipStats {
        let report = ProgressThrottle(progress)
        report.report(0, "준비 중", force: true)
        let plan = ExecutionPlan.make(options, involving: items + [output])
        return try plan.withIOPolicy {
            try compress(items, to: output, options: options, plan: plan, report: report)
        }
    }

    private static func compress(
        _ items: [URL],
        to output: URL,
        options: ZipOptions,
        plan: ExecutionPlan,
        report: ProgressThrottle
    ) throws -> ZipStats {
        let sources = try collect(items, options: options)
        guard !sources.isEmpty else { throw ZipError.nothingToCompress }

        let totalBytes = max(sources.reduce(UInt64(0)) { $0 + $1.size }, 1)
        var doneBytes: UInt64 = 0
        let chunkSize = UInt64(options.chunkSize)

        // 이미 압축된 파일인지 미리 판별 (여러 코어로 동시에, 순차 모드면 순서대로)
        var storeFlags = [Bool](repeating: false, count: sources.count)
        if options.storeCompressedFiles {
            storeFlags.withUnsafeMutableBufferPointer { flags in
                let base = flags.baseAddress!
                let counter = AtomicCounter()
                plan.runWorkers(plan.sequential ? 1 : plan.threads) { _ in
                    while true {
                        let i = counter.increment()
                        if i >= sources.count { return }
                        let s = sources[i]
                        if !s.isDirectory && s.size > 0 { base[i] = ParallelDeflate.shouldStore(s.url, size: s.size) }
                    }
                }
            }
        }

        // 모든 파일을 조각 작업으로 나눈다
        var jobs: [ParallelDeflate.Job] = []
        for (i, src) in sources.enumerated() where !src.isDirectory && src.size > 0 {
            let fileChunk = Self.chunkSize(for: src.size, base: chunkSize)
            var pos: UInt64 = 0
            while pos < src.size {
                let len = Int(min(fileChunk, src.size - pos))
                jobs.append(.init(url: src.url, name: src.name, offset: pos, length: len,
                                  isFirst: pos == 0, isLast: pos + UInt64(len) == src.size, store: storeFlags[i],
                                  fileSize: src.size))
                pos += UInt64(len)
            }
        }
        let pipeline = ChunkPipeline(jobs: jobs, options: options, plan: plan)
        defer { pipeline.cancel() }

        // 같은 폴더에 임시 파일로 쓰고, 끝나면 제자리로 옮긴다.
        let fm = FileManager.default
        let temp = output.deletingLastPathComponent()
            .appendingPathComponent(".zippie-\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: nil) else {
            throw ZipError.cannotRead(output.path)
        }
        var finished = false
        defer { if !finished { try? fm.removeItem(at: temp) } }

        let handle = try FileHandle(forWritingTo: temp)
        defer { try? handle.close() }
        let out = BufferedWriter(handle)

        var records: [CentralRecord] = []

        for (i, src) in sources.enumerated() {
            let offset = out.position
            let encoded = encodeName(src.name, as: options.nameEncoding)
            let (dosTime, dosDate) = DOSDate.encode(src.modified)
            let isEmpty = src.isDirectory || src.size == 0
            let method: UInt16 = isEmpty || storeFlags[i] ? 0 : 8
            let flags: UInt16 = encoded.utf8 ? utf8Flag : 0
            let local64 = !isEmpty && src.size > zip64FileThreshold
            let fileChunk = Self.chunkSize(for: src.size, base: chunkSize)

            // Zip64 보조 필드(0x0001): 원래 크기, 압축 크기 (각 8바이트). 로컬 헤더 보조 필드의 맨 앞에 둔다.
            func zip64Sizes(_ size: UInt64, _ compressed: UInt64) -> Data {
                var d = Data()
                d.le16(0x0001); d.le16(16)
                d.le64(size); d.le64(compressed)
                return d
            }

            func localHeader(crc: UInt32, compressed: UInt64, size: UInt64) -> Data {
                let extra = local64 ? zip64Sizes(size, compressed) + encoded.extra : encoded.extra
                var h = Data()
                h.le32(0x0403_4B50)
                h.le16(local64 ? 45 : 20)
                h.le16(flags)
                h.le16(method)
                h.le16(dosTime)
                h.le16(dosDate)
                h.le32(crc)
                h.le32(local64 ? UInt32.max : UInt32(compressed))
                h.le32(local64 ? UInt32.max : UInt32(size))
                h.le16(UInt16(encoded.bytes.count))
                h.le16(UInt16(extra.count))
                h.append(contentsOf: encoded.bytes)
                h.append(extra)
                return h
            }

            var crc: UInt32 = 0
            var compressed: UInt64 = 0
            var written: UInt64 = 0
            var centralExtra = encoded.extra

            if isEmpty {
                try out.write(localHeader(crc: 0, compressed: 0, size: 0))
            } else if src.size <= fileChunk {
                // 조각 하나짜리(대부분의 파일): 결과를 먼저 받아서 헤더를 한 번에 완성해 쓴다
                let piece = try pipeline.nextOutput()
                (crc, compressed, written) = (piece.crc, UInt64(piece.data.count), UInt64(piece.length))
                try out.write(localHeader(crc: crc, compressed: compressed, size: written))
                try out.write(piece.data)
                doneBytes += written
                report.report(Double(doneBytes) / Double(totalBytes), src.name)
            } else {
                // 큰 파일: 조각들을 순서대로 이어 쓰고, 헤더의 CRC/크기는 나중에 고친다
                try out.write(localHeader(crc: 0, compressed: 0, size: 0))
                var pieceSizes: [UInt32] = []
                while written < src.size {
                    let piece = try pipeline.nextOutput()
                    try out.write(piece.data)
                    crc = written == 0 ? piece.crc : CRC32.combine(crc, piece.crc, length: piece.length)
                    compressed += UInt64(piece.data.count)
                    written += UInt64(piece.length)
                    pieceSizes.append(UInt32(piece.data.count))
                    doneBytes += UInt64(piece.length)
                    report.report(Double(doneBytes) / Double(totalBytes), src.name)
                }
                var patch = Data()
                patch.le32(crc)
                if local64 {
                    try out.patch(at: offset + 14, patch)
                    // 이름 뒤 Zip64 보조 필드의 값 부분 (머리 4바이트 다음)
                    var sizes = Data()
                    sizes.le64(written); sizes.le64(compressed)
                    try out.patch(at: offset + 30 + UInt64(encoded.bytes.count) + 4, sizes)
                } else {
                    patch.le32(UInt32(compressed)); patch.le32(UInt32(written))
                    try out.patch(at: offset + 14, patch)
                }

                // 조각끼리 독립적으로 압축됐으니, 풀 때 병렬로 풀 수 있도록 색인을 남긴다
                if method == 8 {
                    let index = ChunkIndex(chunkSize: UInt32(fileChunk), compressedSizes: pieceSizes).encoded()
                    // Zip64 필드(최대 28바이트) 자리를 남겨 둔다
                    if centralExtra.count + index.count + 28 <= Int(UInt16.max) { centralExtra.append(index) }
                }
            }
            // 4GB 바로 아래 파일이 압축하다 4GB를 넘는 극히 드문 경우: 헤더를 이미 32비트로 써서 되돌릴 수 없다
            guard local64 || compressed < maxUInt32 else { throw ZipError.tooLarge(src.name) }

            let type: UInt32 = src.isDirectory ? 0o040000 : 0o100000
            records.append(CentralRecord(
                nameBytes: encoded.bytes,
                extra: centralExtra,
                flags: flags,
                method: method,
                dosTime: dosTime,
                dosDate: dosDate,
                crc: crc,
                compressedSize: compressed,
                size: written,
                externalAttributes: (type | UInt32(src.mode)) << 16 | (src.isDirectory ? 0x10 : 0),
                localOffset: offset,
                local64: local64
            ))
        }

        // 중앙 디렉터리
        let centralOffset = out.position
        var central = Data()
        for r in records {
            // 32비트 칸에 안 들어가는 값은 0xFFFFFFFF로 두고 Zip64 보조 필드에 순서대로(크기, 압축 크기, 위치) 적는다
            let bigSize = r.local64 || r.size >= maxUInt32
            let bigCompressed = r.local64 || r.compressedSize >= maxUInt32
            let bigOffset = r.localOffset >= maxUInt32
            var zip64 = Data()
            if bigSize { zip64.le64(r.size) }
            if bigCompressed { zip64.le64(r.compressedSize) }
            if bigOffset { zip64.le64(r.localOffset) }
            var extra = Data()
            if !zip64.isEmpty {
                extra.le16(0x0001); extra.le16(UInt16(zip64.count)); extra.append(zip64)
            }
            extra.append(r.extra)
            let needed: UInt16 = zip64.isEmpty ? 20 : 45

            central.le32(0x0201_4B50)
            central.le16(3 << 8 | 45) // 만든 곳: Unix, ZIP 4.5 (Zip64)
            central.le16(needed)
            central.le16(r.flags)
            central.le16(r.method)
            central.le16(r.dosTime)
            central.le16(r.dosDate)
            central.le32(r.crc)
            central.le32(bigCompressed ? UInt32.max : UInt32(r.compressedSize))
            central.le32(bigSize ? UInt32.max : UInt32(r.size))
            central.le16(UInt16(r.nameBytes.count))
            central.le16(UInt16(extra.count))
            central.le16(0) // 주석
            central.le16(0) // 디스크 번호
            central.le16(0) // 내부 속성
            central.le32(r.externalAttributes)
            central.le32(bigOffset ? UInt32.max : UInt32(r.localOffset))
            central.append(contentsOf: r.nameBytes)
            central.append(extra)
        }
        let centralSize = UInt64(central.count)
        let count = UInt64(records.count)

        var end = Data()
        // 파일이 65,535개 이상이거나 목록 위치/크기가 4GB를 넘으면 Zip64 끝 레코드와 위치 표시를 앞에 둔다
        if count >= 0xFFFF || centralOffset >= maxUInt32 || centralSize >= maxUInt32 {
            let zip64EndOffset = centralOffset + centralSize
            end.le32(0x0606_4B50)
            end.le64(44)              // 이 레코드의 나머지 크기
            end.le16(3 << 8 | 45)
            end.le16(45)
            end.le32(0); end.le32(0)  // 디스크 번호
            end.le64(count); end.le64(count)
            end.le64(centralSize)
            end.le64(centralOffset)
            end.le32(0x0706_4B50)     // Zip64 끝 레코드 위치 표시
            end.le32(0)
            end.le64(zip64EndOffset)
            end.le32(1)
        }
        end.le32(0x0605_4B50)
        end.le16(0); end.le16(0)
        end.le16(UInt16(min(count, 0xFFFF))); end.le16(UInt16(min(count, 0xFFFF)))
        end.le32(UInt32(min(centralSize, maxUInt32)))
        end.le32(UInt32(min(centralOffset, maxUInt32)))
        end.le16(0)

        try out.write(central)
        try out.write(end)
        try out.flush()
        try handle.close()

        if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
        try fm.moveItem(at: temp, to: output)
        finished = true
        report.report(1, "", force: true)
        return ZipStats(sequentialIO: plan.sequential, threads: plan.threads)
    }

    // MARK: - 대상 수집

    private static func collect(_ items: [URL], options: ZipOptions) throws -> [Source] {
        let fm = FileManager.default
        var result: [Source] = []

        func add(_ url: URL, name: String) throws {
            var st = stat()
            guard lstat(url.path, &st) == 0 else { throw ZipError.cannotRead(name) }
            let type = st.st_mode & S_IFMT
            guard type == S_IFDIR || type == S_IFREG else { return } // 심볼릭 링크 등은 건너뜀
            let isDir = type == S_IFDIR
            let size = UInt64(st.st_size)
            let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            result.append(Source(
                url: url,
                name: isDir ? name + "/" : name,
                isDirectory: isDir,
                size: isDir ? 0 : size,
                modified: mtime,
                mode: UInt16(st.st_mode & 0o7777)
            ))
        }

        for item in items {
            let top = item.lastPathComponent
            if options.excludeMacFiles && MacJunk.isJunk(component: top) { continue }
            try add(item, name: top)

            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir, let walker = fm.enumerator(atPath: item.path) else { continue }
            while let rel = walker.nextObject() as? String {
                let leaf = (rel as NSString).lastPathComponent
                if options.excludeMacFiles && MacJunk.isJunk(component: leaf) {
                    walker.skipDescendants()
                    continue
                }
                try add(item.appendingPathComponent(rel), name: top + "/" + rel)
            }
        }
        return result
    }

    // MARK: - 파일 이름 인코딩

    struct EncodedName {
        let bytes: [UInt8]
        let utf8: Bool
        let extra: Data
    }

    /// Windows에서 파일 이름으로 쓸 수 없는 문자.
    private static let windowsForbidden = Set("\\:*?\"<>|")

    static func encodeName(_ path: String, as encoding: NameEncoding) -> EncodedName {
        switch encoding {
        case .macDefault:
            let s = path.decomposedStringWithCanonicalMapping
            return EncodedName(bytes: Array(s.utf8), utf8: false, extra: Data())

        case .windowsUTF8:
            let s = windowsSafe(path)
            return EncodedName(bytes: Array(s.utf8), utf8: true, extra: Data())

        case .windowsCP949:
            let s = windowsSafe(path)
            var bytes: [UInt8] = []
            for ch in s {
                if let d = String(ch).data(using: Encodings.cp949) {
                    bytes.append(contentsOf: d)
                } else {
                    bytes.append(UInt8(ascii: "_"))
                }
            }
            // 7-Zip·반디집 등은 이 보조 필드(Info-ZIP Unicode Path)로 원래 이름을 복원한다.
            var extra = Data()
            if s.unicodeScalars.contains(where: { !$0.isASCII }) {
                let utf8 = Array(s.utf8)
                extra.le16(0x7075)
                extra.le16(UInt16(5 + utf8.count))
                extra.append(1)
                extra.le32(CRC32.checksum(bytes))
                extra.append(contentsOf: utf8)
            }
            return EncodedName(bytes: bytes, utf8: false, extra: extra)
        }
    }

    /// NFC(완성형)로 바꾸고 Windows 금지 문자를 _ 로 바꾼다.
    private static func windowsSafe(_ path: String) -> String {
        let nfc = path.precomposedStringWithCanonicalMapping
        return String(nfc.map { ch -> Character in
            ch != "/" && windowsForbidden.contains(ch) ? "_" : ch
        })
    }
}

/// 작업이 어떤 방식으로 진행됐는지.
public struct ZipStats: Sendable {
    /// 외장·네트워크 드라이브라서 순서대로 읽었는지
    public let sequentialIO: Bool
    public let threads: Int
}

/// 작은 쓰기를 모아서 한 번에 디스크에 쓴다. 이미 쓴 위치를 고쳐 쓰는 것(patch)도 지원.
final class BufferedWriter {
    private let handle: FileHandle
    private var buffer = Data()
    private var flushed: UInt64 = 0
    private let limit = 8 << 20

    init(_ handle: FileHandle) {
        self.handle = handle
        buffer.reserveCapacity(limit)
    }

    /// 지금까지 쓴 총 바이트 (= 다음에 쓸 위치)
    var position: UInt64 { flushed + UInt64(buffer.count) }

    func write(_ data: Data) throws {
        if data.count >= limit / 4 {
            try flush()
            try handle.write(contentsOf: data)
            flushed += UInt64(data.count)
            return
        }
        buffer.append(data)
        if buffer.count >= limit { try flush() }
    }

    func flush() throws {
        guard !buffer.isEmpty else { return }
        try handle.write(contentsOf: buffer)
        flushed += UInt64(buffer.count)
        buffer.removeAll(keepingCapacity: true)
    }

    func patch(at offset: UInt64, _ data: Data) throws {
        if offset >= flushed {
            let i = Int(offset - flushed)
            buffer.replaceSubrange(i..<(i + data.count), with: data)
        } else {
            try flush()
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: data)
            try handle.seekToEnd()
        }
    }
}
