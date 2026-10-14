import Foundation
import Testing
@testable import MedicBarCore

// Reads this Mac and checks the numbers are sane, and agree with vm_stat.

@Test func readsThisMac() throws {
    let system = System()
    let memory = try #require(system.memory())
    #expect(memory.total == Int64(ProcessInfo.processInfo.physicalMemory))
    #expect(memory.used > 0 && memory.used <= memory.total)
    #expect(memory.pressure != .unknown)

    let disk = try #require(system.disk())
    #expect(disk.total > 0 && disk.free > 0 && disk.free < disk.total)

    let a = try #require(system.cpuTicks())
    var spin = 0.0
    for i in 0..<3_000_000 { spin += Double(i) }
    let b = try #require(system.cpuTicks())
    #expect(spin > 0)
    if let usage = CPUUsage(from: a, to: b) {
        #expect(usage.total >= 0 && usage.total <= 1)
    }
}

@Test func readsOwnProcessWithCPUTime() throws {
    let me = getpid()
    let p = try #require(System().processes().first { $0.id.pid == me })
    #expect(p.memory > 0)
    #expect(p.cpuTime > 0)
}

@Test func wiredMemoryMatchesVMStat() throws {
    let out = Process()
    out.executableURL = URL(fileURLWithPath: "/usr/bin/vm_stat")
    let pipe = Pipe()
    out.standardOutput = pipe
    try out.run()
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    out.waitUntilExit()
    let line = try #require(text.split(separator: "\n").first { $0.hasPrefix("Pages wired down:") })
    let header = try #require(text.components(separatedBy: "page size of ").last)
    let pageSize = try #require(Int64(header.prefix { $0.isNumber }))
    let pages = try #require(Int64(line.filter(\.isNumber)))
    let memory = try #require(System().memory())
    // Both read the same counter a moment apart; wired memory barely moves.
    #expect(abs(memory.wired - pages * pageSize) < memory.total / 50)
}
