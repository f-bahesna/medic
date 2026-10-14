// Draws docs/screenshot-menubar.png from Medic.app's real menu views, with
// sample data, like the other README screenshots. Run tools/menubar-screenshot.sh.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let gb: Int64 = 1 << 30
let mb: Int64 = 1 << 20
let page: UInt64 = 16384
func pages(_ bytes: Int64) -> UInt64 { UInt64(bytes) / page }

let sample = Snapshot(
    cpu: CPUUsage(user: 0.15, system: 0.08),
    memory: Memory(
        pages: VMPages(
            anonymous: pages(6 * gb + 300 * mb), purgeable: pages(100 * mb), wired: pages(2 * gb + 600 * mb),
            compressor: pages(2 * gb + 600 * mb), fileBacked: pages(3 * gb + 800 * mb), free: pages(300 * mb), pageSize: page),
        total: UInt64(16 * gb), pressure: .normal, swapUsed: UInt64(512 * mb), swapTotal: UInt64(2 * gb)),
    disk: Disk(total: 494_384_795_648, free: 212_400_000_000),
    apps: [
        AppUsage(name: "Safari", processes: 14, memory: 2 * gb + 100 * mb, cpu: 0.12),
        AppUsage(name: "Xcode", processes: 3, memory: 1 * gb + 600 * mb, cpu: 0.38),
        AppUsage(name: "Slack", processes: 6, memory: 912 * mb, cpu: 0.04),
        AppUsage(name: "Music", processes: 1, memory: 412 * mb, cpu: 0.02),
        AppUsage(name: "Finder", processes: 1, memory: 188 * mb, cpu: 0.01),
    ],
    appsHaveCPU: true)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

// A strip of menu bar with Medic's text in it, and the menu panels under it.
let stats = StatsPanel()
stats.update(sample)
let topMemory = TopAppsPanel(title: "Top apps by memory", value: { Double($0.memory) }, text: { formatBytes($0.memory, decimal: false) }, waiting: "")
topMemory.update(sample.apps!, ready: true)
let topCPU = TopAppsPanel(title: "Top apps by CPU", value: { $0.cpu }, text: { formatPercent($0.cpu) }, waiting: "")
topCPU.update(sample.apps!, ready: true)

let barHeight: CGFloat = 24
let margin: CGFloat = 16
// A menu separator, as between the panels in the real menu.
let separator = NSView(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 11))
let line = NSBox(frame: NSRect(x: 10, y: 5, width: menuWidth - 20, height: 1))
line.boxType = .separator
separator.addSubview(line)
let panels: [NSView] = [stats, separator, topMemory, topCPU]
let menuHeight = panels.reduce(0) { $0 + $1.frame.height } + 2 * 6
let size = NSSize(width: menuWidth + 2 * margin + 40, height: barHeight + 6 + menuHeight + margin)

let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
window.appearance = NSAppearance(named: .aqua)
let root = NSView(frame: NSRect(origin: .zero, size: size))
root.wantsLayer = true
root.layer!.backgroundColor = NSColor(srgbRed: 0.86, green: 0.89, blue: 0.93, alpha: 1).cgColor
window.contentView = root

let bar = NSView(frame: NSRect(x: 0, y: size.height - barHeight, width: size.width, height: barHeight))
bar.wantsLayer = true
bar.layer!.backgroundColor = NSColor(white: 0.97, alpha: 0.9).cgColor
root.addSubview(bar)
let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
let title = NSTextField(labelWithAttributedString: NSAttributedString(
    string: barText(style: .cpuAndMemory, cpu: sample.cpu, memory: sample.memory), attributes: [.font: font]))
title.sizeToFit()
let menuX = size.width - margin - menuWidth
// The highlight a clicked menu bar item gets.
let highlight = NSView(frame: NSRect(x: menuX + 8, y: 2, width: title.frame.width + 16, height: barHeight - 4))
highlight.wantsLayer = true
highlight.layer!.backgroundColor = NSColor(white: 0, alpha: 0.1).cgColor
highlight.layer!.cornerRadius = 5
bar.addSubview(highlight)
title.setFrameOrigin(NSPoint(x: menuX + 16, y: (barHeight - title.frame.height) / 2))
bar.addSubview(title)

let menu = NSView(frame: NSRect(x: menuX, y: margin, width: menuWidth, height: menuHeight))
menu.wantsLayer = true
menu.layer!.backgroundColor = NSColor(white: 0.965, alpha: 1).cgColor
menu.layer!.cornerRadius = 10
menu.layer!.borderWidth = 0.5
menu.layer!.borderColor = NSColor(white: 0, alpha: 0.15).cgColor
root.addSubview(menu)
var y = menuHeight - 6
for p in panels {
    y -= p.frame.height
    p.setFrameOrigin(NSPoint(x: 0, y: y))
    menu.addSubview(p)
}

window.orderFrontRegardless()
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
    root.cacheDisplay(in: root.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("screenshot-menubar.png"))
    exit(0)
}
app.run()
