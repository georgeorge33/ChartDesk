import AppKit
import Combine
import Darwin
import Foundation
import IOKit

/// Samples what Chartdesk is costing the machine, for the Performance window.
///
/// CPU and memory are read for this process through Mach. GPU utilisation is read from IOKit's
/// accelerator statistics, which report the **whole system** rather than this process — macOS
/// exposes no public per-process GPU figure, so the window labels it accordingly.
final class PerformanceMonitor: ObservableObject {

    struct Sample {
        var cpuPercent: Double = 0
        var threadCount: Int = 0
        var footprintBytes: UInt64 = 0
        var gpuPercent: Double?
        var gpuName: String?
        var uptime: TimeInterval = 0

        // Chart-specific counters, which are the numbers that actually explain a stall.
        var cacheCount: Int = 0
        var cacheLimit: Int = 0
        var cacheHits: Int = 0
        var cacheMisses: Int = 0
        var lastDecodeSeconds: Double?
        var slowestDecodeSeconds: Double?
        var chartCount: Int = 0
        var airportCount: Int = 0
    }

    @Published private(set) var sample = Sample()
    @Published private(set) var isRunning = false

    /// Peak footprint over the window's lifetime, since the instantaneous figure jumps around.
    @Published private(set) var peakFootprintBytes: UInt64 = 0
    @Published private(set) var peakCPUPercent: Double = 0

    private var timer: Timer?
    private let launchDate = Date()
    private weak var library: ChartLibrary?

    private static let interval: TimeInterval = 1.0

    func start(library: ChartLibrary?) {
        self.library = library
        guard timer == nil else { return }

        isRunning = true
        refresh()

        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // The common mode keeps it ticking while a menu is open or the canvas is being dragged.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    func resetPeaks() {
        peakFootprintBytes = sample.footprintBytes
        peakCPUPercent = sample.cpuPercent
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Sampling

    private func refresh() {
        var next = Sample()

        let cpu = Self.cpuUsage()
        next.cpuPercent = cpu.percent
        next.threadCount = cpu.threads
        next.footprintBytes = Self.memoryFootprint()
        next.uptime = Date().timeIntervalSince(launchDate)

        if let gpu = Self.gpuUtilisation() {
            next.gpuPercent = gpu.percent
            next.gpuName = gpu.name
        }

        let stats = ChartImageStore.shared.statistics()
        next.cacheCount = stats.count
        next.cacheLimit = stats.limit
        next.cacheHits = stats.hits
        next.cacheMisses = stats.misses
        next.lastDecodeSeconds = stats.lastDecodeSeconds
        next.slowestDecodeSeconds = stats.slowestDecodeSeconds

        next.chartCount = library?.chartCount ?? 0
        next.airportCount = library?.airports.count ?? 0

        sample = next
        peakFootprintBytes = max(peakFootprintBytes, next.footprintBytes)
        peakCPUPercent = max(peakCPUPercent, next.cpuPercent)
    }

    // MARK: - CPU

    /// Sums the per-thread CPU usage Mach already tracks, which gives an instantaneous figure
    /// without having to diff samples. 100% means one core fully busy.
    private static func cpuUsage() -> (percent: Double, threads: Int) {
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)

        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threads = threadList else {
            return (0, 0)
        }

        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: threads)),
                          vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride))
        }

        var total = 0.0
        for index in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(THREAD_INFO_MAX)

            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }

            guard result == KERN_SUCCESS,
                  info.flags & TH_FLAGS_IDLE == 0 else { continue }

            total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
        }

        return (total, Int(threadCount))
    }

    // MARK: - Memory

    /// `phys_footprint` is the figure Activity Monitor shows in its Memory column.
    private static func memoryFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }

    // MARK: - GPU

    /// Reads IOKit's accelerator performance statistics. Key names differ between Apple silicon
    /// and Intel/AMD parts, so several are tried. This is a system-wide figure.
    private static func gpuUtilisation() -> (percent: Double, name: String)? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        let candidateKeys = [
            "Device Utilization %",
            "GPU Activity(%)",
            "Renderer Utilization %",
            "GPU Core Utilization"
        ]

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = unmanaged?.takeRetainedValue() as? [String: Any] else {
                continue
            }

            guard let statistics = properties["PerformanceStatistics"] as? [String: Any] else { continue }

            for key in candidateKeys {
                guard let raw = statistics[key] as? NSNumber else { continue }

                let name = (properties["IOClass"] as? String)
                    ?? (properties["CFBundleIdentifier"] as? String)
                    ?? "GPU"

                // "GPU Core Utilization" comes back scaled to ten-millionths on some parts.
                var percent = raw.doubleValue
                if key == "GPU Core Utilization" { percent /= 10_000_000.0 / 100.0 }

                return (min(max(percent, 0), 100), name)
            }
        }

        return nil
    }

    // MARK: - Formatting

    static func bytes(_ value: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: Int64(value))
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    static func milliseconds(_ seconds: Double) -> String {
        seconds < 1 ? String(format: "%.0f ms", seconds * 1000)
                    : String(format: "%.2f s", seconds)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds)
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        let secs = whole % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs)
                         : String(format: "%d:%02d", minutes, secs)
    }

    static var totalMemoryBytes: UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    static var coreCount: Int {
        ProcessInfo.processInfo.processorCount
    }
}
