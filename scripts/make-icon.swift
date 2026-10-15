// 앱 아이콘(1024px PNG) 생성: swift scripts/make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(red: 0.47, green: 0.36, blue: 0.98, alpha: 1),
                    NSColor(red: 0.96, green: 0.45, blue: 0.71, alpha: 1)])!.draw(in: path, angle: -60)

let config = NSImage.SymbolConfiguration(pointSize: 470, weight: .medium)
    .applying(.init(paletteColors: [.white]))
if let sym = NSImage(systemSymbolName: "doc.zipper", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let s = sym.size
    sym.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
}
let label = NSAttributedString(string: "가", attributes: [
    .font: NSFont.systemFont(ofSize: 150, weight: .heavy),
    .foregroundColor: NSColor(red: 0.47, green: 0.36, blue: 0.98, alpha: 1),
])
let badge = NSRect(x: 640, y: 160, width: 230, height: 230)
NSColor.white.setFill(); NSBezierPath(ovalIn: badge).fill()
let ls = label.size()
label.draw(at: NSPoint(x: badge.midX - ls.width / 2, y: badge.midY - ls.height / 2))
img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
