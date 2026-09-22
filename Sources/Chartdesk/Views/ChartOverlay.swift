import AppKit
import MapKit
import SwiftUI

/// The chart layers, drawn by MapKit rather than over it.
///
/// A canvas laid on top of a map view can only ever follow it. MapKit draws, the delegate
/// reports the new rectangle, SwiftUI schedules a redraw, and the chart arrives a frame
/// later — which at a kilometre across is the taxiway sitting off the tarmac for as long as
/// your hand is moving. Nothing tunes that away, because the two are rendered on separate
/// timetables.
///
/// An overlay renderer is on MapKit's timetable. It is handed the same transform the base
/// is drawn with, in the same pass, so the two cannot come apart: the taxiway is welded to
/// the photograph rather than aimed at it.
///
/// Drawing happens in `MKMapPoint`, which for an overlay bounding the world is exactly the
/// renderer's own coordinate space — checked against a real renderer, `point(for:)` is the
/// identity. So the shapes are built by the same code as before and MapKit owns every
/// transform after that.
final class ChartOverlay: NSObject, MKOverlay {
    var coordinate: CLLocationCoordinate2D {
        MKMapPoint(x: MKMapRect.world.midX, y: MKMapRect.world.midY).coordinate
    }
    /// The whole world: the chart has something to say almost anywhere.
    var boundingMapRect: MKMapRect { .world }
}

/// What the renderer needs to know to draw a frame. Handed over whole rather than read
/// piecemeal, because it is read from MapKit's thread and the view's state is not.
struct ChartFrame {
    var layouts: [AirportLayout] = []
    var showsGroundLayout = false
    /// Stands are hundreds of numbers at a big field, and only worth the room at the very
    /// closest zooms.
    var showsStands = false

    /// What would make the drawing different. Compared instead of the layouts themselves,
    /// which are thousands of points each and are only ever swapped whole.
    var stamp: String {
        "\(showsGroundLayout)\(showsStands)"
            + layouts.map(\.icao).joined(separator: ",")
    }
}

final class ChartRenderer: MKOverlayRenderer {

    /// Everything the drawing reads. Replaced wholesale, then the renderer is told to
    /// redraw; never mutated while a draw is in flight.
    var frame = ChartFrame() {
        didSet { setNeedsDisplay() }
    }

    /// How many map points go to one point on the screen, as the map view is actually
    /// showing it.
    ///
    /// Not `1 / zoomScale`, which is what an overlay renderer is handed and which is
    /// quantised to powers of two: MapKit rasterises a tile at the level below and scales
    /// the result up until the next level is reached. A line asked to be two points thick
    /// therefore grew to nearly four before snapping back, and so did the writing, which
    /// is what made the letters breathe with the zoom. The map view is asked for the real
    /// figure instead, and the drawing is sized by that.
    ///
    /// Snapped to a per cent by whoever sets it, so that the frame's writing is not thrown
    /// away and worked out again over a hair of movement.
    var page: Double = 0 {
        didSet { if page != oldValue { setNeedsDisplay() } }
    }

    /// The last settled writing, and the lock over it: tiles are drawn on MapKit's own
    /// queue, and more than one of them at a time.
    private var decided: (key: String, writing: [Placed])?
    private let settled = NSLock()

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard frame.showsGroundLayout, !frame.layouts.isEmpty else { return }
        // Map points to the screen point: what a line width has to be divided by to come
        // out the same thickness however far in you are.
        let scale = page > 0 ? page : 1 / Double(zoomScale)
        let chart = ChartContext(cg: context, mapPointsPerScreenPoint: scale)
        let sheet = MapSheet(mapRect: mapRect, padding: 64 * scale)

        for layout in frame.layouts where sheet.mayShow(layout.cap) {
            ground(layout, in: chart, sheet: sheet)
        }

        // Last, so that it goes over every airport's tarmac rather than each field's
        // writing being buried by the next field's concrete.
        for placed in writing(at: scale, in: chart)
        where sheet.panel.intersects(placed.room) {
            if let label = placed.label { chart.draw(label) }
        }
    }

    /// A label and the room it was given, both in map points.
    private struct Placed {
        /// Nothing, for a reservation: room something else already fills — a runway's
        /// painted number — that no label may be put on top of.
        var label: ChartContext.Label?
        var room: CGRect

        /// Whether this one leaves no space for another: either they overlap, or they say
        /// the same thing too close together to be telling you anything twice.
        func crowds(_ other: ChartContext.Label, room space: CGRect, within apart: Double)
        -> Bool {
            if room.intersects(space) { return true }
            guard let label, label.text == other.text else { return false }
            return hypot(label.at.x - other.at.x, label.at.y - other.at.y) < apart
        }
    }

    /// Every label that won its space, settled once for the whole frame.
    ///
    /// MapKit draws an overlay in tiles — a dozen calls to `draw` for one view — so a
    /// declutter that starts empty in each of them is not one decision but twelve. A
    /// designator that loses its space in one tile and wins it in the next is drawn as half
    /// a designator, and two labels either side of a seam never see each other at all.
    ///
    /// Where the writing goes does not depend on the tile. Labels sit at map points, and
    /// only their size on the page changes with the scale, so panning cannot move them
    /// relative to one another: the answer is the same for every tile at a given zoom, and
    /// worth keeping until the zoom or the layouts change.
    private func writing(at scale: Double, in chart: ChartContext) -> [Placed] {
        let key = "\(frame.stamp)|\(scale)"
        settled.lock()
        defer { settled.unlock() }
        if let decided, decided.key == key { return decided.writing }

        // The whole world, because a tile's own rectangle is the thing being avoided here.
        let sheet = MapSheet(mapRect: .world, padding: 0)
        var found: [ChartContext.Label] = []
        var painted: [CGRect] = []
        for layout in frame.layouts {
            writing(layout, in: sheet, chart: chart, into: &found, painted: &painted)
        }

        var placed: [Placed] = painted.map { Placed(label: nil, room: $0) }
        let air = 2 * scale
        // How far apart two of the same letter have to be. A designator repeated along its
        // own taxiway is how a ground chart reads; three of them inside a hundred metres is
        // not. OpenStreetMap splits one taxiway into as many ways as its tags change, and
        // each of those pieces was asking for its own letter.
        let apart = chart.screen(160)
        for label in found {
            let room = chart.bounds(of: label).insetBy(dx: -air, dy: -air)
            guard !placed.contains(where: { $0.crowds(label, room: room, within: apart) })
            else { continue }
            placed.append(Placed(label: label, room: room))
        }
        decided = (key, placed)
        return placed
    }

    /// The writing on the ground: taxiway designators, runway numbers at the ends they
    /// belong to, the holding positions, and the stands closest in.
    ///
    /// In here with the tarmac rather than on the canvas above it, because a designator
    /// that lags the taxiway it names is worse than no designator — it is a label pointing
    /// at the wrong piece of concrete.
    private func writing(_ layout: AirportLayout, in sheet: MapSheet, chart: ChartContext,
                         into found: inout [ChartContext.Label],
                         painted: inout [CGRect]) {
        for way in layout.taxiways where !way.ref.isEmpty && way.isMovementArea {
            guard let at = middle(of: way, sheet: sheet) else { continue }
            found.append(ChartContext.Label(text: AirportLayout.designator(way.ref),
                                            colour: Theme.taxiLine, box: .black,
                                            border: Theme.taxiLine, at: at))
        }
        // Each runway number once: painted on the runway when it is big enough to read
        // there, and in a label at the threshold when it is not. Both would be the same
        // figures twice, a few metres apart.
        let metre = Self.mapPointsPerMetre(at: layout)
        for way in layout.runways where !way.ref.isEmpty {
            var paintedHere = Set<String>()
            for name in way.names {
                let height = name.height * metre
                guard chart.paintedHeight(inMapPoints: height) >= Self.paintedFrom else {
                    continue
                }
                let centre = sheet.projection.point(name.centre)
                let ahead = sheet.projection.point(name.ahead)
                painted.append(chart.paintedBounds(
                    name.text, centre: centre,
                    facing: CGVector(dx: ahead.x - centre.x, dy: ahead.y - centre.y),
                    capHeight: height))
                paintedHere.insert(name.text)
            }
            for (number, at) in AirportLayout.numbers(of: way)
            where !paintedHere.contains(number) {
                found.append(ChartContext.Label(text: number, colour: .white,
                                                box: NSColor.black.withAlphaComponent(0.85),
                                                border: NSColor.white.withAlphaComponent(0.7),
                                                at: sheet.projection.point(at)))
            }
        }
        for hold in layout.holds where !hold.ref.isEmpty {
            found.append(ChartContext.Label(text: hold.ref, colour: Theme.holdShort,
                                            box: .black, border: Theme.holdShort,
                                            at: sheet.projection.point(hold.direction)))
        }
        guard frame.showsStands else { return }
        for stand in layout.stands where !stand.ref.isEmpty {
            found.append(ChartContext.Label(text: stand.ref, size: 9, bold: false,
                                            colour: Theme.stand,
                                            box: NSColor.black.withAlphaComponent(0.8),
                                            at: sheet.projection.point(stand.direction)))
        }
    }

    /// The middle of a way, where its letter goes.
    private func middle(of way: AirportLayout.Way, sheet: MapSheet) -> CGPoint? {
        guard !way.directions.isEmpty else { return nil }
        return sheet.projection.point(way.directions[way.directions.count / 2])
    }

    /// Metres into map points, at this airport's latitude and not at the equator.
    /// Mercator stretches by 1/cos φ, so the equator's figure would draw Boston's taxiways
    /// a quarter narrower than they are and Svalbard's at half.
    private static func mapPointsPerMetre(at layout: AirportLayout) -> Double {
        let latitude = Coordinate(layout.frame.centre).latitude * .pi / 180
        return MKMapSize.world.width / (40_075_017 * max(cos(latitude), 0.02))
    }

    /// How tall a runway's painted number has to be on the screen, in points, before it
    /// is painted on the runway. Below this the figures are a smudge on the threshold, and
    /// the number goes in a label beside the runway instead.
    private static let paintedFrom: Double = 7

    /// The airport's own ground, in map points.
    private func ground(_ layout: AirportLayout, in chart: ChartContext, sheet: MapSheet) {
        let metre = Self.mapPointsPerMetre(at: layout)
        let wide = { (metres: Double) in metres * metre }

        // The taxiways get only their paint: both base maps are Apple's and both already
        // have the taxiway tarmac in the picture. The aprons and the taxiway pavement are
        // still parsed and still cached, and simply not filled.
        //
        // The runway is different, and is drawn the way a ground chart draws it: a solid
        // dark band the full width of the concrete, and on it, in white, the piano keys,
        // the touchdown zone and the aiming point, the broken centreline and each end's
        // number across the threshold. Everything painted is in metres, because it is
        // paint and should grow with the ground; the lines that are there to be seen
        // rather than to be to scale stay the same on the screen however far in you are.
        for way in layout.runways where sheet.mayShow(way.cap) {
            if way.edges.count == 2 {
                let outline = way.edges[0] + way.edges[1].reversed()
                chart.fill(sheet.path(ring: MapShape(directions: outline, cap: way.cap)),
                           Theme.runwaySurface)
                // A hairline at the edge, faint. Over a light photograph the band's own
                // edge is enough; over Apple's dark map it is not, quite.
                for edge in way.edges {
                    chart.stroke(sheet.path(straight: edge),
                                 Theme.runwayMarking.withAlphaComponent(0.35),
                                 width: chart.screen(1))
                }
            }
            for bar in way.keys {
                chart.stroke(sheet.path(straight: bar), Theme.runwayMarking, width: wide(2.5),
                             cap: .butt)
            }
            for zone in way.zones {
                chart.stroke(sheet.path(straight: zone.line), Theme.runwayMarking,
                             width: wide(zone.width), cap: .butt)
            }
        }

        let line = chart.screen(2.2)
        for way in layout.taxiways where way.isMovementArea && sheet.mayShow(way.cap) {
            chart.stroke(sheet.path(curve: way.directions), Theme.taxiLine,
                         width: line, cap: .round, join: .round)
        }
        for way in layout.runways where sheet.mayShow(way.cap) {
            // Thirty-six metres of paint and twenty-four of gap, which is the FAA's 120ft
            // and 80ft; narrower than a taxiway line, the way the reference draws it.
            chart.stroke(sheet.path(straight: way.centreline), Theme.runwayMarking,
                         width: chart.screen(1.6), dash: [wide(36), wide(24)])
            for name in way.names {
                let height = wide(name.height)
                guard chart.paintedHeight(inMapPoints: height) >= Self.paintedFrom else {
                    continue
                }
                let centre = sheet.projection.point(name.centre)
                let ahead = sheet.projection.point(name.ahead)
                chart.paint(name.text, centre: centre,
                            facing: CGVector(dx: ahead.x - centre.x, dy: ahead.y - centre.y),
                            capHeight: height, colour: Theme.runwayMarking)
            }
        }
        for hold in layout.holds where hold.across.count == 2 {
            chart.stroke(sheet.path(line: hold.across), Theme.holdShort,
                         width: line * 1.6, cap: .butt)
        }
    }
}
