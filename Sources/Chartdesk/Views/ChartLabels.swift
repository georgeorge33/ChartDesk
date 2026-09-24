import AppKit
import MapKit

/// The chart's writing, as things MapKit places rather than paint in its tiles.
///
/// Writing drawn into an overlay renderer's tiles is only ever as sharp as the tile. MapKit
/// rasterises a tile at a zoom level of its own choosing and magnifies it until the next
/// level takes over, and measured on a Retina screen the level it settles on is as often as
/// not the coarser one: 1.1 pixels of tile to a point of screen, so every letter drawn
/// into it is blurred across two. A renderer has no say in that — asked to report a higher
/// scale, MapKit reads the answer and draws the tiles at the same size regardless.
///
/// An annotation view is drawn by AppKit at the screen's own resolution and placed by MapKit
/// in the same pass as the map, so it is as sharp as any other writing on the screen and
/// cannot trail the map the way the old canvas did. The renderer still decides what is
/// written where — the declutter, the priorities, the curves are all unchanged — and each
/// label it places becomes one of these.
final class ChartLabelAnnotation: NSObject, MKAnnotation {

    @objc dynamic var coordinate: CLLocationCoordinate2D
    /// What to write, laid out in map points.
    private(set) var label: ChartContext.Label
    /// Map points to the screen point the label was laid out at.
    private(set) var scale: Double
    let key: String

    init(_ label: ChartContext.Label, scale: Double, key: String) {
        self.label = label
        self.scale = scale
        self.key = key
        coordinate = MKMapPoint(x: Double(label.at.x), y: Double(label.at.y)).coordinate
    }

    /// Whether what is on the map already will do for `label`, laid out at `scale`.
    ///
    /// The same label will. So will the same tag along an airspace boundary laid out at a
    /// zoom within a tenth of this one, a few points from where it was: such a tag is laid
    /// out afresh at every step of a zoom, to follow the ring's curve as it grows on the
    /// screen, but over a tenth of a zoom the curve and the tag's place move by about a
    /// point, and drawing it again for that on every step was most of what a scroll over
    /// airspace cost.
    func stands(for label: ChartContext.Label, at scale: Double) -> Bool {
        if self.label == label { return true }
        guard label.path != nil, self.label.path != nil, self.scale > 0, scale > 0 else {
            return false
        }
        var same = self.label
        same.at = label.at
        same.path = label.path
        guard same == label, abs(log(scale / self.scale)) < log(1.1) else { return false }
        let moved = hypot(label.at.x - self.label.at.x, label.at.y - self.label.at.y)
        return moved / scale < 3
    }

    func update(_ label: ChartContext.Label, scale: Double) {
        self.label = label
        self.scale = scale
        let moved = MKMapPoint(x: Double(label.at.x), y: Double(label.at.y)).coordinate
        if moved.latitude != coordinate.latitude || moved.longitude != coordinate.longitude {
            coordinate = moved
        }
    }

}

extension ChartContext.Label {

    /// Which label this is from one zoom to the next, so a label that is still there is
    /// moved and redrawn rather than taken away and put back.
    ///
    /// Most labels sit at a point that does not change with the zoom — a taxiway's middle,
    /// an airport, a fix — and are known by their writing and that point. A tag along an
    /// airspace boundary is known by the identity the renderer gave it, its ring and its
    /// place round it, because its own point creeps with the zoom. It was known by a coarse
    /// cell of the map once, which a creeping tag left on nearly every step of a zoom:
    /// measured, nineteen in twenty labels put on the map during a scroll were tags taken
    /// off and put back.
    var key: String {
        if let identity { return "\(text)~\(identity)" }
        return "\(text)@\(Int(at.x.rounded())),\(Int(at.y.rounded()))"
    }
}

/// One label, drawn by AppKit at the screen's resolution.
final class ChartLabelView: MKAnnotationView {

    static let reuse = "ChartLabel"

    /// Laid out in map points about the label's anchor; drawn by turning those into this
    /// view's own points.
    private var label: ChartContext.Label?
    private var scale: Double = 1
    /// Where the label's anchor falls in this view.
    private var anchor = CGPoint.zero

    /// A context to measure in, never drawn to. Measuring shapes text and adds nothing up
    /// on the context, so one serves every view.
    private static let measuring: CGContext = CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = false
        isEnabled = false
        // Always drawn: which labels are on the map is the renderer's declutter's to say,
        // not MapKit's.
        displayPriority = .required
        collisionMode = .none
        // Drawn when it changes and at no other time.
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// A plain layer of its own, rather than the one AppKit makes.
    ///
    /// AppKit's draws the view again every time it moves, and MapKit moves every label on
    /// every frame the map moves: measured during a scroll, twenty-odd labels drawn afresh
    /// on each frame, which halved the frames the map managed. A plain layer keeps what was
    /// drawn into it and is moved as it is.
    override func makeBackingLayer() -> CALayer { CALayer() }

    /// On whole pixels, always. What a plain layer keeps is only as sharp as where it
    /// lands, and between two pixels it is blended across both — the very blur this view
    /// exists to avoid. MapKit puts it wherever the map says, to a fraction of a point, so
    /// the fraction is taken off here: a quarter of a point at most, which nobody sees.
    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(onPixels(newOrigin))
    }

    override var frame: NSRect {
        get { super.frame }
        set { super.frame = NSRect(origin: onPixels(newValue.origin), size: newValue.size) }
    }

    private func onPixels(_ point: NSPoint) -> NSPoint {
        let pixels = window?.backingScaleFactor ?? 2
        return NSPoint(x: (point.x * pixels).rounded() / pixels,
                       y: (point.y * pixels).rounded() / pixels)
    }

    /// Down the page, as the map points the label is laid out in are.
    override var isFlipped: Bool { true }

    /// Writing is not a thing to click: a drag that starts on a taxiway's letter is a drag
    /// of the map.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ annotation: ChartLabelAnnotation) {
        let shown = annotation.label
        label = shown
        scale = annotation.scale
        let chart = ChartContext(cg: Self.measuring, mapPointsPerScreenPoint: scale)
        let box = chart.bounds(of: shown)
        // The label's box about its anchor, in screen points, with a point of room for
        // antialiasing at the edges.
        let around = CGRect(x: (box.minX - shown.at.x) / scale, y: (box.minY - shown.at.y) / scale,
                            width: box.width / scale, height: box.height / scale)
            .insetBy(dx: -1, dy: -1)
        // Whole points, so that on whole pixels the picture is pixel for pixel.
        let size = CGSize(width: ceil(around.width), height: ceil(around.height))
        frame = CGRect(origin: frame.origin, size: size)
        anchor = CGPoint(x: -around.minX, y: -around.minY)
        // MapKit puts the view's middle on the coordinate; the anchor is where the label
        // wants to be, so the view is moved by the distance from one to the other.
        centerOffset = CGPoint(x: size.width / 2 - anchor.x, y: size.height / 2 - anchor.y)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let label, let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState()
        // Map points about the anchor into this view's points: the renderer's own drawing,
        // unchanged, at the screen's resolution instead of a tile's.
        cg.translateBy(x: anchor.x, y: anchor.y)
        cg.scaleBy(x: 1 / scale, y: 1 / scale)
        cg.translateBy(x: -label.at.x, y: -label.at.y)
        ChartContext(cg: cg, mapPointsPerScreenPoint: scale).draw(label)
        cg.restoreGState()
    }
}
