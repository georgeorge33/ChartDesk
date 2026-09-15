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
                if trimmedQuery.isEmpty {
                    if flight.plan != nil || flight.problem != nil {
                        flightSection
                    } else if flight.hasAccount {
                        loadFlightSection
                    }
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
            Divider()
                .overlay(Color.ngSeparator)
            bottomBar
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

    /// The clock, and the version when this build is a release candidate: a pre-release that
    /// looks exactly like the real thing is how you end up reporting a bug from the wrong one.
    private var bottomBar: some View {
        HStack(spacing: 8) {
            ZuluClock()
            Spacer(minLength: 0)
            if let candidate = SidebarView.candidateVersion {
                Text(candidate)
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.14),
                                in: Capsule(style: .continuous))
                    .help("This is a release candidate, not a final release")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// The bundle version, but only when it carries a pre-release suffix.
    static var candidateVersion: String? {
        guard let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              version.contains("-") else { return nil }
        return version
    }

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

// MARK: - Zulu clock

/// The UTC clock in the bottom corner of the window.
///
/// Every clearance, METAR, TAF and OFP is in Zulu and the menu bar clock is not, so the
/// conversion is a small recurring cost worth removing. It sits on its own line rather than
/// sharing the folder row, which already gives up space to the stale-charts warning.
///
/// `TimelineView` rather than a `Timer`: SwiftUI stops asking for dates while the view is off
/// screen, so an occluded or minimised window costs nothing.
private struct ZuluClock: View {

    var body: some View {
        // Anchored to the current whole second, so it ticks on the second rather than whenever
        // the view happened to be built.
        let start = Date(timeIntervalSinceReferenceDate:
                            Date().timeIntervalSinceReferenceDate.rounded(.down))

        TimelineView(.periodic(from: start, by: 1)) { context in
            Text(ZuluClock.formatter.string(from: context.date))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .help("Current UTC time")
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        // A 24-hour aviation clock, not a localised time of day: the format is fixed whatever
        // the Mac's region is set to.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "HH:mm:ss 'Z'"
        return formatter
    }()
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
