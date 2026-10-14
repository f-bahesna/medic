// The numbers the menu bar shows, and how they are worked out from raw
// counters. Reading the counters is in System.swift; everything here is pure.

/// CPU time counters since boot, summed over all cores, in ticks.
public struct CPUTicks: Equatable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

/// Share of all cores busy between two readings, each 0...1.
public struct CPUUsage: Equatable {
    public var user: Double
    public var system: Double
    public var total: Double { user + system }

    /// The usage between two readings, nil when no time has passed.
    public init?(from a: CPUTicks, to b: CPUTicks) {
        // Counters only go up; a smaller value means they wrapped or reset.
        func delta(_ x: UInt64, _ y: UInt64) -> Double { y >= x ? Double(y - x) : 0 }
        let user = delta(a.user, b.user) + delta(a.nice, b.nice)
        let system = delta(a.system, b.system)
        let all = user + system + delta(a.idle, b.idle)
        guard all > 0 else { return nil }
        self.user = user / all
        self.system = system / all
    }

    public init(user: Double, system: Double) {
        self.user = user
        self.system = system
    }
}

/// How hard macOS is working to find memory. Only this tells you whether RAM
/// is a problem; a high "used" figure is normal.
public enum Pressure: String {
    case normal, warning, critical, unknown

    /// The value of the kern.memorystatus_vm_pressure_level sysctl.
    public init(level: Int32) {
        switch level {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: self = .unknown
        }
    }
}

/// Page counts from the kernel's virtual memory statistics, as vm_stat prints them.
public struct VMPages: Equatable {
    public var anonymous: UInt64  // "Anonymous pages", internal_page_count
    public var purgeable: UInt64
    public var wired: UInt64
    public var compressor: UInt64  // pages occupied by the compressor
    public var fileBacked: UInt64  // "File-backed pages", external_page_count
    public var free: UInt64
    public var pageSize: UInt64

    public init(anonymous: UInt64, purgeable: UInt64, wired: UInt64, compressor: UInt64, fileBacked: UInt64, free: UInt64, pageSize: UInt64) {
        self.anonymous = anonymous
        self.purgeable = purgeable
        self.wired = wired
        self.compressor = compressor
        self.fileBacked = fileBacked
        self.free = free
        self.pageSize = pageSize
    }
}

/// RAM use in bytes, worked out the way Activity Monitor and `medic memory` do.
public struct Memory: Equatable {
    public var total: Int64
    public var used: Int64  // app + wired + compressed
    public var app: Int64
    public var wired: Int64
    public var compressed: Int64
    public var cached: Int64  // freed instantly when apps need it
    public var free: Int64
    public var swapUsed: Int64
    public var swapTotal: Int64
    public var pressure: Pressure

    public init(pages p: VMPages, total: UInt64, pressure: Pressure, swapUsed: UInt64, swapTotal: UInt64) {
        let size = Int64(p.pageSize)
        self.total = Int64(total)
        wired = Int64(p.wired) * size
        compressed = Int64(p.compressor) * size
        app = max(Int64(p.anonymous) - Int64(p.purgeable), 0) * size
        used = app + wired + compressed
        cached = Int64(p.fileBacked + p.purgeable) * size
        free = Int64(p.free) * size
        self.swapUsed = Int64(swapUsed)
        self.swapTotal = Int64(swapTotal)
        self.pressure = pressure
    }

    /// How much RAM is in use, 0...1.
    public var usedFraction: Double { total > 0 ? min(Double(used) / Double(total), 1) : 0 }
}

/// The startup disk, in bytes.
public struct Disk: Equatable {
    public var total: Int64
    public var free: Int64

    public init(total: Int64, free: Int64) {
        self.total = total
        self.free = free
    }

    public var used: Int64 { total - free }
    public var usedFraction: Double { total > 0 ? min(Double(used) / Double(total), 1) : 0 }
}

/// One process at the moment it was read.
public struct ProcessSample: Equatable {
    /// Tells a process apart from a later one that got the same pid.
    public struct ID: Hashable {
        public var pid: Int32
        public var start: UInt64
    }

    public var id: ID
    public var app: String
    public var memory: Int64  // physical footprint, Activity Monitor's "Memory"
    public var cpuTime: UInt64  // nanoseconds of CPU used since it started

    public init(pid: Int32, start: UInt64, app: String, memory: Int64, cpuTime: UInt64) {
        id = ID(pid: pid, start: start)
        self.app = app
        self.memory = memory
        self.cpuTime = cpuTime
    }
}

/// All processes of one app added up.
public struct AppUsage: Equatable {
    public var name: String
    public var processes: Int
    public var memory: Int64
    /// CPU used between two readings, in cores: 1.5 is 150% in Activity Monitor.
    public var cpu: Double

    public init(name: String, processes: Int, memory: Int64, cpu: Double) {
        self.name = name
        self.processes = processes
        self.memory = memory
        self.cpu = cpu
    }
}

/// The app a process belongs to: everything inside "Foo.app/" counts as Foo,
/// so helper processes add up under their app, as in `medic memory`.
public func appName(path: String) -> String {
    let parts = path.split(separator: "/", omittingEmptySubsequences: true)
    for (i, part) in parts.enumerated() where part.hasSuffix(".app") && part.count > 4 && i < parts.count - 1 {
        return String(part.dropLast(4))
    }
    return parts.last.map(String.init) ?? path
}

/// Adds processes up per app. CPU is the time used since `previous`, over
/// `elapsed` nanoseconds; a process that was not there before counts from 0.
public func appUsage(_ now: [ProcessSample], previous: [ProcessSample]?, elapsed: UInt64) -> [AppUsage] {
    var before: [ProcessSample.ID: UInt64] = [:]
    for p in previous ?? [] { before[p.id] = p.cpuTime }
    var byApp: [String: AppUsage] = [:]
    for p in now {
        var cpu = 0.0
        if previous != nil, elapsed > 0 {
            let start = before[p.id] ?? 0
            cpu = p.cpuTime > start ? Double(p.cpuTime - start) / Double(elapsed) : 0
        }
        var a = byApp[p.app] ?? AppUsage(name: p.app, processes: 0, memory: 0, cpu: 0)
        a.processes += 1
        a.memory += p.memory
        a.cpu += cpu
        byApp[p.app] = a
    }
    return Array(byApp.values)
}

/// The `count` biggest by `key`, ties by name so the list does not jump around.
public func top(_ apps: [AppUsage], by key: (AppUsage) -> Double, count: Int) -> [AppUsage] {
    let sorted = apps.sorted { key($0) != key($1) ? key($0) > key($1) : $0.name < $1.name }
    return Array(sorted.prefix(count))
}
