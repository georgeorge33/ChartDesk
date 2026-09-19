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
    @ObservedObject private var base = BaseMapStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Layers")
                .font(.headline)

            section("Base map") {
                ForEach(BaseMap.allCases) { layer in
                    baseChoice(layer)
                }
                if browser.baseMap.isAppleMaps {
                    if let failure = base.failure {
                        Text("Apple Maps did not answer: \(failure)")
                            .font(.ngSmall)
                            .foregroundStyle(Color.ngWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Drawn from about 30° across and closer. Apple does not permit "
                             + "an app to keep its own copy, so this one needs the network "
                             + "every time — the drawn map stays underneath for when there "
                             + "is none.")
                            .font(.ngSmall)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Apple asks that its maps carry a link to who the data came from. The
                    // map itself carries the logo; this is the other half of it.
                    Link("Legal notices for Apple Maps", destination: BaseMap.legal)
                        .font(.ngSmall)
                }
            }

            Divider().overlay(Color.ngSeparator)

            section("Aeronautical") {
                switchRow("Airspace", on: $browser.showsAirspace,
                          detail: "Rings with their ceilings and floors, the way a chart "
                                + "draws them, from openAIP. Drawn from about 15° across, "
                                + "and only where a ring is big enough to read.")
                if browser.showsAirspace {
                    classes
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
            if openAIP.isInstalled, MapGeography.shared.airspace.isEmpty {
                MapGeography.shared.forgetAirspace()
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

    private func baseChoice(_ layer: BaseMap) -> some View {
        let picked = browser.baseMap == layer

        return Button {
            browser.baseMap = layer
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: picked ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(picked ? Color.ngAccentText : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(layer.name)
                            .font(.ngSmallMedium)
                            .foregroundStyle(.primary)
                        if layer.isAppleMaps {
                            Image(systemName: "apple.logo")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Text(layer.detail)
                        .font(.ngSmall)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Which classes are drawn, each chip in the colour that class is drawn in.
    ///
    /// Six switches rather than six rows: they are one decision, and a row apiece would push
    /// everything else off the bottom of the panel.
    private var classes: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                ForEach(AirspaceSwitch.allCases) { kind in
                    chip(kind)
                }
            }
            if openAIP.isInstalled {
                Text(openAIP.summary.map { "openAIP · " + $0 } ?? "openAIP")
                    .font(.ngSmall)
                    .foregroundStyle(.tertiary)
            } else {
                Text("No openAIP table on this Mac, so there is nothing to draw. Build one "
                     + "with Tools/make_openaip.py and your own free key; it goes in "
                     + "Application Support, not in the app.")
                    .font(.ngSmall)
                    .foregroundStyle(Color.ngWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 2)
    }

    private func chip(_ kind: AirspaceSwitch) -> some View {
        let on = browser.airspaceSwitches.contains(kind)
        let colour = Color(nsColor: Theme.airspace(kind.covers[0]))

        return Button {
            if on {
                browser.airspaceSwitches.remove(kind)
            } else {
                browser.airspaceSwitches.insert(kind)
            }
        } label: {
            Text(kind.label)
                .font(.ngSmallMedium)
                .foregroundStyle(on ? colour : Color.secondary)
                .frame(minWidth: kind == .areas ? 44 : 24)
                .padding(.vertical, 3)
                .padding(.horizontal, 5)
                .background(on ? colour.opacity(0.16) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(on ? colour.opacity(0.6) : Color.ngSeparator)
                }
        }
        .buttonStyle(.plain)
        .help(kind.name)
    }
}
