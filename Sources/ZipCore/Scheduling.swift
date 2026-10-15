import Darwin
import Foundation

/// 파일을 어떻게 읽을지.
public enum IOMode: String, CaseIterable, Identifiable, Sendable {
    /// 내장 SSD면 병렬, 외장·네트워크 드라이브면 순차.
    case auto
    /// 여러 일꾼이 각자 동시에 읽는다 (SSD에 빠름).
    case parallel
    /// 앞에서부터 순서대로 읽고, 압축만 병렬로 한다 (HDD·USB 메모리·NAS에 빠름).
    case sequential

    public var id: String { rawValue }
}

/// 이번 작업을 몇 개의 일꾼으로, 어떤 우선순위로, 어떤 읽기 방식으로 할지.
struct ExecutionPlan: Sendable {
    let threads: Int
    let qos: DispatchQoS.QoSClass
    /// 디스크 우선순위를 낮춰 다른 앱의 입출력을 먼저 처리하게 할지
    let throttleIO: Bool
    /// 순서대로 읽기
    let sequential: Bool

    /// 이보다 큰 원본 파일은 읽을 때 메모리 캐시에 남기지 않는다 (다른 앱이 쓰던 캐시를 밀어내지 않게).
    static let noCacheThreshold: UInt64 = 256 << 20

    static func make(_ options: ZipOptions, involving urls: [URL]) -> ExecutionPlan {
        let sequential: Bool
        switch options.ioMode {
        case .parallel: sequential = false
        case .sequential: sequential = true
        case .auto: sequential = urls.contains { !VolumeInfo.isFastLocal($0) }
        }
        var threads = options.threads
        if options.background {
            // 효율 코어 수만큼만. (Apple Silicon에서 낮은 QoS 작업은 효율 코어에서 돈다)
            threads = min(threads, max(2, efficiencyCoreCount() ?? threads / 2))
        }
        return ExecutionPlan(
            threads: max(1, threads),
            qos: options.background ? .utility : .userInitiated,
            throttleIO: options.background,
            sequential: sequential
        )
    }

    private static func efficiencyCoreCount() -> Int? {
        var n: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.perflevel1.logicalcpu", &n, &size, nil, 0) == 0, n > 0 else { return nil }
        return Int(n)
    }

    /// 이 스레드의 디스크 우선순위를 (필요하면) 낮춘 채로 body를 실행하고 원래대로 돌려놓는다.
    /// GCD 스레드는 재사용되므로 반드시 되돌려야 한다.
    func withIOPolicy<T>(_ body: () throws -> T) rethrows -> T {
        guard throttleIO else { return try body() }
        let old = getiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD)
        setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_UTILITY)
        defer { if old >= 0 { setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, old) } }
        return try body()
    }

    /// 일꾼 count명을 이 계획의 우선순위로 띄우고, 모두 끝날 때까지 기다린다.
    func runWorkers(_ count: Int, _ body: @escaping (Int) -> Void) {
        let group = DispatchGroup()
        startWorkers(count, group: group, body)
        group.wait()
    }

    /// 일꾼 count명을 띄우기만 하고 바로 돌아온다. 끝났는지는 group으로 안다.
    func startWorkers(_ count: Int, group: DispatchGroup, _ body: @escaping (Int) -> Void) {
        let queue = DispatchQueue.global(qos: qos)
        for w in 0..<max(1, count) {
            queue.async(group: group) { self.withIOPolicy { body(w) } }
        }
    }
}

enum VolumeInfo {
    /// 내장 + 로컬 드라이브인지 (= 대개 빠른 SSD). 아직 없는 경로면 가장 가까운 상위 폴더로 판단한다.
    static func isFastLocal(_ url: URL) -> Bool {
        var u = url
        while !FileManager.default.fileExists(atPath: u.path) && u.pathComponents.count > 1 {
            u = u.deletingLastPathComponent()
        }
        guard let v = try? u.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsLocalKey]) else { return true }
        return (v.volumeIsInternal ?? true) && (v.volumeIsLocal ?? true)
    }
}
