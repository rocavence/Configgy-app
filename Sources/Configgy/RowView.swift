import AppKit
import QuartzCore

// A backup-target row with hover glow, a coloured "流光" shimmer while an action
// runs, a completed-state flash, and a crumble animation on removal.
final class RowView: NSView {
    private let id: String
    private var hovering = false
    private var busy = false
    private var tracking: NSTrackingArea?
    private var shimmerLayer: CAGradientLayer?
    private var backupBtn: PillButton?
    private var restoreBtn: PillButton?
    private let radius = UI.s(13)

    var onBackup: ((@escaping (Bool) -> Void) -> Void)?     // perform → completion(success)
    var onRestore: ((@escaping (Bool) -> Void) -> Void)?
    var onRemove: ((@escaping (Bool) -> Void) -> Void)?     // confirm+perform → completion(removed)
    var onAdd: (() -> Void)?
    var onRefresh: (() -> Void)?

    init(entry: AppDelegate.Entry, y: CGFloat, width: CGFloat, rowH: CGFloat) {
        self.id = entry.id
        super.init(frame: NSRect(x: UI.s(12), y: y, width: width - UI.s(24), height: rowH))
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.masksToBounds = false                 // allow glow shadow outside bounds
        layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.12).cgColor
        autoresizingMask = [.width]

        let inner = bounds.width
        let iconX = UI.s(16), isz = UI.s(44)
        let iv = NSImageView(frame: NSRect(x: iconX, y: (rowH - isz) / 2, width: isz, height: isz))
        iv.image = entry.icon; iv.imageScaling = .scaleProportionallyUpOrDown; addSubview(iv)

        var x = inner - UI.s(14)
        func place(_ b: PillButton) {
            x -= b.frame.width
            b.setFrameOrigin(NSPoint(x: x, y: (rowH - b.frame.height) / 2))
            b.autoresizingMask = [.minXMargin]; addSubview(b); x -= UI.s(6)
        }
        if entry.suggestion {
            let add = PillButton(symbol: "plus.circle.fill", title: L.t("加入", "Add"), hoverTint: .controlAccentColor)
            add.onClick = { [weak self] in self?.onAdd?() }; place(add)
        } else {
            let b = PillButton(symbol: "icloud.and.arrow.up", title: L.t("備份", "Back Up"), hoverTint: .systemGreen, widthFor: L.t("備份完成", "Backed up"))
            b.onClick = { [weak self] in self?.tapBackup() }; place(b); backupBtn = b
            let r = PillButton(symbol: "clock.arrow.circlepath", title: L.t("還原", "Restore"), hoverTint: .systemOrange, widthFor: L.t("還原完成", "Restored"))
            r.onClick = { [weak self] in self?.tapRestore() }; place(r); restoreBtn = r
            if id.hasPrefix("t:") {
                let rm = PillButton(symbol: "trash", title: L.t("移除", "Remove"), hoverTint: .systemRed, weak: true)
                rm.onClick = { [weak self] in self?.tapRemove() }; place(rm)
            } else if id == "zen" {
                let dis = PillButton(symbol: "pause.circle", title: L.t("停用", "Disable"), hoverTint: .systemRed, weak: true)
                dis.onClick = { [weak self] in self?.tapRemove() }; place(dis)
            }
        }

        let nameX = iconX + isz + UI.s(12)
        let textW = max(x - UI.s(8) - nameX, UI.s(80))
        let name = NSTextField(labelWithString: entry.name)
        name.font = UI.font(13, .semibold); name.lineBreakMode = .byTruncatingTail
        name.frame = NSRect(x: nameX, y: rowH / 2 + UI.s(2), width: textW, height: UI.s(17))
        name.autoresizingMask = [.width]; addSubview(name)
        let detail = NSTextField(labelWithString: entry.detail)
        detail.font = UI.font(11); detail.textColor = .secondaryLabelColor; detail.lineBreakMode = .byTruncatingTail
        detail.frame = NSRect(x: nameX, y: rowH / 2 - UI.s(17), width: textW, height: UI.s(14))
        detail.autoresizingMask = [.width]; addSubview(detail)
    }
    required init?(coder: NSCoder) { fatalError() }

    // ---- hover glow ----
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with e: NSEvent) { hovering = true; glow(true) }
    override func mouseExited(with e: NSEvent) { hovering = false; glow(false) }
    private func glow(_ on: Bool) {
        guard let l = layer else { return }
        l.shadowColor = NSColor.white.cgColor; l.shadowOffset = .zero
        l.shadowRadius = on ? UI.s(9) : 0
        l.shadowOpacity = on ? 0.45 : 0
        l.backgroundColor = NSColor.gray.withAlphaComponent(on ? 0.18 : 0.12).cgColor
    }

    // ---- shimmer ----
    private func startShimmer(_ color: NSColor) {
        let g = CAGradientLayer()
        g.frame = bounds; g.cornerRadius = radius; g.masksToBounds = true
        g.startPoint = CGPoint(x: 0, y: 0.5); g.endPoint = CGPoint(x: 1, y: 0.5)
        let clear = color.withAlphaComponent(0).cgColor
        g.colors = [clear, color.withAlphaComponent(0.55).cgColor, clear]
        g.locations = [0, 0.5, 1]
        layer?.addSublayer(g)
        let a = CABasicAnimation(keyPath: "locations")
        a.fromValue = [-0.5, -0.2, 0.1]; a.toValue = [0.9, 1.2, 1.5]
        a.duration = 1.0; a.repeatCount = .infinity
        g.add(a, forKey: "shimmer"); shimmerLayer = g
    }
    private func stopShimmer() { shimmerLayer?.removeFromSuperlayer(); shimmerLayer = nil }

    // ---- crumble ----
    private func crumble(_ done: @escaping () -> Void) {
        guard let l = layer else { done(); return }
        let dur = 0.34
        let scale = CABasicAnimation(keyPath: "transform.scale"); scale.toValue = 0.8
        let fade = CABasicAnimation(keyPath: "opacity"); fade.toValue = 0
        let drop = CABasicAnimation(keyPath: "transform.translation.y"); drop.toValue = isFlipped ? 14 : -14
        let grp = CAAnimationGroup(); grp.animations = [scale, fade, drop]; grp.duration = dur
        grp.timingFunction = CAMediaTimingFunction(name: .easeIn); grp.fillMode = .forwards; grp.isRemovedOnCompletion = false
        l.add(grp, forKey: "crumble")
        DispatchQueue.main.asyncAfter(deadline: .now() + dur, execute: done)
    }

    // ---- actions ----
    private func tapBackup() {
        guard !busy, let onBackup else { return }
        busy = true; startShimmer(.systemGreen)
        onBackup { [weak self] ok in
            guard let self else { return }
            self.stopShimmer()
            if ok {
                self.backupBtn?.setState(symbol: "checkmark.circle.fill", title: L.t("備份完成", "Backed up"), color: .systemGreen)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { self.onRefresh?() }
            } else { self.busy = false }
        }
    }
    private func tapRestore() {
        guard !busy, let onRestore else { return }
        busy = true; startShimmer(.systemOrange)
        onRestore { [weak self] ok in
            guard let self else { return }
            self.stopShimmer()
            if ok {
                self.restoreBtn?.setState(symbol: "checkmark.circle.fill", title: L.t("還原完成", "Restored"), color: .systemOrange)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { self.onRefresh?() }
            } else { self.busy = false }
        }
    }
    private func tapRemove() {
        guard !busy, let onRemove else { return }
        onRemove { [weak self] removed in
            guard let self else { return }
            if removed { self.busy = true; self.crumble { self.onRefresh?() } }
        }
    }
}
