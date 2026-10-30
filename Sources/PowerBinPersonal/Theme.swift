import AppKit
import SwiftUI

/// Surface colours that survive Light Mode, and one place to define motion.
///
/// The panel is built on `.ultraThinMaterial`, and every row fill, chip and hairline in it
/// was a literal `Color.white.opacity(0.04…0.08)`. On a dark desktop that reads as a subtle
/// raised row. On a light one it is white on white: the preset rows, the stored-type chips,
/// the preview well and all the 1pt borders vanish. macOS follows the system appearance by
/// default, so about half of users would have got the invisible version.
///
/// `Color.primary` resolves to white in dark mode and black in light, so a low-opacity
/// tint of it is a subtle contrast against the material either way.
enum Theme {
    /// Standard row / chip fill.
    static let surface = Color.primary.opacity(0.05)
    /// Slightly heavier fill, for panes that need to separate from the row behind them.
    static let surfaceStrong = Color.primary.opacity(0.08)
    /// 1pt borders and dividers drawn by hand.
    static let hairline = Color.primary.opacity(0.12)
    /// The recessed well behind a preview screenshot.
    static let previewWell = Color.primary.opacity(0.07)

    static let selectionFill = Color.accentColor.opacity(0.18)
    static let selectionStroke = Color.accentColor.opacity(0.55)
    static let sidebarSelection = Color.accentColor.opacity(0.16)

    static let corner: CGFloat = 6
    static let panelCorner: CGFloat = 12
}

/// Motion, in one place, and switched off when the system asks.
///
/// Nothing in the panel was animated: collapsing the right sidebar, opening the Save field
/// and switching workspaces all snapped. These are short and interruptible so they stay out
/// of the way of a fast keyboard user.
enum Motion {
    static let quick = Animation.easeOut(duration: 0.16)
    static let panel = Animation.spring(response: 0.30, dampingFraction: 0.86)

    /// Honour System Settings → Accessibility → Display → Reduce Motion.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static func animation(_ base: Animation) -> Animation? {
        reduceMotion ? nil : base
    }
}

extension View {
    /// `withAnimation`-equivalent modifier that respects Reduce Motion.
    func motion<V: Equatable>(_ base: Animation, value: V) -> some View {
        animation(Motion.animation(base), value: value)
    }
}

/// Runs `body` inside an animation unless Reduce Motion is on.
func withMotion(_ base: Animation = Motion.quick, _ body: () -> Void) {
    if let animation = Motion.animation(base) {
        withAnimation(animation, body)
    } else {
        body()
    }
}
