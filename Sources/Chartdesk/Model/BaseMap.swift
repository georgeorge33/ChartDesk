import AppKit
import Foundation
import MapKit
import simd

/// What the map draws underneath everything else.
///
/// Drawn geography is the default and always will be: it is the only one that works with the
/// network off, which is most of the point of this app. The other two are Apple Maps, by way
/// of `MKMapSnapshotter` — no key, no account, and Apple carries the licensing of the
/// imagery itself. What they cost is the network: Apple does not permit an app to keep its
/// own copy of map imagery, so unlike the coastline these cannot be built once and kept.
enum BaseMap: String, CaseIterable, Identifiable {

    /// Natural Earth and OpenStreetMap, drawn as shapes. Works on a plane.
    case vector
    /// Apple's own map: roads, places and relief, rendered by MapKit.
    case appleMap
    /// Apple's imagery.
    case satellite

    var id: String { rawValue }

    /// Where a layer comes from.
    enum Source {
        /// Drawn from the tables in the app.
        case drawn
        /// Drawn by MapKit, in a map view of its own under everything else.
        case appleMaps
    }

    var source: Source {
        switch self {
        case .vector: return .drawn
        case .appleMap: return .appleMaps
        case .satellite: return .appleMaps
        }
    }

    var name: String {
        switch self {
        case .vector: return "Drawn"
        case .appleMap: return "Map"
        case .satellite: return "Satellite"
        }
    }

    var detail: String {
        switch self {
        case .vector:
            return "Coastline, lakes and borders, drawn from the tables in the app. Always "
                 + "there, network or no network."
        case .appleMap:
            return "Apple's own map, with roads, place names and shaded relief. Needs the "
                 + "network every time — Apple does not permit an app to keep a copy."
        case .satellite:
            return "Apple Maps imagery. Needs the network every time — Apple does not "
                 + "permit an app to keep a copy."
        }
    }

    /// True for the one whose tiles come from Apple, which changes what must be credited
    /// and what may be kept.
    var isAppleMaps: Bool {
        if case .appleMaps = source { return true }
        return false
    }

    var needsNetwork: Bool {
        if case .drawn = source { return false }
        return true
    }

    /// Shown on the map whenever the layer is drawn, because both of these ask for it.
    var attribution: [String] {
        switch self {
        case .vector: return []
        case .appleMap: return ["Apple Maps"]
        case .satellite: return ["Apple Maps"]
        }
    }

    @MainActor
    var configuration: MKMapConfiguration? {
        switch self {
        case .vector: return nil
        // Realistic elevation is what puts the hills in it; flat would be the road map.
        case .appleMap: return MKStandardMapConfiguration(elevationStyle: .realistic)
        case .satellite: return MKImageryMapConfiguration(elevationStyle: .flat)
        }
    }

    /// Where to read the notices for whatever this layer is made of.
    var legal: URL? {
        switch self {
        case .vector: return nil
        case .appleMap:
            return URL(string: "https://gspe21-ssl.ls.apple.com/html/attribution.html")
        case .satellite: return URL(string: "https://gspe21-ssl.ls.apple.com/html/attribution.html")
        }
    }

    /// Apple asks that its maps be credited where they are shown, and that the credit not be
    /// obscured. `MKMapView` draws this for you; a snapshot is a bare image, so the map draws
    /// it in the corner with the others.
    static let appleAttribution = "Apple Maps"

    /// How much to take off a base map before the overlays go over it.
    ///
    /// Imagery is made to be looked at on its own, and airspace over a bright aerial photo
    /// is two things competing; a third off puts it behind the chart without turning it
    /// into a silhouette. Apple's own map needs far less: it is drawn dark to begin with,
    /// and taking a third off that as well leaves a faint suggestion of roads.
    var dimming: Double {
        switch self {
        case .vector: return 0
        // Apple's map is drawn dark already, and taking a third off it as well leaves a
        // sheet with a faint suggestion of roads on it.
        case .appleMap: return 0.12
        case .satellite: return 0.32
        }
    }

    /// Beyond this the raster base is not drawn at all.
    ///
    /// Tiles are Mercator, which has no north pole and stretches without limit towards it; a
    /// hemisphere's worth of it is not a thing that can be asked for. Past about thirty
    /// degrees across the drawn map takes over — which is also where a base map stops
    /// telling you anything a coastline does not.
    static let widest: Double = 30
}
