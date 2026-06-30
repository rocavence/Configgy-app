import AppKit

extension NSAppearance {
    var isDark: Bool { (bestMatch(from: [.darkAqua, .aqua]) ?? .aqua) == .darkAqua }
}

// Overlays that lighten on dark surfaces and darken on light ones, so cards /
// pills / tabs stay legible in both appearances (white-on-white was invisible).
enum Palette {
    static func overlay(_ dark: Bool, _ a: CGFloat) -> NSColor {
        (dark ? NSColor.white : NSColor.black).withAlphaComponent(a)
    }
    // card / row fill
    static func card(_ dark: Bool) -> NSColor { overlay(dark, dark ? 0.10 : 0.05) }
    // hairline border (always-on in light for Finder-like separation)
    static func hairline(_ dark: Bool) -> NSColor { overlay(dark, dark ? 0.0 : 0.08) }
    static func hoverBorder(_ dark: Bool) -> NSColor { dark ? NSColor.white.withAlphaComponent(0.4) : NSColor.black.withAlphaComponent(0.28) }
    static func hoverFill(_ dark: Bool) -> NSColor { overlay(dark, dark ? 0.17 : 0.07) }
    // neutral pill button
    static func pillFill(_ dark: Bool) -> NSColor { overlay(dark, dark ? 0.08 : 0.05) }
    static func pillBorder(_ dark: Bool) -> NSColor { overlay(dark, dark ? 0.12 : 0.14) }
    // capsule tab track + selected chip
    static func tabTrack(_ dark: Bool) -> NSColor { overlay(dark, dark ? 0.07 : 0.06) }
    static func tabChip(_ dark: Bool) -> NSColor { dark ? NSColor.white.withAlphaComponent(0.16) : NSColor.white.withAlphaComponent(0.9) }
}
