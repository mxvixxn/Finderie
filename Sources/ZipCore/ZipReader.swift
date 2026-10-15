import CLibdeflate
import Foundation
import zlib

/// ZIP을 푼다. Windows(CP949)에서 만든 압축 파일도 한글 이름이 깨지지 않게 인코딩을 자동 감지한다.
public enum ZipReader {
    public enum DetectedEncoding: String, Sendable {
        case utf8Flag = "UTF-8"
        case unicodeExtra = "UTF-8 (보조 필드)"
        case utf8NoFlag = "UTF-8 (표시 없음 · Mac)"
        case cp949 = "CP949 (Windows)"
        case ascii = "ASCII"
        case unknown = "알 수 없음"
        case forcedUTF8 = "UTF-8 (직접 지정)"
        case forcedCP949 = "CP949 (직접 지정)"
    }

    public struct Entry {
        public let name: String
        public let encoding: DetectedEncoding
        let flags: UInt16
        let method: UInt16
        let dosTime: UInt16
        let dosDate: UInt16
        let crc: UInt32
        public let compressedSize: UInt64
        public let size: UInt64
        let madeByHost: UInt8
        let externalAttributes: UInt32
        let localOffset: UInt64
        /// Finderie가 만든 큰 파일의 조각 색인 (있으면 병렬로 풀 수 있다)
        let chunkIndex: ChunkIndex?

        /// Windows PowerShell 5.1의 Compress-Archive처럼 표준과 달리 '\'를 구분자로 쓰는 프로그램도 있다.
        public var isDirectory: Bool { name.hasSuffix("/") || name.hasSuffix("\\") }
    }

    public struct Result {
        public let destination: URL
        public let fileCount: Int
        /// 이름을 어떤 인코딩으로 읽었는지 (가장 많이 나온 것).
        public let encoding: DetectedEncoding
        /// 외장·네트워크 드라이브라서 순서대로 읽었는지
        public let sequentialIO: Bool
    }

    // MARK: - 목록 읽기

    public static func entries(of url: URL, decoding: NameDecoding = .auto) throws -> [Entry] {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let fileSize = try fh.seekToEnd()

        // 끝에서 EOCD(0x06054b50) 찾기. 주석이 최대 65535바이트라 그만큼 뒤져본다.
        let tailLen = min(fileSize, 65_557)
        try fh.seek(toOffset: fileSize - tailLen)
        let tail = [UInt8](try fh.read(upToCount: Int(tailLen)) ?? Data())
        guard tail.count >= 22 else { throw ZipError.corrupt("너무 작음") }

        var eocd = -1
        var i = tail.count - 22
        while i >= 0 {
            if tail[i] == 0x50, tail[i + 1] == 0x4B, tail[i + 2] == 0x05, tail[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.corrupt("끝 레코드 없음") }

        var count = UInt64(tail.u16(eocd + 10))
        var cdSize = UInt64(tail.u32(eocd + 12))
        var cdOffset = UInt64(tail.u32(eocd + 16))
        // Zip64: 끝 레코드 바로 앞의 위치 표시(0x07064b50)를 따라가 64비트 값을 읽는다
        if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            guard eocd >= 20, tail.u32(eocd - 20) == 0x0706_4B50 else { throw ZipError.corrupt("Zip64 위치 표시 없음") }
            let z64Offset = tail.u64(eocd - 20 + 8)
            guard z64Offset + 56 <= fileSize else { throw ZipError.corrupt("Zip64 끝 레코드 위치가 잘못됨") }
            try fh.seek(toOffset: z64Offset)
            let z = [UInt8](try fh.read(upToCount: 56) ?? Data())
            guard z.count == 56, z.u32(0) == 0x0606_4B50 else { throw ZipError.corrupt("Zip64 끝 레코드가 잘못됨") }
            count = z.u64(32)
            cdSize = z.u64(40)
            cdOffset = z.u64(48)
        }
        guard cdOffset + cdSize <= fileSize, count <= cdSize / 46 + 1 else { throw ZipError.corrupt("목록 위치가 잘못됨") }

        try fh.seek(toOffset: cdOffset)
        let cd = [UInt8](try fh.read(upToCount: Int(cdSize)) ?? Data())
        guard cd.count == Int(cdSize) else { throw ZipError.corrupt("목록이 잘림") }

        var result: [Entry] = []
        var p = 0
        result.reserveCapacity(Int(count))
        for _ in 0..<Int(count) {
            guard p + 46 <= cd.count, cd.u32(p) == 0x0201_4B50 else { throw ZipError.corrupt("목록 항목이 잘못됨") }
            let nameLen = Int(cd.u16(p + 28))
            let extraLen = Int(cd.u16(p + 30))
            let commentLen = Int(cd.u16(p + 32))
            guard p + 46 + nameLen + extraLen + commentLen <= cd.count else { throw ZipError.corrupt("목록이 잘림") }

            let flags = cd.u16(p + 8)
            let nameBytes = Array(cd[(p + 46)..<(p + 46 + nameLen)])
            let extra = Array(cd[(p + 46 + nameLen)..<(p + 46 + nameLen + extraLen)])
            let (name, enc) = decodeName(nameBytes, flags: flags, extra: extra, decoding: decoding)

            var csize = UInt64(cd.u32(p + 20))
            var usize = UInt64(cd.u32(p + 24))
            var offset = UInt64(cd.u32(p + 42))
            // 0xFFFFFFFF인 칸은 Zip64 보조 필드(0x0001)에 원래 크기, 압축 크기, 위치 순서로 들어 있다
            if csize == 0xFFFF_FFFF || usize == 0xFFFF_FFFF || offset == 0xFFFF_FFFF {
                guard let z = Self.zip64Field(extra) else { throw ZipError.corrupt("Zip64 정보 없음: \(name)") }
                var q = 0
                func next() throws -> UInt64 {
                    guard q + 8 <= z.count else { throw ZipError.corrupt("Zip64 정보가 짧음: \(name)") }
                    defer { q += 8 }
                    return z.u64(q)
                }
                if usize == 0xFFFF_FFFF { usize = try next() }
                if csize == 0xFFFF_FFFF { csize = try next() }
                if offset == 0xFFFF_FFFF { offset = try next() }
            }

            result.append(Entry(
                name: name,
                encoding: enc,
                flags: flags,
                method: cd.u16(p + 10),
                dosTime: cd.u16(p + 12),
                dosDate: cd.u16(p + 14),
                crc: cd.u32(p + 16),
                compressedSize: csize,
                size: usize,
                madeByHost: cd[p + 5],
                externalAttributes: cd.u32(p + 38),
                localOffset: offset,
                chunkIndex: ChunkIndex.find(in: extra, size: usize, compressedSize: csize)
            ))
            p += 46 + nameLen + extraLen + commentLen
        }
        return result
    }

    /// 보조 필드 목록에서 Zip64 필드(0x0001)의 내용만 꺼낸다.
    private static func zip64Field(_ extra: [UInt8]) -> [UInt8]? {
        var p = 0
        while p + 4 <= extra.count {
            let id = extra.u16(p)
            let len = Int(extra.u16(p + 2))
            guard p + 4 + len <= extra.count else { return nil }
            if id == 0x0001 { return Array(extra[(p + 4)..<(p + 4 + len)]) }
            p += 4 + len
        }
        return nil
    }

    /// 파일 이름 바이트를 사람이 읽을 수 있는 문자열로. 한글 깨짐 방지의 핵심.
    static func decodeName(_ bytes: [UInt8], flags: UInt16, extra: [UInt8],
                           decoding: NameDecoding = .auto) -> (String, DetectedEncoding) {
        // 0) 사용자가 인코딩을 직접 고른 경우 (그 인코딩으로 읽을 수 없으면 자동으로 넘어간다)
        switch decoding {
        case .utf8:
            if let s = String(bytes: bytes, encoding: .utf8) { return (s.precomposedStringWithCanonicalMapping, .forcedUTF8) }
        case .cp949:
            if let s = String(bytes: bytes, encoding: Encodings.cp949) { return (s, .forcedCP949) }
        case .auto:
            break
        }
        // 1) UTF-8 표시가 있으면 그대로 UTF-8
        if flags & (1 << 11) != 0, let s = String(bytes: bytes, encoding: .utf8) {
            return (s.precomposedStringWithCanonicalMapping, .utf8Flag)
        }
        // 2) Info-ZIP 유니코드 경로 보조 필드(0x7075)
        if let s = unicodePathExtra(extra, nameBytes: bytes) {
            return (s.precomposedStringWithCanonicalMapping, .unicodeExtra)
        }
        // 3) 영문/숫자만
        if bytes.allSatisfy({ $0 < 0x80 }) {
            return (String(decoding: bytes, as: UTF8.self), .ascii)
        }
        // 4) 표시는 없지만 올바른 UTF-8 (Mac 기본 압축이 이렇게 만든다)
        if let s = String(bytes: bytes, encoding: .utf8) {
            return (s.precomposedStringWithCanonicalMapping, .utf8NoFlag)
        }
        // 5) Windows 한국어(CP949)
        if let s = String(bytes: bytes, encoding: Encodings.cp949) {
            return (s, .cp949)
        }
        // 6) 최후의 수단
        let s = String(bytes: bytes, encoding: Encodings.cp437) ?? String(decoding: bytes, as: UTF8.self)
        return (s, .unknown)
    }

    private static func unicodePathExtra(_ extra: [UInt8], nameBytes: [UInt8]) -> String? {
        var p = 0
        while p + 4 <= extra.count {
            let id = extra.u16(p)
            let len = Int(extra.u16(p + 2))
            guard p + 4 + len <= extra.count else { return nil }
            if id == 0x7075, len >= 5, extra[p + 4] == 1 {
                let crc = extra.u32(p + 5)
                // 원래 이름과 짝이 맞을 때만 믿는다 (다른 프로그램이 이름만 바꾼 경우 대비)
                if crc == CRC32.checksum(nameBytes) {
                    return String(bytes: extra[(p + 9)..<(p + 4 + len)], encoding: .utf8)
                }
            }
            p += 4 + len
        }
        return nil
    }

    // MARK: - 풀기

    /// zip 옆에 풀어 놓는다. 최상위 항목이 하나면 그대로, 여러 개면 zip 이름의 폴더를 만든다.
    public static func extract(
        _ zip: URL,
        to directory: URL? = nil,
        options: ZipOptions,
        progress: ProgressHandler? = nil,
        cancel: CancelToken? = nil
    ) throws -> Result {
        let fm = FileManager.default
        var list = try entries(of: zip, decoding: options.nameDecoding)
        if options.excludeMacFiles {
            list.removeAll { e in e.name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains { MacJunk.isJunk(component: String($0)) } }
        }

        // 경로를 안전하게 정리 (../ 나 절대 경로로 밖에 쓰는 것 막기)
        var planned: [(Entry, [String])] = []
        for e in list {
            let parts = e.name.replacingOccurrences(of: "\\", with: "/")
                .split(separator: "/").map(String.init)
                .filter { $0 != "." && !$0.isEmpty }
            if parts.contains("..") { throw ZipError.unsafePath(e.name) }
            if parts.isEmpty { continue }
            planned.append((e, parts))
        }

        let parent = directory ?? zip.deletingLastPathComponent()
        let tops = Set(planned.map { $0.1[0] })
        let root: URL
        var renameTop: (from: String, to: String)?
        if tops.count == 1, let top = tops.first {
            root = parent
            let target = parent.appendingPathComponent(top)
            if fm.fileExists(atPath: target.path) {
                let isDir = planned.contains { $0.1.count > 1 || $0.0.isDirectory }
                let base = isDir ? top : (top as NSString).deletingPathExtension
                let ext = isDir ? "" : (top as NSString).pathExtension
                renameTop = (top, ZipWriter.uniqueURL(in: parent, base: base, ext: ext).lastPathComponent)
            }
        } else {
            root = ZipWriter.uniqueURL(in: parent, base: zip.deletingPathExtension().lastPathComponent, ext: "")
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        }

        let destination: URL
        if tops.count == 1, let top = tops.first {
            destination = parent.appendingPathComponent(renameTop?.to ?? top)
        } else {
            destination = root
        }
        // 도중에 실패하면 반쯤 풀린 결과를 지운다 (항상 새로 만든 이름이라 기존 파일은 건드리지 않음)
        var succeeded = false
        defer { if !succeeded { try? fm.removeItem(at: destination) } }

        let total = max(planned.reduce(UInt64(0)) { $0 + $1.0.compressedSize }, 1)
        var encodingCounts: [DetectedEncoding: Int] = [:]

        // 1단계: 검사하고 폴더를 먼저 만든다 (순서대로)
        var tasks: [String: (entry: Entry, dest: URL, label: String)] = [:]
        var createdDirs = Set<String>()
        for (entry, var parts) in planned {
            if let r = renameTop, parts[0] == r.from { parts[0] = r.to }
            let dest = parts.reduce(root) { $0.appendingPathComponent($1) }
            encodingCounts[entry.encoding, default: 0] += 1

            if entry.isDirectory {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                continue
            }
            if entry.flags & 1 != 0 { throw ZipError.encrypted(entry.name) }
            guard entry.method == 0 || entry.method == 8 else {
                throw ZipError.unsupportedMethod(entry.name, entry.method)
            }
            let parentDir = dest.deletingLastPathComponent()
            if createdDirs.insert(parentDir.path).inserted {
                try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            tasks[dest.path] = (entry, dest, parts.joined(separator: "/")) // 같은 경로가 또 나오면 뒤의 것으로
        }

        // 2단계: 여러 코어로 동시에 푼다.
        // ZIP 파일은 메모리에 연결(mmap)해서 복사 없이 읽는다.
        let report = ProgressThrottle(progress)
        let plan = ExecutionPlan.make(options, involving: [zip])
        let archive = try Data(contentsOf: zip, options: .alwaysMapped)
        // 빠른 SSD: 큰 파일부터 시작해야 마지막에 큰 파일 하나만 남아 기다리는 일이 적다.
        // 순차 모드(외장·네트워크): ZIP 안에 들어 있는 순서대로 처리해서 디스크를 앞에서부터 읽는다.
        let ordered = plan.sequential
            ? tasks.values.sorted { $0.entry.localOffset < $1.entry.localOffset }
            : tasks.values.sorted { $0.entry.compressedSize > $1.entry.compressedSize }
        let files = try ordered.map { t in
            OutputFile(entry: t.entry, dest: t.dest, label: t.label, dataStart: try dataStart(of: t.entry, in: archive))
        }
        defer { files.forEach { $0.closeFile() } }

        // 작업 목록: 색인이 있는 큰 파일은 조각마다 하나씩, 나머지는 파일마다 하나씩
        var jobs: [(file: Int, chunk: Int)] = []
        for f in files where f.canSplit { try f.prepareChunks() }
        if plan.sequential {
            for (i, f) in files.enumerated() {
                if f.canSplit { for k in 0..<f.chunkCount { jobs.append((i, k)) } } else { jobs.append((i, -1)) }
            }
        } else {
            for (i, f) in files.enumerated() where f.canSplit { for k in 0..<f.chunkCount { jobs.append((i, k)) } }
            for (i, f) in files.enumerated() where !f.canSplit { jobs.append((i, -1)) }
        }
        if plan.sequential {
            archive.withUnsafeBytes { b in
                if let base = b.baseAddress { _ = madvise(UnsafeMutableRawPointer(mutating: base), b.count, MADV_SEQUENTIAL) }
            }
        }

        let counter = AtomicCounter()
        let lock = NSLock()
        var done: UInt64 = 0
        var firstError: Error?
        func fail(_ e: Error) { lock.lock(); if firstError == nil { firstError = e }; lock.unlock() }

        // 순차 모드에서는 여러 파일을 동시에 쓰면 HDD가 헤드를 오가느라 느려지므로 일꾼 수를 줄인다.
        let workers = max(1, min(plan.sequential ? min(plan.threads, 4) : plan.threads, jobs.count))
        plan.runWorkers(workers) { _ in
            guard let decompressor = libdeflate_alloc_decompressor() else {
                fail(ZipError.corrupt("압축 해제 준비 실패")); return
            }
            defer { libdeflate_free_decompressor(decompressor) }
            archive.withUnsafeBytes { (zipBytes: UnsafeRawBufferPointer) in
                while true {
                    let k = counter.increment()
                    if cancel?.isCancelled == true { fail(ZipError.cancelled); break }
                    lock.lock(); let stop = firstError != nil; lock.unlock()
                    if k >= jobs.count || stop { break }
                    let job = jobs[k]
                    let f = files[job.file]
                    do {
                        let n = job.chunk < 0
                            ? try f.extractWhole(zipBytes, decompressor)
                            : try f.extractChunk(job.chunk, zipBytes, decompressor)
                        lock.lock(); done += n; let d = done; lock.unlock()
                        report.report(Double(min(d, total)) / Double(total), f.label)
                    } catch {
                        fail(error)
                    }
                }
            }
        }
        if let firstError { throw firstError }
        report.report(1, "", force: true)

        let main = encodingCounts
            .filter { $0.key != .ascii }
            .max { $0.value < $1.value }?.key ?? .ascii
        succeeded = true
        return Result(destination: destination, fileCount: files.count, encoding: main, sequentialIO: plan.sequential)
    }

    private static func dataStart(of e: Entry, in archive: Data) throws -> Int {
        let o = Int(e.localOffset)
        guard o + 30 <= archive.count else { throw ZipError.corrupt(e.name) }
        let local = [UInt8](archive[o..<(o + 30)])
        guard local.u32(0) == 0x0403_4B50 else { throw ZipError.corrupt(e.name) }
        let start = o + 30 + Int(local.u16(26)) + Int(local.u16(28))
        guard start + Int(e.compressedSize) <= archive.count else { throw ZipError.corrupt(e.name) }
        return start
    }
}

/// 풀어서 만들 파일 하나. 조각 단위로 여러 스레드가 동시에 채울 수 있다.
private final class OutputFile: @unchecked Sendable {
    let entry: ZipReader.Entry
    let dest: URL
    let label: String
    let dataStart: Int

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var chunkOffsets: [Int] = []
    private var chunkCRCs: [UInt32] = []
    private var remaining = 0
    private let mode: mode_t?
    private let modified: Date?

    /// 이보다 큰 압축 항목(색인 없음)은 메모리에 통째로 풀지 않고 조금씩 풀어서 쓴다.
    private static let wholeInMemoryLimit = 64 << 20
    /// 그대로 담긴(저장) 큰 파일을 나눠 쓸 조각 크기.
    private static let storedPiece = 4 << 20

    init(entry: ZipReader.Entry, dest: URL, label: String, dataStart: Int) {
        self.entry = entry
        self.dest = dest
        self.label = label
        self.dataStart = dataStart
        let m = (entry.externalAttributes >> 16) & 0o777
        mode = entry.madeByHost == 3 && m != 0 ? mode_t(m) : nil
        modified = DOSDate.decode(time: entry.dosTime, date: entry.dosDate)
    }

    private var isStoredSplit: Bool { entry.method == 0 && entry.size >= UInt64(Self.storedPiece * 2) }

    /// 여러 조각으로 나눠 동시에 풀 수 있는지.
    /// - 그대로 담긴 큰 파일: 언제나 가능
    /// - 압축된 큰 파일: Finderie 색인이 있을 때만
    var canSplit: Bool {
        isStoredSplit || (entry.method == 8 && (entry.chunkIndex?.compressedSizes.count ?? 0) > 1)
    }

    var chunkCount: Int {
        if isStoredSplit { return Int((entry.size + UInt64(Self.storedPiece) - 1) / UInt64(Self.storedPiece)) }
        return entry.chunkIndex?.compressedSizes.count ?? 1
    }

    private var chunkSize: Int { isStoredSplit ? Self.storedPiece : Int(entry.chunkIndex!.chunkSize) }

    // MARK: 조각 단위

    func prepareChunks() throws {
        if isStoredSplit {
            guard entry.compressedSize == entry.size else { throw ZipError.corrupt(entry.name) }
            chunkOffsets = (0..<chunkCount).map { dataStart + $0 * Self.storedPiece }
        } else {
            var pos = dataStart
            chunkOffsets = entry.chunkIndex!.compressedSizes.map { s in defer { pos += Int(s) }; return pos }
        }
        chunkCRCs = Array(repeating: 0, count: chunkCount)
        remaining = chunkCount
        // 미리 전체 크기로 만들어 두고, 조각들이 각자 자기 위치에 쓴다
        let f = open(dest.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard f >= 0 else { throw ZipError.cannotRead(dest.path) }
        guard ftruncate(f, off_t(entry.size)) == 0 else { close(f); throw ZipError.cannotRead(dest.path) }
        fd = f
    }

    func extractChunk(_ k: Int, _ zip: UnsafeRawBufferPointer, _ d: OpaquePointer) throws -> UInt64 {
        let outOffset = k * chunkSize
        let outLen = min(chunkSize, Int(entry.size) - outOffset)
        let input = zip.baseAddress! + chunkOffsets[k]
        let crc: UInt32
        let inLen: Int

        if isStoredSplit {
            inLen = outLen
            try Self.writeAll(fd, input, outLen, at: outOffset, dest)
            crc = libdeflate_crc32(0, input, outLen)
        } else {
            let index = entry.chunkIndex!
            inLen = Int(index.compressedSizes[k])
            let out = UnsafeMutableRawPointer.allocate(byteCount: outLen, alignment: 16)
            defer { out.deallocate() }
            if k == index.compressedSizes.count - 1 {
                try Self.inflate(d, input, inLen, out, outLen, entry.name)
            } else {
                // 마지막이 아닌 조각에는 끝 표시가 없다. 빈 마지막 블록(03 00)을 붙여 완결된 스트림으로 만든다.
                var buf = [UInt8](repeating: 0, count: inLen + 2)
                buf.withUnsafeMutableBytes { $0.baseAddress!.copyMemory(from: input, byteCount: inLen) }
                buf[inLen] = 0x03
                buf[inLen + 1] = 0x00
                try buf.withUnsafeBytes { try Self.inflate(d, $0.baseAddress!, inLen + 2, out, outLen, entry.name) }
            }
            crc = libdeflate_crc32(0, out, outLen)
            try Self.writeAll(fd, out, outLen, at: outOffset, dest)
        }

        lock.lock()
        chunkCRCs[k] = crc
        remaining -= 1
        let finished = remaining == 0
        lock.unlock()

        if finished {
            var total = chunkCRCs[0]
            for j in 1..<chunkCRCs.count {
                total = CRC32.combine(total, chunkCRCs[j], length: min(chunkSize, Int(entry.size) - j * chunkSize))
            }
            closeFile()
            guard total == entry.crc else { throw ZipError.checksumMismatch(entry.name) }
        }
        return UInt64(inLen)
    }

    // MARK: 통째로

    func extractWhole(_ zip: UnsafeRawBufferPointer, _ d: OpaquePointer) throws -> UInt64 {
        let inLen = Int(entry.compressedSize)
        let size = Int(entry.size)
        let input = zip.baseAddress! + dataStart
        var crc = CRC32()

        if entry.method == 0 {
            guard inLen == size else { throw ZipError.corrupt(entry.name) }
            crc.update(UnsafeRawBufferPointer(start: input, count: size))
            try writeFile(input, size)
        } else if size == 0 {
            try writeFile(input, 0)
        } else if size <= Self.wholeInMemoryLimit {
            let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
            defer { buf.deallocate() }
            try Self.inflate(d, input, inLen, buf, size, entry.name)
            crc.update(UnsafeRawBufferPointer(start: buf, count: size))
            try writeFile(buf, size)
        } else {
            // 색인 없는 큰 항목(다른 프로그램이 만든 ZIP): 메모리를 조금만 쓰며 순서대로 풀어 쓴다
            crc = try streamInflate(input, inLen)
        }
        guard crc.final == entry.crc else { throw ZipError.checksumMismatch(entry.name) }
        return UInt64(inLen)
    }

    /// zlib으로 4MB씩 풀어서 바로 쓴다. 수십 GB 파일도 메모리를 몇 MB만 쓴다.
    private func streamInflate(_ input: UnsafeRawPointer, _ inLen: Int) throws -> CRC32 {
        let f = open(dest.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard f >= 0 else { throw ZipError.cannotRead(dest.path) }
        defer { close(f) }

        var strm = z_stream()
        guard inflateInit2_(&strm, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ZipError.corrupt(entry.name)
        }
        defer { inflateEnd(&strm) }

        let bufSize = 4 << 20
        let buf = UnsafeMutablePointer<Bytef>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        var crc = CRC32()
        var fed = 0
        var written = 0
        let src = UnsafeMutablePointer(mutating: input.assumingMemoryBound(to: Bytef.self))

        while true {
            if strm.avail_in == 0 && fed < inLen {
                let n = min(inLen - fed, 1 << 30) // avail_in은 32비트라 1GB씩 넣는다
                strm.next_in = src + fed
                strm.avail_in = uInt(n)
                fed += n
            }
            strm.next_out = buf
            strm.avail_out = uInt(bufSize)
            let rc = zlib.inflate(&strm, Z_NO_FLUSH)
            let produced = bufSize - Int(strm.avail_out)
            if produced > 0 {
                crc.update(UnsafeRawBufferPointer(start: buf, count: produced))
                try Self.writeAll(f, buf, produced, at: written, dest)
                written += produced
            }
            if rc == Z_STREAM_END { break }
            if rc != Z_OK && !(rc == Z_BUF_ERROR && (strm.avail_in > 0 || fed < inLen)) {
                throw ZipError.corrupt("압축 데이터 오류: \(entry.name)")
            }
        }
        guard written == Int(entry.size) else { throw ZipError.corrupt("크기가 맞지 않음: \(entry.name)") }
        applyAttributes(f)
        return crc
    }

    // MARK: 도우미

    /// 열린 파일에 권한과 수정 시각을 바로 적용한다 (경로로 다시 찾는 것보다 빠르다).
    private func applyAttributes(_ f: Int32) {
        if let mode { fchmod(f, mode) }
        if let modified {
            let sec = Int(modified.timeIntervalSince1970)
            var times = [timeval(tv_sec: sec, tv_usec: 0), timeval(tv_sec: sec, tv_usec: 0)]
            futimes(f, &times)
        }
    }

    /// 파일을 바로 쓴다. (FileManager.createFile은 임시 파일을 거쳐서 파일이 많을 때 느리다)
    private func writeFile(_ bytes: UnsafeRawPointer, _ count: Int) throws {
        let f = open(dest.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard f >= 0 else { throw ZipError.cannotRead(dest.path) }
        defer { close(f) }
        try Self.writeAll(f, bytes, count, at: 0, dest)
        applyAttributes(f)
    }

    private static func writeAll(_ f: Int32, _ bytes: UnsafeRawPointer, _ count: Int, at offset: Int, _ url: URL) throws {
        var done = 0
        while done < count {
            let n = pwrite(f, bytes + done, count - done, off_t(offset + done))
            if n < 0 { if errno == EINTR { continue }; throw ZipError.cannotRead(url.path) }
            done += n
        }
    }

    /// libdeflate로 한 번에 푼다. 결과 크기가 정확히 맞아야 성공으로 친다.
    private static func inflate(_ d: OpaquePointer, _ input: UnsafeRawPointer, _ inLen: Int,
                                _ out: UnsafeMutableRawPointer, _ outLen: Int, _ name: String) throws {
        let r = libdeflate_deflate_decompress(d, input, inLen, out, outLen, nil)
        guard r == LIBDEFLATE_SUCCESS else { throw ZipError.corrupt("압축 데이터 오류: \(name)") }
    }

    /// 조각 단위로 쓰던 파일을 닫는다. 수정 시각은 데이터를 다 쓴 뒤에 설정한다.
    func closeFile() {
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 {
            applyAttributes(fd)
            close(fd)
        }
        fd = -1
    }
}
