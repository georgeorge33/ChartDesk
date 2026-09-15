import SwiftUI

private struct PinnedGroup: Identifiable {
    let id: String
    let charts: [Chart]
}

struct ChartListColumn: View {

    @EnvironmentObject private var library: ChartLibrary
    @EnvironmentObject private var browser: BrowserState
    @EnvironmentObject private var annotations: AnnotationStore
    @EnvironmentObject private var flight: FlightPlanStore
    @EnvironmentObject private var weather: WeatherStore

    private var selectedAirport: Airport? {
        library.airport(code: browser.sidebarSelection?.airportCode)
    }

    private var isPinnedList: Bool {
        browser.sidebarSelection == .pinned
    }

    private var baseCharts: [Chart] {
        if isPinnedList { return library.pinnedCharts }
        guard let airport = selectedAirport else { return [] }
        return prioritised(airport.chartList(in: browser.category))
    }

    /// The runway SimBrief planned here, if this airport is in the loaded flight.
    private var plannedRunway: String? {
        guard let code = selectedAirport?.code else { return nil }
        return flight.plannedRunway(at: code)
    }

    /// Floats the plates for the planned runway to the top, keeping the existing order within
    /// each group. Eleven approaches at a big field is a lot to read through when the flight
    /// plan already says which one you want.
    private func prioritised(_ list: [Chart]) -> [Chart] {
        guard let planned = plannedRunway else { return list }
        let matching = list.filter { $0.serves(runway: planned) }
        guard !matching.isEmpty, matching.count < list.count else { return list }
        return matching + list.filter { !$0.serves(runway: planned) }
    }

    private var charts: [Chart] {
        let query = browser.chartQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return baseCharts }
        return baseCharts.filter { $0.searchText.localizedCaseInsensitiveContains(query) }
    }

    private var pinnedGroups: [PinnedGroup] {
        var order: [String] = []
        var buckets: [String: [Chart]] = [:]
        for chart in charts {
            if buckets[chart.airportCode] == nil { order.append(chart.airportCode) }
            buckets[chart.airportCode, default: []].append(chart)
        }
        return order.map { PinnedGroup(id: $0, charts: buckets[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
                .overlay(Color.ngSeparator)
            if charts.isEmpty {
                emptyState
            } else {
                list
            }

            if !isPinnedList, weather.isEnabled, let airport = selectedAirport {
                Divider().overlay(Color.ngSeparator)
                WeatherPanel(icao: airport.code)
            }
        }
        .frame(minWidth: 250)
        .background(Color.ngPanel)
        .onAppear { weather.show(icao: selectedAirport?.code) }
        .onChange(of: browser.sidebarSelection) { _ in
            handleSelectionChange()
            weather.show(icao: selectedAirport?.code)
        }
    }

    // MARK: - Header

    private var headerTitle: String {
        if isPinnedList { return "Pinned Charts" }
        return selectedAirport?.displayTitle ?? "No Airport Selected"
    }

    private var headerSubtitle: String? {
        if isPinnedList { return "\(library.pinnedCharts.count) charts" }
        guard let airport = selectedAirport else { return nil }
        // The reordering is invisible unless it says so, and then it explains itself.
        if let planned = plannedRunway { return "RWY \(planned) planned" }
        if let name = airport.displaySubtitle, !name.isEmpty { return name }
        return "\(airport.charts.count) charts"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(headerTitle)
                    .font(.headline)
                if let subtitle = headerSubtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            if !isPinnedList {
                CategoryStrip(selection: $browser.category, isEnabled: selectedAirport != nil)
                    .help("Airport, Departure, Arrival, Approach and Reference charts")
            }

            MacSearchField(text: $browser.chartQuery,
                           placeholder: "Filter charts",
                           focusNotification: .focusChartSearch,
                           onSubmit: selectFirstChart)
                .frame(height: 22)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 9)
    }

    // MARK: - List

    private var list: some View {
        List(selection: $browser.selectedChartID) {
            if isPinnedList {
                ForEach(pinnedGroups) { group in
                    Section(group.id) {
                        ForEach(group.charts) { chart in
                            row(for: chart, showsAirport: false)
                        }
                    }
                }
            } else {
                ForEach(charts) { chart in
                    row(for: chart, showsAirport: false)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private func row(for chart: Chart, showsAirport: Bool) -> some View {
        ChartRow(chart: chart,
                 showsAirport: showsAirport,
                 isPinned: library.isPinned(chart),
                 servesPlannedRunway: plannedRunway.map { chart.serves(runway: $0) } ?? false) {
            library.togglePin(chart)
        }
        .tag(chart.id)
        .contextMenu {
            Button(library.isPinned(chart) ? "Unpin Chart" : "Pin Chart") {
                library.togglePin(chart)
            }
            Divider()
            Button("Reveal in Finder") { ChartActions.reveal(chart) }
            Button("Open in Preview") { ChartActions.openExternally(chart) }
            Button("Copy Image") { ChartActions.copyToPasteboard(chart, state: browser, marks: annotations) }
            Button("Export as PNG…") { ChartActions.exportPNG(chart, state: browser, marks: annotations) }
            if annotations.hasMarks(for: chart.id) {
                Button("Clear Marks") { annotations.clear(chart.id) }
            }
            Divider()
            Menu("Move to Category") {
                ForEach(ChartCategory.displayOrder) { category in
                    Button(category.displayName) {
                        library.setCategory(category, for: chart)
                    }
                    .disabled(category == chart.category)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: emptyStateSymbol)
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text(emptyStateTitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }

    private var emptyStateSymbol: String {
        if isPinnedList { return "star" }
        if selectedAirport == nil { return "airplane" }
        return browser.category.symbolName
    }

    private var emptyStateTitle: String {
        if !browser.chartQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No charts match the filter"
        }
        if isPinnedList { return "No pinned charts yet" }
        guard let airport = selectedAirport else { return "Choose an airport in the sidebar" }
        return "No \(browser.category.displayName.lowercased()) charts for \(airport.displayTitle)"
    }

    // MARK: - Selection

    private func handleSelectionChange() {
        browser.chartQuery = ""
        guard let airport = selectedAirport else { return }
        library.noteVisit(airportCode: airport.code)

        if airport.count(in: browser.category) == 0 {
            browser.category = airport.firstPopulatedCategory
        }
        let available = airport.chartList(in: browser.category)
        if let current = browser.selectedChartID, available.contains(where: { $0.id == current }) {
            return
        }
        browser.selectedChartID = available.first?.id
    }

    private func selectFirstChart() {
        guard let first = charts.first else { return }
        browser.selectedChartID = first.id
    }
}

// MARK: - Row

private struct ChartRow: View {
    let chart: Chart
    let showsAirport: Bool
    let isPinned: Bool
    /// Matches the runway the flight plan named, so the badge stands out from the rest.
    let servesPlannedRunway: Bool
    let togglePin: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: chart.category.symbolName)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(chart.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if showsAirport {
                        Text(chart.airportCode)
                            .fontWeight(.medium)
                    }
                    // Same tint as the tab it lives under, so a glance down the list reads
                    // as the same colour coding rather than two unrelated schemes.
                    Text(chart.category.shortName)
                        .foregroundStyle(chart.category.tint)
                    if let runway = chart.runway {
                        Text("RWY \(runway)")
                            .fontWeight(servesPlannedRunway ? .semibold : .regular)
                            .foregroundStyle(servesPlannedRunway ? Color.ngAccentText : Color.secondary)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            if isPinned || isHovering {
                Button(action: togglePin) {
                    Image(systemName: isPinned ? "star.fill" : "star")
                        .foregroundStyle(isPinned ? Color.ngAccentText : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(isPinned ? "Unpin chart" : "Pin chart")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Category strip

/// The tab strip, one colour per chart type.
///
/// Hand-built rather than a segmented `Picker`, which paints every segment the same and gives
/// no way in to tint them individually.
private struct CategoryStrip: View {

    @Binding var selection: ChartCategory
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ChartCategory.displayOrder) { category in
                tab(category)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.ngPanelRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.ngSeparator, lineWidth: 1)
                )
        )
        .opacity(isEnabled ? 1 : 0.45)
        .disabled(!isEnabled)
    }

    private func tab(_ category: ChartCategory) -> some View {
        let chosen = selection == category
        return Button {
            selection = category
        } label: {
            Text(category.shortName)
                .font(.system(size: 11, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 21)
                // Dark text on the filled pill: the tints are bright, so the window colour is
                // what stays legible on top of them.
                .foregroundStyle(chosen ? Color.ngWindow : category.tint)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(chosen ? category.tint : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(category.displayName)
        .help(category.displayName)
    }
}
