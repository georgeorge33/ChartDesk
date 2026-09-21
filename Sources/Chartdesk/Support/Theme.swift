import AppKit
import SwiftUI

/// The Navigraph-style palette. The app is pinned to dark, so these are fixed values
/// rather than dynamic system colours.
enum Theme {

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green:   CGFloat((hex >> 8) & 0xFF) / 255,
                blue:    CGFloat(hex & 0xFF) / 255,
                alpha:   1)
    }

    /// Window, sidebar and detail background.
    static let windowBackground = rgb(0x000810)
    /// The middle chart-list column.
    static let panel            = rgb(0x101828)
    /// Overlays that float above the canvas.
    static let panelRaised      = rgb(0x081020)
    /// Dividers and hairlines.
    static let separator        = rgb(0x182838)
    /// Filled controls, selection, window tint.
    static let accent           = rgb(0x185890)
    /// Accent-coloured *text and glyphs*. `accent` is only 2.7:1 against the shell, so it
    /// fails as a foreground colour; this is 8.6:1.
    static let accentText       = rgb(0x30B8F0)
    /// Backdrop behind a chart, and the sea on the map.
    static let canvas           = rgb(0x000810)
    /// Map land. Lifted well clear of the sea: at the old panel colour the coast was a guess.
    static let land             = rgb(0x14243A)
    /// Map coastline.
    static let coast            = rgb(0x2E4A68)
    /// Altitude and speed restrictions, which on an Airbus display are magenta and nothing
    /// else is: on an F-PLN page only the constrained fix's figures are magenta, and that is
    /// exactly what makes the colour worth reading.
    static let constraint       = rgb(0xFF00FF)
    /// What the aeroplane is predicted to do, which on the same page is green. Both are
    /// eyeballed from a real F-PLN rather than taken from a specification.
    static let prediction       = rgb(0x24E024)
    /// Map country borders. Drawn dashed as well as lighter: at the same weight as a coast a
    /// border reads as one, and the St Lawrence and the 49th parallel are not the same thing.
    static let border           = rgb(0x44607F)
    /// Runway tarmac, drawn once the zoom is close enough for a runway to be longer than a
    /// few points. Pale, because at that zoom it is the brightest thing on the sheet.
    static let runway           = rgb(0x8EA6BE)
    /// Controlled airspace, in the colours a VFR chart uses: Class B solid blue, Class C
    /// magenta, Class D blue and dashed. Not ForeFlight's own greys — these are the ones a
    /// pilot already reads without having to learn them.
    static let airspaceB        = rgb(0x4A9BE8)
    static let airspaceC        = rgb(0xC85AA8)
    static let airspaceD        = rgb(0x6FA8DC)
    /// The two openAIP brings that the FAA's table has no equivalent of. Class A is the
    /// airspace above a European TMA and is drawn as the blues are; Class E is the faded
    /// magenta a sectional uses for it.
    static let airspaceA        = rgb(0x3D7FC0)
    static let airspaceE        = rgb(0xA06A92)
    /// Prohibited, restricted and danger areas: red, because they are the one thing on this
    /// layer that is about staying out rather than talking to someone.
    static let airspaceDanger   = rgb(0xD9534F)
    /// The airport's own ground, at the closest zoom there is: tarmac, and the lines
    /// painted on it. Taxiway centrelines are yellow on every airfield on earth.
    static let taxiway         = rgb(0x5C6874)
    /// Asphalt, and darker than the concrete beside it, which is what tells a runway from a
    /// taxiway before you have read a single number.
    static let runwayAsphalt   = rgb(0x22272E)
    static let runwayMarking   = rgb(0xF2F4F7)
    static let taxiLine        = rgb(0xE8C33A)
    static let apron           = rgb(0x4A5561)
    /// The bar you hold short at, and the stand you park on. Magenta is what a ground chart
    /// paints a holding position in.
    static let holdShort       = rgb(0xE05AC8)
    static let stand           = rgb(0xBFD0E0)

    /// The colour a kind of airspace is drawn in, so the map and the Layers panel cannot
    /// disagree about what a chip means.
    static func airspace(_ klass: AirspaceClass) -> NSColor {
        switch klass {
        case .a: return airspaceA
        case .b: return airspaceB
        case .c: return airspaceC
        case .d: return airspaceD
        case .e: return airspaceE
        case .prohibited, .restricted, .danger: return airspaceDanger
        }
    }

    /// Internal borders — states, provinces — fainter than a frontier between countries.
    static let stateBorder      = rgb(0x35506B)
    /// The names of towns.
    static let place            = rgb(0x9FB3C8)

    /// The same ink, for a base map that is pale rather than dark.
    ///
    /// Every colour above is navy chosen to glow a little against near-black. Over the
    /// terrain layer that arrangement inverts — the ground is the pale thing now — and the
    /// same lines drawn in the same colours wash out entirely. These are their opposites:
    /// the hue kept, the value flipped, so a border still reads as a border.
    /// Contour lines. The sepia every paper chart prints them in — brown enough to be
    /// clearly not a road or a river, quiet enough to lie under everything aeronautical.
    static let contour          = rgb(0x6B5836)

    enum OnLight {
        static let coast        = rgb(0x5A6B7B)
        static let border       = rgb(0x5B6A78)
        static let stateBorder  = rgb(0x78868F)
        static let place        = rgb(0x33414D)
        static let runway       = rgb(0x3E4B58)
    }
    /// The "not for real-world navigation" red. Brighter than the system red, which goes
    /// muddy at caption sizes against this navy.
    static let warning          = rgb(0xFF5A5A)

    /// A tint per chart category, matching the colour coding Navigraph Charts uses on its own
    /// tab strip. Bright enough to read as a label on the navy, and dark text sits on top of
    /// them when a tab is selected.
    static func category(_ category: ChartCategory) -> NSColor {
        switch category {
        case .arrival:   return rgb(0x5BD98A)
        case .approach:  return rgb(0xF5A33C)
        case .airport:   return rgb(0x30B8F0)
        case .departure: return rgb(0xB98BF5)
        case .reference: return rgb(0xC2D0DE)
        }
    }
}

extension ChartCategory {
    var tint: Color { Color(nsColor: Theme.category(self)) }
}

extension Font {
    /// The floor for type in the app: nothing is set smaller than this.
    ///
    /// 10.5 rather than `.caption`, which resolves to 10 on macOS and was the smallest thing
    /// here until a set of hand-picked 9-point labels made it smaller still. Named rather than
    /// written out at each site so the floor is one number to change and nothing can quietly
    /// slip under it.
    static let ngSmall = Font.system(size: 10.5)
    /// The credits in the corner of the map, and nothing else. Its own size so that making
    /// it smaller does not shrink every caption in the app with it.
    static let ngCredit = Font.system(size: 5)
    static let ngSmallMedium = Font.system(size: 10.5, weight: .medium)
    static let ngSmallBold = Font.system(size: 10.5, weight: .semibold)
    static let ngSmallMono = Font.system(size: 10.5, design: .monospaced)
}

extension Color {
    static let ngWindow      = Color(nsColor: Theme.windowBackground)
    static let ngPanel       = Color(nsColor: Theme.panel)
    static let ngPanelRaised = Color(nsColor: Theme.panelRaised)
    static let ngSeparator   = Color(nsColor: Theme.separator)
    static let ngAccent      = Color(nsColor: Theme.accent)
    static let ngAccentText  = Color(nsColor: Theme.accentText)
    static let ngWarning     = Color(nsColor: Theme.warning)
}
