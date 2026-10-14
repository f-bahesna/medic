// Draws docs/screenshot-dmg.png: the window Medic.dmg opens in, from the same
// background and icon the DMG gets, with the icons where dmg-settings.py puts
// them. Run tools/macapp-screenshots.sh.
//
//   swift macos/Art/dmg-screenshot.swift ARTDIR OUTDIR
//
// ARTDIR is the output of macos/Art/draw.swift.
import AppKit

let art = URL(fileURLWithPath: CommandLine.arguments[1])
let out = URL(fileURLWithPath: CommandLine.arguments[2])

// As in macos/Resources/dmg-settings.py.
let content = NSSize(width: 640, height: 400)
let iconSize: CGFloat = 112
let icons: [(name: String, center: NSPoint, image: NSImage)] = [
    ("Medic", NSPoint(x: 170, y: 180), NSImage(contentsOf: art.appendingPathComponent("Medic.iconset/icon_128x128@2x.png"))!),
    ("Applications", NSPoint(x: 470, y: 180), NSWorkspace.shared.icon(forFile: "/Applications")),
]

let titleBar: CGFloat = 28
let margin: CGFloat = 32
let window = NSRect(x: margin, y: margin, width: content.width, height: content.height + titleBar)
let size = NSSize(width: window.width + 2 * margin, height: window.height + 2 * margin)
let scale = 2

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale, bitsPerSample: 8,
    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current!.imageInterpolation = .high
NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
    // The desktop, as behind the menu bar screenshot.
    NSColor(srgbRed: 0.86, green: 0.89, blue: 0.93, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()

    let frame = NSBezierPath(roundedRect: window, xRadius: 10, yRadius: 10)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    shadow.shadowBlurRadius = 24
    shadow.set()
    NSColor.windowBackgroundColor.setFill()
    frame.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    frame.addClip()
    // The title bar, with the window's name and its three buttons.
    let bar = NSRect(x: window.minX, y: window.maxY - titleBar, width: window.width, height: titleBar)
    NSColor(white: 0.93, alpha: 1).setFill()
    bar.fill()
    for (i, hex) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: bar.minX + 13 + CGFloat(i) * 20, y: bar.midY - 6, width: 12, height: 12)).fill()
    }
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let title = NSAttributedString(string: "Medic", attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
    ])
    title.draw(in: NSRect(x: bar.minX, y: bar.midY - title.size().height / 2, width: bar.width, height: title.size().height))

    NSImage(contentsOf: art.appendingPathComponent("background@2x.png"))!
        .draw(in: NSRect(x: window.minX, y: window.minY, width: content.width, height: content.height))
    for icon in icons {
        // dmg-settings.py measures from the top left of the window's content.
        let center = NSPoint(x: window.minX + icon.center.x, y: window.minY + content.height - icon.center.y)
        icon.image.draw(in: NSRect(x: center.x - iconSize / 2, y: center.y - iconSize / 2, width: iconSize, height: iconSize))
        let name = NSAttributedString(string: icon.name, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
        ])
        let height = name.size().height
        name.draw(in: NSRect(x: center.x - 80, y: center.y - iconSize / 2 - 4 - height, width: 160, height: height))
    }
    NSGraphicsContext.restoreGraphicsState()

    NSColor(white: 0, alpha: 0.2).setStroke()
    frame.lineWidth = 0.5
    frame.stroke()
}
try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("screenshot-dmg.png"))
