import SwiftUI

struct SettingsView: View {

    @State private var tab = SettingsView.firstTab

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            ViewingSettingsView()
                .tabItem { Label("Viewing", systemImage: "eye") }
                .tag("viewing")
            MarkupSettingsView()
                .tabItem { Label("Markup", systemImage: "pencil.tip.crop.circle") }
                .tag("markup")
        }
        .frame(width: 540, height: 400)
    }

    /// General — or in a debug build the tab `CHARTDESK_SETTINGS_TAB` names, so that a test
    /// copy's Settings can be looked at on any tab without a click.
    private static var firstTab: String {
        #if DEBUG
        if let tab = ProcessInfo.processInfo.environment["CHARTDESK_SETTINGS_TAB"] { return tab }
        #endif
        return "general"
    }
}

private struct GeneralSettingsView: View {

    @EnvironmentObject private var library: ChartLibrary
    @EnvironmentObject private var browser: BrowserState
    @EnvironmentObject private var updater: UpdateController
    @EnvironmentObject private var importer: ImportController
    @EnvironmentObject private var navdata: NavDataStore
    @EnvironmentObject private var flight: FlightPlanStore

    /// The whole folder's size, as Finder would put it: nil while it is being counted.
    @State private var folderSize: String?

    var body: some View {
        Form {
            Section("Chart Library") {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(library.hasLibrary ? library.folderPath : "No folder chosen yet")
                            .font(.ng(.callout))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .foregroundStyle(library.hasLibrary ? Color.primary : Color.secondary)
                        Text("\(library.chartCount) charts · \(library.airports.count) airports")
                            .font(.ngSmall)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if library.hasLibrary {
                        Group {
                            if let folderSize {
                                Text(folderSize)
                                    .font(.ng(.callout))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            } else {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                        .help("Everything in the folder, as Finder counts it")
                    }
                }
                // Counted when Settings opens and again after every rescan, off the main
                // thread: a big library is tens of thousands of files.
                .task(id: library.scanID) {
                    guard let root = library.rootURL else { return }
                    folderSize = nil
                    let bytes = await Task.detached(priority: .utility) {
                        ChartLibrary.size(of: root)
                    }.value
                    folderSize = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                }

                HStack {
                    Button("Choose Folder…") { library.chooseFolder() }
                    Button("Rescan") { library.rescan() }
                        .disabled(!library.hasLibrary)
                    Spacer()
                    if library.isScanning {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                    }
                }
            }

            Section("Navigation Data") {
                HStack(spacing: 8) {
                    if let cycle = navdata.installed {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Cycle \(cycle.stamp)")
                                .font(.ng(.callout))
                            Text(cycle.span
                                 + (navdata.isCurrent ? " · current" : " · out of date"))
                                .font(.ngSmall)
                                .foregroundStyle(navdata.isCurrent ? .secondary : Color.orange)
                        }
                    } else {
                        Text("Not installed")
                            .font(.ng(.callout))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    if navdata.isWorking {
                        ProgressView().progressViewStyle(.circular).controlSize(.small)
                    } else {
                        Button(navdata.installed == nil ? "Download" : "Check Now") {
                            navdata.update()
                        }
                    }
                }

                Toggle("Fetch the current cycle on launch", isOn: $navdata.updateOnLaunch)

                if let status = navdata.status {
                    Text(status)
                        .font(.ngSmall)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("SID and STAR altitude restrictions, from the FAA's Coded Instrument "
                     + "Flight Procedures — public domain, reissued every 28 days, and United "
                     + "States only. A restriction shows on the route in magenta with a bar "
                     + "under a floor, over a ceiling, or both for a single altitude. The "
                     + "cycle before is deleted when a new one lands.")
                    .font(.ngSmall)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Startup") {
                Toggle("Reopen the last chart on launch", isOn: $browser.restoreLastChart)
                Toggle("Install updates on launch", isOn: $updater.checkOnLaunch)
                Toggle("File charts waiting in Downloads", isOn: $importer.importOnLaunch)
                Text("Charts saved as KMKE/AGC.png, or KMKE AGC.png, are moved into the "
                     + "matching airport folder. One you already have is replaced by the new "
                     + "download, and the old one goes to the Trash.")
                    .font(.ngSmall)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("A newer release is fetched and installed when the app opens, and it "
                     + "reopens on the new version. Turn this off and Check for Updates in "
                     + "the Chartdesk menu still asks first. Updating uses the GitHub CLI, "
                     + "because the repository is private.")
                    .font(.ngSmall)
                    .foregroundStyle(.secondary)
            }

            Section("SimBrief") {
                TextField("Username or pilot ID", text: $flight.account)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Toggle("Load the latest flight on launch", isOn: $flight.fetchOnLaunch)
                    Spacer()
                    if flight.isFetching {
                        ProgressView().progressViewStyle(.circular).controlSize(.small)
                    } else {
                        Button("Load Now") { flight.refresh() }
                            .disabled(!flight.hasAccount)
                    }
                }
                if let problem = flight.problem {
                    Text(problem)
                        .font(.ngSmall)
                        .foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let plan = flight.plan {
                    HStack {
                        Text("\(plan.title) · \(plan.airfields.count) airports")
                            .font(.ngSmall)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Clear") { flight.clear() }
                    }
                } else {
                    Text("Your flight's airports appear at the top of the sidebar. Nothing is written to your chart folder.")
                        .font(.ngSmall)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Toolbar") {
                HStack {
                    Text("Add, remove or rearrange the buttons above the chart.")
                        .font(.ng(.callout))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Customize…") { ToolbarCustomization.present() }
                }
            }

            Section("Stored Corrections") {
                HStack {
                    Text("\(library.categoryOverrides.count) charts moved by hand · \(library.pinnedIDs.count) pinned")
                        .font(.ng(.callout))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                HStack {
                    Button("Reset Categories") { library.clearCategoryOverrides() }
                        .disabled(library.categoryOverrides.isEmpty)
                    Button("Clear Pins") { library.clearPins() }
                        .disabled(library.pinnedIDs.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ViewingSettingsView: View {

    @EnvironmentObject private var browser: BrowserState
    @Bindable private var typeface = Typeface.shared

    var body: some View {
        Form {
            Section("Opening a Chart") {
                Toggle("Zoom to fit the window", isOn: $browser.zoomToFitOnOpen)
                Text("When this is off, charts open at full size with the top of the plate in view.")
                    .font(.ngSmall)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Canvas") {
                Picker("Background behind charts", selection: $browser.canvasBackground) {
                    ForEach(CanvasBackground.allCases) { background in
                        Text(background.displayName).tag(background)
                    }
                }
                Text("Chart Navy matches the rest of the app.")
                    .font(.ngSmall)
                    .foregroundStyle(.secondary)
            }

            Section("Typeface") {
                Toggle("Use B612 Mono", isOn: $typeface.usesB612Mono)
                    .disabled(!Typeface.isInstalled)
                // In B612 Mono whichever is on, so it can be seen before it is chosen.
                Text("KBOS  ILS RWY 22L  110.30  FL370  M0.78")
                    .font(.custom(Typeface.regular, fixedSize: 13 * Typeface.scale))
                    .foregroundStyle(Color.ngAccentText)
                Text(Typeface.isInstalled
                     ? "The typeface Airbus drew for its cockpit displays, in its monospaced "
                       + "cut, so a briefing or a METAR keeps its columns. The map's labels "
                       + "and the briefing follow it too; menus and window titles stay in the "
                       + "system font."
                     : "B612 Mono is missing from this copy of Chartdesk.")
                    .font(.ngSmall)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

private struct MarkupSettingsView: View {

    @EnvironmentObject private var annotations: AnnotationStore

    var body: some View {
        Form {
            Section("New Marks") {
                Picker("Tool", selection: $annotations.tool) {
                    ForEach(AnnotationTool.drawing) { tool in
                        Text(tool.displayName).tag(tool)
                    }
                }
                Picker("Colour", selection: $annotations.color) {
                    ForEach(AnnotationColor.allCases) { color in
                        Text(color.displayName).tag(color)
                    }
                }
                Picker("Weight", selection: $annotations.width) {
                    ForEach(AnnotationWidth.allCases) { width in
                        Text(width.displayName).tag(width)
                    }
                }
                Text("Weights are set as a share of the chart's width, so the same choice looks equally thick on a small plate and a large one.")
                    .font(.ngSmall)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Showing Marks") {
                Toggle("Draw marks over charts", isOn: $annotations.showMarks)
                Text("Turning this off hides every mark and leaves them out of copies, exports and printouts. Nothing is deleted.")
                    .font(.ngSmall)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Stored Marks") {
                HStack {
                    Text(summary)
                        .font(.ng(.callout))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                HStack {
                    Button("Clear All Marks") { annotations.clearAll() }
                        .disabled(annotations.totalCount == 0)
                    Spacer()
                }
                Text("Marks live in ~/Library/Application Support/Chartdesk/annotations.json. Your chart files are never written to.")
                    .font(.ngSmall)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var summary: String {
        let total = annotations.totalCount
        guard total > 0 else { return "No marks yet" }
        let charts = annotations.chartCount
        return "\(total) \(total == 1 ? "mark" : "marks") on \(charts) \(charts == 1 ? "chart" : "charts")"
    }
}
