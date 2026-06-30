import AppKit

// Custom pill button, dynamically sized to its content. Neutral by default; on
// hover adopts a semantic tint (green/orange). `weak` = de-emphasized (no chrome)
// for destructive actions. setState() shows a transient "completed" look and
// resizes to fit (caller re-lays-out the cluster).
final class PillButton: NSView {
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let hoverTint: NSColor
    private let weak: Bool
    private let baseTitle: String
    private let baseSymbol: String
    private var hovering = false
    private var pressed = false
    private var locked = false
    private var tracking: NSTrackingArea?
    private let H = UI.s(28)
    var onClick: (() -> Void)?

    init(symbol: String, title: String, hoverTint: NSColor? = nil, weak: Bool = false) {
        self.hoverTint = hoverTint ?? .secondaryLabelColor
        self.weak = weak
        self.baseTitle = title
        self.baseSymbol = symbol
        super.init(frame: NSRect(x: 0, y: 0, width: 10, height: H))
        wantsLayer = true
        layer?.cornerRadius = H / 2
        layer?.borderWidth = weak ? 0 : 1
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(UI.symCfg(12))
        addSubview(iconView)
        label.font = UI.font(11.5, weak ? .regular : .medium)
        label.isBezeled = false; label.drawsBackground = false; label.isEditable = false; label.isSelectable = false
        label.stringValue = title
        addSubview(label)
        toolTip = title; setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(title)
        layoutContents()
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func layoutContents() {                // size to fit current title
        let padH = weak ? UI.s(8) : UI.s(11), iconSz = UI.s(15), gap = UI.s(6)
        label.sizeToFit()
        let lw = label.frame.width, lh = label.frame.height
        setFrameSize(NSSize(width: (padH + iconSz + gap + lw + padH).rounded(), height: H))
        iconView.frame = NSRect(x: padH, y: (H - iconSz) / 2, width: iconSz, height: iconSz)
        label.frame = NSRect(x: padH + iconSz + gap, y: (H - lh) / 2, width: lw, height: lh)
    }
    func setState(symbol: String?, title: String, color: NSColor) {
        locked = true
        if let symbol { iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?.withSymbolConfiguration(UI.symCfg(12)) }
        label.stringValue = title
        iconView.contentTintColor = color; label.textColor = color
        layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
        layer?.borderColor = color.withAlphaComponent(0.34).cgColor
        layoutContents()                           // dynamic resize
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
