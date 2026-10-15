import SwiftUI
import ZipCore

struct ContentView: View {
    @EnvironmentObject private var worker: Worker
    @State private var isTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("", selection: $worker.mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(worker.isBusy)

            dropZone

            optionsSection

            statusSection
        }
        .padding(20)
        .frame(width: 440)
    }

    // MARK: - 끌어다 놓기 영역

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: worker.mode == .compress ? "doc.zipper" : "archivebox")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tint)
            Text(worker.mode == .compress
                 ? "압축할 파일이나 폴더를 여기에 끌어다 놓으세요"
                 : "풀 ZIP 파일을 여기에 끌어다 놓으세요")
                .font(.headline)
            Button("파일 선택…") { worker.chooseFiles() }
                .disabled(worker.isBusy)
        }
        .frame(maxWidth: .infinity, minHeight: 170)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                              style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard !worker.isBusy else { return false }
            worker.run(urls)
            return true
        } isTargeted: { isTargeted = $0 }
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }

    // MARK: - 옵션

    @ViewBuilder
    private var optionsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if worker.mode == .compress {
                    Picker("압축 속도", selection: $worker.level) {
                        ForEach(CompressionLevel.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("사진·영상·zip처럼 이미 압축된 파일은 그대로 담기 (훨씬 빠름)",
                           isOn: $worker.storeCompressedFiles)
                    Divider()
                    Picker("한글 파일 이름", selection: $worker.nameEncoding) {
                        ForEach(NameEncoding.allCases) { Text($0.title).tag($0) }
                    }
                    Text(worker.nameEncoding.detail)
                        .font(.caption)
                        .foregroundStyle(worker.nameEncoding == .macDefault ? .orange : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("한글 이름 인코딩(UTF-8 / Windows CP949)을 자동으로 알아내서 깨지지 않게 풀어요.",
                          systemImage: "character.book.closed")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                Toggle("백그라운드 모드 (조금 느리지만 다른 작업을 방해하지 않아요)", isOn: $worker.background)
                Toggle(worker.mode == .compress
                       ? "Mac 전용 숨김 파일 빼기 (.DS_Store, ._파일)"
                       : "Mac 전용 숨김 파일 빼기 (__MACOSX, .DS_Store)",
                       isOn: $worker.excludeMacFiles)
            }
            .padding(6)
            .disabled(worker.isBusy)
        }
    }

    // MARK: - 상태

    @ViewBuilder
    private var statusSection: some View {
        switch worker.status {
        case .idle:
            EmptyView()
        case .working(let progress, let name):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress)
                Text(name.isEmpty ? "준비 중…" : name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .done(let message, let url):
            HStack {
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .lineLimit(2)
                Spacer()
                Button("Finder에서 보기") { worker.reveal(url) }
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
