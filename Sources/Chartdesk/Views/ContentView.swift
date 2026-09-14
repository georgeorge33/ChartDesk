import SwiftUI

struct ContentView: View {

    @EnvironmentObject private var library: ChartLibrary
    @EnvironmentObject private var browser: BrowserState
    @EnvironmentObject private var updater: UpdateController
    @EnvironmentObject private var flight: FlightPlanStore

    @Environment(\.openWindow) private var openWindow

    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if library.hasLibrary {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 200, ideal: 244, max: 360)
                } content: {
                    ChartListColumn()
                        .navigationSplitViewColumnWidth(min: 250, ideal: 310, max: 460)
                } detail: {
                    ChartDetailView()
                }
                .navigationSplitViewStyle(.balanced)
                .background(Color.ngWindow)
            } else {
                WelcomeView()
            }
        }
        .background(WindowDragEnabler())
        .onAppear {
            restoreSelection()
            updater.checkOnLaunchIfWanted()
            flight.refreshOnLaunchIfWanted()
        }
        .onChange(of: library.scanID) { _ in restoreSelection() }
        .alert("Update Available",
               isPresented: $updater.showAvailable,
               presenting: updater.available) { release in
            Button("Update and Relaunch") { updater.installAvailable() }
            Button("Later", role: .cancel) { updater.dismissAvailable() }
        } message: { release in
            Text("Chartdesk \(release.version) is available. You have \(updater.currentVersion).\n\nChartdesk will quit, replace itself in your Applications folder, and reopen.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .showPerformance)) { _ in
            openWindow(id: "performance")
        }
        .alert("Software Update", isPresented: $updater.showMessage) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(updater.message ?? "")
        }
    }

    /// Picks something sensible to show after a scan: the chart you were last on, else the
    /// airport you were last on, else the first airport in the library.
    private func restoreSelection() {
        guard !library.airports.isEmpty else { return }

        if browser.selectedChartID == nil,
           browser.restoreLastChart,
           let identifier = browser.lastChartID,
           let chart = library.chart(id: identifier) {
            browser.category = chart.category
            browser.selectedChartID = chart.id
            browser.sidebarSelection = .airport(chart.airportCode)
            return
        }

        if let code = browser.sidebarSelection?.airportCode, library.airport(code: code) == nil {
            browser.sidebarSelection = nil
        }

        if browser.sidebarSelection == nil {
            if let code = browser.lastAirportCode, library.airport(code: code) != nil {
                browser.sidebarSelection = .airport(code)
            } else if let first = library.airports.first {
                browser.sidebarSelection = .airport(first.code)
            }
        }

        if let identifier = browser.selectedChartID, library.chart(id: identifier) == nil {
            browser.selectedChartID = nil
        }
    }
}

// MARK: - Welcome

struct WelcomeView: View {

    @EnvironmentObject private var library: ChartLibrary

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 18) {
                Image(systemName: "map")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(Color.ngAccentText)

                VStack(spacing: 6) {
                    Text("Welcome to Chartdesk")
                        .font(.largeTitle)
                    Text("A browser for the chart images you already have on disk.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button {
                    library.chooseFolder()
                } label: {
                    Text("Choose Charts Folder…")
                        .frame(minWidth: 180)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Chartdesk reads the folder without changing anything in it. Both of these layouts work:")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(alignment: .top, spacing: 26) {
                            layoutExample(title: "A folder per airport", lines: [
                                "Charts/",
                                "  EGLL – London Heathrow/",
                                "    AGC.png",
                                "    IAC ILS Z RWY 27R.png",
                                "  EIDW/",
                                "    SID RWY 28.png"
                            ])
                            layoutExample(title: "Everything in one folder", lines: [
                                "Charts/",
                                "  EGLL AGC.png",
                                "  EGLL IAC ILS 27R.png",
                                "  EIDW STAR 28.png",
                                "  EIDW AFC.png",
                                ""
                            ])
                        }

                        Text("Airport codes, chart types and runways are read from the file and folder names. Anything filed in the wrong tab can be moved with a right-click.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6)
                }
                .frame(maxWidth: 620)
            }
            .padding(40)

            Spacer(minLength: 0)

            Text("For flight simulation use. Not for real-world navigation.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ngWindow)
    }

    private func layoutExample(title: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { item in
                    Text(item.element)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
