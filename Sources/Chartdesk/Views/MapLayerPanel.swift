import SwiftUI

/// What the Layers button opens.
///
/// One section so far — where the coastline comes from. Written as a list of sections rather
/// than as a single picker because the next things that belong on a map like this are each a
/// layer with its own switch: airspace, procedures, terrain, the winds aloft. A button called
/// Layers ought to be able to grow those without turning into a different button.
struct MapLayerPanel: View {

    @EnvironmentObject private var browser: BrowserState
    @ObservedObject private var coastline = CoastlineStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Layers")
                .font(.headline)

            section("Aeronautical") {
                switchRow("Airspace", on: $browser.showsAirspace,
                          detail: "Class B, C and D with their ceilings and floors, from the "
                                + "FAA. Thorough over the United States, thinner elsewhere. "
                                + "Drawn from about 15° across.")
            }

            Divider().overlay(Color.ngSeparator)

            section("Places") {
                switchRow("State borders", on: $browser.showsStateBorders,
                          detail: "States, provinces and counties.")
                switchRow("Town and city names", on: $browser.showsCityNames,
                          detail: "As many as there is room for, the largest first.")
            }

            Divider().overlay(Color.ngSeparator)

            section("Coastline") {
                ForEach(CoastlineSource.allCases) { source in
                    choice(source)
                }
            }

            Divider().overlay(Color.ngSeparator)

            Text("Lakes and borders stay Natural Earth whichever coastline is picked: "
                 + "OpenStreetMap's download is the coast and nothing else.")
                .font(.ngSmall)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 340)
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

    private func choice(_ source: CoastlineSource) -> some View {
        let available = !source.needsCoastlineOnDisk || coastline.isInstalled
        let picked = browser.coastline == source

        return Button {
            browser.coastline = source
            if source.needsCoastlineOnDisk { coastline.load() }
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

                    // ODbL asks for this wherever the data is shown, and the panel is where
                    // the choice is made.
                    if let credit = source.attribution {
                        Text(credit + " · ODbL")
                            .font(.ngSmall)
                            .foregroundStyle(.tertiary)
                    }
                    if source.needsCoastlineOnDisk, !coastline.isInstalled {
                        Text("Not on this Mac. Build it with Tools/make_coastline.py; "
                             + "it goes in Application Support, not in the app.")
                            .font(.ngSmall)
                            .foregroundStyle(Color.ngWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .opacity(available ? 1 : 0.55)
    }
}
