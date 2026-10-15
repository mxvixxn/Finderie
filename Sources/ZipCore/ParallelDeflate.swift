import CLibdeflate
import Foundation

/// 여러 코어로 동시에 압축하기 위한 조각 단위 deflate.
///
/// 압축은 모두 libdeflate로 한다 (zlib보다 코어당 약 2배 빠르고 결과도 더 작다).
/// - 한 조각에 들어가는 작은 파일: 한 번에 압축.
/// - 큰 파일: 조각으로 나눠 각각 따로 압축한 뒤 순서대로 이어 붙인다.
///   마지막이 아닌 조각은 끝 블록 없이 바이트 경계에서 끝나므로(Z_SYNC_FLUSH와 같은 모양) 이어 붙이면 하나의 올바른 deflate 스트림이 되고,
///   다른 프로그램은 평범한 ZIP으로 읽는다.
///   조각끼리 서로 참조하지 않게(사전 없이) 압축하고 조각 크기 색인(ChunkIndex)을 남겨 두면,
///   Finderie는 풀 때도 조각들을 여러 코어로 동시에 풀 수 있다.
enum ParallelDeflate {
    struct Job {
        let url: URL
        let name: String
        let offset: UInt64
        let length: Int
        let isFirst: Bool
        let isLast: Bool
        let store: Bool
        let fileSize: UInt64
    }

    struct Output {
        let data: Data
        let crc: UInt32
        let length: Int
    }

    /// 조각 하나를 원본 파일에서 읽는다.
    static func read(_ job: Job) throws -> Data {
        guard let fh = try? FileHandle(forReadingFrom: job.url) else { throw ZipError.cannotRead(job.name) }
        defer { try? fh.close() }
        if job.fileSize >= ExecutionPlan.noCacheThreshold {
            _ = fcntl(fh.fileDescriptor, F_NOCACHE, 1)
        }
        if job.offset > 0 { try fh.seek(toOffset: job.offset) }
        let raw = try fh.read(upToCount: job.length) ?? Data()
        guard raw.count == job.length else { throw ZipError.cannotRead(job.name) }
        return raw
    }

    /// 읽어 온 조각을 압축한다. 여러 스레드에서 동시에 불린다.
    /// compressor는 일꾼(스레드)마다 하나씩 따로 쓴다.
    static func compress(_ job: Job, _ raw: Data, compressor: OpaquePointer?) throws -> Output {
        try raw.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Output in
            var crc = CRC32()
            crc.update(input)
            if job.store {
                return Output(data: raw, crc: crc.final, length: job.length)
            }
            guard let compressor else { throw ZipError.cannotRead(job.name) }
            // 마지막이 아닌 조각은 끝 표시 없이 바이트 경계에서 끝낸다 (libdeflate에 추가한 Finderie 패치)
            let packed = try libdeflateCompress(input, compressor: compressor, syncFlush: !job.isLast, name: job.name)
            return Output(data: packed, crc: crc.final, length: job.length)
        }
    }

    /// libdeflate로 압축한다.
    /// syncFlush가 true면 끝 블록 없이 zlib의 Z_SYNC_FLUSH처럼 끝나서, 뒤에 다음 조각을 이어 붙일 수 있다.
    static func libdeflateCompress(_ input: UnsafeRawBufferPointer, compressor: OpaquePointer,
                                   syncFlush: Bool, name: String) throws -> Data {
        // 이 모드는 아주 짧은 입력(64바이트 이하)을 지원하지 않는다. 중간 조각은 항상 64KB 이상이다.
        precondition(!syncFlush || input.count > 64)
        libdeflate_finderie_set_sync_flush(compressor, syncFlush ? 1 : 0)
        defer { libdeflate_finderie_set_sync_flush(compressor, 0) }
        let capacity = libdeflate_deflate_compress_bound(compressor, input.count) + 8
        var out = Data(count: capacity)
        let n = out.withUnsafeMutableBytes { o in
            libdeflate_deflate_compress(compressor, input.baseAddress, input.count, o.baseAddress, capacity)
        }
        guard n > 0 else { throw ZipError.cannotRead(name) }
        out.count = n
        return out
    }

    // MARK: - 이미 압축된 파일 판별

    private static let compressedExtensions: Set<String> = [
        // 사진
        "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "avif", "jxl",
        // 영상·음악
        "mp4", "m4v", "mov", "mkv", "avi", "webm", "wmv", "flv", "mp3", "m4a", "aac", "flac", "ogg", "opus", "wma",
        // 압축 파일·설치 파일
        "zip", "7z", "rar", "alz", "egg", "gz", "tgz", "bz2", "xz", "zst", "lz4", "lzma", "cab",
        "dmg", "pkg", "ipa", "apk", "jar", "xip",
        // 내부가 zip인 문서
        "docx", "xlsx", "pptx", "hwpx", "odt", "ods", "odp", "epub", "key", "pages", "numbers",
    ]

    /// 다시 압축해도 거의 안 줄어드는 파일인지. 확장자로 먼저 보고, 모르면 앞부분을 시험 압축해 본다.
    static func shouldStore(_ url: URL, size: UInt64) -> Bool {
        if compressedExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard size >= 256 * 1024 else { return false }
        guard let fh = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? fh.close() }
        guard let sample = try? fh.read(upToCount: 64 * 1024), !sample.isEmpty else { return false }
        guard let c = libdeflate_alloc_compressor(1) else { return false }
        defer { libdeflate_free_compressor(c) }
        let packed = sample.withUnsafeBytes { try? libdeflateCompress($0, compressor: c, syncFlush: false, name: "") }
        guard let packed else { return false }
        return Double(packed.count) > Double(sample.count) * 0.97
    }
}

/// 큰 파일의 조각별 압축 크기 목록. ZIP의 보조 필드(0x5A50, 'PZ')로 저장한다.
/// 다른 프로그램은 모르는 보조 필드를 그냥 건너뛰므로 호환성에 영향이 없다.
struct ChunkIndex {
    static let headerID: UInt16 = 0x5A50
    let chunkSize: UInt32
    let compressedSizes: [UInt32]

    func encoded() -> Data {
        var body = Data()
        body.append(1) // 버전
        body.le32(chunkSize)
        body.le32(UInt32(compressedSizes.count))
        for s in compressedSizes { body.le32(s) }
        var d = Data()
        d.le16(Self.headerID)
        d.le16(UInt16(body.count))
        d.append(body)
        return d
    }

    /// 보조 필드 목록에서 색인을 찾아, 실제 항목과 맞는지 확인까지 한다.
    static func find(in extra: [UInt8], size: UInt64, compressedSize: UInt64) -> ChunkIndex? {
        var p = 0
        while p + 4 <= extra.count {
            let id = extra.u16(p)
            let len = Int(extra.u16(p + 2))
            guard p + 4 + len <= extra.count else { return nil }
            if id == headerID, len >= 9, extra[p + 4] == 1 {
                let chunk = extra.u32(p + 5)
                let count = Int(extra.u32(p + 9))
                guard chunk > 0, len == 9 + count * 4 else { return nil }
                let sizes = (0..<count).map { extra.u32(p + 13 + $0 * 4) }
                let expectedCount = Int((size + UInt64(chunk) - 1) / UInt64(chunk))
                guard count == expectedCount,
                      sizes.reduce(UInt64(0), { $0 + UInt64($1) }) == compressedSize else { return nil }
                return ChunkIndex(chunkSize: chunk, compressedSizes: sizes)
            }
            p += 4 + len
        }
        return nil
    }
}

/// 조각들을 여러 일꾼이 계속 압축하고, 쓰는 쪽은 순서대로 하나씩 꺼내 간다.
/// 압축과 디스크 쓰기가 동시에 진행된다. 쓰는 쪽보다 window개 넘게 앞서 나가지 않아서 메모리는 일정하다.
/// 순차 읽기 모드에서는 읽기만 조각 순서대로 하나씩 하고, 압축은 그대로 병렬로 한다.
final class ChunkPipeline: @unchecked Sendable {
    private let jobs: [ParallelDeflate.Job]
    private let plan: ExecutionPlan
    private let level: Int32

    private let cond = NSCondition()
    private var results: [Int: Result<ParallelDeflate.Output, Error>] = [:]
    private var cancelled = false
    private var next = 0      // 쓰는 쪽이 다음에 가져갈 조각
    private var issued = 0    // 일꾼에게 나눠 준 조각 수
    private let window: Int   // 쓰는 쪽보다 최대 몇 조각 앞서 나갈지
    private let group = DispatchGroup()

    private let readCond = NSCondition()
    private var readTurn = 0

    init(jobs: [ParallelDeflate.Job], options: ZipOptions, plan: ExecutionPlan) {
        self.jobs = jobs
        self.plan = plan
        self.level = options.level.libdeflateLevel
        // 큰 조각을 쓰는 아주 큰 파일이 있어도 미리 쌓아 두는 양(메모리)이 늘지 않게 조각 크기에 맞춰 줄인다
        let largest = max(jobs.map(\.length).max() ?? 1, 1)
        self.window = max(plan.threads * 4 * options.chunkSize / largest, plan.threads + 2, 4)
        guard !jobs.isEmpty else { return }
        plan.startWorkers(min(plan.threads, jobs.count), group: group) { [self] _ in work() }
    }

    deinit { cancel() }

    private var isCancelled: Bool {
        cond.lock(); defer { cond.unlock() }
        return cancelled
    }

    private func work() {
        let compressor = libdeflate_alloc_compressor(level)
        defer { if let compressor { libdeflate_free_compressor(compressor) } }
        while true {
            // 다음 조각을 받는다. 쓰는 쪽보다 너무 앞서 있으면 따라올 때까지 기다린다 (메모리 제한).
            cond.lock()
            while !cancelled && issued < jobs.count && issued - next >= window { cond.wait() }
            if cancelled || issued >= jobs.count { cond.unlock(); return }
            let k = issued
            issued += 1
            cond.unlock()

            let job = jobs[k]
            let result = Result<ParallelDeflate.Output, Error> {
                let raw = plan.sequential ? try readInOrder(k) { try ParallelDeflate.read(job) }
                                          : try ParallelDeflate.read(job)
                return try ParallelDeflate.compress(job, raw, compressor: compressor)
            }
            cond.lock()
            results[k] = result
            cond.broadcast()
            cond.unlock()
        }
    }

    /// k번 조각의 읽을 차례가 올 때까지 기다렸다가 읽는다.
    private func readInOrder<T>(_ k: Int, _ body: () throws -> T) throws -> T {
        readCond.lock()
        while readTurn != k && !isCancelled { readCond.wait() }
        readCond.unlock()
        defer {
            readCond.lock()
            readTurn = k + 1
            readCond.broadcast()
            readCond.unlock()
        }
        if isCancelled { throw CancellationError() }
        return try body()
    }

    /// 다음 조각의 결과 (순서 보장). 아직이면 나올 때까지 기다린다.
    func nextOutput() throws -> ParallelDeflate.Output {
        cond.lock()
        while results[next] == nil { cond.wait() }
        let r = results.removeValue(forKey: next)!
        next += 1
        cond.broadcast() // 기다리던 일꾼을 깨운다
        cond.unlock()
        return try r.get()
    }

    /// 남은 일을 멈춘다 (오류로 중단할 때).
    func cancel() {
        cond.lock(); cancelled = true; cond.broadcast(); cond.unlock()
        readCond.lock(); readCond.broadcast(); readCond.unlock()
    }
}

final class AtomicCounter: @unchecked Sendable {
    private var value = -1
    private let lock = NSLock()
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}
