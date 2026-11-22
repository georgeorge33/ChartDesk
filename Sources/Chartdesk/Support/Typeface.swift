import AppKit
import CoreText
import Observation
import os
import SwiftUI

/// The face the app's own writing is set in: the system's, or B612 Mono.
///
/// B612 is the typeface Airbus had drawn for its cockpit displays, to be read at a glance on a
/// screen in poor light. It is published under the SIL Open Font License, which lets it ship
/// inside the app as long as its licence goes with it. The monospaced cut is the one here
/// because so much of what the app shows is set out in columns — a SimBrief briefing above
/// all, but a METAR, a route's fixes and their altitudes too — and in a proportional face
/// those stop lining up. Two weights, regular and bold, and no italic: nothing here is set
/// in italic.
///
/// Observable, and read by the `Font` helpers in `Theme.swift` while a view builds its body.
/// That is what has SwiftUI build again exactly the views that set a font when the switch
/// changes, with nothing handed down to each of them — and without building the window
/// afresh, which would put the splash back up and lose every scroll position in it.
@Observable
final class Typeface {

    static let shared = Typeface()

    /// The PostScript names of the two faces in `Resources/Fonts`.
    static let regular = "B612Mono-Regular"
    static let bold = "B612Mono-Bold"

    /// Whether the app is to be set in B612 Mono. Saved the moment it changes.
    var usesB612Mono: Bool {
        didSet {
            UserDefaults.standard.set(usesB612Mono, forKey: DefaultsKey.useB612Mono)
            let now = isB612Mono
            Self.labelFlag.withLock { $0 = now }
        }
    }

    /// Set in B612 Mono now: switched on, and the faces found when the app opened. Without
    /// them the switch does nothing, rather than asking SwiftUI for a face that is not there,
    /// which it would draw in the system's face at B612's size.
    var isB612Mono: Bool { usesB612Mono && Self.isInstalled }

    private init() {
        usesB612Mono = UserDefaults.standard.bool(forKey: DefaultsKey.useB612Mono)
        let now = isB612Mono
        Self.labelFlag.withLock { $0 = now }
    }

    // MARK: - The faces

    /// Registers the bundled faces with this process, and says whether both came through.
    ///
    /// With this process only, not with the Mac: they are gone again when the app quits, and
    /// never turn up in anyone else's font menus.
    static let isInstalled: Bool = {
        let folder = Bundle.main.resourceURL?.appendingPathComponent("Fonts", isDirectory: true)
        for name in [regular, bold] {
            guard let file = folder?.appendingPathComponent("\(name).ttf") else { continue }
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
        return NSFont(name: regular, size: 12) != nil && NSFont(name: bold, size: 12) != nil
    }()

    /// What B612 Mono's sizes are multiplied by, so that its capitals stand as tall as the
    /// system face's do at the size asked for. B612's are six per cent taller at the same
    /// size, and set at the same size the whole app read a size larger than it is.
    static let scale: CGFloat = {
        guard isInstalled, let face = NSFont(name: regular, size: 100) else { return 1 }
        return NSFont.systemFont(ofSize: 100).capHeight / face.capHeight
    }()

    /// B612 Mono's face for a weight. There is a regular and a bold: semibold and heavier are
    /// set bold, and medium regular. B612's regular is already a sturdy face, and SwiftUI left
    /// to choose rounds medium up to the bold, which had every lightly emphasised word in the
    /// app shouting.
    static func face(for weight: Font.Weight) -> String {
        [.semibold, .bold, .heavy, .black].contains(weight) ? bold : regular
    }

    /// The same, for the map's writing, which AppKit weights.
    static func face(for weight: NSFont.Weight) -> String {
        weight.rawValue >= NSFont.Weight.semibold.rawValue ? bold : regular
    }

    // MARK: - The map

    /// The switch again, for the map's labels, which are laid out and drawn off the main
    /// thread while the switch is only ever thrown on it.
    private static let labelFlag = OSAllocatedUnfairLock(initialState: false)

    /// Whether a map label made now is set in B612 Mono.
    static var labelsInB612Mono: Bool { labelFlag.withLock { $0 } }

    // MARK: - The briefing

    /// Both faces as a style sheet's `@font-face` rules, for the SimBrief briefing.
    ///
    /// A web view draws in a process of its own, which knows nothing of the faces registered
    /// with this one, so they go in with the page. Read once, the first time a briefing is
    /// shown in B612 Mono, and not at all otherwise.
    static let briefingFaces: String = {
        let folder = Bundle.main.resourceURL?.appendingPathComponent("Fonts", isDirectory: true)
        return [(regular, 400), (bold, 700)].compactMap { name, weight -> String? in
            guard let file = folder?.appendingPathComponent("\(name).ttf"),
                  let data = try? Data(contentsOf: file) else { return nil }
            return "@font-face { font-family: \"B612 Mono\"; font-weight: \(weight); "
                + "src: url(data:font/ttf;base64,\(data.base64EncodedString())) format(\"truetype\"); }"
        }.joined(separator: "\n")
    }()
}

extension View {

    /// In B612 Mono, writing that names no font of its own set in it, at a text style's size:
    /// a toggle's label, a button's title, a list's row. In the system's face nothing at all,
    /// so each of those keeps the face and size macOS gives it in its own place.
    ///
    /// Round each window, and on the rows and headers of lists and tables as well: a list
    /// sets its own font on its rows, over anything set further up.
    func ngTypeface(_ style: Font.TextStyle = .body, weight: Font.Weight? = nil) -> some View {
        modifier(DefaultTypeface(style: style, weight: weight))
    }

    /// `fontWeight`, for writing whose face is set further up, with B612 Mono's two weights
    /// chosen the way the `Font` helpers choose them rather than the way SwiftUI would.
    func ngWeight(_ weight: Font.Weight) -> some View {
        modifier(TypefaceWeight(weight: weight))
    }
}

private struct DefaultTypeface: ViewModifier {
    let style: Font.TextStyle
    let weight: Font.Weight?

    func body(content: Content) -> some View {
        // Read here, in the body, where SwiftUI notices it, rather than in the closure.
        let font: Font? = Typeface.shared.isB612Mono ? .ng(style, weight: weight) : nil
        content.transformEnvironment(\.font) { inherited in
            if let font { inherited = font }
        }
    }
}

private struct TypefaceWeight: ViewModifier {
    let weight: Font.Weight

    func body(content: Content) -> some View {
        // One modifier either way, so the writing stays the same view when the switch is
        // thrown.
        content.fontWeight(!Typeface.shared.isB612Mono ? weight
                           : Typeface.face(for: weight) == Typeface.bold ? .bold : .regular)
    }
}
