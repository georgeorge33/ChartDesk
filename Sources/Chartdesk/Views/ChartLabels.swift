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

    func update(_ label: ChartContext.Label, scale: Double) {
        self.label = label
        self.scale = scale
        let moved = MKMapPoint(x: Double(label.at.x), y: Double(label.at.y)).coordinate
        if moved.latitude != coordinate.latitude || moved.longitude != coordinate.longitude {
            coordinate = moved
        }
    }

    /// Which label this is from one zoom to the next, so a label that is still there is
    /// moved and redrawn rather than taken away and put back, which flickers.
    ///
    /// Most labels sit at a point that does not change with the zoom — a taxiway's middle,
    /// an airport, a fix — and are known by their writing and that point. A tag laid along
    /// an airspace boundary is set in by so many screen points, so its point creeps as the
    /// zoom changes; it is known by its writing and a coarse cell instead. Two tags saying
    /// the same thing are always hundreds of points apart, so they never share one.
    static func key(for label: ChartContext.Label) -> String {
        if label.path != nil {
            return "\(label.text)~\(Int((label.at.x / 4096).rounded())),\(Int((label.at.y / 4096).rounded()))"
        }
        return "\(label.text)@\(Int(label.at.x.rounded())),\(Int(label.at.y.rounded()))"
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
    }

    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// Down the page, as the map points the label is laid out in are.
    override var isFlipped: Bool { true }

    /// Writing is not a thing to click: a drag that starts on a taxiway's letter is a drag
    /// of the map.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ annotation: ChartLabelAnnotation) {
        label = annotation.label
        scale = annotation.scale
        let label = annotation.label
        let chart = ChartContext(cg: Self.measuring, mapPointsPerScreenPoint: scale)
        let box = chart.bounds(of: label)
        // The label's box about its anchor, in screen points, with a point of room for
        // antialiasing at the edges.
        let around = CGRect(x: (box.minX - label.at.x) / scale, y: (box.minY - label.at.y) / scale,
                            width: box.width / scale, height: box.height / scale)
            .insetBy(dx: -1, dy: -1)
        frame = CGRect(origin: frame.origin, size: around.size)
        anchor = CGPoint(x: -around.minX, y: -around.minY)
        // MapKit puts the view's middle on the coordinate; the anchor is where the label
        // wants to be, so the view is moved by the distance from one to the other.
        centerOffset = CGPoint(x: around.midX, y: around.midY)
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
