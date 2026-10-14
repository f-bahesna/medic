import AppKit
import MedicBarCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let monitor = Monitor()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let stats = StatsPanel()
    private let topMemory = TopAppsPanel(
        title: "Top apps by memory", value: { Double($0.memory) },
        text: { formatBytes($0.memory, decimal: false) }, waiting: "Reading…")
    private let topCPU = TopAppsPanel(
        title: "Top apps by CPU", value: { $0.cpu },
        text: { formatPercent($0.cpu) }, waiting: "Measuring…")
    private let installCLIItem = NSMenuItem(title: "Install “medic” Command…", action: #selector(installCLI), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private let styleMenu = NSMenu()
    private var timer: Timer?
    private var menuOpen = false
    private var shownTitle: NSAttributedString?

    private static let styleKey = "barStyle"
    private var style: BarStyle {
        get { BarStyle(rawValue: UserDefaults.standard.string(forKey: Self.styleKey) ?? "") ?? .cpuAndMemory }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.styleKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Actions.clearHelperQuarantine()
        buildMenu()
        statusItem.menu = menu
        statusItem.button?.toolTip = "Medic"
        refresh()
        schedule(interval: 2)
    }

    // MARK: Menu

    private func buildMenu() {
        menu.delegate = self
        menu.autoenablesItems = false
        menu.addItem(viewItem(stats))
        menu.addItem(.separator())
        menu.addItem(viewItem(topMemory))
        menu.addItem(viewItem(topCPU))
        menu.addItem(.separator())
        menu.addItem(item("Full Report in Terminal", #selector(openReport)))
        menu.addItem(item("Clean Up in Terminal…", #selector(openClean)))
        menu.addItem(item("Open Activity Monitor", #selector(openActivityMonitor)))
        menu.addItem(.separator())
        installCLIItem.target = self
        menu.addItem(installCLIItem)
        for s in BarStyle.allCases {
            let i = NSMenuItem(title: s.title, action: #selector(pickStyle(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = s.rawValue
            styleMenu.addItem(i)
        }
        let styleItem = NSMenuItem(title: "Show in Menu Bar", action: nil, keyEquivalent: "")
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)
        if Actions.loginItemSupported {
            loginItem.target = self
            menu.addItem(loginItem)
        }
        menu.addItem(.separator())
        menu.addItem(item("About Medic", #selector(about)))
        menu.addItem(item("Quit Medic", #selector(quit), key: "q"))
    }

    private func viewItem(_ view: NSView) -> NSMenuItem {
        let i = NSMenuItem()
        i.view = view
        return i
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menuOpen = true
        let installed = Actions.cli.installed
        installCLIItem.title = installed ? "“medic” Command Installed" : "Install “medic” Command…"
        installCLIItem.state = installed ? .on : .off
        installCLIItem.isEnabled = !installed
        loginItem.state = Actions.opensAtLogin ? .on : .off
        for i in styleMenu.items { i.state = i.representedObject as? String == style.rawValue ? .on : .off }
        refresh()
        // Faster while open, and per-app CPU needs a second reading soon.
        schedule(interval: 1)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menuOpen = false
        schedule(interval: 2)
    }

    // MARK: Updating

    private func schedule(interval: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        t.tolerance = interval / 10
        // .common keeps it running while the menu is open and tracking the mouse.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func refresh() {
        guard let s = monitor.sample(apps: menuOpen) else { return }
        updateTitle(s)
        guard menuOpen else { return }
        stats.update(s)
        topMemory.update(s.apps ?? [], ready: s.apps != nil)
        topCPU.update(s.apps ?? [], ready: s.appsHaveCPU)
    }

    private func updateTitle(_ s: Snapshot) {
        guard let button = statusItem.button else { return }
        // The menu bar's own font size, with digits of one width.
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        let text = barText(style: style, cpu: s.cpu, memory: s.memory)
        let title = NSMutableAttributedString(string: text, attributes: [.font: font])
        // Like a low battery: memory turns orange or red only when RAM is short.
        if s.memory.pressure == .warning || s.memory.pressure == .critical, let r = text.range(of: "RAM") {
            title.addAttribute(.foregroundColor, value: Colors.pressure(s.memory.pressure), range: NSRange(r.lowerBound..<text.endIndex, in: text))
        }
        // Redrawing the menu bar is most of what Medic costs, so only on change.
        // The button adds its own attributes, so compare with what was set.
        guard title != shownTitle else { return }
        shownTitle = title
        button.attributedTitle = title
    }

    // MARK: Actions

    @objc private func openReport() { Actions.runInTerminal([]) }
    @objc private func openClean() { Actions.runInTerminal(["clean"]) }
    @objc private func openActivityMonitor() { Actions.openActivityMonitor() }
    @objc private func installCLI() { Actions.installCLI() }
    @objc private func toggleLogin() { Actions.setOpensAtLogin(!Actions.opensAtLogin) }

    @objc private func pickStyle(_ sender: NSMenuItem) {
        style = BarStyle(rawValue: sender.representedObject as? String ?? "") ?? .cpuAndMemory
        refresh()
    }

    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: "CPU, memory and disk at a glance.\nhttps://github.com/f-bahesna/medic",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
