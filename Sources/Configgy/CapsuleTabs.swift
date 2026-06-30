import AppKit

// A capsule segmented control (Mole-style top nav): a rounded track with a
// highlighted chip behind the selected segment.
final class CapsuleTabs: NSView {
    var onSelect: ((Int) -> Void)?
    private var labels: [NSTextField] = []
    private let chip = NSView()
    private var segFrames: [NSRect] = []
    private(set) var selected = 0

    init(titles: [String]) {
        super.init(frame: .zero)
        wantsLayer = true
        let H = UI.s(32), padH = UI.s(18), gap = UI.s(4), inset = UI.s(3)
        layer?.cornerRadius = H / 2
        chip.wantsLayer = true; chip.layer?.cornerRadius = (H - inset * 2) / 2
        addSubview(chip)

        var x = inset
        for (i, t) in titles.enumerated() {
            let l = NSTextField(labelWithString: t)
            l.font = UI.font(12.5, .semibold); l.alignment = .center
            l.isBezeled = false; l.drawsBackground = false; l.isEditable = false; l.isSelectable = false
            l.sizeToFit()
            let segW = (l.frame.width + padH * 2).rounded()
            segFrames.append(NSRect(x: x, y: inset, width: segW, height: H - inset * 2))
            l.frame = NSRect(x: x, y: (H - l.frame.height) / 2, width: segW, height: l.frame.height)
            l.tag = i
            l.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(tap(_:))))
            addSubview(l); labels.append(l)
            x += segW + gap
        }
        frame = NSRect(x: 0, y: 0, width: x - gap + inset, height: H)
        select(0)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tap(_ g: NSClickGestureRecognizer) {
        guard let l = g.view as? NSTextField else { return }
        select(l.tag); onSelect?(l.tag)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyColors() }
    private func applyColors() {
        let dark = effectiveAppearance.isDark
        layer?.backgroundColor = Palette.tabTrack(dark).cgColor
        chip.layer?.backgroundColor = Palette.tabChip(dark).cgColor
        let onChip: NSColor = dark ? .labelColor : .labelColor   // dark text reads on the light chip; white text on dark chip
        for (j, l) in labels.enumerated() { l.textColor = (j == selected && !chip.isHidden) ? onChip : .secondaryLabelColor }
    }
    func select(_ i: Int) {
        if i < 0 || i >= segFrames.count { chip.isHidden = true; applyColors(); return }   // none (Settings)
        selected = i; chip.isHidden = false; chip.frame = segFrames[i]
        applyColors()
    }
}
