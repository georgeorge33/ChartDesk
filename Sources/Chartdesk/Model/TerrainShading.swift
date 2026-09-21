import Foundation

/// Turns a tile of raw elevation into a picture of the ground.
///
/// The terrain tiles are not a map, they are a measurement: every pixel is a height in
/// metres, packed into the three colour channels. Nobody has drawn anything. So unlike every
/// other base layer, this one is rendered here rather than fetched ready-made — which is
/// also why it is the only one that can be made to match the rest of the app rather than
/// fighting it.
///
/// Two things are drawn on top of each other. A hillshade, which is where the shape comes
/// from, and a colour by height, which is where the reading comes from: at a glance, how
/// high is the ground under me. Both matter to a pilot and neither is much use alone —
/// hillshade without colour cannot tell a 300 m ridge from a 3,000 m one, and colour
/// without hillshade is a weather map.
enum TerrainShading {

    /// Metres, from the three bytes the tiles pack them into.
    ///
    /// "Terrarium" encoding: a 16-bit height with eight bits of fraction, offset so that
    /// everything is positive, spread across red, green and blue. The offset is why the
    /// ocean is not black — below sea level is a real number here, from ETOPO1, and the sea
    /// floor comes out of the same arithmetic as the Alps.
    static func metres(red: UInt8, green: UInt8, blue: UInt8) -> Double {
        Double(red) * 256 + Double(green) + Double(blue) / 256 - 32768
    }

    /// The light: from the north-west and 45° up, which is where every relief map has put it
    /// since they were painted by hand. Lit from anywhere else and hills read as hollows.
    ///
    /// Kept as the vector pointing at it rather than as an angle, because shading is then a
    /// dot product with the surface normal — the same figure the slope-and-aspect form
    /// gives, without four transcendentals a pixel to get there.
    private static let sunEast = -0.5
    private static let sunNorth = 0.5
    private static let sunUp = 0.7071067811865476

    /// How much to exaggerate the slope before shading it.
    ///
    /// Honest relief is nearly flat at the scales a map is looked at: a 10° hillside is a
    /// 10° hillside, and 10° of shading is nothing. Every relief map exaggerates, and the
    /// only question is how much before it turns into crumpled foil. A chart shades
    /// gently, so this is gentler than a relief poster would want.
    private static let steepen = 1.6

    /// Paints one tile and gives back the contour lines on it.
    ///
    /// Both from one call because the heights only exist until the paint overwrites them:
    /// the tile arrives as a measurement and leaves as a picture, and anything that wants
    /// the numbers has to ask on the way past.
    static func render(_ pixels: TilePixels, at tile: MapTile) -> [TerrainContour] {
        let side = pixels.side
        guard side > 1 else { return [] }
        let height = heights(of: pixels)
        let lines = TerrainContours.find(in: height, side: side, tile: tile,
                                         interval: TerrainContours.interval(forZoom: tile.z))
        paint(pixels, at: tile, height: height)
        return lines
    }

    /// The tile as a list of heights in metres, before anything is drawn over them.
    static func heights(of pixels: TilePixels) -> [Double] {
        let side = pixels.side
        var height = [Double](repeating: 0, count: side * side)
        let bytes = pixels.bytes
        for index in 0..<(side * side) {
            let at = index * 4
            height[index] = metres(red: bytes[at], green: bytes[at + 1], blue: bytes[at + 2])
        }
        return height
    }

    /// Paints one tile, in place.
    ///
    /// The heights are passed in rather than read here, because a hillshade needs the pixels
    /// around each pixel and writing as it went would shade a tile against itself
    /// half-painted.
    static func paint(_ pixels: TilePixels, at tile: MapTile, height: [Double]) {
        let side = pixels.side
        guard side > 1, height.count == side * side else { return }
        let bytes = pixels.bytes

        // How far apart two pixels are on the ground, which is what turns a difference in
        // height into a slope. Mercator shrinks towards the poles, so this is the tile's
        // own latitude and not a constant: shade Svalbard with the equator's figure and it
        // comes out as a mountain range.
        let across = Double(1 << tile.z)
        let north = atan(sinh(.pi * (1 - 2 * (Double(tile.y) + 0.5) / across)))
        let spacing = max(40_075_016.686 * cos(north) / (across * Double(side)), 0.5)

        for row in 0..<side {
            let up = max(row - 1, 0) * side
            let here = row * side
            let down = min(row + 1, side - 1) * side
            for column in 0..<side {
                let left = max(column - 1, 0)
                let right = min(column + 1, side - 1)

                // Horn's method: the eight neighbours, the middles weighted double. Steadier
                // than two differences, which on data quantised to 1/256 m reads every
                // rounding step as a terrace.
                let dx = ((height[up + right] + 2 * height[here + right] + height[down + right])
                        - (height[up + left] + 2 * height[here + left] + height[down + left]))
                        / (8 * spacing)
                let dy = ((height[down + left] + 2 * height[down + column] + height[down + right])
                        - (height[up + left] + 2 * height[up + column] + height[up + right]))
                        / (8 * spacing)

                // The surface normal. Rows run south, so the northward gradient is the
                // negative of `dy`, and the normal is (-dx, +dy, 1) before it is stretched.
                let east = -dx * steepen
                let north = dy * steepen
                let length = (east * east + north * north + 1).squareRoot()

                let above = height[here + column]
                var light: Double
                if above < 0 {
                    // The sea is flat, whatever the sea floor is doing. Shading it turns
                    // every ridge on the bottom into a wave and every coastline to mush.
                    light = 1
                } else {
                    let facing = (east * sunEast + north * sunNorth + sunUp) / length
                    // Nothing on a map is truly unlit: a face turned away from the sun still
                    // has the sky on it, and painted black it swallows what is drawn over it.
                    light = 0.62 + 0.38 * max(facing, 0)
                }

                let (red, green, blue) = colour(at: above)
                let at = (here + column) * 4
                bytes[at] = shade(red, light)
                bytes[at + 1] = shade(green, light)
                bytes[at + 2] = shade(blue, light)
                bytes[at + 3] = 255
            }
        }
    }

    private static func shade(_ channel: Double, _ light: Double) -> UInt8 {
        UInt8(max(0, min(255, channel * light)))
    }

    /// Height to colour.
    ///
    /// Sampled off a Navigraph VFR chart rather than invented: pale cream on the valley
    /// floors, sage green over the slopes, olive and then tan as the ground gets up, and
    /// rock and snow above that. Water is the pale cyan those charts use for a river, going
    /// deeper only where the sea does.
    ///
    /// Pale low and green above it is the opposite way round to an atlas, and it is not a
    /// mistake. On their chart the green is land cover — forest against field — which
    /// elevation tiles do not carry. But in mountains the two line up: the farmed floor is
    /// the low ground and the forest is on the slopes, so a ramp in this order reproduces
    /// what their map looks like from the only thing this layer knows.
    private static let ramp: [(metres: Double, red: Double, green: Double, blue: Double)] = [
        (-9000,  92, 158, 186),
        (-2000, 142, 196, 218),
        ( -200, 180, 224, 238),
        (   -1, 205, 242, 250),
        (    0, 234, 240, 212),
        (  350, 214, 226, 190),
        (  800, 152, 184, 152),
        ( 1500, 136, 168, 136),
        ( 2000, 160, 168, 132),
        ( 2500, 168, 152, 120),
        ( 3000, 200, 168, 152),
        ( 3500, 223, 201, 158),
        ( 4200, 226, 218, 204),
        ( 5200, 242, 242, 242),
        ( 8900, 252, 252, 252),
    ]

    static func colour(at metres: Double) -> (Double, Double, Double) {
        if metres <= ramp[0].metres { return (ramp[0].red, ramp[0].green, ramp[0].blue) }
        for index in 1..<ramp.count {
            let top = ramp[index]
            guard metres <= top.metres else { continue }
            let bottom = ramp[index - 1]
            // The step from the last sea stop to the first land stop is a shoreline and not
            // a gradient, so a zero-width step is taken as it stands.
            let span = top.metres - bottom.metres
            let part = span > 0 ? (metres - bottom.metres) / span : 1
            return (bottom.red + (top.red - bottom.red) * part,
                    bottom.green + (top.green - bottom.green) * part,
                    bottom.blue + (top.blue - bottom.blue) * part)
        }
        let last = ramp[ramp.count - 1]
        return (last.red, last.green, last.blue)
    }
}
