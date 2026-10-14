import Darwin

/// Reads the system's counters. Each call is a few system calls, no
/// subprocesses, so it is cheap enough to run every second.
public final class System {
    private let host = mach_host_self()
    private let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    // A process keeps its executable, so its app is looked up only once.
    private var appNames: [ProcessSample.ID: String] = [:]

    public init() {}

    deinit { mach_port_deallocate(mach_task_self_, host) }

    public func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks  // indexed by CPU_STATE_USER, SYSTEM, IDLE, NICE
        return CPUTicks(user: UInt64(t.0), system: UInt64(t.1), idle: UInt64(t.2), nice: UInt64(t.3))
    }

    public func memory() -> Memory? {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pages = VMPages(
            anonymous: UInt64(vm.internal_page_count),
            purgeable: UInt64(vm.purgeable_count),
            wired: UInt64(vm.wire_count),
            compressor: UInt64(vm.compressor_page_count),
            fileBacked: UInt64(vm.external_page_count),
            free: UInt64(vm.free_count) - min(UInt64(vm.free_count), UInt64(vm.speculative_count)),
            pageSize: UInt64(vm_kernel_page_size))
        let total: UInt64 = sysctl("hw.memsize") ?? 0
        let level: Int32 = sysctl("kern.memorystatus_vm_pressure_level") ?? 0
        let swap: xsw_usage = sysctl("vm.swapusage") ?? xsw_usage()
        return Memory(pages: pages, total: total, pressure: Pressure(level: level), swapUsed: swap.xsu_used, swapTotal: swap.xsu_total)
    }

    /// The startup disk. Its APFS volumes share one container, so "free" is
    /// the container's free space, as in `medic disk`.
    public func disk() -> Disk? {
        var fs = statfs()
        guard statfs("/", &fs) == 0 else { return nil }
        let block = Int64(fs.f_bsize)
        return Disk(total: Int64(fs.f_blocks) * block, free: Int64(fs.f_bavail) * block)
    }

    /// The processes this user may read: their own. System processes need
    /// root and are left out.
    public func processes() -> [ProcessSample] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let n = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.stride)))
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        var samples: [ProcessSample] = []
        samples.reserveCapacity(max(n, 0))
        var names: [ProcessSample.ID: String] = [:]
        for pid in pids.prefix(max(n, 0)) where pid > 0 {
            var info = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard ok == 0 else { continue }
            let id = ProcessSample.ID(pid: pid, start: info.ri_proc_start_abstime)
            guard let app = appNames[id] ?? (proc_pidpath(pid, &path, UInt32(path.count)) > 0 ? appName(path: String(cString: path)) : nil) else { continue }
            names[id] = app
            samples.append(ProcessSample(
                pid: pid,
                start: id.start,
                app: app,
                memory: Int64(info.ri_phys_footprint),
                cpuTime: nanoseconds(info.ri_user_time + info.ri_system_time)))
        }
        appNames = names  // forget processes that ended
        return samples
    }

    /// Monotonic clock in nanoseconds.
    public func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    // rusage CPU times are in mach time units, which are not nanoseconds on Apple silicon.
    private func nanoseconds(_ machTime: UInt64) -> UInt64 {
        UInt64(Double(machTime) * Double(timebase.numer) / Double(max(timebase.denom, 1)))
    }

    private func sysctl<T>(_ name: String) -> T? {
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        var size = MemoryLayout<T>.size
        guard sysctlbyname(name, value, &size, nil, 0) == 0, size == MemoryLayout<T>.size else { return nil }
        return value.pointee
    }
}
