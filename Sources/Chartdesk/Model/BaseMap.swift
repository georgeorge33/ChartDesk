import AppKit
import Foundation
import MapKit

/// What the map draws underneath everything else.
///
/// Both are Apple's, by way of MapKit: no key, no account, and Apple carries the licensing
/// of the imagery itself. What they cost is the network — Apple does not permit an app to
/// keep its own copy of what it draws, so the base map is the one part of this app that
/// needs a connection. The charts in your library do not, which is the part that matters
/// at the aeroplane.
///
/// There was a third, drawn from Natural Earth and OpenStreetMap tables in the app, and it
/// was the one that worked offline. It went when MapKit took over the panning: a drawn map
/// still needed a map view underneath to pan against, so it was fetching tiles nobody could
/// see, and the offline promise was already broken.
enum BaseMap: String, CaseIterable, Identifiable {

    /// Apple's own map: roads, places and relief, rendered by MapKit.
    case appleMap
    /// Apple's imagery.
    case satellite

    var id: String { rawValue }

    var name: String {
        switch self {
        case .appleMap: return "Map"
        case .satellite: return "Satellite"
        }
    }

    var detail: String {
        switch self {
        case .appleMap:
            return "Roads, place names and shaded relief, drawn by MapKit itself, which is "
                 + "why it pans and zooms the way the Maps app does."
        case .satellite:
            return "Apple Maps imagery, with the frontiers, state lines and town names "
                 + "drawn over it — a photograph has none of those."
        }
    }

    /// Shown on the map whenever it is drawn, because Apple asks to be credited where its
    /// maps are shown and asks that the credit not be obscured.
    var attribution: [String] { [Self.appleAttribution] }

    static let appleAttribution = "Apple Maps"

    @MainActor
    var configuration: MKMapConfiguration {
        switch self {
        // Flat, both of them, and not for looks. `.realistic` is what the old
        // `satelliteFlyover` and `hybridFlyover` map types became — the 3D modes, the ones
        // that curve into a globe when you zoom out. That is a lovely map and a hopeless
        // one to draw over: `MKMapPoint` is Mercator whatever the view is doing, so the
        // moment MapKit stops being flat the airspace stops being where the airspace is.
        case .appleMap: return MKStandardMapConfiguration(elevationStyle: .flat)
        case .satellite: return MKImageryMapConfiguration(elevationStyle: .flat)
        }
    }

    /// Where to read the notices for what this is made of.
    var legal: URL? {
        URL(string: "https://gspe21-ssl.ls.apple.com/html/attribution.html")
    }

    /// How much to take off the base before the overlays go over it.
    ///
    /// Imagery is made to be looked at on its own, and airspace over a bright aerial photo
    /// is two things competing; a third off puts it behind the chart without turning it
    /// into a silhouette. Apple's own map needs far less: it is drawn dark to begin with,
    /// and taking a third off that as well leaves a faint suggestion of roads.
    var dimming: Double {
        switch self {
        case .appleMap: return 0.12
        case .satellite: return 0.32
        }
    }
}
