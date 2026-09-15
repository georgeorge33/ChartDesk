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
    /// Backdrop behind a chart.
    static let canvas           = rgb(0x000810)
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

extension Color {
    static let ngWindow      = Color(nsColor: Theme.windowBackground)
    static let ngPanel       = Color(nsColor: Theme.panel)
    static let ngPanelRaised = Color(nsColor: Theme.panelRaised)
    static let ngSeparator   = Color(nsColor: Theme.separator)
    static let ngAccent      = Color(nsColor: Theme.accent)
    static let ngAccentText  = Color(nsColor: Theme.accentText)
    static let ngWarning     = Color(nsColor: Theme.warning)
}
