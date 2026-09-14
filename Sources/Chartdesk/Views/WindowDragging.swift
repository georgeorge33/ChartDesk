import AppKit
import SwiftUI

/// Makes the window draggable from anywhere that is not an actual control.
///
/// By default only the gaps between toolbar items move the window, which on a bar this full is
/// a narrow strip. Setting `isMovableByWindowBackground` widens that to every inert pixel —
/// the title, the subtitle, the empty run between the title and the buttons.
///
/// The catch is that the flag applies to the whole window, so a drag on the chart would move
/// the window instead of panning the plate. `ChartCanvas` opts its views out by returning
/// false from `mouseDownCanMoveWindow`, which is what keeps panning, drawing and aligning
/// behaving as they did.
struct WindowDragEnabler: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView { Probe() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.isMovableByWindowBackground = true
        }

        /// This view is only here to reach the window; it should never be the thing you grab.
        override var mouseDownCanMoveWindow: Bool { false }
    }
}
