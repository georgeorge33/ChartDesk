import SwiftUI

/// What the Layers button opens.
///
/// Two sections so far — what is drawn over the geography, and what is named on it — with a
/// note about the geography itself. Written as a list of sections rather than as a single
/// picker because the next things that belong on a map like this are each a layer with its
/// own switch: procedures, terrain, the winds aloft. A button called Layers ought to be able
/// to grow those without turning into a different button.
struct MapLayerPanel: View {

    @EnvironmentObject private var browser: BrowserState
    @ObservedObject private var coastline = CoastlineStore.shared
    @ObservedObject private var openAIP = OpenAIPStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Layers")
                .font(.headline)

            section("Aeronautical") {
                switchRow("Airspace", on: $browser.showsAirspace,
                          detail: "Rings with their ceilings and floors, the way a chart "
                                + "draws them. Drawn from about 15° across.")
                if browser.showsAirspace {
                    ForEach(AirspaceSource.allCases) { source in
                        airspaceChoice(source)
                    }
                }
            }

            Divider().overlay(Color.ngSeparator)

            section("Places") {
                switchRow("State borders", on: $browser.showsStateBorders,
                          detail: "States, provinces and counties.")
                switchRow("Town and city names", on: $browser.showsCityNames,
                          detail: "As many as there is room for, the largest first.")
            }

            Divider().overlay(Color.ngSeparator)

            // No choice of coastline any more, but it still has to say whose it is and it
            // still has to say when the detailed half of it is missing.
            VStack(alignment: .leading, spacing: 4) {
                Text("The coast is OpenStreetMap's: simplified in the app, and in full from "
                     + "about 5° across where the full table is on this Mac. Lakes and "
                     + "borders stay Natural Earth — OpenStreetMap's download is the coast "
                     + "and nothing else.")
                    .font(.ngSmall)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Coastline.attribution + " · " + Coastline.licence)
                    .font(.ngSmall)
                    .foregroundStyle(.tertiary)
                if !coastline.isInstalled {
                    Text("The full coastline is not on this Mac, so the simplified one draws "
                         + "all the way in. Build it with Tools/make_coastline.py.")
                        .font(.ngSmall)
                        .foregroundStyle(Color.ngWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(width: 340)
        // A table built while the app was running should turn the choice on without a
        // relaunch, and opening this panel is when anyone would look for it.
        .onAppear {
            openAIP.refresh()
            // The read that found nothing is what would otherwise stick: without this,
            // building the table meant quitting the app to see it.
            if openAIP.isInstalled, MapGeography.shared.airspace(from: .openAIP).isEmpty {
                MapGeography.shared.forgetAirspace(.openAIP)
            }
        }
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.ngSmallMedium)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func switchRow(_ title: String, on: Binding<Bool>,
                           detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: on)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.ngSmallMedium)
            Text(detail)
                .font(.ngSmall)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 2)
    }

    /// Where the airspace comes from. Shown only while the layer is on: a source for a
    /// layer you have switched off is a setting for nothing.
    private func airspaceChoice(_ source: AirspaceSource) -> some View {
        let available = !source.needsTableOnDisk || openAIP.isInstalled
        let picked = browser.airspaceSource == source

        return Button {
            browser.airspaceSource = source
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: picked ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(picked ? Color.ngAccentText : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name)
                        .font(.ngSmallMedium)
                        .foregroundStyle(.primary)
                    Text(source.detail)
                        .font(.ngSmall)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let credit = source.attribution {
                        Text(credit + (source.licence.map { " · " + $0 } ?? ""))
                            .font(.ngSmall)
                            .foregroundStyle(.tertiary)
                    }
                    if source.needsTableOnDisk {
                        if let summary = openAIP.summary {
                            // Airspace goes stale, so how old the table is belongs next to
                            // the choice rather than in a README no one opens.
                            Text("On this Mac · " + summary)
                                .font(.ngSmall)
                                .foregroundStyle(.tertiary)
                        } else {
                            Text("Not on this Mac, so the FAA's table is being drawn "
                                 + "instead. Build it with Tools/make_openaip.py and your "
                                 + "own openAIP key; it goes in Application Support, not "
                                 + "in the app.")
                                .font(.ngSmall)
                                .foregroundStyle(Color.ngWarning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.55)
        .padding(.leading, 2)
    }
}
