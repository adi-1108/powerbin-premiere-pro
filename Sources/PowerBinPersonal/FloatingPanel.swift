import AppKit

/// Borderless, non-activating panel that dismisses on focus loss.
/// Raycast / Spotlight-style overlay.
final class FloatingPanel: NSPanel {
    var onResignKey: (() -> Void)?

    init(contentRect: NSRect) {
        Log.line("   FP.init enter")
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: true
        )
        Log.line("   FP.init super done")

        isFloatingPanel = true
        level = .floating
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hasShadow = true

        // The SwiftUI content draws its own `.ultraThinMaterial` surface with a 12pt
        // corner radius. With an opaque `windowBackgroundColor` behind it, the material
        // blurred the window's own fill instead of the desktop, and the window's square
        // fill showed through at the four rounded corners. Clear + non-opaque lets the
        // content be the whole visible surface, which is what the material is for.
        isOpaque = false
        backgroundColor = .clear

        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        hidesOnDeactivate = false
        Log.line("   FP.init done")
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
        onResignKey?()
    }
}
