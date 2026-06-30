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
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        chip.wantsLayer = true; chip.layer?.cornerRadius = (H - inset * 2) / 2
        chip.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
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
    func select(_ i: Int) {
        guard i >= 0, i < segFrames.count else {        // -1 = none selected (e.g. Settings page)
            chip.isHidden = true
            for l in labels { l.textColor = .secondaryLabelColor }
            return
        }
        selected = i; chip.isHidden = false; chip.frame = segFrames[i]
        for (j, l) in labels.enumerated() { l.textColor = (j == i) ? .labelColor : .secondaryLabelColor }
    }
}
