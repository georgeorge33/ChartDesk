import CoreGraphics
import Foundation
import simd

// The layers that go over the geography: airspace, internal borders, and the names of towns.
// Each is read only when it is switched on, and each is a table built by Tools/.

/// A class of controlled airspace, as a chart draws it.
enum AirspaceClass: String, CaseIterable {
    case b = "B"
    case c = "C"
    case d = "D"

    var name: String {
        switch self {
        case .b: return "Class B"
        case .c: return "Class C"
        case .d: return "Class D"
        }
    }
}

/// One shelf of controlled airspace: a ring, and what it reaches from and to.
///
/// A Class B is several of these — Boston's is four, stacked from the surface to 7,000ft —
/// which is why each carries its own ceiling and floor rather than the airport carrying one
/// pair. It is what lets the map label a ring the way a chart does.
struct MapAirspace {
    let klass: AirspaceClass
    let airport: String
    /// Feet above mean sea level.
    let ceiling: Int
    let floor: Int
    /// True where the floor is the ground rather than an altitude.
    let atSurface: Bool

    let directions: [SIMD3<Double>]
    let cap: SphericalCap

    /// Hundreds of feet, the way a chart writes it: 70 over 20, or 70 over SFC.
    var ceilingLabel: String { "\(ceiling / 100)" }
    var floorLabel: String { atSurface ? "SFC" : "\(floor / 100)" }

    /// Where to write the ceiling and floor.
    ///
    /// Not the middle of the ring. A Class B is several shelves about one airport, and every
    /// one of them has its middle over the runway — so labelling them there stacks four
    /// figures on one spot and a declutterer keeps one. Offset out towards each shelf's own
    /// edge instead, which spreads them the way a chart does, each figure sitting in the ring
    /// it belongs to.
    var labelAt: Coordinate {
        let middle = Coordinate(cap.centre)
        let out = cap.radius * 180 / .pi * 0.72
        return Coordinate(latitude: min(max(middle.latitude + out, -89), 89),
                          longitude: middle.longitude)
    }
}

/// A town or city, with Natural Earth's own sense of how important it is.
struct MapCity {
    /// 0 belongs on a world map, 10 on a local one.
    let rank: Int
    let coordinate: Coordinate
    let direction: SIMD3<Double>
    let name: String
}

extension WorldData {

    /// Class B, C and D airspace, from the FAA. United States only.
    nonisolated static func loadAirspace() -> [MapAirspace] {
        guard let url = Bundle.main.url(forResource: "airspace", withExtension: "txt"),
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
        else { return [] }
        return parseAirspace(data)
    }

    /// Kept apart from the reading so it can be checked against the table on disk, without a
    /// bundle to find it in.
    nonisolated static func parseAirspace(_ data: Data) -> [MapAirspace] {
        var out: [MapAirspace] = []
        out.reserveCapacity(4_500)

        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 5,
                  let klass = AirspaceClass(rawValue: String(fields[0])),
                  let ceiling = Int(fields[2])
            else { continue }

            let floorText = String(fields[3])
            let atSurface = floorText == "SFC"
            let floor = atSurface ? 0 : (Int(floorText) ?? 0)

            var directions: [SIMD3<Double>] = []
            let numbers = fields[4].split(separator: " ")
            var index = 0
            while index + 1 < numbers.count {
                if let longitude = Double(numbers[index]),
                   let latitude = Double(numbers[index + 1]) {
                    directions.append(Coordinate(latitude: latitude,
                                                 longitude: longitude).direction)
                }
                index += 2
            }
            guard directions.count >= 4 else { continue }

            out.append(MapAirspace(klass: klass,
                                   airport: String(fields[1]),
                                   ceiling: ceiling,
                                   floor: floor,
                                   atSurface: atSurface,
                                   directions: directions,
                                   cap: SphericalCap(directions)))
        }
        return out
    }

    /// Internal borders — states, provinces, counties — for every country.
    nonisolated static func loadStates() -> [MapShape] {
        shapes("states")
    }

    /// Towns and cities, in the order the tables put them: most important first.
    nonisolated static func loadCities() -> [MapCity] {
        guard let url = Bundle.main.url(forResource: "cities", withExtension: "txt"),
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe])
        else { return [] }
        return parseCities(data)
    }

    nonisolated static func parseCities(_ data: Data) -> [MapCity] {
        var out: [MapCity] = []
        out.reserveCapacity(7_500)
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
        where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 4,
                  let rank = Int(fields[0]),
                  let latitude = Double(fields[1]),
                  let longitude = Double(fields[2])
            else { continue }
            let coordinate = Coordinate(latitude: latitude, longitude: longitude)
            out.append(MapCity(rank: rank, coordinate: coordinate,
                               direction: coordinate.direction, name: String(fields[3])))
        }
        return out
    }
}

/// How much of each layer there is room for at a given zoom.
enum MapLayerRoom {

    /// Airspace is only worth drawing once a ring is more than a smudge. Below this it is a
    /// heap of overlapping circles with no labels legible on any of them.
    static let airspaceFrom: CGFloat = 20_000
    /// Internal borders clutter a view of a continent and place a view of a state.
    static let statesFrom: CGFloat = 6_000

    /// The least important town worth naming, on Natural Earth's own scale of 0 to 10.
    ///
    /// Drawn in rank order and decluttered, so this is a floor on the work rather than on what
    /// appears: a name that will not fit is dropped whatever its rank.
    static func cityRank(degreesAcross: Double) -> Int {
        switch degreesAcross {
        case 150...: return 0
        case 60..<150: return 1
        case 30..<60: return 2
        case 15..<30: return 4
        case 7..<15: return 6
        case 3..<7: return 7
        default: return 10
        }
    }
}
