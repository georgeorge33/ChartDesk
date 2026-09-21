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
    /// True over Apple's own map, where the tarmac is already in the picture.
    var overAppleMap = false

    /// What would make the drawing different. Compared instead of the layouts themselves,
    /// which are thousands of points each and are only ever swapped whole.
    var stamp: String {
        "\(showsGroundLayout)\(overAppleMap)" + layouts.map(\.icao).joined(separator: ",")
    }
}

final class ChartRenderer: MKOverlayRenderer {

    /// Everything the drawing reads. Replaced wholesale, then the renderer is told to
    /// redraw; never mutated while a draw is in flight.
    var frame = ChartFrame() {
        didSet { setNeedsDisplay() }
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard frame.showsGroundLayout, !frame.layouts.isEmpty else { return }
        // Map points to the screen point: what a line width has to be divided by to come
        // out the same thickness however far in you are.
        let scale = 1 / Double(zoomScale)
        let chart = ChartContext(cg: context, mapPointsPerScreenPoint: scale)
        let sheet = MapSheet(mapRect: mapRect, padding: 64 * scale)

        for layout in frame.layouts where sheet.mayShow(layout.cap) {
            ground(layout, in: chart, sheet: sheet)
        }
    }

    /// The airport's own ground, in map points.
    private func ground(_ layout: AirportLayout, in chart: ChartContext, sheet: MapSheet) {
        // Metres into map points, at this airport's latitude and not at the equator.
        // Mercator stretches by 1/cos φ, so the equator's figure would draw Boston's
        // taxiways a quarter narrower than they are and Svalbard's at half.
        let latitude = Coordinate(layout.frame.centre).latitude * .pi / 180
        let metre = MKMapSize.world.width / (40_075_017 * max(cos(latitude), 0.02))
        let wide = { (metres: Double) in metres * metre }

        if !frame.overAppleMap {
            for apron in layout.aprons where sheet.mayShow(apron.cap) {
                chart.fill(sheet.path(ring: MapShape(directions: apron.directions,
                                                     cap: apron.cap)), Theme.apron)
            }
            for slab in layout.pavement where sheet.mayShow(slab.cap) {
                let colour = slab.surface == .runway ? Theme.runwayAsphalt : Theme.taxiway
                chart.fill(sheet.path(ring: MapShape(directions: slab.directions,
                                                     cap: slab.cap)), colour)
            }
            for way in layout.taxiways
            where way.isMovementArea && !way.paved && sheet.mayShow(way.cap) {
                chart.stroke(sheet.path(curve: way.directions), Theme.taxiway,
                             width: wide(way.width), cap: .round, join: .round)
            }
        }

        for way in layout.runways where sheet.mayShow(way.cap) {
            if !frame.overAppleMap && !way.paved {
                chart.stroke(sheet.path(straight: way.directions), Theme.runwayAsphalt,
                             width: wide(way.width), cap: .butt)
            }
            for edge in way.edges {
                chart.stroke(sheet.path(straight: edge), Theme.runwayMarking.withAlphaComponent(0.85),
                             width: chart.screen(1))
            }
            for bar in way.keys {
                chart.stroke(sheet.path(straight: bar), Theme.runwayMarking, width: wide(2.5),
                             cap: .butt)
            }
        }

        let line = chart.screen(1.6)
        for way in layout.taxiways where way.isMovementArea && sheet.mayShow(way.cap) {
            chart.stroke(sheet.path(curve: way.directions), Theme.taxiLine,
                         width: line, cap: .round, join: .round)
        }
        for way in layout.runways where sheet.mayShow(way.cap) {
            chart.stroke(sheet.path(straight: way.directions), Theme.runwayMarking,
                         width: line, dash: [wide(30), wide(20)])
        }
        for hold in layout.holds where hold.across.count == 2 {
            chart.stroke(sheet.path(line: hold.across), Theme.holdShort,
                         width: line * 1.6, cap: .butt)
        }
    }
}
