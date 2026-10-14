import Foundation

/// Formats bytes like `medic` does: decimal (Finder, disks) starts at KB,
/// binary (Activity Monitor, memory) at B. GB and TB get one decimal.
public func formatBytes(_ bytes: Int64, decimal: Bool) -> String {
    let base = decimal ? 1000.0 : 1024.0
    let units = decimal ? ["KB", "MB", "GB", "TB"] : ["B", "KB", "MB", "GB", "TB"]
    var v = Double(max(bytes, 0))
    if decimal { v /= base }
    var i = 0
    while v >= base && i < units.count - 1 {
        v /= base
        i += 1
    }
    if units[i] == "GB" || units[i] == "TB" {
        return String(format: "%.1f %@", v, units[i])
    }
    return String(format: "%.0f %@", v.rounded(), units[i])
}

/// A share as a whole percentage: 0.237 is "24%".
public func formatPercent(_ fraction: Double) -> String {
    "\(Int((max(fraction, 0) * 100).rounded()))%"
}

/// What the menu bar shows.
public enum BarStyle: String, CaseIterable {
    case cpuAndMemory, cpu, memory

    public var title: String {
        switch self {
        case .cpuAndMemory: return "CPU and RAM"
        case .cpu: return "CPU Only"
        case .memory: return "RAM Only"
        }
    }
}

/// The menu bar text, like "CPU 12%  RAM 64%". Before the first CPU reading
/// the CPU figure is a dash. Figures are padded to two digits with figure
/// spaces, which are as wide as a digit, so the menu bar does not shift as
/// they change; only a rare 100% is wider.
public func barText(style: BarStyle, cpu: CPUUsage?, memory: Memory) -> String {
    func pad(_ s: String) -> String { String(repeating: "\u{2007}", count: max(3 - s.count, 0)) + s }
    let cpuText = "CPU " + pad(cpu.map { formatPercent($0.total) } ?? "–")
    let memText = "RAM " + pad(formatPercent(memory.usedFraction))
    switch style {
    case .cpuAndMemory: return cpuText + "  " + memText
    case .cpu: return cpuText
    case .memory: return memText
    }
}
