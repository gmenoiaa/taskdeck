// Draws the TaskDeck icon as a 1024x1024 PNG: three bold kanban columns and a play badge.
// Few, large shapes so it still reads at 16-32 px in the Dock, Finder and menu bar.
// Usage: swift scripts/make-icon.swift out.png   — scripts/make-icon.sh builds the .icns.
import AppKit

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
func rounded(_ rect: CGRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

let topRed = color(0xFF5A4F), bottomRed = color(0xA30F22)

// Background: rounded square at the standard macOS icon size, with a soft shadow.
let bgRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let bg = rounded(bgRect, 186)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.30).cgColor)
color(0xC81E2D).setFill()
bg.fill()
ctx.restoreGState()
NSGradient(starting: topRed, ending: bottomRed)!.draw(in: bg, angle: -90)

// Three solid columns of different heights, hanging from the same top line.
let columnWidth: CGFloat = 176, gap: CGFloat = 48
let startX = bgRect.minX + (bgRect.width - (columnWidth * 3 + gap * 2)) / 2
let top: CGFloat = 800
let heights: [CGFloat] = [560, 360, 250]
for (i, height) in heights.enumerated() {
    let rect = CGRect(x: startX + CGFloat(i) * (columnWidth + gap), y: top - height, width: columnWidth, height: height)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: NSColor.black.withAlphaComponent(0.20).cgColor)
    color(0xFFFFFF, 0.97).setFill()
    rounded(rect, 44).fill()
    ctx.restoreGState()
}

// Play badge in the free corner under the short columns: the running timer.
let badgeCenter = CGPoint(x: 668, y: 356)
let badgeRadius: CGFloat = 158
let badgeRect = CGRect(x: badgeCenter.x - badgeRadius, y: badgeCenter.y - badgeRadius,
                       width: badgeRadius * 2, height: badgeRadius * 2)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: NSColor.black.withAlphaComponent(0.30).cgColor)
color(0x2A1216).setFill()
NSBezierPath(ovalIn: badgeRect).fill()
ctx.restoreGState()

let tri = NSBezierPath()
tri.move(to: CGPoint(x: badgeCenter.x - 44, y: badgeCenter.y + 70))
tri.line(to: CGPoint(x: badgeCenter.x - 44, y: badgeCenter.y - 70))
tri.line(to: CGPoint(x: badgeCenter.x + 76, y: badgeCenter.y))
tri.close()
tri.lineJoinStyle = .round
tri.lineWidth = 22
NSColor.white.setFill()
NSColor.white.setStroke()
tri.fill()
tri.stroke()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
