import SwiftUI

struct SidebarView: View {

    @EnvironmentObject private var library: ChartLibrary
    @EnvironmentObject private var browser: BrowserState

    private var trimmedQuery: String {
        browser.airportQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredAirports: [Airport] {
        guard !trimmedQuery.isEmpty else { return library.airports }
        return library.airports.filter { $0.searchText.localizedCaseInsensitiveContains(trimmedQuery) }
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

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
            Text(library.folderName)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(library.folderPath)
            Spacer(minLength: 0)

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
