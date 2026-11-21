import AppKit
import SwiftUI

private struct PinnedGroup: Identifiable {
    let id: String
    let charts: [Chart]
}

/// The charts the middle column lists, in the order it lists them — which is the order the
/// arrow keys and Previous and Next Chart step through, so the next chart is the one under
/// this one on the screen. It was the airport's charts in their own order once, which with a
/// runway planned or a filter typed was a different list from the one being looked at.
@MainActor
enum ChartListing {

    static func charts(library: ChartLibrary, browser: BrowserState,
                       flight: FlightPlanStore) -> [Chart] {
        let listed: [Chart]
        if browser.sidebarSelection == .pinned {
            listed = byAirport(library.pinnedCharts)
        } else if let airport = library.airport(code: browser.sidebarSelection?.airportCode) {
            listed = prioritised(airport.chartList(in: browser.category),
                                 runway: flight.plannedRunway(at: airport.code))
        } else {
            return []
        }
        let query = browser.chartQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return listed }
        // Folded once here rather than per chart.
        let folded = SearchKey.fold(query)
        return listed.filter { $0.matches(foldedQuery: folded) }
    }

    /// Floats the plates for the planned runway to the top, keeping the existing order within
    /// each group. Eleven approaches at a big field is a lot to read through when the flight
    /// plan already says which one you want.
    private static func prioritised(_ list: [Chart], runway planned: String?) -> [Chart] {
        guard let planned else { return list }
        let matching = list.filter { $0.serves(runway: planned) }
        guard !matching.isEmpty, matching.count < list.count else { return list }
        return matching + list.filter { !$0.serves(runway: planned) }
    }

    /// Pinned charts together by airport, the airports in the order their first chart was
    /// pinned — the way the pinned list sections them.
    private static func byAirport(_ list: [Chart]) -> [Chart] {
        var order: [String] = []
        var buckets: [String: [Chart]] = [:]
        for chart in list {
            if buckets[chart.airportCode] == nil { order.append(chart.airportCode) }
            buckets[chart.airportCode, default: []].append(chart)
        }
        return order.flatMap { buckets[$0] ?? [] }
    }

    /// The chart `delta` rows from the selected one, stopping at either end; the first when
    /// none is selected.
    static func step(_ delta: Int, in list: [Chart], from selected: String?) -> String? {
        guard !list.isEmpty else { return nil }
        guard let selected, let index = list.firstIndex(where: { $0.id == selected }) else {
            return list.first?.id
        }
        let target = index + delta
        guard list.indices.contains(target) else { return nil }
        return list[target].id
    }
}

struct ChartListColumn: View {

    @EnvironmentObject private var library: ChartLibrary
    @EnvironmentObject private var browser: BrowserState
    @EnvironmentObject private var annotations: AnnotationStore
    @EnvironmentObject private var flight: FlightPlanStore
    @EnvironmentObject private var weather: WeatherStore

    @State private var tab: ColumnTab = .charts

    private var selectedAirport: Airport? {
        library.airport(code: browser.sidebarSelection?.airportCode)
    }

    private var isPinnedList: Bool {
        browser.sidebarSelection == .pinned
    }

    private var isMap: Bool {
        browser.sidebarSelection == .map
    }

    /// The runway SimBrief planned here, if this airport is in the loaded flight.
    private var plannedRunway: String? {
        guard let code = selectedAirport?.code else { return nil }
        return flight.plannedRunway(at: code)
    }

    private var charts: [Chart] {
        ChartListing.charts(library: library, browser: browser, flight: flight)
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
        if isMap {
            RouteFixList()
        } else {
            column
        }
    }

    private var column: some View {
        VStack(spacing: 0) {
            header

            if showsTabs {
                ColumnTabStrip(selection: $tab, tabs: availableTabs)
            }

            Divider()
                .overlay(Color.ngSeparator)

            switch showsTabs ? tab : .charts {
            case .info:
                if let airport = selectedAirport {
                    AirportInfoTab(airport: airport,
                                   variation: weather.variation(for: airport.code))
                }
            case .charts:
                chartsTab
            case .weather:
                if let airport = selectedAirport {
                    WeatherPanel(icao: airport.code, face: .reports)
                }
            case .runways:
                if let airport = selectedAirport {
                    WeatherPanel(icao: airport.code, face: .runways)
                }
            }
        }
        .frame(minWidth: 250)
        .background(Color.ngPanel)
        .onAppear {
            weather.show(icao: selectedAirport?.code)
            weather.isExpanded = tab.needsWeather
        }
        .onChange(of: browser.sidebarSelection) {
            handleSelectionChange()
            weather.show(icao: selectedAirport?.code)
            if !availableTabs.contains(tab) { tab = .charts }
        }
        // A tab that does not need weather is the new "collapsed": the store fetches nothing
        // while one of those is on top.
        .onChange(of: tab) { weather.isExpanded = tab.needsWeather }
    }

    /// The pinned list is not an airport: it has no runways to describe and no weather.
    private var showsTabs: Bool { !isPinnedList && selectedAirport != nil }

    private var availableTabs: [ColumnTab] {
        weather.isEnabled ? ColumnTab.allCases : ColumnTab.allCases.filter { !$0.needsWeather }
    }

    /// The category strip, the filter and the list — what the column used to be on its own.
    private var chartsTab: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
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
            .padding(.top, 9)
            .padding(.bottom, 9)

            Divider()
                .overlay(Color.ngSeparator)

            if charts.isEmpty {
                emptyState
            } else {
                list
            }
        }
    }

    // MARK: - Header

    private var headerTitle: String {
        if isMap { return "Route Map" }
        if isPinnedList { return "Pinned Charts" }
        return selectedAirport?.displayTitle ?? "No Airport Selected"
    }

    /// The flight plans a runway here and nothing in the library serves it. Worth saying where
    /// you would go looking for the plate, not only in the flight section that named it.
    private var plannedRunwayHasNoChart: Bool {
        guard let planned = plannedRunway, let code = selectedAirport?.code else { return false }
        return !library.hasChart(serving: planned, at: code)
    }

    /// The airport's name: from its folder if it carries one, then from the bundled list of
    /// every airfield's name, and last from the flight plan.
    private var headerName: String? {
        guard !isPinnedList, let airport = selectedAirport else { return nil }
        if let name = airport.displaySubtitle, !name.isEmpty { return name }
        return flight.name(at: airport.code)
    }

    private var headerDetail: String? {
        if isPinnedList { return "\(library.pinnedCharts.count) charts" }
        guard let airport = selectedAirport else { return nil }
        // The reordering is invisible unless it says so, and then it explains itself.
        if let planned = plannedRunway { return "RWY \(planned) planned" }
        return "\(airport.charts.count) charts"
    }

    /// Centred, with the airport's own name under its code — the identity of what you are
    /// looking at, rather than a line of statistics with the code buried in it.
    private var header: some View {
        VStack(spacing: 1) {
            Text(headerTitle)
                .font(.system(size: 18, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                // Only this line keeps clear of the clock, so it stays centred in the column
                // rather than in what is left of it. The lines below get the full width —
                // reserving it for them truncated the warning to "No plate for plann…".
                .padding(.horizontal, 64)

            // With an orange clock beside it when the newest plate here is a cycle old: the
            // Info tab says how old, and this says it before anyone thinks to look there.
            let outOfDate = !isPinnedList && (selectedAirport?.chartsAreOutOfDate ?? false)
            if let name = headerName, !name.isEmpty {
                HStack(spacing: 4) {
                    Text(name)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if outOfDate, let airport = selectedAirport {
                        OutOfDateClock(airport: airport)
                    }
                }
                .font(.subheadline)
            } else if outOfDate, let airport = selectedAirport {
                OutOfDateClock(airport: airport)
                    .font(.subheadline)
            }

            // One line, not two: the warning replaces the plain "RWY 19R planned" rather than
            // sitting under it saying the same thing in a different colour. When a plate does
            // serve the runway, that plain line is what comes back.
            if plannedRunwayHasNoChart, let planned = plannedRunway {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("No plate for planned RWY \(planned)")
                }
                .font(.ngSmallMedium)
                .foregroundStyle(Color.orange)
                .lineLimit(1)
                .help("The flight plans RWY \(planned) here and none of this airport's plates "
                      + "serve it. Check the runway, or download the plate.")
            } else if let detail = headerDetail {
                Text(detail)
                    .font(.ngSmall)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .overlay(alignment: .topTrailing) {
            ZuluClock()
                .padding(.trailing, 12)
                // Matched to the title's own top padding, so the clock sits on its line.
                .padding(.top, 18)
        }
    }

    // MARK: - List

    private var list: some View {
        ScrollViewReader { scroller in
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
            .background(PlainSelection(selected: browser.selectedChartID))
            .background(ArrowKeys { delta in step(delta) })
            // The chart the keys land on is kept in view, the least scroll that shows it.
            .onChange(of: browser.selectedChartID) { _, selected in
                guard let selected else { return }
                scroller.scrollTo(selected)
            }
        }
    }

    /// Up or down the list by one.
    private func step(_ delta: Int) {
        if let next = ChartListing.step(delta, in: charts, from: browser.selectedChartID) {
            browser.selectedChartID = next
        }
    }

    private func row(for chart: Chart, showsAirport: Bool) -> some View {
        ChartRow(chart: chart,
                 showsAirport: showsAirport,
                 isSelected: chart.id == browser.selectedChartID,
                 isPinned: library.isPinned(chart),
                 servesPlannedRunway: plannedRunway.map { chart.serves(runway: $0) } ?? false) {
            library.togglePin(chart)
        }
        .tag(chart.id)
        // The open chart, green from end to end whether or not the list has the keyboard, in
        // the shape the list's own highlight has.
        .listRowBackground(chart.id == browser.selectedChartID
                           ? RoundedRectangle(cornerRadius: 6, style: .continuous)
                               .fill(Color.ngChartSelection)
                               .padding(.horizontal, 10)
                           : nil)
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
    /// The chart open beside the list, whose row is painted green and written on in white.
    let isSelected: Bool
    let isPinned: Bool
    /// Matches the runway the flight plan named, so the badge stands out from the rest.
    let servesPlannedRunway: Bool
    let togglePin: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: chart.category.symbolName)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.85))
                                            : AnyShapeStyle(.secondary))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(chart.title)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
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
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85)
                                                    : chart.category.tint)
                    if let runway = chart.runway {
                        // A chip rather than a third word in a run of faint text: the
                        // designator is the thing you scan this list for, and "APP RWY 25L"
                        // ran together as one phrase at this size. Digits are tabular so
                        // 25L sits under 04R down the list rather than drifting.
                        Text(runway)
                            .font(.ngSmallBold)
                            .monospacedDigit()
                            .foregroundStyle(isSelected ? Color.white
                                             : servesPlannedRunway ? Color.ngAccentText
                                             : Color.primary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(isSelected ? Color.black.opacity(0.25)
                                        : servesPlannedRunway ? Color.ngAccent.opacity(0.45)
                                        : Color.ngSeparator,
                                        in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                            .help(servesPlannedRunway
                                  ? "Runway \(runway) — the one this flight plans"
                                  : "Runway \(runway)")
                    }
                }
                .font(.ngSmall)
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.85))
                                            : AnyShapeStyle(.secondary))
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            if isPinned || isHovering {
                Button(action: togglePin) {
                    Image(systemName: isPinned ? "star.fill" : "star")
                        .foregroundStyle(isSelected ? Color.white
                                         : isPinned ? Color.ngAccentText : Color.secondary)
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

/// The list's own selection highlight, switched off, so that the open chart's row can be
/// painted green instead.
///
/// The list paints its selection in the accent colour only while it has the keyboard, and in
/// grey the rest of the time — which after a click on a row is all of the time, since SwiftUI's
/// list does not take the keyboard for a click. So the open chart sat in a grey row however
/// the window was focused. SwiftUI has no way to change that grey, so the table under the list
/// is asked to draw no highlight at all, and the row draws its own.
private struct PlainSelection: NSViewRepresentable {

    /// Only so that every change of chart comes through here: the table is made after this
    /// view is, and SwiftUI makes a fresh one when the list is rebuilt for another airport,
    /// so it is looked for again each time rather than once.
    let selected: String?

    func makeNSView(context: Context) -> Finder { Finder() }

    func updateNSView(_ view: Finder, context: Context) { view.plain() }

    final class Finder: NSView {

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Once the list has been laid out, which it has not been yet.
            DispatchQueue.main.async { [weak self] in self?.plain() }
        }

        /// The table this sits behind, found by where it is: this view is the list's
        /// background, so the table whose scroll view covers its middle is the list's own and
        /// never the sidebar's.
        func plain() {
            guard let root = window?.contentView else { return }
            let area = convert(bounds, to: nil)
            let middle = NSPoint(x: area.midX, y: area.midY)
            for table in Self.tables(in: root) {
                let holder: NSView = table.enclosingScrollView ?? table
                guard holder.convert(holder.bounds, to: nil).contains(middle) else { continue }
                if table.selectionHighlightStyle != .none {
                    table.selectionHighlightStyle = .none
                }
                return
            }
        }

        private static func tables(in view: NSView) -> [NSTableView] {
            var found: [NSTableView] = []
            if let table = view as? NSTableView { found.append(table) }
            for sub in view.subviews { found += tables(in: sub) }
            return found
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// ↑ and ↓ for the chart list, whatever was clicked last.
///
/// SwiftUI's list moves its selection with the arrows once it has the keyboard, and it does
/// not take the keyboard when a row is clicked: the click opens the chart and leaves the window
/// itself as first responder, and so does a click on the chart, so the arrows went nowhere.
/// This takes them when nothing else has the keyboard and steps the list. Anything that does
/// have it keeps its arrows — a search field, the sidebar's list, a mark being typed.
private struct ArrowKeys: NSViewRepresentable {

    let step: (Int) -> Void

    func makeNSView(context: Context) -> Catcher { Catcher() }

    func updateNSView(_ view: Catcher, context: Context) { view.step = step }

    final class Catcher: NSView {
        var step: ((Int) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let host = self.window, event.window === host,
                      host.firstResponder === host,
                      event.modifierFlags.intersection([.command, .option, .control, .shift])
                          .isEmpty
                else { return event }
                switch event.keyCode {
                case 125: self.step?(1)
                case 126: self.step?(-1)
                default: return event
                }
                return nil
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
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

// MARK: - Tabs

enum ColumnTab: String, CaseIterable, Identifiable {
    case info, charts, weather, runways

    var id: String { rawValue }

    var title: String {
        switch self {
        case .info: return "Info"
        case .charts: return "Charts"
        case .weather: return "Weather"
        case .runways: return "Runways"
        }
    }

    /// Whether being on this tab is a reason to fetch weather.
    var needsWeather: Bool { self == .weather || self == .runways }
}

/// Info / Charts / Weather. Built by hand rather than with a Picker for the same reason the
/// category strip is: a segmented control takes the window tint for every segment, with no way
/// in to style the selection.
private struct ColumnTabStrip: View {

    @Binding var selection: ColumnTab
    let tabs: [ColumnTab]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                let chosen = selection == tab
                Button {
                    selection = tab
                } label: {
                    Text(tab.title)
                        // Four equal cells in a 250-point column: at 12 point "Runways" left
                        // no air either side of itself.
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 23)
                        .foregroundStyle(chosen ? Color.white : Color.secondary)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(chosen ? Color.ngAccent : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.ngPanelRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.ngSeparator, lineWidth: 1)
                )
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 9)
    }
}

// MARK: - Info

/// What the app knows about an airport without opening a chart: its runways, what you hold for
/// it, and where those files are. Everything here is already to hand — nothing is fetched.
private struct AirportInfoTab: View {

    let airport: Airport
    /// Magnetic variation as set in the Runways tab, shown here because the wind components
    /// are quietly wrong by exactly this much when it is left at zero.
    let variation: Double

    private var categories: [ChartCategory] {
        ChartCategory.displayOrder.filter { airport.count(in: $0) > 0 }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                section("Charts") {
                    VStack(alignment: .leading, spacing: 3) {
                        if categories.isEmpty {
                            Text("No charts filed here yet.")
                                .font(.ngSmall)
                                .foregroundStyle(.tertiary)
                        }
                        ForEach(categories) { category in
                            HStack(spacing: 6) {
                                Text(category.displayName)
                                    .foregroundStyle(category.tint)
                                Spacer(minLength: 8)
                                Text("\(airport.count(in: category))")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .font(.ngSmall)
                        }
                    }
                }

                section("Details") {
                    VStack(alignment: .leading, spacing: 3) {
                        detail("Variation", variationText,
                               help: "Set it from the chart in the Runways tab. METAR wind is "
                                   + "true north, runway numbers are magnetic.")

                        if let date = airport.newestChartDate {
                            detail("Newest chart", dateText(date),
                                   tint: airport.chartsAreOutOfDate ? Color.orange : .secondary,
                                   help: "When the newest plate here was last written. A LIDO "
                                       + "cycle is 28 days.")
                        }

                        if let folder = airport.charts.first?.folderPath {
                            detail("Folder", folder)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var variationText: String {
        let rounded = (variation * 10).rounded() / 10
        guard rounded != 0 else { return "0°" }
        let magnitude = abs(rounded)
        let value = magnitude == magnitude.rounded()
            ? String(Int(magnitude))
            : String(format: "%.1f", magnitude)
        return value + "°" + (rounded > 0 ? "W" : "E")
    }

    private func dateText(_ date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: date, to: .now).day ?? 0
        let stamp = date.formatted(date: .abbreviated, time: .omitted)
        switch days {
        case ..<1: return stamp + " · today"
        case 1: return stamp + " · 1 day old"
        default: return stamp + " · \(days) days old"
        }
    }

    private func detail(_ label: String, _ value: String,
                        tint: Color = .secondary, help: String = "") -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(tint)
                .multilineTextAlignment(.trailing)
        }
        .font(.ngSmall)
        .help(help)
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.ngSmallBold)
                .foregroundStyle(.secondary)
            content()
        }
    }
}
