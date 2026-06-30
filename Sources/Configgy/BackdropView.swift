import AppKit

// Translucent window backdrop. In dark mode it lays a black tint over the blur so
// the window reads more solid (less see-through); in light mode it stays clear.
// Content views are added on top of the tint.
final class BackdropView: NSVisualEffectView {
    private let tint = NSView()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if tint.superview == nil {
            tint.wantsLayer = true
            tint.frame = bounds
            tint.autoresizingMask = [.width, .height]
            addSubview(tint, positioned: .below, relativeTo: nil)   // behind content, above the material
        }
        applyTint()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }
    private func applyTint() {
        let dark = effectiveAppearance.isDark
        // dark: deep black; light: a clean light wash (Finder-like, still slightly translucent)
        tint.layer?.backgroundColor = (dark ? NSColor.black.withAlphaComponent(0.8) : NSColor.white.withAlphaComponent(0.55)).cgColor
    }
}
