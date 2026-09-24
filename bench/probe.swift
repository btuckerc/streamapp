// Resource sampler for bench/run.py. Emits one JSON object per line on stdout.
//
//   probe [--root PID ...] [--interval 0.5]   samples until SIGTERM/SIGINT (no root: machine-wide only)
//   probe --once [--root PID ...]             one sample, then exit
//
// Everything is cumulative so the caller differences two samples for any window:
// - procs: the root processes, their descendants and processes whose *responsible* process is in
//   that set (for example the VTEncoderXPCService instance VideoToolbox spawns per client).
//   Kernel rusage v6: CPU time, instructions, cycles, CPU energy estimate, footprint, wakeups, disk.
// - gpu_ns: per-process GPU time from the AGX driver's per-client AppUsage.
// - host_ticks: machine-wide CPU ticks (user, system, idle, nice), 100 per second per core.
// - energy_nj: machine-wide IOReport "Energy Model" channels that report nonzero values without root
//   (on this Mac only "GPU Energy"); summed since the probe started.
// - windowserver_gpu_ns: compositor GPU time, which both apps' screen capture drives.
import Foundation
import IOKit

var roots: [pid_t] = []
var interval = 0.5
var once = false
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--root": guard let v = arguments.next(), let pid = pid_t(v) else { fatal("--root needs a pid") }; roots.append(pid)
    case "--interval": guard let v = arguments.next(), let s = Double(v), s >= 0.05 else { fatal("--interval needs seconds >= 0.05") }; interval = s
    case "--once": once = true
    default: fatal("unknown argument \(argument)")
    }
}

func fatal(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); exit(2) }

var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
func ns(_ ticks: UInt64) -> UInt64 { ticks * UInt64(timebase.numer) / UInt64(timebase.denom) }

typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
let responsible: ResponsibleFn? = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid").map { unsafeBitCast($0, to: ResponsibleFn.self) }

struct Info { let pid: pid_t; let ppid: pid_t; let name: String }
func allProcesses() -> [Info] {
    let capacity = Int(proc_listallpids(nil, 0)) + 64
    var pids = [pid_t](repeating: 0, count: capacity)
    let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
    var result: [Info] = []; result.reserveCapacity(count)
    var bsd = proc_bsdinfo()
    for pid in pids.prefix(count) where pid > 0 {
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { continue }
        let name = withUnsafeBytes(of: bsd.pbi_name) { raw in String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self) }
        result.append(Info(pid: pid, ppid: pid_t(bsd.pbi_ppid), name: name.isEmpty ? withUnsafeBytes(of: bsd.pbi_comm) { raw in String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self) } : name))
    }
    return result
}

func tracked(_ processes: [Info]) -> [Info] {
    var chosen = Set(roots)
    var grew = true
    while grew {
        grew = false
        for p in processes where !chosen.contains(p.pid) {
            if chosen.contains(p.ppid) || (responsible.map { chosen.contains($0(p.pid)) } ?? false) { chosen.insert(p.pid); grew = true }
        }
    }
    return processes.filter { chosen.contains($0.pid) }
}

func usage(_ info: Info, gpu: [pid_t: UInt64]) -> [String: Any]? {
    var u = rusage_info_v6()
    let status = withUnsafeMutablePointer(to: &u) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(info.pid, RUSAGE_INFO_V6, $0) } }
    guard status == 0 else { return nil }
    return ["pid": info.pid, "ppid": info.ppid, "name": info.name, "responsible": responsible?(info.pid) ?? -1,
            "user_ns": ns(u.ri_user_time), "system_ns": ns(u.ri_system_time),
            "instructions": u.ri_instructions, "cycles": u.ri_cycles, "energy_nj": u.ri_energy_nj,
            "footprint": u.ri_phys_footprint, "lifetime_max_footprint": u.ri_lifetime_max_phys_footprint,
            "idle_wakeups": u.ri_pkg_idle_wkups, "interrupt_wakeups": u.ri_interrupt_wkups,
            "disk_read": u.ri_diskio_bytesread, "disk_written": u.ri_diskio_byteswritten,
            "gpu_ns": gpu[info.pid] ?? 0]
}

// Per-process GPU time: every AGX user client names its creator ("pid 408, WindowServer"), which
// also identifies WindowServer even though its rusage is not readable without root.
func gpuTimes() -> (byPID: [pid_t: UInt64], windowServer: UInt64) {
    var result: [pid_t: UInt64] = [:]
    var windowServer: UInt64 = 0
    var services: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &services) == KERN_SUCCESS else { return (result, 0) }
    defer { IOObjectRelease(services) }
    var service = IOIteratorNext(services)
    while service != 0 {
        var clients: io_iterator_t = 0
        if IORegistryEntryGetChildIterator(service, kIOServicePlane, &clients) == KERN_SUCCESS {
            var client = IOIteratorNext(clients)
            while client != 0 {
                if let creator = IORegistryEntryCreateCFProperty(client, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                   creator.hasPrefix("pid "), let pid = pid_t(creator.dropFirst(4).prefix(while: { $0 != "," })),
                   let usage = IORegistryEntryCreateCFProperty(client, "AppUsage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [[String: Any]] {
                    let time = usage.reduce(UInt64(0)) { $0 + ((($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value) ?? 0) }
                    result[pid, default: 0] += time
                    if creator.hasSuffix(", WindowServer") { windowServer += time }
                }
                IOObjectRelease(client); client = IOIteratorNext(clients)
            }
            IOObjectRelease(clients)
        }
        IOObjectRelease(service); service = IOIteratorNext(services)
    }
    return (result, windowServer)
}

func hostTicks() -> [UInt64] {
    var load = host_cpu_load_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
    let status = withUnsafeMutablePointer(to: &load) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) } }
    guard status == KERN_SUCCESS else { return [] }
    return [UInt64(load.cpu_ticks.0), UInt64(load.cpu_ticks.1), UInt64(load.cpu_ticks.2), UInt64(load.cpu_ticks.3)]
}

// IOReport (private, loaded from the dyld cache). Only channels with a nonzero value are reported.
final class EnergyReport {
    typealias CopyGroup = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    typealias CreateSubscription = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> OpaquePointer?
    typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias Delta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    typealias Text = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    typealias Integer = @convention(c) (CFDictionary, Int32) -> Int64
    let createSamples: CreateSamples, delta: Delta, name: Text, unit: Text, value: Integer
    let subscription: OpaquePointer, channels: CFMutableDictionary
    var previous: CFDictionary
    var totals: [String: Double] = [:]

    init?() {
        guard let lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func sym<T>(_ n: String, _: T.Type) -> T? { dlsym(lib, n).map { unsafeBitCast($0, to: T.self) } }
        guard let copy = sym("IOReportCopyChannelsInGroup", CopyGroup.self), let subscribe = sym("IOReportCreateSubscription", CreateSubscription.self),
              let samples = sym("IOReportCreateSamples", CreateSamples.self), let delta = sym("IOReportCreateSamplesDelta", Delta.self),
              let name = sym("IOReportChannelGetChannelName", Text.self), let unit = sym("IOReportChannelGetUnitLabel", Text.self),
              let value = sym("IOReportSimpleGetIntegerValue", Integer.self),
              let desired = copy("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { return nil }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = subscribe(nil, desired, &subscribed, 0, nil), let channels = subscribed?.takeRetainedValue(),
              let first = samples(subscription, channels, nil)?.takeRetainedValue() else { return nil }
        (createSamples, self.delta, self.name, self.unit, self.value) = (samples, delta, name, unit, value)
        (self.subscription, self.channels, previous) = (subscription, channels, first)
    }

    func sample() -> [String: Double] {
        guard let current = createSamples(subscription, channels, nil)?.takeRetainedValue(),
              let change = delta(previous, current, nil)?.takeRetainedValue() as NSDictionary? else { return totals }
        previous = current
        for channel in change["IOReportChannels"] as? [NSDictionary] ?? [] {
            let v = value(channel, 0)
            guard v != 0, let n = name(channel)?.takeUnretainedValue() as String? else { continue }
            let scale: Double = switch unit(channel)?.takeUnretainedValue() as String? ?? "" { case "mJ": 1e6; case "uJ": 1e3; case "nJ": 1; default: 0 }
            if scale > 0 { totals[n, default: 0] += Double(v) * scale }
        }
        return totals
    }
}

let energy = EnergyReport()
// (WindowServer is identified by its GPU client name; see gpuTimes.)
let output = FileHandle.standardOutput

func emit() {
    let processes = allProcesses()
    let gpu = gpuTimes()
    let sample: [String: Any] = [
        "t_ns": clock_gettime_nsec_np(CLOCK_UPTIME_RAW),
        "host_ticks": hostTicks(),
        "energy_nj": energy?.sample() ?? [:],
        "windowserver_gpu_ns": gpu.windowServer,
        "procs": tracked(processes).compactMap { usage($0, gpu: gpu.byPID) },
    ]
    output.write(try! JSONSerialization.data(withJSONObject: sample)); output.write(Data([0x0A]))
}

if once { emit(); exit(0) }
for signalNumber in [SIGTERM, SIGINT] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler { emit(); exit(0) }  // final sample closes the last window exactly
    source.resume()
    _ = Unmanaged.passRetained(source)
}
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(5))
timer.setEventHandler(handler: emit)
timer.resume()
dispatchMain()
