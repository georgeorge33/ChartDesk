import AppKit
import SwiftUI

struct SidebarView: View {

    @EnvironmentObject private var library: ChartLibrary
    @EnvironmentObject private var browser: BrowserState
    @EnvironmentObject private var flight: FlightPlanStore

    private var trimmedQuery: String {
        browser.airportQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredAirports: [Airport] {
        guard !trimmedQuery.isEmpty else { return library.airports }
        return library.airports.filter { $0.searchText.localizedCaseInsensitiveContains(trimmedQuery) }
    }

    /// The airports this flight needs, straight from the SimBrief plan. A section rather than
    /// a folder on disk: Chartdesk never writes to your chart library, and copying files about
    /// would mean cleaning them up again every time the flight changed.
    @ViewBuilder
    private var flightSection: some View {
        Section {
            if let problem = flight.problem {
                Text(problem)
                    .font(.caption)
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
        }
    }

    /// Airports you don't have charts for are listed but not selectable. Finding that out on
    /// the ground is the point — it is the same check you would otherwise do from memory.
    @ViewBuilder
    private func flightRow(_ field: FlightPlan.Airfield) -> some View {
        if let airport = library.airport(code: field.icao) {
            FlightAirportRow(field: field, chartCount: airport.charts.count, name: airport.name)
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
                if trimmedQuery.isEmpty, flight.plan != nil || flight.problem != nil {
                    flightSection
                }

                if !library.pinnedCharts.isEmpty {
                    Section {
                        pinnedRow
                            .tag(SidebarItem.pinned)
                    }
                }

                if trimmedQuery.isEmpty, !library.recentAirports.isEmpty {
                    Section("Recent") {
                        ForEach(library.recentAirports) { airport in
                            AirportRow(airport: airport)
                                .tag(SidebarItem.airport(airport.code))
                        }
                    }
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
        }
        .frame(minWidth: 200)
        .background(Color.ngWindow)
    }

    // MARK: - Pieces

    private var pinnedRow: some View {
        HStack(spacing: 8) {
            Label("Pinned Charts", systemImage: "star.fill")
            Spacer(minLength: 4)
            Text("\(library.pinnedCharts.count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
            Text(library.folderName)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(library.folderPath)
            Spacer(minLength: 0)

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
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func selectFirstMatch() {
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text("\(airport.charts.count)")
                .font(.caption)
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
                .font(.caption)
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

    var body: some View {
        if chartCount == nil {
            // Nothing to select, so the row does the next most useful thing instead.
            Button(action: openInPlanner) { row }
                .buttonStyle(.plain)
                .onHover { inside in
                    inside ? NSCursor.pointingHand.push() : NSCursor.pop()
                }
                .help("\(field.icao) isn't in your library — open the MSFS flight planner")
        } else {
            row.help(name ?? field.icao)
        }
    }

    private var row: some View {
        HStack(spacing: 8) {
            Text(field.role.badge)
                .font(.system(size: 9, weight: .semibold))
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
                        .font(.caption2)
                        .foregroundStyle(chartCount == nil ? Color.orange : Color.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if let count = chartCount {
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Image(systemName: "arrow.up.forward.square")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
            }
        }
        .contentShape(Rectangle())
    }

    private var detail: String? {
        guard chartCount != nil else { return "not in your library" }
        if let runway = field.runway, !runway.isEmpty { return "RWY \(runway)" }
        return name
    }

    private func openInPlanner() {
        guard let url = URL(string: "https://planner.flightsimulator.com") else { return }
        NSWorkspace.shared.open(url)
    }
}
