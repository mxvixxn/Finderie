import Foundation
import ZipCore

/// 화면 확인 도구(finderie-snap)가 상태를 만들 때 쓰는 통로. 앱 자체는 쓰지 않는다.
@MainActor
public enum SnapshotSupport {
    public static func addHistory(_ model: AppModel, name: String, isCompress: Bool, detail: String, path: String, minutesAgo: Double) {
        model.history.append(HistoryItem(id: UUID(), name: name, isCompress: isCompress, detail: detail,
                                         path: path, date: Date().addingTimeInterval(-minutesAgo * 60)))
    }

    public static func setDragging(_ model: AppModel, isExtract: Bool, summary: String) {
        model.isDropTargeted = true
        model.dragInfo = DragInfo(isExtract: isExtract, summary: summary)
    }

    /// 실제 작업은 너무 빨리 끝나서, '작업 중' 화면은 예시 값으로 채운다.
    public static func addRunningExample(_ model: AppModel, folder: URL, zip: URL) {
        let running = Job(kind: .compress, inputs: [folder], target: nil)
        running.phase = .running
        running.totalBytes = 1_900_000_000
        running.fraction = 0.62
        running.bytesPerSecond = 860_000_000
        running.secondsLeft = 0.8
        running.currentName = "여행 사진 2026/2026-03 제주/IMG_0412.HEIC"
        let queued = Job(kind: .extract, inputs: [zip], target: nil)
        model.jobs = [running, queued]
    }

    public static func showPreview(_ model: AppModel, zip: URL) {
        model.showPreview(zip)
    }

    /// 작업 카드들의 상태를 글로 (확인용)
    public static func describe(_ model: AppModel) -> [String] {
        model.jobs.map { job in
            let base = "\(job.kind == .compress ? "압축" : "풀기") \(job.displayName): \(job.phase)"
            if let f = job.failure { return base + " — \(f.title) / \(f.reason)" }
            return base + " — \(job.summary) → \(job.resultURL?.lastPathComponent ?? "-")"
        }
    }

    /// 아직 진행 중인 일이 있는지 (작업, 미리보기 불러오기, 보내기 준비)
    public static func isBusy(_ model: AppModel) -> Bool {
        model.jobs.contains(where: \.isActive) || model.preview?.loading == true || model.prep?.isBusy == true
    }

    public static func setTab(_ model: AppModel, prep: Bool) {
        model.settings.tab = prep ? .prep : .zip
    }

    /// 보고서 상태에서 [복사본 만들기]
    public static func runPrepCopy(_ model: AppModel) {
        guard let prep = model.prep, case .ready(let report) = prep.phase else { return }
        prep.run(report, mode: .copy)
    }

    public static func describePrep(_ model: AppModel) -> String {
        guard let prep = model.prep else { return "prep: none" }
        switch prep.phase {
        case .scanning: return "prep: scanning"
        case .ready(let r): return "prep: ready files=\(r.fileCount) issues=\(r.issues.count) fixable=\(r.fixable.map(\.rawValue).sorted())"
        case .working: return "prep: working"
        case .done(_, let o, let zip): return "prep: done renamed=\(o.renamed) removed=\(o.removed) bom=\(o.bomAdded) converted=\(o.converted) zip=\(zip?.lastPathComponent ?? "-") folder=\(o.folder?.lastPathComponent ?? "-")"
        case .failed(let m, _): return "prep: failed \(m)"
        }
    }
}
