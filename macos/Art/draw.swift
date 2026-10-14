// Draws the app icon and the DMG window background, so they are made from
// source rather than checked in as images. Used by tools/macapp.sh:
//
//   swift macos/Art/draw.swift OUTDIR [--unsigned]
//
// Writes OUTDIR/Medic.iconset/*.png and OUTDIR/background.png, background@2x.png.
// --unsigned adds how to open an app macOS cannot verify to the DMG window.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let unsigned = CommandLine.arguments.contains("--unsigned")

func png(_ pixels: Int, _ height: Int? = nil, to url: URL, draw: (CGFloat) -> Void) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: height ?? pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: height ?? pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// A pulse line, as on a heart monitor, in a unit square.
func pulse(in rect: NSRect) -> NSBezierPath {
    let points: [(CGFloat, CGFloat)] = [
        (0.00, 0.50), (0.30, 0.50), (0.38, 0.62), (0.46, 0.20), (0.56, 0.86), (0.64, 0.40), (0.70, 0.50), (1.00, 0.50),
    ]
    let path = NSBezierPath()
    for (i, (x, y)) in points.enumerated() {
        let p = NSPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        i == 0 ? path.move(to: p) : path.line(to: p)
    }
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    return path
}

/// The icon on a 1024 grid: Apple's macOS icon shape is an 824 point rounded
/// square with a 185 point corner, centered, with a soft shadow below.
func icon(_ size: CGFloat) {
    let s = size / 1024
    let shape = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: shape, xRadius: 185 * s, yRadius: 185 * s)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 20 * s
    shadow.set()
    rgb(0x0B6E5F).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(starting: rgb(0x34D399), ending: rgb(0x0F766E))!.draw(in: shape, angle: -90)
    // Faint grid, like a monitor's screen.
    rgb(0xFFFFFF, 0.08).setStroke()
    for i in 1..<6 {
        let x = shape.minX + shape.width * CGFloat(i) / 6
        let y = shape.minY + shape.height * CGFloat(i) / 6
        let grid = NSBezierPath()
        grid.move(to: NSPoint(x: x, y: shape.minY))
        grid.line(to: NSPoint(x: x, y: shape.maxY))
        grid.move(to: NSPoint(x: shape.minX, y: y))
        grid.line(to: NSPoint(x: shape.maxX, y: y))
        grid.lineWidth = max(4 * s, 0.5)
        grid.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()

    let line = pulse(in: shape.insetBy(dx: 130 * s, dy: 170 * s))
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    glow.shadowOffset = NSSize(width: 0, height: -6 * s)
    glow.shadowBlurRadius = 12 * s
    glow.set()
    line.lineWidth = 64 * s
    NSColor.white.setStroke()
    line.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

let iconset = out.appendingPathComponent("Medic.iconset")
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    png(points, to: iconset.appendingPathComponent("icon_\(points)x\(points).png"), draw: icon)
    png(points * 2, to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"), draw: icon)
}

// The DMG window: the app on the left, Applications on the right (positions
// in tools/dmg-settings.py), an arrow between them and a short instruction.
let windowSize = NSSize(width: 640, height: 400)
func background(_ width: CGFloat) {
    let s = width / windowSize.width
    NSGradient(starting: rgb(0xF7F8FA), ending: rgb(0xE9ECF0))!.draw(in: NSRect(x: 0, y: 0, width: width, height: windowSize.height * s), angle: -90)

    let arrow = NSBezierPath()
    let y = (400 - 180) * s  // icon centers are 180 points from the top
    arrow.move(to: NSPoint(x: 265 * s, y: y))
    arrow.line(to: NSPoint(x: 375 * s, y: y))
    arrow.move(to: NSPoint(x: 357 * s, y: y + 16 * s))
    arrow.line(to: NSPoint(x: 377 * s, y: y))
    arrow.line(to: NSPoint(x: 357 * s, y: y - 16 * s))
    arrow.lineWidth = 5 * s
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    rgb(0x9AA3AE).setStroke()
    arrow.stroke()

    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let text = NSAttributedString(string: "Drag Medic to Applications, then open it from there.", attributes: [
        .font: NSFont.systemFont(ofSize: 15 * s, weight: .medium),
        .foregroundColor: rgb(0x4B5563),
        .paragraphStyle: style,
    ])
    text.draw(in: NSRect(x: 0, y: 70 * s, width: width, height: 24 * s))
    let note = NSAttributedString(string: "Medic shows CPU and memory in the menu bar, at the top right of the screen.", attributes: [
        .font: NSFont.systemFont(ofSize: 12 * s),
        .foregroundColor: rgb(0x6B7280),
        .paragraphStyle: style,
    ])
    note.draw(in: NSRect(x: 0, y: 46 * s, width: width, height: 20 * s))
    if unsigned {
        let gatekeeper = NSAttributedString(
            string: "If macOS says it cannot verify Medic: System Settings > Privacy & Security > Open Anyway.",
            attributes: [.font: NSFont.systemFont(ofSize: 11 * s), .foregroundColor: rgb(0x6B7280), .paragraphStyle: style])
        gatekeeper.draw(in: NSRect(x: 0, y: 20 * s, width: width, height: 18 * s))
    }
}
png(Int(windowSize.width), Int(windowSize.height), to: out.appendingPathComponent("background.png"), draw: background)
png(Int(windowSize.width * 2), Int(windowSize.height * 2), to: out.appendingPathComponent("background@2x.png"), draw: background)
