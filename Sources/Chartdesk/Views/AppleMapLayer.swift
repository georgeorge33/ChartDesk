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

    /// Which of Apple's two maps.
    var configuration: MKMapConfiguration
    /// Where the map is looking. Written when something other than a gesture moves it.
    @Binding var rect: MKMapRect
    /// What the chart renderer should draw, inside the map rather than over it.
    var chart: ChartFrame
    /// Called whenever the user moves it, so the layers above can be redrawn.
    var moved: (MKMapRect) -> Void

    func makeNSView(context: Context) -> MKMapView {
        let view = ZoomingMapView()
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
        // The rectangle first and the delegate second, and in that order for a reason.
        // `setVisibleMapRect` calls the delegate synchronously, and the delegate writes
        // SwiftUI state — do that while the view is still being made and the state change
        // lands in the middle of the update that is making it, which SwiftUI answers by
        // never committing the window at all. No crash, no log, no window.
        view.setVisibleMapRect(rect, animated: false)
        context.coordinator.showing = rect
        view.delegate = context.coordinator
        // The chart, as something MapKit draws. Added after the delegate, which is what
        // hands back the renderer for it.
        context.coordinator.chart.frame = chart
        context.coordinator.stamp = chart.stamp
        view.addOverlay(context.coordinator.overlay, level: .aboveLabels)
        return view
    }

    func updateNSView(_ view: MKMapView, context: Context) {
        apply(configuration, to: view)
        // The view has a size by now, which it did not when it was made, so this is where
        // the renderer first learns how big a point on the screen is.
        context.coordinator.measure(view)
        #if DEBUG
        context.coordinator.zoomTest(view)
        #endif
        // Only when it would draw differently: setting it marks the overlay dirty, and the
        // map view calls update on every frame it moves.
        if context.coordinator.stamp != chart.stamp {
            context.coordinator.stamp = chart.stamp
            context.coordinator.chart.frame = chart
            // And the labels for it: the ask in `measure` was made against the old frame.
            context.coordinator.refreshLabels(view)
        }
        // Only when something else moved it. Writing back the rectangle the map just told
        // us about would fight the gesture that produced it.
        guard !MKMapRectEqualToRect(context.coordinator.showing, rect) else { return }
        context.coordinator.showing = rect
        // Detached from the delegate for the same reason: a synchronous report from inside
        // an update writes state inside that update.
        view.delegate = nil
        view.setVisibleMapRect(rect, animated: false)
        view.delegate = context.coordinator
    }

    private func apply(_ wanted: MKMapConfiguration, to view: MKMapView) {
        // Only when it is the other kind: setting it again reloads the map.
        if type(of: view.preferredConfiguration) != type(of: wanted) {
            view.preferredConfiguration = wanted
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(moved: moved) }

    /// A map view where the wheel zooms instead of panning.
    ///
    /// MapKit's own answer to a scroll on the Mac is to slide the map, which is right for a
    /// document and wrong for a map: every map anyone has used in a browser for twenty
    /// years zooms on the wheel, and this one did too before the map view took the gestures
    /// over. Dragging still pans, and pinching still zooms, because those are untouched.
    private final class ZoomingMapView: MKMapView {

        override func scrollWheel(with event: NSEvent) {
            // A trackpad reports fine-grained deltas and a wheel reports notches; the
            // notches have to be scaled up or a wheel click barely moves.
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY
                                                        : event.deltaY * 10
            guard delta != 0 else { return }
            let factor = 1 + delta * 0.006
            guard factor > 0.1, factor < 10 else { return }

            let cursor = convert(event.locationInWindow, from: nil)
            guard bounds.contains(cursor) else { return }

            // Zoom about the middle, then slide back so that whatever was under the pointer
            // is under it again. Done by asking the map what is there before and after
            // rather than by arithmetic on the rectangle, because that way the view's own
            // flipped-or-not coordinates are MapKit's problem and not this method's.
            let before = convert(cursor, toCoordinateFrom: self)
            let rect = visibleMapRect
            let wide = rect.width / factor, high = rect.height / factor
            setVisibleMapRect(MKMapRect(x: rect.midX - wide / 2, y: rect.midY - high / 2,
                                        width: wide, height: high), animated: false)

            let after = convert(cursor, toCoordinateFrom: self)
            let wanted = MKMapPoint(before), landed = MKMapPoint(after)
            let moved = visibleMapRect
            setVisibleMapRect(MKMapRect(x: moved.minX + wanted.x - landed.x,
                                        y: moved.minY + wanted.y - landed.y,
                                        width: moved.width, height: moved.height),
                              animated: false)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        /// What we last told the map to show, so its own reports can be told apart from
        /// ours and the two do not chase each other.
        var showing = MKMapRect.world
        let overlay = ChartOverlay()
        lazy var chart = ChartRenderer(overlay: overlay)
        var stamp = ""
        private let moved: (MKMapRect) -> Void

        init(moved: @escaping (MKMapRect) -> Void) { self.moved = moved }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            chart
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let label = annotation as? ChartLabelAnnotation else { return nil }
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: ChartLabelView.reuse)
                        as? ChartLabelView)
                ?? ChartLabelView(annotation: label, reuseIdentifier: ChartLabelView.reuse)
            view.annotation = label
            view.show(label)
            return view
        }

        #if DEBUG
        private var zoomTested = false

        /// Zooms the map in by half again over about four seconds, a frame at a time, with
        /// nothing but the map view doing it — for watching what follows the map in motion.
        func zoomTest(_ mapView: MKMapView) {
            guard RenderProbe.zoomsItself, !zoomTested, mapView.bounds.width > 0 else { return }
            zoomTested = true
            let start = mapView.visibleMapRect
            let began = Date()
            Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak mapView] timer in
                MainActor.assumeIsolated {
                    guard let mapView else { timer.invalidate(); return }
                    // Held still for the first three seconds, so the start can be seen, then
                    // four seconds of zoom, measured by the clock rather than counted.
                    let elapsed = -began.timeIntervalSinceNow
                    guard elapsed > 3 else { return }
                    let t = min((elapsed - 3) / 4, 1)
                    let shrink = 1 - 0.5 * t
                    let rect = MKMapRect(x: start.midX - start.width * shrink / 2,
                                         y: start.midY - start.height * shrink / 2,
                                         width: start.width * shrink,
                                         height: start.height * shrink)
                    mapView.setVisibleMapRect(rect, animated: false)
                    if t >= 1 { timer.invalidate() }
                }
            }
        }
        #endif

        // MARK: - Writing

        /// The labels on the map now, by key, and which settled frame they came from.
        private var placed: [String: ChartLabelAnnotation] = [:]
        private var placedFrom = ""
        private var asking = false
        private var askAgain = false
        private let labeller = DispatchQueue(label: "chartdesk.labels", qos: .userInitiated)

        /// Asks the renderer for the labels at the map's current zoom, off the main thread,
        /// and puts them on the map when they come back.
        ///
        /// One ask at a time. This is called on every frame the map moves, and at a zoom
        /// it has settled before the answer is a cache lookup; an ask made while one is out
        /// is folded into a single one more when it lands, so the labels finish on the
        /// frame the map finished on.
        func refreshLabels(_ mapView: MKMapView) {
            guard !asking else { askAgain = true; return }
            asking = true
            let renderer = chart
            labeller.async { [weak self, weak mapView] in
                let found = renderer.placedLabels()
                Task { @MainActor in
                    guard let self else { return }
                    self.asking = false
                    if let found, let mapView, found.key != self.placedFrom {
                        self.placedFrom = found.key
                        self.apply(found.labels, scale: found.scale, to: mapView)
                    }
                    if self.askAgain, let mapView {
                        self.askAgain = false
                        self.refreshLabels(mapView)
                    }
                }
            }
        }

        /// The labels put on the map: those still there moved and redrawn, those gone
        /// taken off, and the new ones added.
        private func apply(_ labels: [ChartContext.Label], scale: Double, to mapView: MKMapView) {
            var next: [String: ChartLabelAnnotation] = [:]
            var added: [ChartLabelAnnotation] = []
            var gone = placed
            for label in labels {
                let base = ChartLabelAnnotation.key(for: label)
                var key = base
                var count = 1
                while next[key] != nil {
                    count += 1
                    key = "\(base)#\(count)"
                }
                if let kept = gone.removeValue(forKey: key) {
                    kept.update(label, scale: scale)
                    (mapView.view(for: kept) as? ChartLabelView)?.show(kept)
                    next[key] = kept
                } else {
                    let made = ChartLabelAnnotation(label, scale: scale, key: key)
                    next[key] = made
                    added.append(made)
                }
            }
            if !gone.isEmpty { mapView.removeAnnotations(Array(gone.values)) }
            if !added.isEmpty { mapView.addAnnotations(added) }
            placed = next
        }

        /// Every frame of a pan or a zoom, not just the end of one. That is the whole point
        /// — the layers over the map have to move with it rather than catch up afterwards.
        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            let shown = mapView.visibleMapRect
            measure(mapView)
            guard !MKMapRectEqualToRect(shown, showing) else { return }
            showing = shown
            moved(shown)
        }

        /// Tell the renderer how big a screen point is in the map's own units, and what
        /// the map is showing.
        ///
        /// The scale is snapped to steps of three per cent, because setting a new one
        /// redraws every tile. It used to be rounded to two decimal places, which is not
        /// a per cent of anything: a map point per screen point is sixteen at two
        /// kilometres across and sixteen thousand at a continent, so the steps were a
        /// sixteenth of a per cent close in and nothing at all far out — every frame of a
        /// zoom redrew everything. Three per cent is past seeing in a line's weight or a
        /// letter's height, and a zoom now redraws a few dozen times rather than hundreds.
        func measure(_ mapView: MKMapView) {
            let across = mapView.bounds.width
            guard across > 0 else { return }
            let scale = mapView.visibleMapRect.width / Double(across)
            guard scale > 0 else { return }
            let step = log(1.03)
            chart.page = exp((log(scale) / step).rounded() * step)
            chart.view = mapView.visibleMapRect
            refreshLabels(mapView)
        }
    }
}
