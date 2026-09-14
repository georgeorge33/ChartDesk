import SwiftUI

private struct PinnedGroup: Identifiable {
    let id: String
    let charts: [Chart]
}

struct ChartListColumn: View {

    @EnvironmentObject private var library: ChartLibrary
    @EnvironmentObject private var browser: BrowserState

    private var selectedAirport: Airport? {
        library.airport(code: browser.sidebarSelection?.airportCode)
    }

    private var isPinnedList: Bool {
        browser.sidebarSelection == .pinned
    }

    private var baseCharts: [Chart] {
        if isPinnedList { return library.pinnedCharts }
        guard let airport = selectedAirport else { return [] }
        return airport.chartList(in: browser.category)
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
        }
        .frame(minWidth: 250)
        .background(Color.ngPanel)
        .onChange(of: browser.sidebarSelection) { _ in
            handleSelectionChange()
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
                Picker("Category", selection: $browser.category) {
                    ForEach(ChartCategory.displayOrder) { category in
                        Text(category.shortName).tag(category)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(selectedAirport == nil)
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
                 isPinned: library.isPinned(chart)) {
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
            Button("Copy Image") { ChartActions.copyToPasteboard(chart, state: browser) }
            Button("Export as PNG…") { ChartActions.exportPNG(chart, state: browser) }
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
                    Text(chart.category.shortName)
                    if let runway = chart.runway {
                        Text("RWY \(runway)")
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
