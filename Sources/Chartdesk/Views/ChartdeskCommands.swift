import SwiftUI

struct ChartdeskCommands: Commands {

    @ObservedObject var library: ChartLibrary
    @ObservedObject var browser: BrowserState
    @ObservedObject var viewer: ChartViewerController

    private var chart: Chart? {
        library.chart(id: browser.selectedChartID)
    }

    private var currentList: [Chart] {
        if browser.sidebarSelection == .pinned { return library.pinnedCharts }
        guard let airport = library.airport(code: browser.sidebarSelection?.airportCode) else { return [] }
        return airport.chartList(in: browser.category)
    }

    var body: some Commands {

        // File
        CommandGroup(replacing: .newItem) {
            Button("Open Charts Folder…") {
                library.chooseFolder()
            }
            .keyboardShortcut("o", modifiers: .command)

            Button("Rescan Library") {
                library.rescan()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!library.hasLibrary)
        }

        CommandGroup(after: .newItem) {
            Divider()

            Button("Reveal Chart in Finder") {
                if let chart = chart { ChartActions.reveal(chart) }
            }
            .disabled(chart == nil)

            Button("Open Chart in Preview") {
                if let chart = chart { ChartActions.openExternally(chart) }
            }
            .disabled(chart == nil)

            Button("Export Chart as PNG…") {
                if let chart = chart { ChartActions.exportPNG(chart, state: browser) }
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(chart == nil)
        }

        CommandGroup(replacing: .printItem) {
            Button("Print Chart…") {
                if let chart = chart { ChartActions.printChart(chart, state: browser) }
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(chart == nil)
        }

        // View
        CommandGroup(after: .toolbar) {
            Divider()

            Button("Zoom In") { viewer.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(chart == nil)

            Button("Zoom Out") { viewer.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(chart == nil)

            Button("Zoom to Fit") { viewer.zoomToFit() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(chart == nil)

            Button("Actual Size") { viewer.actualSize() }
                .keyboardShortcut("9", modifiers: .command)
                .disabled(chart == nil)

            Divider()

            Button(browser.nightMode ? "Turn Off Night Mode" : "Turn On Night Mode") {
                browser.nightMode.toggle()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(chart == nil)

            Button("Rotate Right") { browser.rotateRight() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(chart == nil)

            Button("Rotate Left") { browser.rotateLeft() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(chart == nil)

            Button("Reset Rotation") { browser.resetRotation() }
                .disabled(chart == nil || browser.rotation == 0)
        }

        // Chart
        CommandMenu("Chart") {
            Button("Previous Chart") { step(-1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(currentList.isEmpty)

            Button("Next Chart") { step(1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(currentList.isEmpty)

            Divider()

            ForEach(ChartCategory.displayOrder) { category in
                Button("\(category.displayName) Charts") {
                    browser.category = category
                }
                .keyboardShortcut(shortcutKey(for: category), modifiers: .command)
                .disabled(browser.sidebarSelection?.airportCode == nil)
            }

            Divider()

            Button(isPinned ? "Unpin Chart" : "Pin Chart") {
                if let chart = chart { library.togglePin(chart) }
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(chart == nil)

            Button("Copy Chart Image") {
                if let chart = chart { ChartActions.copyToPasteboard(chart, state: browser) }
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(chart == nil)

            Divider()

            Button("Search Airports") {
                NotificationCenter.default.post(name: .focusAirportSearch, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)

            Button("Filter Charts") {
                NotificationCenter.default.post(name: .focusChartSearch, object: nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
        }

        CommandGroup(replacing: .help) { }
    }

    // MARK: - Helpers

    private var isPinned: Bool {
        guard let chart = chart else { return false }
        return library.isPinned(chart)
    }

    private func shortcutKey(for category: ChartCategory) -> KeyEquivalent {
        KeyEquivalent(Character("\(category.sortIndex + 1)"))
    }

    private func step(_ delta: Int) {
        let list = currentList
        guard !list.isEmpty else { return }

        guard let identifier = browser.selectedChartID,
              let index = list.firstIndex(where: { $0.id == identifier }) else {
            browser.selectedChartID = list.first?.id
            return
        }

        let target = index + delta
        guard target >= 0, target < list.count else { return }
        browser.selectedChartID = list[target].id
    }
}
