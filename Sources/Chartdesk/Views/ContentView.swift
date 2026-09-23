import SwiftUI

struct ContentView: View {

    @EnvironmentObject private var library: ChartLibrary
    @EnvironmentObject private var browser: BrowserState
    @EnvironmentObject private var updater: UpdateController
    @EnvironmentObject private var flight: FlightPlanStore
    @EnvironmentObject private var importer: ImportController
    @EnvironmentObject private var navdata: NavDataStore

    @Environment(\.openWindow) private var openWindow

    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// The splash, up until the first scan is done and a readable minimum has passed. Two
    /// pieces of state rather than one so whichever finishes second dismisses it.
    @State private var isStarting = true

    /// Past the welcome screen to the map with no library at all, for the debug hook that
    /// opens on it. With no library there is nothing to import into, so nothing is moved.
    private var opensOnMap: Bool {
        #if DEBUG
        return RenderProbe.openAt != nil
        #else
        return false
        #endif
    }
    @State private var minimumShown = false

    var body: some View {
        Group {
            if library.hasLibrary || opensOnMap {
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
        .overlay {
            if isStarting || updater.installing != nil {
                StartupScreen(status: library.isScanning ? "Scanning your charts…" : "",
                              update: updater.installing)
                    .transition(.opacity)
            }
        }
        // For an update asked for from the menu, where this screen arrives over a window you
        // were using rather than over a launch.
        .animation(.easeOut(duration: 0.22), value: updater.installing != nil)
        .overlay(alignment: .bottom) {
            // Never while an update is installing: that window is about to close.
            if updater.installing == nil, !isStarting {
                if !importer.waiting.isEmpty {
                    ImportBanner(onImport: { importer.performImport() })
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if importer.report != nil || importer.trouble != nil {
                    ImportReport()
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeOut(duration: 0.24), value: importer.waiting.count)
        .task {
            try? await Task.sleep(for: .milliseconds(2000))
            minimumShown = true
            finishStartingIfReady()
        }
        .onChange(of: library.isScanning) { _, scanning in
            if !scanning { finishStartingIfReady() }
        }
        .onAppear {
            restoreSelection()
            updater.checkOnLaunchIfWanted()
            flight.refreshOnLaunchIfWanted()
            navdata.checkOnLaunchIfWanted()
            // So the first frame the map ever draws has a world on it. Only the coarsest
            // tier, which is a hundred kilobytes: the finer ones are read when a zoom asks
            // for them, and reading all three at launch would be reading two for nothing.
            MapGeography.shared.warmUp()
        }
        .onChange(of: library.scanID) { restoreSelection() }
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
        .onReceive(NotificationCenter.default.publisher(for: .showAirportLayouts)) { _ in
            openWindow(id: "airportLayouts")
        }
        .alert("Software Update", isPresented: $updater.showMessage) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(updater.message ?? "")
        }
    }

    private func finishStartingIfReady() {
        guard isStarting, minimumShown, !library.isScanning else { return }
        withAnimation(.easeOut(duration: 0.28)) { isStarting = false }
        // Only now, so the ten seconds the offer stands are ten seconds you can see.
        if let root = library.rootURL, updater.installing == nil {
            importer.checkOnLaunch(libraryRoot: root) { library.rescan() }
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

        // Pinned and the map are selections in their own right; only an airport that has
        // gone missing from the library should be cleared.
        if browser.sidebarSelection == .map { return }
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
                            .font(.ngSmall)
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
                .font(.ngSmallMedium)
                .foregroundStyle(Color.ngWarning)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ngWindow)
        // The same corner the sidebar puts it in, for the one screen that has no sidebar.
        .overlay(alignment: .bottomLeading) {
            Text(Bundle.main.appVersion)
                .font(.ngSmall)
                .monospacedDigit()
                .foregroundStyle(Bundle.main.isCandidateBuild ? Color.orange : .secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
    }

    private func layoutExample(title: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.ngSmall)
                .fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { item in
                    Text(item.element)
                        .font(.ngSmallMono)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
