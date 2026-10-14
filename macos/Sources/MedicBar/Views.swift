import AppKit
import MedicBarCore

// The panels inside the menu. Each is a fixed size view so the menu never
// changes size while it is open.

let menuWidth: CGFloat = 300
// Matches the left edge of the text of ordinary menu items next to a
// checkmark column, so panels and items line up.
let leading: CGFloat = 22
let trailing: CGFloat = 14

enum Colors {
    static func usage(_ fraction: Double) -> NSColor {
        fraction >= 0.9 ? .systemRed : fraction >= 0.75 ? .systemOrange : .systemGreen
    }

    static func pressure(_ p: Pressure) -> NSColor {
        switch p {
        case .normal: return .systemGreen
        case .warning: return .systemOrange
        case .critical: return .systemRed
        case .unknown: return .tertiaryLabelColor
        }
    }
}

func label(_ text: String = "", size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .monospacedDigitSystemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    field.translatesAutoresizingMaskIntoConstraints = false
    return field
}

/// A thin rounded usage bar.
final class BarView: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var color: NSColor = .systemGreen { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 6) }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let width = bounds.width * CGFloat(max(0, min(fraction, 1)))
        guard width > 0 else { return }
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: max(width, bounds.height), height: bounds.height), xRadius: radius, yRadius: radius).fill()
    }
}

/// A "name ... value" line.
final class Row: NSView {
    let name: NSTextField
    let value: NSTextField

    init(_ title: String, size: CGFloat = 13, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) {
        name = label(title, size: size, weight: weight, color: color)
        value = label(size: size, weight: weight, color: color)
        value.alignment = .right
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(name)
        addSubview(value)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        value.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor),
            name.firstBaselineAnchor.constraint(equalTo: value.firstBaselineAnchor),
            value.trailingAnchor.constraint(equalTo: trailingAnchor),
            value.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 12),
            value.topAnchor.constraint(equalTo: topAnchor),
            value.bottomAnchor.constraint(equalTo: bottomAnchor),
            name.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Stacks rows into a menu panel of a fixed width.
class Panel: NSView {
    let stack = NSStackView()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: menuWidth, height: 10))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trailing),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func add(_ view: NSView, spacingAfter: CGFloat? = nil) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if let spacingAfter { stack.setCustomSpacing(spacingAfter, after: view) }
    }

    /// Call once all rows are added: fixes the height to what they need.
    func finish() {
        layoutSubtreeIfNeeded()
        setFrameSize(NSSize(width: menuWidth, height: fittingSize.height))
    }
}

/// CPU, memory and disk.
final class StatsPanel: Panel {
    private let cpu = Row("CPU", weight: .semibold)
    private let cpuBar = BarView()
    private let cpuUser = Row("User", size: 12, color: .secondaryLabelColor)
    private let cpuSystem = Row("System", size: 12, color: .secondaryLabelColor)

    private let memory = Row("Memory", weight: .semibold)
    private let memoryBar = BarView()
    private let pressure = Row("Memory pressure", size: 12, color: .secondaryLabelColor)
    private let app = Row("App memory", size: 12, color: .secondaryLabelColor)
    private let wired = Row("Wired", size: 12, color: .secondaryLabelColor)
    private let compressed = Row("Compressed", size: 12, color: .secondaryLabelColor)
    private let cached = Row("Cached", size: 12, color: .secondaryLabelColor)
    private let swap = Row("Swap used", size: 12, color: .secondaryLabelColor)

    private let disk = Row("Startup disk", weight: .semibold)
    private let diskBar = BarView()
    private let diskUsed = Row("Used", size: 12, color: .secondaryLabelColor)

    override init() {
        super.init()
        add(cpu, spacingAfter: 5)
        add(cpuBar, spacingAfter: 5)
        add(cpuUser)
        add(cpuSystem, spacingAfter: 12)
        add(memory, spacingAfter: 5)
        add(memoryBar, spacingAfter: 5)
        for row in [pressure, app, wired, compressed, cached] { add(row) }
        add(swap, spacingAfter: 12)
        add(disk, spacingAfter: 5)
        add(diskBar, spacingAfter: 5)
        add(diskUsed)
        finish()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ s: Snapshot) {
        if let c = s.cpu {
            cpu.value.stringValue = formatPercent(c.total)
            cpuUser.value.stringValue = formatPercent(c.user)
            cpuSystem.value.stringValue = formatPercent(c.system)
            cpuBar.fraction = c.total
        } else {
            for row in [cpu, cpuUser, cpuSystem] { row.value.stringValue = "–" }
        }
        cpuBar.color = .controlAccentColor

        let m = s.memory
        let mem = { formatBytes($0, decimal: false) }
        memory.value.stringValue = "\(mem(m.used)) of \(mem(m.total))"
        // Only pressure says whether RAM is short, so the bar follows it.
        memoryBar.fraction = m.usedFraction
        memoryBar.color = Colors.pressure(m.pressure)
        let dot = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: Colors.pressure(m.pressure)])
        dot.append(NSAttributedString(string: m.pressure.rawValue.capitalized, attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
        let right = NSMutableParagraphStyle()
        right.alignment = .right
        dot.addAttributes([.font: pressure.value.font!, .paragraphStyle: right], range: NSRange(location: 0, length: dot.length))
        pressure.value.attributedStringValue = dot
        app.value.stringValue = mem(m.app)
        wired.value.stringValue = mem(m.wired)
        compressed.value.stringValue = mem(m.compressed)
        cached.value.stringValue = mem(m.cached)
        swap.value.stringValue = m.swapTotal > 0 ? "\(mem(m.swapUsed)) of \(mem(m.swapTotal))" : mem(m.swapUsed)

        if let d = s.disk {
            disk.value.stringValue = "\(formatBytes(d.free, decimal: true)) free"
            diskUsed.value.stringValue = "\(formatBytes(d.used, decimal: true)) of \(formatBytes(d.total, decimal: true))"
            diskBar.fraction = d.usedFraction
            diskBar.color = Colors.usage(d.usedFraction)
        }
    }
}

/// The apps using the most of something.
final class TopAppsPanel: Panel {
    static let count = 5
    private let rows: [Row]
    private let value: (AppUsage) -> Double
    private let text: (AppUsage) -> String
    private let waiting: String

    init(title: String, value: @escaping (AppUsage) -> Double, text: @escaping (AppUsage) -> String, waiting: String) {
        rows = (0..<Self.count).map { _ in Row("", size: 12) }
        self.value = value
        self.text = text
        self.waiting = waiting
        super.init()
        add(label(title, size: 12, weight: .semibold, color: .secondaryLabelColor), spacingAfter: 4)
        rows.forEach { add($0) }
        finish()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(_ apps: [AppUsage], ready: Bool) {
        let list = ready ? top(apps, by: value, count: Self.count) : []
        for (i, row) in rows.enumerated() {
            if !ready {
                row.name.stringValue = i == 0 ? waiting : ""
                row.name.textColor = .tertiaryLabelColor
                row.value.stringValue = ""
            } else if i < list.count {
                let a = list[i]
                row.name.stringValue = a.processes > 1 ? "\(a.name) (\(a.processes))" : a.name
                row.name.textColor = .labelColor
                row.value.stringValue = text(a)
            } else {
                row.name.stringValue = ""
                row.value.stringValue = ""
            }
        }
    }
}
