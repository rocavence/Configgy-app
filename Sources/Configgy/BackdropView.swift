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
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(dark ? 0.8 : 0.0).cgColor
    }
}
