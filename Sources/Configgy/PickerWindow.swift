import AppKit

// App-icon resolution: real app icon by bundle id, else the Terminal icon for
// plain config files (shell, git, dotfiles…).
enum Icons {
    static let terminal: NSImage = resolve("com.apple.Terminal") ?? sf("terminal")
    static func app(_ bundleId: String?) -> NSImage {
        if let b = bundleId, let img = resolve(b) { return img }
        return terminal
    }
    private static func resolve(_ id: String) -> NSImage? {
        guard let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return NSWorkspace.shared.icon(forFile: u.path)
    }
    private static func sf(_ n: String) -> NSImage {
        NSImage(systemSymbolName: n, accessibilityDescription: nil) ?? NSImage()
    }
    static func menuIcon(_ bundleId: String?) -> NSImage {
        let img = (app(bundleId).copy() as? NSImage) ?? app(bundleId)
        img.size = NSSize(width: 16, height: 16)
        return img
    }
}

struct PickerRow { let id: String; let title: String; let subtitle: String; let icon: NSImage }

final class FlippedView: NSView { override var isFlipped: Bool { true } }

// A clean native list window (Mole-style): icon + title + subtitle rows, with a
// soft material background. Multi-select uses checkboxes; single-select uses row
// highlight. Must run on the main thread.
final class PickerWindow: NSObject {
    private var win: NSWindow!
    private var multi = false
    private var checked: [String: Bool] = [:]            // multi-select state (image-based, no NSButton)
    private var checkViews: [String: NSImageView] = [:]
    private var rowViews: [String: NSView] = [:]
    private var selectedId: String?
    private var selectAllBtn: NSButton?

    static func chooseMany(title: String, prompt: String, items: [PickerRow], ok: String) -> Set<String>? {
        guard !items.isEmpty else { return nil }
        let p = PickerWindow()
        return p.run(title: title, prompt: prompt, items: items, ok: ok, multi: true).map { Set($0) }
    }
    static func chooseOne(title: String, prompt: String, items: [PickerRow], ok: String) -> String? {
        guard !items.isEmpty else { return nil }
        let p = PickerWindow()
        return p.run(title: title, prompt: prompt, items: items, ok: ok, multi: false)?.first
    }

    private func run(title: String, prompt: String, items: [PickerRow], ok: String, multi: Bool) -> [String]? {
        self.multi = multi
        selectedId = multi ? nil : items.first?.id
        let width = UI.s(520), rowH = UI.s(52), headerH = UI.s(46), footerH = UI.s(60)
        let listH = min(CGFloat(items.count) * rowH, UI.s(460))
        let winH = headerH + listH + footerH

        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: winH),
                       styleMask: [.titled], backing: .buffered, defer: false)
        win.title = title
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: winH))
        bg.material = .windowBackground; bg.blendingMode = .behindWindow; bg.state = .active
        bg.autoresizingMask = [.width, .height]
        win.contentView = bg

        let head = NSTextField(labelWithString: prompt)
        head.font = UI.font(12); head.textColor = .secondaryLabelColor
        head.lineBreakMode = .byTruncatingTail
        head.frame = NSRect(x: UI.s(22), y: winH - UI.s(34), width: width - UI.s(44) - (multi ? UI.s(116) : 0), height: UI.s(18))
        head.autoresizingMask = [.minYMargin, .width]
        bg.addSubview(head)
        if multi {                                // Select All / Deselect All — top-right
            let sa = NSButton(title: L.t("全選", "Select All"), target: self, action: #selector(selectAllTapped))
            sa.bezelStyle = .rounded; sa.font = UI.font(11)
            sa.frame = NSRect(x: width - UI.s(116), y: winH - UI.s(38), width: UI.s(102), height: UI.s(26))
            sa.autoresizingMask = [.minXMargin, .minYMargin]
            bg.addSubview(sa); selectAllBtn = sa
        }

        let scroll = NSScrollView(frame: NSRect(x: UI.s(12), y: footerH, width: width - UI.s(24), height: listH))
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: width - UI.s(24), height: CGFloat(items.count) * rowH))
        for (i, it) in items.enumerated() { doc.addSubview(makeRow(it, y: CGFloat(i) * rowH, width: width - UI.s(24), rowH: rowH)) }
        scroll.documentView = doc
        bg.addSubview(scroll)

        let cancel = NSButton(title: L.t("取消", "Cancel"), target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"; cancel.font = UI.font(13)
        cancel.frame = NSRect(x: width - UI.s(212), y: UI.s(14), width: UI.s(96), height: UI.s(32))
        let okB = NSButton(title: ok, target: self, action: #selector(okTapped))
        okB.bezelStyle = .rounded; okB.keyEquivalent = "\r"; okB.font = UI.font(13)
        okB.frame = NSRect(x: width - UI.s(110), y: UI.s(14), width: UI.s(96), height: UI.s(32))
        cancel.autoresizingMask = [.minXMargin]; okB.autoresizingMask = [.minXMargin]
        bg.addSubview(cancel); bg.addSubview(okB)

        win.center()
        NSApp.activate(ignoringOtherApps: true)
        let code = NSApp.runModal(for: win)
        win.orderOut(nil)
        guard code == .OK else { return nil }
        if multi { return checked.filter { $0.value }.map { $0.key } }
        return selectedId.map { [$0] }
    }

    private func makeRow(_ it: PickerRow, y: CGFloat, width: CGFloat, rowH: CGFloat) -> NSView {
        let row = NSView(frame: NSRect(x: UI.s(6), y: y + UI.s(3), width: width - UI.s(12), height: rowH - UI.s(6)))
        row.wantsLayer = true
        row.layer?.cornerRadius = UI.s(8)
        row.identifier = NSUserInterfaceItemIdentifier(it.id)
        rowViews[it.id] = row
        if !multi, it.id == selectedId { row.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor }
        let inH = rowH - UI.s(6)
        let isz = UI.s(30)
        let iv = NSImageView(frame: NSRect(x: UI.s(12), y: (inH - isz) / 2, width: isz, height: isz))
        iv.image = it.icon; iv.imageScaling = .scaleProportionallyUpOrDown
        row.addSubview(iv)

        let hasSub = !it.subtitle.isEmpty
        let textX = UI.s(54), textW = width - UI.s(12) - UI.s(54) - UI.s(44)
        let title = NSTextField(labelWithString: it.title)
        title.font = UI.font(13, .medium); title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: textX, y: hasSub ? inH / 2 - UI.s(1) : (inH - UI.s(18)) / 2, width: textW, height: UI.s(18))
        row.addSubview(title)
        if hasSub {
            let sub = NSTextField(labelWithString: it.subtitle)
            sub.font = UI.font(11); sub.textColor = .secondaryLabelColor; sub.lineBreakMode = .byTruncatingTail
            sub.frame = NSRect(x: textX, y: inH / 2 - UI.s(18), width: textW, height: UI.s(15))
            row.addSubview(sub)
        }
        if multi {
            let csz = UI.s(22)
            let civ = NSImageView(frame: NSRect(x: width - UI.s(12) - csz, y: (inH - csz) / 2, width: csz, height: csz))
            civ.imageScaling = .scaleProportionallyUpOrDown
            row.addSubview(civ); checkViews[it.id] = civ; checked[it.id] = false
            updateCheck(it.id, false)             // start unchecked; whole row toggles it
        }
        let g = NSClickGestureRecognizer(target: self, action: #selector(rowTapped(_:)))
        row.addGestureRecognizer(g)
        return row
    }
    private func updateCheck(_ id: String, _ on: Bool) {
        let iv = checkViews[id]
        iv?.image = NSImage(systemSymbolName: on ? "checkmark.circle.fill" : "circle", accessibilityDescription: nil)
        iv?.contentTintColor = on ? .controlAccentColor : .tertiaryLabelColor
    }

    @objc private func rowTapped(_ g: NSClickGestureRecognizer) {
        guard let row = g.view, let id = row.identifier?.rawValue else { return }
        if multi {
            let on = !(checked[id] ?? false)
            checked[id] = on
            updateCheck(id, on)
        } else {
            if let prev = selectedId, let pv = rowViews[prev] { pv.layer?.backgroundColor = nil }
            selectedId = id
            rowViews[id]?.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
        }
    }
    @objc private func selectAllTapped() {
        let turnOn = checked.values.contains { !$0 }   // any unchecked → select all; else clear all
        for id in checked.keys { checked[id] = turnOn; updateCheck(id, turnOn) }
        selectAllBtn?.title = turnOn ? L.t("全不選", "Deselect All") : L.t("全選", "Select All")
    }
    @objc private func okTapped() { NSApp.stopModal(withCode: .OK) }
    @objc private func cancelTapped() { NSApp.stopModal(withCode: .cancel) }
}
