import AppKit
import SwiftUI
import ZipCore

/// 앱 아이콘과 맞춘 색. 글자 대비가 필요한 곳은 진한 하늘색(primary)을 쓴다.
enum Theme {
    /// 아이콘의 손잡이 몸통 색
    static let sky = Color(red: 0x2F / 255, green: 0xA6 / 255, blue: 0xF2 / 255)
    /// 아이콘의 손잡이 고리 색
    static let skyLight = Color(red: 0x7C / 255, green: 0xCF / 255, blue: 1)
    /// 흰 글씨를 올리는 버튼 색 (대비 4.5:1 이상)
    static let primary = Color(red: 0x0A / 255, green: 0x74 / 255, blue: 0xC2 / 255)
    static let success = Color(red: 0x1B / 255, green: 0x7F / 255, blue: 0x45 / 255)
    static let warning = Color(red: 0xA9 / 255, green: 0x4F / 255, blue: 0x06 / 255)

    /// 카드 바탕 (라이트: 흰색, 다크: 짙은 회색)
    static let card = Color(nsColor: .controlBackgroundColor)
    /// 카드 테두리
    static let hairline = Color.primary.opacity(0.12)
}

/// 앱 아이콘과 같은 지퍼 그림 (위가 진하고 아래로 갈수록 연한 이빨 + 하늘색 손잡이).
struct ZipperGlyph: View {
    var size: CGFloat = 64
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { ctx, area in
            let s = area.width / 100
            func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
                Path(roundedRect: CGRect(x: x * s, y: y * s, width: w * s, height: h * s), cornerRadius: r * s)
            }
            let dark = scheme == .dark
            let teethGradient = Gradient(colors: dark
                ? [Color(white: 0.96), Color(white: 0.34)]
                : [Color(white: 0.08), Color(red: 0.71, green: 0.73, blue: 0.76)])
            var teeth = Path()
            let spots: [(CGFloat, CGFloat)] = [(41, 2), (51, 6), (41, 10), (51, 14), (41, 18), (51, 22),
                                               (41, 82), (51, 86), (41, 90), (51, 94)]
            for (x, y) in spots { teeth.addPath(box(x, y, 8, 4.6, 2.3)) }
            ctx.fill(teeth, with: .linearGradient(teethGradient, startPoint: .zero, endPoint: CGPoint(x: 0, y: area.height)))

            var tab = box(37.5, 42, 25, 44, 12.5)
            tab.addPath(box(44.5, 64, 11, 15, 5.5))
            ctx.fill(tab, with: .color(Theme.skyLight), style: FillStyle(eoFill: true))
            ctx.fill(box(29, 24, 42, 24, 12), with: .color(Theme.sky))
            ctx.fill(box(44, 31, 12, 4, 2), with: .color(.white.opacity(0.85)))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// 카드 모양: 바탕 + 얇은 테두리 + 옅은 그림자
struct CardBackground: ViewModifier {
    var radius: CGFloat = 14
    var border: Color = Theme.hairline

    func body(content: Content) -> some View {
        content
            .background(Theme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(border, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.04), radius: 4, y: 2)
    }
}

extension View {
    func card(radius: CGFloat = 14, border: Color = Theme.hairline) -> some View {
        modifier(CardBackground(radius: radius, border: border))
    }
}

/// 아이콘만 있는 둥근 버튼 (취소 ✕, Finder에서 보기 등)
struct IconButton: View {
    let systemName: String
    let label: String
    var filled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: filled ? 10 : 13, weight: filled ? .bold : .medium))
                .foregroundStyle(.secondary)
                .frame(width: filled ? 26 : 30, height: filled ? 26 : 30)
                .background(filled ? Color.primary.opacity(0.07) : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}

// MARK: - 표시 형식

enum Fmt {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }

    static func seconds(_ t: TimeInterval) -> String {
        if t < 0.1 { return "0.1초 미만" }
        if t < 10 { return String(format: "%.1f초", t) }
        if t < 60 { return "\(Int(t.rounded()))초" }
        return "\(Int(t) / 60)분 \(Int(t) % 60)초"
    }

    static func timeLeft(_ t: TimeInterval) -> String {
        if t < 1 { return "곧 끝나요" }
        if t < 60 { return "약 \(Int(t.rounded(.up)))초 남음" }
        return "약 \(Int((t / 60).rounded(.up)))분 남음"
    }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.unitsStyle = .full
        if Date().timeIntervalSince(date) < 60 { return "방금" }
        return f.localizedString(for: date, relativeTo: Date())
    }

    /// 이름 뒤에 붙일 목적격 조사 (을/를). 한글은 받침으로, 영문·숫자는 읽는 소리로 대강 판단한다.
    static func objectParticle(for word: String) -> String {
        guard let last = word.trimmingCharacters(in: .whitespaces).unicodeScalars.last else { return "을(를)" }
        let v = last.value
        if (0xAC00...0xD7A3).contains(v) { return (v - 0xAC00) % 28 == 0 ? "를" : "을" }
        let c = Character(last).lowercased()
        if "013678".contains(c) { return "을" }
        if "2459".contains(c) { return "를" }
        if "bklmnpt".contains(c) { return "을" }
        return "를"
    }

    static func quoted(_ name: String) -> String { "‘\(name)’\(objectParticle(for: name))" }
}

extension NameEncoding {
    /// 칩에 쓰는 짧은 이름
    var shortTitle: String {
        switch self {
        case .windowsUTF8: return "Windows 호환"
        case .windowsCP949: return "구형 Windows"
        case .macDefault: return "Mac 기본"
        }
    }

    /// 완료 카드에 쓰는 설명
    var resultTitle: String {
        switch self {
        case .windowsUTF8: return "Windows 호환(UTF-8)"
        case .windowsCP949: return "구형 Windows 호환(CP949)"
        case .macDefault: return "Mac 기본 방식"
        }
    }
}
