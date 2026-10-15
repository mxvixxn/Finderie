import SwiftUI

// 보내기 준비 · 용량 줄이기 탭이 함께 쓰는 부품

/// 파일을 놓는 큰 칸. 끌고 들어오면 무엇을 할지 크게 보여 준다.
struct ToolDropWell<Glyph: View>: View {
    @ObservedObject var model: AppModel
    let targetedSymbol: String
    let targetedTitle: String
    let title: String
    let subtitle: String
    @ViewBuilder let glyph: () -> Glyph

    private var targeted: Bool { model.isDropTargeted }

    var body: some View {
        VStack(spacing: 10) {
            if targeted {
                Image(systemName: targetedSymbol)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(Theme.sky, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: Theme.sky.opacity(0.35), radius: 10, y: 6)
                    .accessibilityHidden(true)
                Text(targetedTitle).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.primary)
                Text(model.dragInfo?.summary ?? " ").font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                glyph()
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
                Button("파일 선택…") { model.chooseFiles() }
                    .controlSize(.regular)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 232)
        .background(targeted ? Theme.sky.opacity(0.13) : Theme.sky.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(targeted ? Theme.sky : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: targeted ? 2 : 1.5, dash: targeted ? [] : [6, 4]))
        )
        .shadow(color: targeted ? Theme.sky.opacity(0.25) : .clear, radius: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("파일을 놓는 곳")
    }
}

/// 무엇을 하는지 미리 알려 주는 목록 카드
struct ChecksCard: View {
    let title: String
    let rows: [(String, String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 2)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    HStack(spacing: 12) {
                        Image(systemName: row.0)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.primary)
                            .frame(width: 28, height: 28)
                            .background(Theme.sky.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.1).font(.system(size: 13, weight: .medium))
                            Text(row.2).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 48)
                    if i < rows.count - 1 { Divider().padding(.leading, 52) }
                }
            }
            .card(radius: 12)
        }
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
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.primary)
                .frame(width: 36, height: 36)
                .background(Theme.sky.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
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
                Image(systemName: "exclamationmark")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.warning)
                    .frame(width: 36, height: 36).background(Theme.warning.opacity(0.13), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .bold))
                    Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack { actions() }.controlSize(.large)
        }
        .padding(16)
        .card()
    }
}
