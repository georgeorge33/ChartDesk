import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            ViewingSettingsView()
                .tabItem { Label("Viewing", systemImage: "eye") }
        }
        .frame(width: 520, height: 340)
    }
}

private struct GeneralSettingsView: View {

    @EnvironmentObject private var library: ChartLibrary
    @EnvironmentObject private var browser: BrowserState
    @EnvironmentObject private var updater: UpdateController

    var body: some View {
        Form {
            Section("Chart Library") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(library.hasLibrary ? library.folderPath : "No folder chosen yet")
                        .font(.callout)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .foregroundStyle(library.hasLibrary ? Color.primary : Color.secondary)
                    Text("\(library.chartCount) charts · \(library.airports.count) airports")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

            Section("Startup") {
                Toggle("Reopen the last chart on launch", isOn: $browser.restoreLastChart)
                Toggle("Check for updates on launch", isOn: $updater.checkOnLaunch)
                Text("Updating uses the GitHub CLI, because the repository is private.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Stored Corrections") {
                HStack {
                    Text("\(library.categoryOverrides.count) charts moved by hand · \(library.pinnedIDs.count) pinned")
                        .font(.callout)
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

    var body: some View {
        Form {
            Section("Opening a Chart") {
                Toggle("Zoom to fit the window", isOn: $browser.zoomToFitOnOpen)
                Text("When this is off, charts open at full size with the top of the plate in view.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Night Mode") {
                Toggle("Remove colour when inverted", isOn: $browser.desaturateNight)
                Text("Inverting a chart also flips its colours, so blues turn orange. Removing colour keeps an inverted chart looking like a plain negative.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Canvas") {
                Picker("Background behind charts", selection: $browser.canvasBackground) {
                    ForEach(CanvasBackground.allCases) { background in
                        Text(background.displayName).tag(background)
                    }
                }
                Text("Chart Navy matches the rest of the app. Night mode always uses a dark background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
