import Foundation
import simd

/// Picking two points on an airport and finding the way between them.
///
/// This existed once before and was taken out for 1.0, because the route had to be drawn
/// onto a scanned plate and the plate had to be dragged into alignment with the ground by
/// hand. That is not how it works now: the layout is on the map, in the same coordinates as
/// everything else, so there is nothing to line up. What is left is the part that was always
/// worth having.
@MainActor
final class TaxiRouteStore: ObservableObject {

    static let shared = TaxiRouteStore()

    /// True while a click on the map means "route from here" rather than nothing.
    @Published var isPicking = false
    @Published private(set) var route: TaxiRoute?
    @Published private(set) var failure: String?
    /// The two ends, for drawing them before there is a route between them.
    @Published private(set) var from: SIMD3<Double>?
    @Published private(set) var to: SIMD3<Double>?
    /// Set when the field is mapped in pieces, which is worth saying out loud: a route that
    /// happens to be found across a broken network is still only as good as the network.
    @Published private(set) var doubt: String?

    /// Whose airport the picks belong to. A click at another field starts again.
    private(set) var icao: String?
    /// Built once each and kept: a network is a millisecond to build and nothing to hold.
    private var networks: [String: TaxiNetwork] = [:]

    func network(for layout: AirportLayout) -> TaxiNetwork {
        if let held = networks[layout.icao] { return held }
        let made = TaxiNetwork(layout)
        networks[layout.icao] = made
        return made
    }

    /// Takes a click.
    func pick(_ direction: SIMD3<Double>, on layout: AirportLayout) {
        if icao != layout.icao { reset() }
        icao = layout.icao
        let network = network(for: layout)

        guard !network.isEmpty, let node = network.nearest(to: direction) else {
            failure = "Nothing to taxi on there."
            return
        }
        let at = network.direction(of: node)

        // Two ends already, so this is the start of a new route.
        if from != nil, to != nil { reset(); icao = layout.icao }

        guard let start = from else {
            from = at
            failure = nil
            doubt = nil
            return
        }
        guard let first = network.nearest(to: start) else { reset(); return }
        to = at

        guard let found = network.route(from: first, to: node) else {
            route = nil
            failure = "No way between those two on what is mapped here."
            return
        }
        route = found
        failure = nil
        doubt = network.wholeness < 0.97
            ? String(format: "This field is mapped in pieces — %.0f%% of its taxiways join up, "
                             + "so there may be a better way than this one.",
                     network.wholeness * 100)
            : nil
    }

    func reset() {
        from = nil
        to = nil
        route = nil
        failure = nil
        doubt = nil
        icao = nil
    }

    /// Everything goes when the layouts do, because the networks were built from them.
    func forget() {
        networks.removeAll()
        reset()
    }
}
