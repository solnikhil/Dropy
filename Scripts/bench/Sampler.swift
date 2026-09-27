// Samples per-process CPU, memory and wakeups plus system GPU utilization once per
// second, then prints one summary line per target. Built and run by benchmark.sh.
//
//   Sampler <seconds> <label>=<pid> [<label>=<pid> ...]
//
// proc_pid_rusage works for the caller's own processes. Other users' processes,
// such as WindowServer, fall back to `ps` CPU time and RSS, and report no wakeups;
// `sudo powermetrics --samplers tasks` is the way to measure those.
import Darwin
import Foundation
import IOKit

struct Reading {
    var cpuNanoseconds: Double
    var memoryBytes: Double
    var idleWakeups: Double?
    var interruptWakeups: Double?
}

func rusageReading(_ pid: pid_t) -> Reading? {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
        }
    }
    guard result == 0 else { return nil }
    // proc_pid_rusage reports nanoseconds, unlike mach_absolute_time ticks.
    let nanoseconds = Double(info.ri_user_time) + Double(info.ri_system_time)
    return Reading(cpuNanoseconds: nanoseconds,
                   memoryBytes: Double(info.ri_phys_footprint),
                   idleWakeups: Double(info.ri_pkg_idle_wkups),
                   interruptWakeups: Double(info.ri_interrupt_wkups))
}

func psReading(_ pid: pid_t) -> Reading? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "time=,rss=", "-p", String(pid)]
    let pipe = Pipe()
    process.standardOutput = pipe
    guard (try? process.run()) != nil else { return nil }
    process.waitUntilExit()
    let fields = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(whereSeparator: \.isWhitespace)
    guard fields.count == 2, let rss = Double(fields[1]) else { return nil }
    // time is [[hh:]mm:]ss.cc
    let seconds = fields[0].split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
    return Reading(cpuNanoseconds: seconds * 1e9, memoryBytes: rss * 1024,
                   idleWakeups: nil, interruptWakeups: nil)
}

func reading(_ pid: pid_t) -> Reading? { rusageReading(pid) ?? psReading(pid) }

func gpuUtilization() -> Double? {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"),
                                       &iterator) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iterator) }
    var values: [Double] = []
    while case let service = IOIteratorNext(iterator), service != 0 {
        defer { IOObjectRelease(service) }
        if let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                                       kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any],
           let utilization = stats["Device Utilization %"] as? NSNumber {
            values.append(utilization.doubleValue)
        }
    }
    return values.max()
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1))]
}

let arguments = CommandLine.arguments.dropFirst()
guard let seconds = arguments.first.flatMap(Int.init), seconds > 0 else {
    FileHandle.standardError.write(Data("usage: Sampler <seconds> <label>=<pid> ...\n".utf8))
    exit(2)
}
let targets: [(label: String, pid: pid_t)] = arguments.dropFirst().compactMap { spec in
    let parts = spec.split(separator: "=")
    guard parts.count == 2, let pid = pid_t(parts[1]) else { return nil }
    return (String(parts[0]), pid)
}

var previous = targets.map { reading($0.pid) }
var previousTime = Date()
var cpu = Array(repeating: [Double](), count: targets.count)
var memory = Array(repeating: [Double](), count: targets.count)
var idle = Array(repeating: [Double](), count: targets.count)
var interrupts = Array(repeating: [Double](), count: targets.count)
var gpu: [Double] = []

for _ in 0..<seconds {
    Thread.sleep(forTimeInterval: 1)
    let now = Date()
    let elapsed = now.timeIntervalSince(previousTime)
    previousTime = now
    if let value = gpuUtilization() { gpu.append(value) }
    for (index, target) in targets.enumerated() {
        guard let current = reading(target.pid) else { continue }
        if let last = previous[index] {
            cpu[index].append((current.cpuNanoseconds - last.cpuNanoseconds) / (elapsed * 1e9) * 100)
            if let now = current.idleWakeups, let before = last.idleWakeups {
                idle[index].append((now - before) / elapsed)
            }
            if let now = current.interruptWakeups, let before = last.interruptWakeups {
                interrupts[index].append((now - before) / elapsed)
            }
        }
        memory[index].append(current.memoryBytes)
        previous[index] = current
    }
}

func mean(_ values: [Double]) -> Double { values.isEmpty ? .nan : values.reduce(0, +) / Double(values.count) }
func fmt(_ value: Double) -> String { value.isNaN ? "-" : String(format: "%.1f", value) }

for (index, target) in targets.enumerated() {
    print("\(target.label): cpuMean=\(fmt(mean(cpu[index])))% cpuP95=\(fmt(percentile(cpu[index], 0.95)))%"
        + " memMax=\(fmt((memory[index].max() ?? .nan) / 1_048_576))MB"
        + " idleWakeups=\(fmt(mean(idle[index])))/s interruptWakeups=\(fmt(mean(interrupts[index])))/s"
        + " samples=\(cpu[index].count)")
}
print("gpu: utilMean=\(fmt(mean(gpu)))% utilP95=\(fmt(percentile(gpu, 0.95)))% samples=\(gpu.count)")
