import SwiftUI

// 보내기 준비 · 용량 줄이기 탭이 함께 쓰는 부품

/// 파일을 놓는 큰 칸. 끌고 들어오면 무엇을 할지 크게 보여 준다.
struct ToolDropWell<Glyph: View>: View {
    @ObservedObject var model: AppModel
    let targetedSymbol: String
    let targetedTitle: String
    let title: String
    @ViewBuilder let glyph: () -> Glyph

    private var targeted: Bool { model.isDropTargeted }

    var body: some View {
        VStack(spacing: 10) {
            if targeted {
                Image(systemName: targetedSymbol)
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(Theme.accent)
                    .frame(height: 64)
                    .accessibilityHidden(true)
                Text(targetedTitle).font(.title2.weight(.semibold)).foregroundStyle(Theme.accent)
                Text(model.dragInfo?.summary ?? " ").font(.body).foregroundStyle(.secondary)
            } else {
                glyph()
                Text(title).font(.title3.weight(.semibold))
                Button("파일 선택…") { model.chooseFiles() }
                    .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 232)
        .glassSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous),
                    tint: targeted ? Theme.accent.opacity(0.35) : nil, interactive: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("파일을 놓는 곳")
    }
}

/// 고른 항목 이름과 한 줄 요약
struct ToolHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    let isFolder: Bool
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isFolder ? "folder" : "doc")
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            trailing()
        }
    }
}

struct ToolFailureCard<Actions: View>: View {
    let title: String
    let message: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2).foregroundStyle(Theme.warning)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(message).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack { actions() }.glassButton().controlSize(.large)
        }
        .padding(16)
        .card()
    }
}

/// 묶음 줄 오른쪽의 "8 ›": 눌러서 파일 목록을 펼친다
struct DisclosureCount: View {
    let count: Int
    @Binding var expanded: Bool

    var body: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Text("\(count)")
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded ? "파일 목록 접기" : "파일 \(count)개 보기")
    }
}
