/// Everything the menu shows at one moment.
public struct Snapshot {
    public var cpu: CPUUsage?  // nil until there are two readings
    public var memory: Memory
    public var disk: Disk?
    public var apps: [AppUsage]?  // nil when apps were not read
    public var appsHaveCPU: Bool  // false on the first app reading
}

/// Takes readings and keeps the previous one, since CPU use is the difference
/// between two.
public final class Monitor {
    private let system = System()
    private var lastTicks: CPUTicks?
    private var lastProcesses: [ProcessSample]?
    private var lastProcessTime: UInt64 = 0

    public init() {}

    /// A new reading. `apps` also reads every process, which only the open
    /// menu needs.
    public func sample(apps: Bool) -> Snapshot? {
        guard let memory = system.memory() else { return nil }
        let ticks = system.cpuTicks()
        let cpu = lastTicks.flatMap { last in ticks.flatMap { CPUUsage(from: last, to: $0) } }
        if let ticks { lastTicks = ticks }

        var usage: [AppUsage]?
        var appsHaveCPU = false
        if apps {
            let now = system.now()
            let processes = system.processes()
            appsHaveCPU = lastProcesses != nil
            usage = appUsage(processes, previous: lastProcesses, elapsed: now - lastProcessTime)
            lastProcesses = processes
            lastProcessTime = now
        } else {
            // Stale process times would spread old CPU use over a long gap.
            lastProcesses = nil
        }
        return Snapshot(cpu: cpu, memory: memory, disk: system.disk(), apps: usage, appsHaveCPU: appsHaveCPU)
    }
}
