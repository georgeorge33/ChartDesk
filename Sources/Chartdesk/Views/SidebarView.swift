import AppKit
import SwiftUI

struct SidebarView: View {

    @EnvironmentObject private var library: ChartLibrary
    @EnvironmentObject private var browser: BrowserState
    @EnvironmentObject private var flight: FlightPlanStore
    @EnvironmentObject private var importer: ImportController

    private var trimmedQuery: String {
        browser.airportQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredAirports: [Airport] {
        guard !trimmedQuery.isEmpty else { return library.airports }
        // Folded once here rather than per airport.
        let query = SearchKey.fold(trimmedQuery)
        return library.airports.filter { $0.matches(foldedQuery: query) }
    }

    /// The airports this flight needs, straight from the SimBrief plan. A section rather than
    /// a folder on disk: Chartdesk never writes to your chart library, and copying files about
    /// would mean cleaning them up again every time the flight changed.
    @ViewBuilder
    private var flightSection: some View {
        Section {
            if let problem = flight.problem {
                Text(problem)
                    .font(.ngSmall)
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let plan = flight.plan {
                ForEach(plan.airfields) { field in
                    flightRow(field)
                }
            }
        } header: {
            HStack(spacing: 6) {
                Text(flight.plan?.title ?? "Flight")
                    .lineLimit(1)
                if let subtitle = flight.plan?.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)

                // Next to the section it removes, rather than only in Settings: this is where
                // you are when you decide you are done with a flight.
                Button {
                    flight.clear()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear this flight and remove the section")

                if flight.isFetching {
                    ProgressView().progressViewStyle(.circular).controlSize(.mini)
                } else {
                    Button {
                        flight.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.ngAccentText)
                    .help("Fetch the latest flight from SimBrief")
                }
            }
            // Eight points, measured: a section header sits on the list's own inset while the
            // footer is a plain row, so this button and the rescan below it were not in the
            // same column.
            .padding(.trailing, 8)
        }
    }

    /// Where the flight section was, once it has been cleared. Without this, getting a flight
    /// back means remembering that ⇧⌘B exists. Only shown when there is an account to fetch
    /// from, so it costs nothing to anyone who does not use SimBrief.
    private var loadFlightSection: some View {
        Section {
            Button {
                flight.refresh()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "airplane.departure")
                        .foregroundStyle(Color.ngAccentText)
                    Text(flight.isFetching ? "Loading Flight…" : "Load SimBrief Flight")
                    Spacer(minLength: 0)
                    if flight.isFetching {
                        ProgressView().progressViewStyle(.circular).controlSize(.mini)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(flight.isFetching)
            .help("Fetch your latest flight from SimBrief")
        }
    }

    /// Airports you don't have charts for are listed but not selectable. Finding that out on
    /// the ground is the point — it is the same check you would otherwise do from memory.
    @ViewBuilder
    private func flightRow(_ field: FlightPlan.Airfield) -> some View {
        if let airport = library.airport(code: field.icao) {
            // Only worth saying for an airport you actually hold charts for: one that is
            // missing entirely says so already, and both at once is just noise.
            let planned = field.runway ?? ""
            FlightAirportRow(field: field,
                             chartCount: airport.charts.count,
                             name: airport.name,
                             hasRunwayChart: library.hasChart(serving: planned, at: field.icao))
                .tag(SidebarItem.airport(field.icao))
        } else {
            FlightAirportRow(field: field, chartCount: nil, name: field.name)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            MacSearchField(text: $browser.airportQuery,
                           placeholder: "Search airports",
                           focusNotification: .focusAirportSearch,
                           onSubmit: selectFirstMatch)
                .frame(height: 24)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 6)

            List(selection: $browser.sidebarSelection) {
                if trimmedQuery.isEmpty {
                    if flight.plan != nil || flight.problem != nil {
                        flightSection
                    } else if flight.hasAccount {
                        loadFlightSection
                    }
                }

                Section {
                    if !library.pinnedCharts.isEmpty {
                        pinnedRow
                            .tag(SidebarItem.pinned)
                    }
                    mapRow
                        .tag(SidebarItem.map)
                }

                Section("Airports") {
                    ForEach(filteredAirports) { airport in
                        AirportRow(airport: airport)
                            .tag(SidebarItem.airport(airport.code))
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .overlay {
                if library.airports.isEmpty && !library.isScanning {
                    EmptyLibraryNotice()
                } else if filteredAirports.isEmpty && !trimmedQuery.isEmpty {
                    Text("No matching airports")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }

            Divider()
                .overlay(Color.ngSeparator)
            footer
            Divider()
                .overlay(Color.ngSeparator)
            versionBar
        }
        .frame(minWidth: 200)
        .background(Color.ngWindow)
    }

    // MARK: - Pieces

    /// The map is a place in the app rather than a window of its own: one selection, one
    /// window, and it keeps the flight's airports a click away in the same sidebar.
    private var mapRow: some View {
        HStack(spacing: 8) {
            Label("Route Map", systemImage: "map")
            Spacer(minLength: 4)
            if let count = flight.plan?.waypoints.count, count > 0 {
                Text("\(count)")
                    .font(.ngSmall)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .help(flight.plan == nil
              ? "The world, and the airports you hold charts for"
              : "The loaded flight drawn on the map")
    }

    private var pinnedRow: some View {
        HStack(spacing: 8) {
            Label("Pinned Charts", systemImage: "star.fill")
            Spacer(minLength: 4)
            Text("\(library.pinnedCharts.count)")
                .font(.ngSmall)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }

    /// The version this copy is, always on show.
    ///
    /// A candidate is called out in orange, which is what this row was first for: a pre-release
    /// that looks exactly like the real thing is how you end up reporting a bug from the wrong
    /// one. A final release says which one it is and otherwise keeps quiet.
    private var versionBar: some View {
        HStack(spacing: 8) {
            if Bundle.main.isCandidateBuild {
                Text(version)
                    .font(.ngSmallBold)
                    .monospacedDigit()
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.14), in: Capsule(style: .continuous))
                    .help("This is a release candidate, not a final release")
            } else {
                Text(version)
                    .font(.ngSmall)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help("Chartdesk \(version)")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var version: String { Bundle.main.appVersion }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
            Text(library.folderName)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(library.folderPath)
            Spacer(minLength: 0)

            // Flying a stale chart set is the kind of mistake you only notice afterwards, so
            // the age sits next to the folder rather than behind a menu.
            if library.chartsAreStale, let days = library.chartAgeInDays {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("\(days) days old")
                }
                .foregroundStyle(Color.orange)
                .help("The newest file in your chart library is \(days) days old. "
                      + "A LIDO cycle is 28 days, so this set is likely out of date.")
            }

            // Beside the rescan rather than only in the Chart menu: this is where you are
            // when you have just saved a plate and want it filed.
            Button {
                guard let root = library.rootURL else { return }
                importer.checkNow(libraryRoot: root) { library.rescan() }
            } label: {
                Image(systemName: "tray.and.arrow.down")
            }
            .buttonStyle(.borderless)
            .disabled(!library.hasLibrary)
            .help("Look in \(ChartImporter.downloadsFolder.lastPathComponent) for charts to file")

            if library.isScanning {
                ProgressView()
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else {
                Button {
                    library.rescan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Rescan the chart folder")
            }
        }
        .font(.ngSmall)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    /// Return in the search field. With the map open it shows the airport on the map and
    /// stays there — the first one listed if you have charts for it, and otherwise any
    /// airport the map knows. Anywhere else it opens the first one listed.
    private func selectFirstMatch() {
        if browser.sidebarSelection == .map {
            // Nothing typed is nothing to find, rather than the first airport in the library.
            guard !trimmedQuery.isEmpty else { return }
            let listed = filteredAirports.lazy.compactMap { WorldData.airport($0.code) }.first
            let exact = WorldData.airport(trimmedQuery)
            if let airport = exact ?? listed ?? WorldData.airport(searchingFor: trimmedQuery) {
                browser.showOnMap(airport)
            } else {
                NSSound.beep()
            }
            return
        }
        guard let first = filteredAirports.first else { return }
        browser.sidebarSelection = .airport(first.code)
    }
}

// MARK: - Rows

private struct AirportRow: View {
    let airport: Airport

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(airport.displayTitle)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)
                if let subtitle = airport.displaySubtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.ngSmall)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text("\(airport.charts.count)")
                .font(.ngSmall)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
    }
}

private struct EmptyLibraryNotice: View {
    @EnvironmentObject private var library: ChartLibrary

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("No charts found")
                .font(.callout)
            Text("Pick a folder that contains chart images.")
                .font(.ngSmall)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Choose Folder…") {
                library.chooseFolder()
            }
            .controlSize(.small)
        }
        .padding(20)
    }
}

// MARK: - Flight row

private struct FlightAirportRow: View {

    let field: FlightPlan.Airfield
    /// nil when the airport isn't in the library at all.
    let chartCount: Int?
    let name: String?
    /// Whether a plate covers the runway the flight plans. True when it plans none.
    var hasRunwayChart = true

    /// The runway this flight plans here, when there is one.
    private var planned: String? {
        let runway = field.runway ?? ""
        return runway.isEmpty ? nil : runway
    }

    private var isMissingChart: Bool { chartCount != nil && planned != nil && !hasRunwayChart }

    var body: some View {
        if chartCount == nil {
            // Nothing to select, so the row does the next most useful thing instead.
            Button(action: openInPlanner) { row }
                .buttonStyle(.plain)
                .onHover { inside in
                    inside ? NSCursor.pointingHand.push() : NSCursor.pop()
                }
                .help("\(field.icao) isn't in your library — open the MSFS flight planner")
        } else if isMissingChart, let planned = planned {
            row.help("No plate at \(field.icao) serves RWY \(planned). "
                     + "You have charts for this airport, but none for the planned runway.")
        } else {
            row.help(name ?? field.icao)
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            Text(field.role.badge)
                .font(.ngSmallBold)
                .frame(width: 36)
                .padding(.vertical, 2)
                .background(Color.ngAccent.opacity(chartCount == nil ? 0.25 : 1),
                            in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                .foregroundStyle(chartCount == nil ? Color.secondary : Color.white)

            VStack(alignment: .leading, spacing: 1) {
                Text(field.icao)
                    .font(.callout)
                    .foregroundStyle(chartCount == nil ? Color.secondary : Color.primary)
                if let detail = detail {
                    Text(detail)
                        .font(.ngSmall)
                        .foregroundStyle(chartCount == nil || isMissingChart
                                         ? Color.orange : Color.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if let count = chartCount {
                if isMissingChart {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.ngSmall)
                        .foregroundStyle(Color.orange)
                }
                Text("\(count)")
                    .font(.ngSmall)
                    .foregroundStyle(.tertiary)
            } else {
                Image(systemName: "arrow.up.forward.square")
                    .font(.ngSmall)
                    .foregroundStyle(Color.orange)
            }
        }
        .contentShape(Rectangle())
    }

    private var detail: String? {
        guard chartCount != nil else { return "not in your library" }
        if let planned = planned {
            return isMissingChart ? "RWY \(planned) — no chart" : "RWY \(planned)"
        }
        return name
    }

    private func openInPlanner() {
        guard let url = URL(string: "https://planner.flightsimulator.com") else { return }
        NSWorkspace.shared.open(url)
    }
}
