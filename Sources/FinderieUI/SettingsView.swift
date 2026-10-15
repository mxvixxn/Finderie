import SwiftUI
import ZipCore

/// 설정 창 (⌘,). 자주 바꾸지 않는 옵션은 여기에 둔다.
public struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    public init(settings: AppSettings) {
        self.settings = settings
    }

    public var body: some View {
        Form {
            Section("압축") {
                Picker("한글 파일 이름", selection: $settings.nameEncoding) {
                    ForEach(NameEncoding.allCases) { Text($0.title).tag($0) }
                }
                Text(settings.nameEncoding.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("압축 속도", selection: $settings.level) {
                    ForEach(CompressionLevel.allCases) { Text($0.title).tag($0) }
                }
                Toggle("사진 · 영상 · ZIP처럼 이미 압축된 파일은 그대로 담기", isOn: $settings.storeCompressedFiles)
            }

            Section("풀기") {
                Toggle("풀기 전에 미리보기 보여 주기", isOn: Binding(get: { !settings.skipPreview },
                                                                  set: { settings.skipPreview = !$0 }))
                Picker("기본 풀 위치", selection: $settings.extractDestination) {
                    ForEach(ExtractDestination.allCases) { Text($0.title).tag($0) }
                }
            }

            Section("공통") {
                Toggle("Mac 전용 숨김 파일 빼기 (.DS_Store, ._파일, __MACOSX)", isOn: $settings.excludeMacFiles)
                Toggle("백그라운드 모드", isOn: $settings.background)
                Text("조금 느려지지만, 큰 작업 중에도 다른 앱이 버벅이지 않게 효율 코어 위주로 낮은 우선순위로 일해요.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}
