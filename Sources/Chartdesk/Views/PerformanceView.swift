import SwiftUI

struct PerformanceView: View {

    @EnvironmentObject private var library: ChartLibrary
    @StateObject private var monitor = PerformanceMonitor()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("This Process") {
                    meter("CPU",
                          value: monitor.sample.cpuPercent,
                          // One core fully busy reads as 100%, so the bar is scaled to all cores.
                          of: Double(PerformanceMonitor.coreCount) * 100,
                          text: PerformanceMonitor.percent(monitor.sample.cpuPercent))
                    row("Peak CPU", PerformanceMonitor.percent(monitor.peakCPUPercent))
                    row("Threads", "\(monitor.sample.threadCount)")

                    meter("Memory",
                          value: Double(monitor.sample.footprintBytes),
                          of: Double(PerformanceMonitor.totalMemoryBytes),
                          text: PerformanceMonitor.bytes(monitor.sample.footprintBytes))
                    row("Peak memory", PerformanceMonitor.bytes(monitor.peakFootprintBytes))
                    row("Running for", PerformanceMonitor.duration(monitor.sample.uptime))
                }

                section("System") {
                    if let gpu = monitor.sample.gpuPercent {
                        meter("GPU", value: gpu, of: 100, text: PerformanceMonitor.percent(gpu))
                        Text("GPU use is reported for the whole system. macOS exposes no per-process figure.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let name = monitor.sample.gpuName {
                            row("Device", name)
                        }
                    } else {
                        row("GPU", "Not reported on this Mac")
                    }
                    row("CPU cores", "\(PerformanceMonitor.coreCount)")
                    row("Installed memory", PerformanceMonitor.bytes(PerformanceMonitor.totalMemoryBytes))
                }

                section("Charts") {
                    row("Image cache", "\(monitor.sample.cacheCount) of \(monitor.sample.cacheLimit)")
                    row("Cache hits", hitRateText)
                    row("Last decode", monitor.sample.lastDecodeSeconds
                        .map(PerformanceMonitor.milliseconds) ?? "—")
                    row("Slowest decode", monitor.sample.slowestDecodeSeconds
                        .map(PerformanceMonitor.milliseconds) ?? "—")
                    row("Library", "\(monitor.sample.chartCount) charts · \(monitor.sample.airportCount) airports")
                }

                HStack(spacing: 10) {
                    Button("Reset Peaks") {
                        monitor.resetPeaks()
                        ChartImageStore.shared.resetStatistics()
                    }
                    Button("Empty Image Cache") {
                        ChartImageStore.shared.clearCache()
                    }
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.ngWindow)
        .frame(minWidth: 360, minHeight: 480)
        .navigationTitle("Performance")
        // Sampling only runs while the window is open, so the tracker does not itself cost
        // anything when it is closed.
        .onAppear { monitor.start(library: library) }
        .onDisappear { monitor.stop() }
    }

    private var hitRateText: String {
        let hits = monitor.sample.cacheHits
        let total = hits + monitor.sample.cacheMisses
        guard total > 0 else { return "—" }
        return "\(hits) of \(total) (\(Int((Double(hits) / Double(total)) * 100))%)"
    }

    // MARK: - Pieces

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 7) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.ngPanel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }

    private func meter(_ label: String, value: Double, of total: Double, text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            row(label, text)
            GeometryReader { geometry in
                let fraction = total > 0 ? min(max(value / total, 0), 1) : 0
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.ngSeparator)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.ngAccentText)
                        .frame(width: max(geometry.size.width * fraction, fraction > 0 ? 3 : 0))
                }
            }
            .frame(height: 6)
        }
    }
}
