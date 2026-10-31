import Foundation
import zlib
import CLibdeflate

/// 압축할 때 파일 이름을 어떤 방식으로 기록할지.
public enum NameEncoding: String, CaseIterable, Identifiable, Sendable {
    /// NFC 완성형 + UTF-8 플래그. Windows 10/11, Mac, 반디집, 7-Zip 모두 정상.
    case windowsUTF8
    /// CP949(확장 완성형) + 유니코드 경로 보조 필드. 구형 Windows, 오래된 알집 등.
    case windowsCP949
    /// Mac 기본 압축과 같은 방식(NFD, 플래그 없음). Windows에서 한글이 깨질 수 있음.
    case macDefault

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .windowsUTF8: return "Windows 호환 · UTF-8 (권장)"
        case .windowsCP949: return "구형 Windows 호환 · CP949"
        case .macDefault: return "Mac 기본 방식"
        }
    }

    public var detail: String {
        switch self {
        case .windowsUTF8:
            return "자모 분리 없이 완성형 한글로 저장하고 UTF-8 표시를 붙여요. Windows에서 못 쓰는 이름(: ? CON, 끝의 점 등)도 고쳐요. Windows 10/11, Mac, 반디집, 7-Zip에서 모두 정상으로 보여요."
        case .windowsCP949:
            return "Windows 7 이하나 오래된 압축 프로그램용이에요. CP949로 표현할 수 없는 글자(이모지 등)는 _ 로 바뀌어요."
        case .macDefault:
            return "Mac의 '압축하기'와 같은 방식이에요. Windows에서 한글 이름이 깨질 수 있어요."
        }
    }
}

/// 압축 강도. 숫자는 zlib 레벨.
public enum CompressionLevel: String, CaseIterable, Identifiable, Sendable {
    case fast, normal, best
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .fast: return "빠르게"
        case .normal: return "보통"
        case .best: return "최대 압축"
        }
    }
    var libdeflateLevel: Int32 { zlibLevel }
    var zlibLevel: Int32 {
        switch self {
        case .fast: return 1
        case .normal: return 6
        case .best: return 9
        }
    }
}

/// 압축을 풀 때 파일 이름을 어떤 인코딩으로 읽을지.
public enum NameDecoding: String, CaseIterable, Identifiable, Sendable {
    /// UTF-8 표시, 유니코드 보조 필드, 바이트 모양을 보고 알아서 판단
    case auto
    /// 무조건 UTF-8로
    case utf8
    /// 무조건 CP949(Windows 한국어)로
    case cp949

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return "자동"
        case .utf8: return "UTF-8"
        case .cp949: return "CP949 (Windows)"
        }
    }
}

/// 진행 중인 작업을 멈추게 하는 신호. 다른 스레드에서 cancel()을 불러도 된다.
public final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }

    public func cancel() {
        lock.lock(); flag = true; lock.unlock()
    }

    func check() throws {
        if isCancelled { throw ZipError.cancelled }
    }
}

public struct ZipOptions: Sendable {
    public var nameEncoding: NameEncoding
    /// .DS_Store, ._*, __MACOSX 같은 Mac 전용 파일을 빼기.
    public var excludeMacFiles: Bool
    public var level: CompressionLevel
    /// 사진·영상·zip처럼 이미 압축된 파일은 다시 압축하지 않고 그대로 담기.
    public var storeCompressedFiles: Bool
    /// 동시에 일할 CPU 코어 수.
    public var threads: Int
    /// 큰 파일을 나눠서 여러 코어가 동시에 압축하는 조각 크기.
    public var chunkSize: Int
    /// 백그라운드 모드: 효율 코어 위주로, 낮은 우선순위와 낮은 디스크 우선순위로 일한다.
    public var background: Bool
    /// 파일 읽기 방식. auto면 외장·네트워크 드라이브일 때 순서대로 읽는다.
    public var ioMode: IOMode
    /// 압축을 풀 때 파일 이름 인코딩
    public var nameDecoding: NameDecoding

    public init(
        nameEncoding: NameEncoding = .windowsUTF8,
        excludeMacFiles: Bool = true,
        level: CompressionLevel = .normal,
        storeCompressedFiles: Bool = true,
        threads: Int = ProcessInfo.processInfo.activeProcessorCount,
        chunkSize: Int = 1 << 20,
        background: Bool = false,
        ioMode: IOMode = .auto,
        nameDecoding: NameDecoding = .auto
    ) {
        self.nameEncoding = nameEncoding
        self.excludeMacFiles = excludeMacFiles
        self.level = level
        self.storeCompressedFiles = storeCompressedFiles
        self.threads = max(1, threads)
        self.chunkSize = max(64 * 1024, chunkSize)
        self.background = background
        self.ioMode = ioMode
        self.nameDecoding = nameDecoding
    }
}

public enum ZipError: LocalizedError {
    case tooLarge(String)
    case cannotRead(String)
    case corrupt(String)
    case unsupportedMethod(String, UInt16)
    case encrypted(String)
    case unsafePath(String)
    case checksumMismatch(String)
    case nothingToCompress
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .tooLarge(let name): return "크기 정보를 기록할 수 없는 항목이 있어요: \(name)"
        case .cannotRead(let name): return "파일을 읽을 수 없어요: \(name)"
        case .corrupt(let why): return "ZIP 파일이 손상됐거나 지원하지 않는 형식이에요. (\(why))"
        case .unsupportedMethod(let name, let m): return "지원하지 않는 압축 방식(\(m))이에요: \(name)"
        case .encrypted(let name): return "암호가 걸린 파일은 아직 풀 수 없어요: \(name)"
        case .unsafePath(let name): return "위험한 경로가 들어 있어서 건너뛸 수 없어요: \(name)"
        case .checksumMismatch(let name): return "데이터가 손상됐어요 (CRC 불일치): \(name)"
        case .nothingToCompress: return "압축할 파일이 없어요."
        case .cancelled: return "작업을 취소했어요."
        }
    }
}

/// 진행률(0...1)과 현재 처리 중인 이름.
public typealias ProgressHandler = (Double, String) -> Void

/// 진행률 알림을 0.05초에 한 번 정도로 줄인다. 파일이 수천 개일 때 화면 갱신이 일을 방해하지 않게.
final class ProgressThrottle: @unchecked Sendable {
    private let handler: ProgressHandler?
    private let lock = NSLock()
    private var lastNanos: UInt64 = 0

    init(_ handler: ProgressHandler?) { self.handler = handler }

    func report(_ fraction: Double, _ name: String, force: Bool = false) {
        guard let handler else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let due = force || now &- lastNanos > 50_000_000
        if due { lastNanos = now }
        lock.unlock()
        if due { handler(fraction, name) }
    }
}

// MARK: - Mac 전용 파일 판별

enum MacJunk {
    static func isJunk(component: String) -> Bool {
        component == ".DS_Store"
            || component == "__MACOSX"
            || component.hasPrefix("._")
            || component == "Icon\r"
            || component == ".localized"
    }
}

// MARK: - 인코딩

enum Encodings {
    /// CP949 (Windows 한국어, 확장 완성형).
    static let cp949: String.Encoding = {
        let cf = CFStringEncoding(CFStringEncodings.dosKorean.rawValue)
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }()
    /// 옛 DOS 기본(CP437). 어떤 바이트든 디코딩 가능한 최후의 수단.
    static let cp437: String.Encoding = {
        let cf = CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }()
}

// MARK: - CRC32 (libdeflate의 하드웨어 가속 구현 사용)

struct CRC32 {
    private(set) var final: UInt32 = 0

    mutating func update(_ buffer: UnsafeRawBufferPointer) {
        guard let p = buffer.baseAddress, buffer.count > 0 else { return }
        final = libdeflate_crc32(final, p, buffer.count)
    }

    mutating func update(_ data: Data) { data.withUnsafeBytes { update($0) } }
    mutating func update(_ bytes: [UInt8]) { bytes.withUnsafeBytes { update($0) } }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var c = CRC32(); c.update(bytes); return c.final
    }

    /// crc(A+B) = combine(crc(A), crc(B), B의 길이). 조각별로 따로 계산한 CRC를 합칠 때 쓴다.
    static func combine(_ a: UInt32, _ b: UInt32, length: Int) -> UInt32 {
        UInt32(zlib.crc32_combine(uLong(a), uLong(b), length))
    }
}

// MARK: - 바이트 읽기/쓰기 도우미

extension Data {
    mutating func le16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func le32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func le64(_ v: UInt64) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
}

extension Array where Element == UInt8 {
    func u16(_ at: Int) -> UInt16 { UInt16(self[at]) | UInt16(self[at + 1]) << 8 }
    func u32(_ at: Int) -> UInt32 {
        UInt32(self[at]) | UInt32(self[at + 1]) << 8 | UInt32(self[at + 2]) << 16 | UInt32(self[at + 3]) << 24
    }
    func u64(_ at: Int) -> UInt64 { UInt64(u32(at)) | UInt64(u32(at + 4)) << 32 }
}

// MARK: - DOS 날짜/시간

enum DOSDate {
    static func encode(_ date: Date) -> (time: UInt16, date: UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        let year = Swift.min(Swift.max((c.year ?? 1980) - 1980, 0), 127)
        let d = UInt16(year << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        let t = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        return (t, d)
    }

    static func decode(time: UInt16, date: UInt16) -> Date? {
        var c = DateComponents()
        c.year = Int(date >> 9) + 1980
        c.month = Int((date >> 5) & 0xF)
        c.day = Int(date & 0x1F)
        c.hour = Int(time >> 11)
        c.minute = Int((time >> 5) & 0x3F)
        c.second = Int(time & 0x1F) * 2
        return Calendar(identifier: .gregorian).date(from: c)
    }
}
