import AppKit
import SwiftUI
import ZipCore

// MARK: - 진행 중

struct ActiveSection: View {
    @ObservedObject var model: AppModel
    let jobs: [Job]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("진행 중 · \(jobs.count)개").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("모두 취소") { model.cancelAll() }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 2)
            ForEach(jobs) { job in
                JobProgressCard(job: job, model: model)
            }
        }
    }
}

struct JobProgressCard: View {
    @ObservedObject var job: Job
    @ObservedObject var model: AppModel

    private var verb: String { job.kind == .compress ? "압축" : "풀기" }

    var body: some View {
        if job.phase == .queued {
            HStack(spacing: 12) {
                badge(color: Color.primary.opacity(0.07), fg: .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(job.displayName) \(verb)").font(.system(size: 13.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text("대기 중").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                IconButton(systemName: "xmark", label: "이 작업 취소", filled: true) { model.cancel(job) }
            }
            .padding(14)
            .card()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    badge(color: Theme.sky, fg: .white)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(job.displayName) \(job.kind == .compress ? "압축 중" : "푸는 중")")
                            .font(.system(size: 13.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        Text(job.currentName.isEmpty ? "준비 중…" : job.currentName)
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    IconButton(systemName: "xmark", label: "이 작업 취소", filled: true) { model.cancel(job) }
                }
                ProgressBar(value: job.fraction)
                    .accessibilityLabel("\(job.displayName) \(verb) 진행률")
                    .accessibilityValue("\(Int(job.fraction * 100))%")
                HStack {
                    Text(detailLine).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Text("\(Int(job.fraction * 100))%").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                }
            }
            .padding(14)
            .card()
        }
    }

    private var detailLine: String {
        guard job.totalBytes > 0 else { return "크기를 세는 중…" }
        var parts = ["\(Fmt.bytes(UInt64(job.fraction * Double(job.totalBytes)))) / \(Fmt.bytes(job.totalBytes))"]
        if job.bytesPerSecond > 0 { parts.append("초당 \(Fmt.bytes(UInt64(job.bytesPerSecond)))") }
        if let left = job.secondsLeft { parts.append(Fmt.timeLeft(left)) }
        return parts.joined(separator: " · ")
    }

    private func badge(color: Color, fg: Color) -> some View {
        Image(systemName: job.kind == .compress ? "arrow.down.to.line" : "arrow.up.to.line")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(fg)
            .frame(width: 36, height: 36)
            .background(color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// 얇은 진행 막대 (6pt)
struct ProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule().fill(Theme.sky).frame(width: max(6, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.2), value: value)
    }
}

// MARK: - 완료 · 오류

struct FinishedSection: View {
    @ObservedObject var model: AppModel
    let jobs: [Job]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if jobs.count > 1 {
                HStack {
                    Text("끝난 작업 · \(jobs.count)개").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("모두 지우기") { model.clearFinished() }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 2)
            }
            ForEach(Array(jobs.enumerated()), id: \.element.id) { i, job in
                if i == 0 {
                    if job.phase == .failed { ErrorCard(job: job, model: model) } else { DoneCard(job: job, model: model) }
                } else {
                    CompactFinishedRow(job: job, model: model)
                }
            }
        }
    }
}

struct DoneCard: View {
    @ObservedObject var job: Job
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.success)
                    .frame(width: 36, height: 36)
                    .background(Theme.success.opacity(0.13), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(job.kind == .compress ? "압축 완료" : "풀기 완료").font(.system(size: 14, weight: .bold))
                    Text(job.summary).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                IconButton(systemName: "xmark", label: "카드 닫기", filled: true) { model.dismiss(job) }
            }

            if let url = job.resultURL {
                ResultChip(url: url, isZip: job.kind == .compress)
                HStack(spacing: 8) {
                    Button {
                        model.reveal(url)
                    } label: {
                        Label("Finder에서 보기", systemImage: "magnifyingglass").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.primary)
                    .controlSize(.large)

                    ShareLink(item: url) {
                        Label("공유…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
        }
        .padding(16)
        .card()
    }
}

/// 결과 파일. 끌어서 메일이나 메신저에 바로 넣을 수 있다.
struct ResultChip: View {
    let url: URL
    let isZip: Bool

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if isZip {
                    ZipperGlyph(size: 26)
                } else {
                    Image(systemName: "folder.fill").font(.system(size: 18)).foregroundStyle(Theme.skyLight)
                }
            }
            .frame(width: 40, height: 40)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text("끌어서 메일이나 메신저에 바로 넣을 수 있어요").font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .contentShape(Rectangle())
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .help("끌어서 다른 앱에 놓기")
        .accessibilityElement(children: .combine)
        .accessibilityHint("끌어서 다른 앱에 놓을 수 있어요")
    }
}

struct ErrorCard: View {
    @ObservedObject var job: Job
    @ObservedObject var model: AppModel

    var body: some View {
        let f = job.failure
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.warning)
                    .frame(width: 36, height: 36)
                    .background(Theme.warning.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(f?.title ?? "작업을 마치지 못했어요").font(.system(size: 14, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(f?.reason ?? "").font(.system(size: 12.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("이렇게 해 보세요").font(.system(size: 12.5, weight: .semibold))
                Text(f?.hint ?? "").font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                Text(f?.cleanupNote ?? "").font(.system(size: 12.5)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack(spacing: 8) {
                Spacer()
                if f?.retryable ?? true {
                    Button("닫기") { model.dismiss(job) }
                        .controlSize(.large)
                    Button("다시 시도") { model.retry(job) }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.primary)
                        .controlSize(.large)
                } else {
                    Button("닫기") { model.dismiss(job) }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.primary)
                        .controlSize(.large)
                }
            }
        }
        .padding(16)
        .card(border: Theme.warning.opacity(0.35))
    }
}

struct CompactFinishedRow: View {
    @ObservedObject var job: Job
    @ObservedObject var model: AppModel

    var body: some View {
        let failed = job.phase == .failed
        HStack(spacing: 12) {
            Image(systemName: failed ? "exclamationmark.triangle" : "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(failed ? Theme.warning : Theme.success)
                .frame(width: 30, height: 30)
                .background((failed ? Theme.warning : Theme.success).opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(failed ? (job.failure?.title ?? "실패") : "\(job.displayName) \(job.kind == .compress ? "압축" : "풀기") 완료")
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(failed ? (job.failure?.reason ?? "") : job.summary)
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let url = job.resultURL {
                IconButton(systemName: "magnifyingglass", label: "Finder에서 보기") { model.reveal(url) }
            } else if failed && job.failure?.retryable == true {
                IconButton(systemName: "arrow.clockwise", label: "다시 시도") { model.retry(job) }
            }
            IconButton(systemName: "xmark", label: "카드 닫기", filled: true) { model.dismiss(job) }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 11)
        .card()
    }
}
