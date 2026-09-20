import AppKit
import SwiftUI

/// Opens AppKit's own toolbar customisation sheet for the chart window. SwiftUI builds the
/// palette from the identified items in `ChartDetailView`; there is no API to present it, so
/// the window is asked directly.
enum ToolbarCustomization {
    static func present() {
        let candidates = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 } + NSApp.windows
        for window in candidates {
            guard let toolbar = window.toolbar, toolbar.allowsUserCustomization else { continue }
            window.makeKeyAndOrderFront(nil)
            toolbar.runCustomizationPalette(nil)
            return
        }
        NSSound.beep()
    }
}

struct ChartdeskCommands: Commands {

    @ObservedObject var library: ChartLibrary
    @ObservedObject var browser: BrowserState
    @ObservedObject var viewer: ChartViewerController
    @ObservedObject var updater: UpdateController
    @ObservedObject var marks: AnnotationStore
    @ObservedObject var flight: FlightPlanStore
    @ObservedObject var weather: WeatherStore
    @ObservedObject var importer: ImportController

    private var chart: Chart? {
        library.chart(id: browser.selectedChartID)
    }

    private var currentList: [Chart] {
        if browser.sidebarSelection == .pinned { return library.pinnedCharts }
        guard let airport = library.airport(code: browser.sidebarSelection?.airportCode) else { return [] }
        return airport.chartList(in: browser.category)
    }

    var body: some Commands {

        CommandGroup(after: .sidebar) {
            Button("Route Map") {
                browser.sidebarSelection = .map
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
        }

        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                updater.check(manual: true)
            }
            .disabled(updater.isWorking)
        }

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

            Button("File Downloaded Charts…") {
                guard let root = library.rootURL else { return }
                importer.checkNow(libraryRoot: root) { library.rescan() }
            }
            .disabled(!library.hasLibrary)

            Divider()

            Button(flight.isFetching ? "Loading Flight…" : "Load SimBrief Flight") {
                flight.refresh()
            }
            .keyboardShortcut("b", modifiers: [.command, .shift])
            .disabled(flight.isFetching || !flight.hasAccount)

            Button("Clear Flight") {
                flight.clear()
            }
            .disabled(flight.plan == nil)
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
                if let chart = chart { ChartActions.exportPNG(chart, state: browser, marks: marks) }
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(chart == nil)
        }

        CommandGroup(replacing: .printItem) {
            Button("Print Chart…") {
                if let chart = chart { ChartActions.printChart(chart, state: browser, marks: marks) }
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(chart == nil)
        }

        // Edit — the only undoable thing in Chartdesk is marking up a chart, so the standard
        // pair is pointed at that rather than left doing nothing.
        CommandGroup(replacing: .undoRedo) {
            Button("Undo Mark") {
                marks.undo(browser.selectedChartID)
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(!marks.canUndo(browser.selectedChartID))

            Button("Redo Mark") {
                marks.redo(browser.selectedChartID)
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(!marks.canRedo(browser.selectedChartID))
        }

        // View
        CommandGroup(after: .toolbar) {
            Divider()

            Button("Customize Toolbar…") {
                ToolbarCustomization.present()
            }

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

            Button("Rotate Right") { browser.rotateRight() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(chart == nil)

            Button("Rotate Left") { browser.rotateLeft() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(chart == nil)

            Button("Reset Rotation") { browser.resetRotation() }
                .disabled(chart == nil || browser.rotation == 0)

            Divider()

            Button(weather.isExpanded ? "Hide Weather" : "Show Weather") {
                weather.isEnabled = true
                weather.isExpanded.toggle()
            }
            .keyboardShortcut("w", modifiers: [.command, .shift])
        }

        // Window
        //
        // Both of these are for looking at the app rather than at a chart, which is what
        // makes them a submenu of their own rather than four more lines of the View menu.
        CommandGroup(after: .windowArrangement) {
            Menu("Debug") {
                Button("Performance…") {
                    NotificationCenter.default.post(name: .showPerformance, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .option])

                Button("Airport Layouts…") {
                    NotificationCenter.default.post(name: .showAirportLayouts, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command, .option])
            }
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
                if let chart = chart { ChartActions.copyToPasteboard(chart, state: browser, marks: marks) }
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

        // Markup
        CommandMenu("Markup") {
            Button(marks.isAnnotating ? "Stop Annotating" : "Annotate Chart") {
                marks.isAnnotating.toggle()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(chart == nil)

            Divider()

            ForEach(Array(AnnotationTool.allCases.enumerated()), id: \.element) { index, tool in
                Button(marks.tool == tool ? "✓ \(tool.displayName)" : tool.displayName) {
                    marks.tool = tool
                    marks.isAnnotating = true
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
                .disabled(chart == nil)
            }

            Divider()

            Button(marks.showMarks ? "Hide Marks" : "Show Marks") {
                marks.showMarks.toggle()
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])

            Button("Clear Marks on This Chart") {
                marks.clear(browser.selectedChartID)
            }
            .disabled(!marks.hasMarks(for: browser.selectedChartID))
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
