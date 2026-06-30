import AppKit

// Custom pill button. Neutral by default; on hover it adopts a semantic tint
// (green = back up, orange = restore, red = remove). `weak` = de-emphasized
// (no fill/border, faint) for destructive actions. `widthFor` reserves width for
// a longer transient title (e.g. "備份完成") so flashing it doesn't reflow.
final class PillButton: NSView {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let hoverTint: NSColor
    private let weak: Bool
    private let baseTitle: String
    private var hovering = false
    private var pressed = false
    private var locked = false
    private var tracking: NSTrackingArea?
    var onClick: (() -> Void)?

    init(symbol: String, title: String, hoverTint: NSColor? = nil, weak: Bool = false, widthFor: String? = nil) {
        self.hoverTint = hoverTint ?? .secondaryLabelColor
        self.weak = weak
        self.baseTitle = title
        super.init(frame: .zero)
        wantsLayer = true

        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(UI.symCfg(12))
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)
        label.font = UI.font(11.5, weak ? .regular : .medium)
        label.isBezeled = false; label.drawsBackground = false; label.isEditable = false; label.isSelectable = false
        label.stringValue = widthFor ?? title; label.sizeToFit()
        let lw = label.frame.width, lh = label.frame.height
        label.stringValue = title
        addSubview(label)
        toolTip = title; setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(title)

        let H = UI.s(28), padH = weak ? UI.s(8) : UI.s(11), iconSz = UI.s(15), gap = UI.s(6)
        frame = NSRect(x: 0, y: 0, width: (padH + iconSz + gap + lw + padH).rounded(), height: H)
        layer?.cornerRadius = H / 2
        layer?.borderWidth = weak ? 0 : 1
        iconView.frame = NSRect(x: padH, y: (H - iconSz) / 2, width: iconSz, height: iconSz)
        label.frame = NSRect(x: padH + iconSz + gap, y: (H - lh) / 2, width: lw, height: lh)
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    // transient "completed" look that keeps frame; call reset() to restore
    func setState(symbol: String?, title: String, color: NSColor) {
        locked = true
        if let symbol { iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(UI.symCfg(12)) }
        label.stringValue = title
        iconView.contentTintColor = color; label.textColor = color
        layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
        layer?.borderColor = color.withAlphaComponent(0.34).cgColor
    }

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
        if locked { return }
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
