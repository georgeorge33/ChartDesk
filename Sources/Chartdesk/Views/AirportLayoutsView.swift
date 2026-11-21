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
    @EnvironmentObject private var library: ChartLibrary
    @EnvironmentObject private var flights: FlightPlanStore

    @State private var airports: [AirportLayoutSummary] = []
    @State private var reading = true
    @State private var filter = ""
    @State private var confirmingDelete = false

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
                         + "or all at once with Fetch Your Airports.")
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
                    // Ten columns at most: that is all a table's builder takes, so where each
                    // layout came from goes beside the airport's name rather than in a column.
                    TableColumn("Airport") { row in airportName(row) }.width(min: 220)
                    TableColumn("Taxiways") { row in figure(row.taxiways) }.width(68)
                    TableColumn("Runways") { row in figure(row.runways) }.width(62)
                    TableColumn("Stands") { row in figure(row.stands) }.width(56)
                    TableColumn("Holds") { row in figure(row.holds) }.width(52)
                    // Drawn pavement rather than a centreline with a width tag: nearly always
                    // nothing from OpenStreetMap, which is worth being able to see.
                    TableColumn("Outlines") { row in sparse(row.outlines) }.width(64)
                    // Painted lines, which only X-Plane's airport files have.
                    TableColumn("Paint") { row in sparse(row.markings) }.width(56)
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
        .frame(minWidth: 820, minHeight: 420)
        .navigationTitle("Airport Layouts")
        .onAppear(perform: read)
        // A layout that arrives while the window is open belongs in the list.
        .onChange(of: ground.layouts.count) { read() }
        // And everything a fetch of your airports brought, once it has finished: reading the
        // list after every airport of it would be reading the whole cache a hundred times.
        .onChange(of: ground.bulk?.isRunning ?? false) { _, running in
            if !running { read() }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                    .font(.ngSmallMedium)
                Text("From the X-Plane Scenery Gateway, or OpenStreetMap where the Gateway "
                     + "has nothing; one airport at a time, and kept once fetched.")
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
            if let bulk = ground.bulk, bulk.isRunning {
                Button("Stop Fetching (\(bulk.done) of \(bulk.total))") {
                    ground.stopFetchingLayouts()
                }
            } else {
                Button("Fetch Your Airports") { ground.fetchLayouts(for: yourAirports) }
                    .disabled(yourAirports.isEmpty)
                    .help("Every airport you have charts for, and your flight's, from the "
                          + "X-Plane Gateway")
            }
            Button("Delete All…", role: .destructive) { confirmingDelete = true }
                .disabled(airports.isEmpty)
                .help("Throw away every layout on this Mac")
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // Hours of asking a shared service went into these, so the button says what it is
        // about to cost before it does it rather than after.
        .confirmationDialog("Delete every airport layout?",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete \(airports.count) Layouts", role: .destructive) {
                AirportLayoutStore.shared.deleteAll()
                read()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("\(airports.count) layouts and \(Self.bytes(totalBytes)) go from this Mac, "
                 + "and the map stops drawing their taxiways. They are fetched again one at "
                 + "a time as you zoom in on a field: a second or two each from the X-Plane "
                 + "Gateway, and a minute or two each from OpenStreetMap — those took hours "
                 + "to collect.")
        }
    }

    private var totalBytes: Int { airports.reduce(0) { $0 + $1.bytes } }

    /// Every airport there are charts for, and the flight's own.
    private var yourAirports: [String] {
        library.airports.map(\.code).filter { $0 != Airport.unsortedCode }
            + (flights.plan?.airfields ?? []).map(\.icao)
    }

    private var summary: String {
        guard !airports.isEmpty else { return "Airport layouts" }
        let taxiways = airports.reduce(0) { $0 + $1.taxiways }
        let held = airports.filter(\.loaded).count
        let xplane = airports.filter { $0.source == "X-Plane" }.count
        return "\(airports.count) layouts (\(xplane) from X-Plane) · \(taxiways) taxiways · "
            + "\(Self.bytes(totalBytes)) · \(held) held by the map"
    }

    /// The airport's name, and whose copy of its layout this is.
    private func airportName(_ row: AirportLayoutSummary) -> some View {
        HStack(spacing: 6) {
            Text(row.name.isEmpty ? "—" : row.name)
                .foregroundStyle(row.name.isEmpty ? .tertiary : .primary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(row.source)
                .font(.ngSmall)
                .foregroundStyle(.secondary)
        }
    }

    /// A count that is often nothing, shown as a dash when it is.
    private func sparse(_ value: Int) -> some View {
        Text(value == 0 ? "—" : "\(value)")
            .monospacedDigit()
            .foregroundStyle(value == 0 ? .tertiary : .primary)
            .frame(maxWidth: .infinity, alignment: .trailing)
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
