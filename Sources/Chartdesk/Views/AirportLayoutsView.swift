import AppKit
import SwiftUI

/// What ground layouts are on this Mac.
///
/// A debugging window rather than a feature: the layouts arrive one at a time from a shared
/// service that is often busy, they are kept forever once they arrive, and until now the
/// only way to know which of them you had was to fly somewhere and see whether the taxiways
/// were drawn. This says so directly.
struct AirportLayoutsView: View {

    @ObservedObject private var ground = AirportLayoutStore.shared

    @State private var airports: [AirportLayoutSummary] = []
    @State private var reading = true
    @State private var filter = ""

    private var shown: [AirportLayoutSummary] {
        let wanted = filter.trimmingCharacters(in: .whitespaces).uppercased()
        guard !wanted.isEmpty else { return airports }
        return airports.filter {
            $0.icao.contains(wanted) || $0.name.uppercased().contains(wanted)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider().overlay(Color.ngSeparator)

            if reading {
                centred { ProgressView().controlSize(.small) }
            } else if airports.isEmpty {
                centred {
                    Text("No layouts on this Mac yet. They arrive as you zoom in on a field, "
                         + "or all at once from Tools/make_layouts.py.")
                        .font(.ngSmall)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
            } else {
                Table(shown) {
                    TableColumn("ICAO") { row in
                        HStack(spacing: 5) {
                            // A filled dot for one the map is holding, hollow for one that
                            // is only on the disk.
                            Image(systemName: row.loaded ? "circle.fill" : "circle")
                                .font(.system(size: 6))
                                .foregroundStyle(row.loaded ? AnyShapeStyle(Color.ngAccentText)
                                                            : AnyShapeStyle(.tertiary))
                            Text(row.icao).monospaced()
                        }
                        .help(row.loaded ? "Held by the map" : "On disk")
                    }
                    .width(78)
                    TableColumn("Airport") { row in
                        Text(row.name.isEmpty ? "—" : row.name)
                            .foregroundStyle(row.name.isEmpty ? .tertiary : .primary)
                    }
                    TableColumn("Taxiways") { row in figure(row.taxiways) }.width(68)
                    TableColumn("Runways") { row in figure(row.runways) }.width(62)
                    TableColumn("Stands") { row in figure(row.stands) }.width(56)
                    TableColumn("Holds") { row in figure(row.holds) }.width(52)
                    TableColumn("Outlines") { row in
                        // Drawn pavement rather than a centreline with a width tag. Nearly
                        // always nothing, which is worth being able to see.
                        Text(row.outlines == 0 ? "—" : "\(row.outlines)")
                            .monospacedDigit()
                            .foregroundStyle(row.outlines == 0 ? .tertiary : .primary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(64)
                    TableColumn("Size") { row in
                        Text(Self.bytes(row.bytes))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(66)
                    TableColumn("Fetched") { row in
                        Text(row.fetched, format: .dateTime.year().month(.abbreviated).day())
                            .foregroundStyle(.secondary)
                    }
                    .width(88)
                }
                .tableStyle(.inset)
            }
        }
        .background(Color.ngWindow)
        .frame(minWidth: 680, minHeight: 420)
        .navigationTitle("Airport Layouts")
        .onAppear(perform: read)
        // A layout that arrives while the window is open belongs in the list.
        .onChange(of: ground.layouts.count) { read() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                    .font(.ngSmallMedium)
                Text("From OpenStreetMap, one airport at a time, and kept once fetched.")
                    .font(.ngSmall)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
            Button("Reveal") {
                NSWorkspace.shared.activateFileViewerSelecting([AirportLayoutStore.directory])
            }
            .help("Show the cache folder in the Finder")
            Button("Reread", action: read)
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var summary: String {
        guard !airports.isEmpty else { return "Airport layouts" }
        let taxiways = airports.reduce(0) { $0 + $1.taxiways }
        let size = airports.reduce(0) { $0 + $1.bytes }
        let held = airports.filter(\.loaded).count
        return "\(airports.count) airports · \(taxiways) taxiways · \(Self.bytes(size))"
            + " · \(held) held by the map"
    }

    private func figure(_ value: Int) -> some View {
        Text("\(value)")
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func centred<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Reads and counts the lot off the main thread: it is a few milliseconds an airport,
    /// which is nothing for a window and too much for the one drawing the map.
    private func read() {
        let held = ground.held
        reading = airports.isEmpty
        Task.detached(priority: .userInitiated) {
            let found = AirportLayoutStore.inventory(loaded: held)
            await MainActor.run {
                airports = found
                reading = false
            }
        }
    }

    static func bytes(_ count: Int) -> String {
        count >= 1_048_576 ? String(format: "%.1f MB", Double(count) / 1_048_576)
                           : "\(max(count / 1024, 1)) KB"
    }
}
