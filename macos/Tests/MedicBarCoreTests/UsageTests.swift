import Testing
@testable import MedicBarCore

@Test func cpuUsageIsTheShareOfTicksBetweenReadings() throws {
    let a = CPUTicks(user: 100, system: 50, idle: 800, nice: 50)
    let b = CPUTicks(user: 160, system: 80, idle: 900, nice: 60)
    let u = try #require(CPUUsage(from: a, to: b))
    #expect(u.user == 70.0 / 200)  // user + nice
    #expect(u.system == 30.0 / 200)
    #expect(u.total == 0.5)
}

@Test func cpuUsageNeedsTimeToPass() {
    let a = CPUTicks(user: 1, system: 1, idle: 1, nice: 1)
    #expect(CPUUsage(from: a, to: a) == nil)
}

@Test func cpuUsageIgnoresCountersThatWentBack() throws {
    let a = CPUTicks(user: 500, system: 50, idle: 100, nice: 0)
    let b = CPUTicks(user: 10, system: 50, idle: 200, nice: 0)
    let u = try #require(CPUUsage(from: a, to: b))
    #expect(u.total == 0)
}

@Test func memoryAddsUpLikeActivityMonitor() {
    let pages = VMPages(anonymous: 1000, purgeable: 100, wired: 300, compressor: 200, fileBacked: 400, free: 50, pageSize: 16384)
    let m = Memory(pages: pages, total: 4 * 1024 * 16384, pressure: .warning, swapUsed: 7, swapTotal: 9)
    #expect(m.app == 900 * 16384)
    #expect(m.used == (900 + 300 + 200) * 16384)
    #expect(m.cached == 500 * 16384)
    #expect(m.free == 50 * 16384)
    #expect(m.swapUsed == 7 && m.swapTotal == 9)
    #expect(m.usedFraction == 1400.0 / 4096)
}

@Test func memoryAppNeverGoesNegative() {
    let pages = VMPages(anonymous: 10, purgeable: 20, wired: 0, compressor: 0, fileBacked: 0, free: 0, pageSize: 4096)
    #expect(Memory(pages: pages, total: 0, pressure: .normal, swapUsed: 0, swapTotal: 0).app == 0)
    #expect(Memory(pages: pages, total: 0, pressure: .normal, swapUsed: 0, swapTotal: 0).usedFraction == 0)
}

@Test func pressureLevels() {
    #expect(Pressure(level: 1) == .normal)
    #expect(Pressure(level: 2) == .warning)
    #expect(Pressure(level: 4) == .critical)
    #expect(Pressure(level: 0) == .unknown)
}

@Test func appNameIsTheOutermostApp() {
    #expect(appName(path: "/Applications/Slack.app/Contents/MacOS/Slack") == "Slack")
    #expect(appName(path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)") == "Google Chrome")
    #expect(appName(path: "/usr/bin/ssh") == "ssh")
    #expect(appName(path: "/Users/me/bin/my.app") == "my.app")  // a file named .app, not a bundle
}

@Test func appUsageAddsProcessesAndMeasuresCPUSinceTheLastReading() throws {
    let before = [
        ProcessSample(pid: 1, start: 10, app: "Slack", memory: 100, cpuTime: 1_000),
        ProcessSample(pid: 2, start: 10, app: "Slack", memory: 50, cpuTime: 5_000),
        ProcessSample(pid: 3, start: 10, app: "zsh", memory: 10, cpuTime: 0),
    ]
    let now = [
        ProcessSample(pid: 1, start: 10, app: "Slack", memory: 120, cpuTime: 1_500),
        ProcessSample(pid: 2, start: 10, app: "Slack", memory: 60, cpuTime: 6_000),
        // pid 3 was reused by a new process: all its CPU time is new.
        ProcessSample(pid: 3, start: 99, app: "zsh", memory: 10, cpuTime: 250),
    ]
    let apps = appUsage(now, previous: before, elapsed: 1_000)
    let slack = try #require(apps.first { $0.name == "Slack" })
    #expect(slack.processes == 2)
    #expect(slack.memory == 180)
    #expect(slack.cpu == 1.5)
    #expect(try #require(apps.first { $0.name == "zsh" }).cpu == 0.25)
}

@Test func appUsageHasNoCPUOnTheFirstReading() {
    let apps = appUsage([ProcessSample(pid: 1, start: 1, app: "a", memory: 1, cpuTime: 9_999)], previous: nil, elapsed: 0)
    #expect(apps.map(\.cpu) == [0])
}

@Test func topSortsByValueThenName() {
    let apps = [
        AppUsage(name: "b", processes: 1, memory: 5, cpu: 0),
        AppUsage(name: "a", processes: 1, memory: 5, cpu: 0),
        AppUsage(name: "c", processes: 1, memory: 9, cpu: 0),
    ]
    #expect(top(apps, by: { Double($0.memory) }, count: 2).map(\.name) == ["c", "a"])
}

@Test func formatsBytesLikeMedic() {
    #expect(formatBytes(512, decimal: false) == "512 B")
    #expect(formatBytes(1536, decimal: false) == "2 KB")
    #expect(formatBytes(16 * 1024 * 1024 * 1024, decimal: false) == "16.0 GB")
    #expect(formatBytes(494_384_795_648, decimal: true) == "494.4 GB")
    #expect(formatBytes(999, decimal: true) == "1 KB")
    #expect(formatBytes(-5, decimal: true) == "0 KB")
}

@Test func barTextKeepsItsWidth() {
    let pages = VMPages(anonymous: 64, purgeable: 0, wired: 0, compressor: 0, fileBacked: 0, free: 0, pageSize: 1)
    let m = Memory(pages: pages, total: 100, pressure: .normal, swapUsed: 0, swapTotal: 0)
    let figure = "\u{2007}"
    #expect(barText(style: .cpuAndMemory, cpu: CPUUsage(user: 0.05, system: 0), memory: m) == "CPU \(figure)5%  RAM 64%")
    #expect(barText(style: .cpu, cpu: CPUUsage(user: 1, system: 0), memory: m) == "CPU 100%")
    #expect(barText(style: .cpu, cpu: nil, memory: m) == "CPU \(figure)\(figure)–")
    #expect(barText(style: .memory, cpu: nil, memory: m) == "RAM 64%")
    #expect(barText(style: .cpuAndMemory, cpu: nil, memory: m).count == barText(style: .cpuAndMemory, cpu: CPUUsage(user: 0.42, system: 0), memory: m).count)
}
