import AppKit

// Custom pill button. Neutral by default; on hover it adopts a semantic tint
// (green = back up, orange = restore, red = remove). `weak` = de-emphasized
// (no fill/border, faint color) for destructive actions so they don't read as
// prominent buttons. All metrics derive from UI.s so 1.x scaling stays in proportion.
final class PillButton: NSView {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let hoverTint: NSColor
    private let weak: Bool
    private var hovering = false
    private var pressed = false
    private var tracking: NSTrackingArea?
    var onClick: (() -> Void)?

    init(symbol: String, title: String, hoverTint: NSColor? = nil, weak: Bool = false) {
        self.hoverTint = hoverTint ?? .secondaryLabelColor
        self.weak = weak
        super.init(frame: .zero)
        wantsLayer = true

        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(UI.symCfg(12))
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)
        label.stringValue = title
        label.font = UI.font(11.5, weak ? .regular : .medium)
        label.isBezeled = false; label.drawsBackground = false; label.isEditable = false; label.isSelectable = false
        label.sizeToFit()
        addSubview(label)
        toolTip = title; setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(title)

        let H = UI.s(28), padH = weak ? UI.s(8) : UI.s(11), iconSz = UI.s(15), gap = UI.s(6)
        let lw = label.frame.width, lh = label.frame.height
        frame = NSRect(x: 0, y: 0, width: (padH + iconSz + gap + lw + padH).rounded(), height: H)
        layer?.cornerRadius = H / 2
        layer?.borderWidth = weak ? 0 : 1
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
        let active = hovering || pressed
        let content: NSColor = active ? hoverTint : (weak ? .tertiaryLabelColor : .labelColor)
        iconView.contentTintColor = content
        label.textColor = content
        if weak {
            layer?.backgroundColor = active ? hoverTint.withAlphaComponent(pressed ? 0.20 : 0.13).cgColor : NSColor.clear.cgColor
            layer?.borderColor = NSColor.clear.cgColor
        } else if active {
            layer?.backgroundColor = hoverTint.withAlphaComponent(pressed ? 0.24 : 0.16).cgColor
            layer?.borderColor = hoverTint.withAlphaComponent(0.34).cgColor
        } else {
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
            layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        }
    }
}
