import AppKit
import QuartzCore

// A backup-target row: border-highlight on hover, a flowing-light progress bar
// while an action runs, a completed-state flash, and a crumble on removal.
final class RowView: NSView {
    private let id: String
    private var busy = false
    private var tracking: NSTrackingArea?
    private var progressTrack: CALayer?
    private var actionButtons: [PillButton] = []   // right-to-left order
    private var backupBtn: PillButton?
    private var restoreBtn: PillButton?
    private let radius = UI.s(13)

    var onBackup: ((@escaping (Bool) -> Void) -> Void)?
    var onRestore: ((@escaping (Bool) -> Void) -> Void)?
    var onRemove: ((@escaping (Bool) -> Void) -> Void)?
    var onAdd: (() -> Void)?
    var onRefresh: (() -> Void)?

    init(entry: AppDelegate.Entry, y: CGFloat, width: CGFloat, rowH: CGFloat) {
        self.id = entry.id
        super.init(frame: NSRect(x: UI.s(12), y: y, width: width - UI.s(24), height: rowH))
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.masksToBounds = true                  // clip everything to the rounded rect (fixes corner glitch)
        layer?.backgroundColor = NSColor.gray.withAlphaComponent(0.12).cgColor
        autoresizingMask = [.width]

        let iconX = UI.s(16), isz = UI.s(44)
        let iv = NSImageView(frame: NSRect(x: iconX, y: (rowH - isz) / 2, width: isz, height: isz))
        iv.image = entry.icon; iv.imageScaling = .scaleProportionallyUpOrDown; addSubview(iv)

        if entry.suggestion {
            let add = PillButton(symbol: "plus.circle.fill", title: L.t("加入", "Add"), hoverTint: .controlAccentColor)
            add.onClick = { [weak self] in self?.onAdd?() }; actionButtons = [add]; addSubview(add)
        } else {
            let b = PillButton(symbol: "icloud.and.arrow.up", title: L.t("備份", "Back Up"), hoverTint: .systemGreen)
            b.onClick = { [weak self] in self?.tapBackup() }; backupBtn = b
            let r = PillButton(symbol: "clock.arrow.circlepath", title: L.t("還原", "Restore"), hoverTint: .systemOrange)
            r.onClick = { [weak self] in self?.tapRestore() }; restoreBtn = r
            actionButtons = [b, r]
            if id.hasPrefix("t:") {
                let rm = PillButton(symbol: "trash", title: L.t("移除", "Remove"), hoverTint: .systemRed, weak: true)
                rm.onClick = { [weak self] in self?.tapRemove() }; actionButtons.append(rm)
            } else if id == "zen" {
                let dis = PillButton(symbol: "pause.circle", title: L.t("停用", "Disable"), hoverTint: .systemRed, weak: true)
                dis.onClick = { [weak self] in self?.tapRemove() }; actionButtons.append(dis)
            }
            actionButtons.forEach { addSubview($0) }
        }
        layoutActions()
        let leftEdge = actionButtons.map { $0.frame.minX }.min() ?? bounds.width
        let nameX = iconX + isz + UI.s(12)
        let textW = max(leftEdge - UI.s(10) - nameX, UI.s(80))
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

    private func layoutActions() {                  // right-aligned cluster, dynamic widths
        var x = bounds.width - UI.s(14)
        for b in actionButtons {
            x -= b.frame.width
            b.setFrameOrigin(NSPoint(x: x, y: (bounds.height - b.frame.height) / 2))
            x -= UI.s(6)
        }
    }

    // ---- hover: border highlight ----
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with e: NSEvent) { highlight(true) }
    override func mouseExited(with e: NSEvent) { highlight(false) }
    private func highlight(_ on: Bool) {
        layer?.borderWidth = on ? UI.s(1.5) : 0
        layer?.borderColor = on ? NSColor.white.withAlphaComponent(0.55).cgColor : NSColor.clear.cgColor
        layer?.backgroundColor = NSColor.gray.withAlphaComponent(on ? 0.17 : 0.12).cgColor
    }

    // ---- flowing-light progress bar (indeterminate) along the bottom ----
    private func startProgress(_ color: NSColor) {
        let bh = UI.s(3)
        let track = CALayer()
        track.frame = CGRect(x: UI.s(14), y: UI.s(6), width: bounds.width - UI.s(28), height: bh)
        track.backgroundColor = color.withAlphaComponent(0.18).cgColor
        track.cornerRadius = bh / 2; track.masksToBounds = true
        layer?.addSublayer(track)
        let segW = track.bounds.width * 0.35
        let seg = CAGradientLayer()
        seg.frame = CGRect(x: 0, y: 0, width: segW, height: bh)
        seg.startPoint = CGPoint(x: 0, y: 0.5); seg.endPoint = CGPoint(x: 1, y: 0.5)
        seg.colors = [color.withAlphaComponent(0).cgColor, color.cgColor, color.withAlphaComponent(0).cgColor]
        track.addSublayer(seg)
        let a = CABasicAnimation(keyPath: "position.x")
        a.fromValue = -segW / 2; a.toValue = track.bounds.width + segW / 2
        a.duration = 0.95; a.repeatCount = .infinity
        seg.add(a, forKey: "flow")
        progressTrack = track
    }
    private func stopProgress() { progressTrack?.removeFromSuperlayer(); progressTrack = nil }

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
        busy = true; startProgress(.systemGreen)
        onBackup { [weak self] ok in
            guard let self else { return }
            self.stopProgress()
            if ok {
                self.backupBtn?.setState(symbol: "checkmark.circle.fill", title: L.t("備份完成", "Backed up"), color: .systemGreen)
                self.layoutActions()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { self.onRefresh?() }
            } else { self.busy = false }
        }
    }
    private func tapRestore() {
        guard !busy, let onRestore else { return }
        busy = true; startProgress(.systemOrange)
        onRestore { [weak self] ok in
            guard let self else { return }
            self.stopProgress()
            if ok {
                self.restoreBtn?.setState(symbol: "checkmark.circle.fill", title: L.t("還原完成", "Restored"), color: .systemOrange)
                self.layoutActions()
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
