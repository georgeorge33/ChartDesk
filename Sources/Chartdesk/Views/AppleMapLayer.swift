import AppKit
import MapKit
import SwiftUI

/// A real `MKMapView` under the chart layers.
///
/// This replaces a stack of machinery it is worth naming, because the reason for the change
/// is exactly what that machinery could not do. The map used to take *photographs* of
/// MapKit — `MKMapSnapshotter`, one bitmap per slippy tile, warped pixel by pixel onto an
/// orthographic globe. A snapshot is taken at one zoom and one place: move the camera and
/// every tile has to be asked for again, four at a time, about four tenths of a second
/// each, and until they land you are looking at a coarser tile magnified. That is the
/// pixelated sections, and no amount of tuning removes it, because the thing on screen is a
/// photograph of a map rather than a map.
///
/// A map view is the map. It is vector data drawn by MapKit continuously, at whatever
/// fractional zoom the gesture is passing through, with Apple's own refinement. So it owns
/// the panning and the zooming here, and everything else follows it: the delegate reports
/// the rectangle it is showing, and the chart layers are drawn over the top against that
/// same rectangle. Nothing has to be kept in step, because there is only one camera.
struct AppleMapLayer: NSViewRepresentable {

    /// Which of Apple's maps, or nothing to leave it blank for the drawn map.
    var configuration: MKMapConfiguration?
    /// Where the map is looking. Written when something other than a gesture moves it.
    @Binding var rect: MKMapRect
    /// Called whenever the user moves it, so the layers above can be redrawn.
    var moved: (MKMapRect) -> Void

    func makeNSView(context: Context) -> MKMapView {
        let view = MKMapView()
        view.delegate = context.coordinator
        view.showsCompass = false
        view.showsScale = false
        view.showsZoomControls = false
        view.showsPitchControl = false
        // Flat and north-up: the charts drawn over it are, and a tilted base under a
        // straight overlay is worse than no base.
        view.isPitchEnabled = false
        view.isRotateEnabled = false
        view.pointOfInterestFilter = .excludingAll
        apply(configuration, to: view)
        view.setVisibleMapRect(rect, animated: false)
        context.coordinator.showing = rect
        return view
    }

    func updateNSView(_ view: MKMapView, context: Context) {
        apply(configuration, to: view)
        // Only when something else moved it. Writing back the rectangle the map just told
        // us about would fight the gesture that produced it.
        guard !MKMapRectEqualToRect(context.coordinator.showing, rect) else { return }
        context.coordinator.showing = rect
        view.setVisibleMapRect(rect, animated: false)
    }

    private func apply(_ wanted: MKMapConfiguration?, to view: MKMapView) {
        // Never hidden, even for the drawn map, because a hidden view does not hit-test and
        // the map view is what does the panning. For the drawn map the canvas simply paints
        // over it, opaquely, and the map underneath is never seen.
        //
        // The cost of that is real and worth writing down: the drawn map is the layer that
        // promises to work with the network off, and there is a map view behind it fetching
        // tiles nobody will look at. Fixing it properly means a separate path for the drawn
        // map that does its own panning, which is a second camera to keep in step.
        guard let wanted else { return }
        if type(of: view.preferredConfiguration) != type(of: wanted) {
            view.preferredConfiguration = wanted
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(moved: moved) }

    final class Coordinator: NSObject, MKMapViewDelegate {
        /// What we last told the map to show, so its own reports can be told apart from
        /// ours and the two do not chase each other.
        var showing = MKMapRect.world
        private let moved: (MKMapRect) -> Void

        init(moved: @escaping (MKMapRect) -> Void) { self.moved = moved }

        /// Every frame of a pan or a zoom, not just the end of one. That is the whole point
        /// — the layers over the map have to move with it rather than catch up afterwards.
        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            showing = mapView.visibleMapRect
            moved(showing)
        }
    }
}
