import AppKit

// A custom, fully controlled pill button for the dark UI: explicit internal
// padding, fixed icon→label gap, subtle fill that lifts on hover/press, and a
// destructive (red) variant. Everything derives from UI.s so it scales in
// proportion. Beats NSButton's bezel, whose insets don't scale harmoniously.
final class PillButton: NSView {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let tint: NSColor
    private let destructive: Bool
    private var hovering = false
    private var pressed = false
    private var tracking: NSTrackingArea?
    var onClick: (() -> Void)?

    init(symbol: String, title: String, destructive: Bool = false) {
        self.destructive = destructive
        self.tint = destructive ? .systemRed : .labelColor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = UI.s(7)
        layer?.borderWidth = 1

        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(UI.symCfg(12))
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = tint
        addSubview(iconView)

        label.stringValue = title
        label.font = UI.font(11.5, .medium)
        label.textColor = tint
        label.isBezeled = false; label.drawsBackground = false; label.isEditable = false; label.isSelectable = false
        label.sizeToFit()
        addSubview(label)

        toolTip = title
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(title)

        let H = UI.s(28), padH = UI.s(11), iconSz = UI.s(15), gap = UI.s(6)
        let lw = label.frame.width, lh = label.frame.height
        frame = NSRect(x: 0, y: 0, width: (padH + iconSz + gap + lw + padH).rounded(), height: H)
        iconView.frame = NSRect(x: padH, y: (H - iconSz) / 2, width: iconSz, height: iconSz)
        label.frame = NSRect(x: padH + iconSz + gap, y: (H - lh) / 2, width: lw, height: lh)
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with e: NSEvent) { hovering = true; updateColors() }
    override func mouseExited(with e: NSEvent) { hovering = false; pressed = false; updateColors() }
    override func mouseDown(with e: NSEvent) { pressed = true; updateColors() }
    override func mouseUp(with e: NSEvent) {
        let inside = bounds.contains(convert(e.locationInWindow, from: nil))
        pressed = false; updateColors()
        if inside { onClick?() }
    }
    private func updateColors() {
        let base = destructive ? NSColor.systemRed : NSColor.white
        let a: CGFloat = pressed ? 0.22 : (hovering ? 0.15 : 0.08)
        layer?.backgroundColor = base.withAlphaComponent(a).cgColor
        layer?.borderColor = base.withAlphaComponent(destructive ? 0.24 : 0.12).cgColor
    }
}
