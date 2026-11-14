// Draws the TaskDeck icon as a 1024x1024 PNG: a stack of cards, the top one a task with its timer running.
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

// The deck: two cards behind, each narrower and fainter, so the stack reads as depth.
color(0xFFFFFF, 0.38).setFill()
rounded(CGRect(x: 322, y: 470, width: 380, height: 300), 56).fill()
color(0xFFFFFF, 0.66).setFill()
rounded(CGRect(x: 262, y: 400, width: 500, height: 300), 60).fill()

// The top card: the task being worked on.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: NSColor.black.withAlphaComponent(0.28).cgColor)
color(0xFFFFFF).setFill()
rounded(CGRect(x: 202, y: 232, width: 620, height: 400), 68).fill()
ctx.restoreGState()

// Play badge on the card: the running timer.
let badgeCenter = CGPoint(x: 342, y: 432)
let badgeRadius: CGFloat = 88
color(0xC81E2D).setFill()
NSBezierPath(ovalIn: CGRect(x: badgeCenter.x - badgeRadius, y: badgeCenter.y - badgeRadius,
                            width: badgeRadius * 2, height: badgeRadius * 2)).fill()

let tri = NSBezierPath()
tri.move(to: CGPoint(x: badgeCenter.x - 18, y: badgeCenter.y + 36))
tri.line(to: CGPoint(x: badgeCenter.x - 18, y: badgeCenter.y - 36))
tri.line(to: CGPoint(x: badgeCenter.x + 44, y: badgeCenter.y))
tri.close()
tri.lineJoinStyle = .round
tri.lineWidth = 12
NSColor.white.setFill()
NSColor.white.setStroke()
tri.fill()
tri.stroke()

// Two bars standing in for the task's title and detail.
color(0x2A1216, 0.82).setFill()
rounded(CGRect(x: 480, y: 452, width: 280, height: 48), 24).fill()
color(0x2A1216, 0.28).setFill()
rounded(CGRect(x: 480, y: 364, width: 190, height: 48), 24).fill()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
