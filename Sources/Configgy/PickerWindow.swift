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
    private var checks: [String: NSButton] = [:]
    private var rowViews: [String: NSView] = [:]
    private var selectedId: String?

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
        let width: CGFloat = 520, rowH: CGFloat = 52, headerH: CGFloat = 46, footerH: CGFloat = 60
        let listH = min(CGFloat(items.count) * rowH, 460)
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
        head.font = .systemFont(ofSize: 12); head.textColor = .secondaryLabelColor
        head.frame = NSRect(x: 22, y: winH - 34, width: width - 44, height: 18)
        head.autoresizingMask = [.minYMargin, .width]
        bg.addSubview(head)

        let scroll = NSScrollView(frame: NSRect(x: 12, y: footerH, width: width - 24, height: listH))
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: width - 24, height: CGFloat(items.count) * rowH))
        for (i, it) in items.enumerated() { doc.addSubview(makeRow(it, y: CGFloat(i) * rowH, width: width - 24, rowH: rowH)) }
        scroll.documentView = doc
        bg.addSubview(scroll)

        let cancel = NSButton(title: L.t("取消", "Cancel"), target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: width - 210, y: 14, width: 94, height: 32)
        let okB = NSButton(title: ok, target: self, action: #selector(okTapped))
        okB.bezelStyle = .rounded; okB.keyEquivalent = "\r"
        okB.frame = NSRect(x: width - 110, y: 14, width: 96, height: 32)
        cancel.autoresizingMask = [.minXMargin]; okB.autoresizingMask = [.minXMargin]
        bg.addSubview(cancel); bg.addSubview(okB)

        win.center()
        NSApp.activate(ignoringOtherApps: true)
        let code = NSApp.runModal(for: win)
        win.orderOut(nil)
        guard code == .OK else { return nil }
        if multi { return checks.filter { $0.value.state == .on }.map { $0.key } }
        return selectedId.map { [$0] }
    }

    private func makeRow(_ it: PickerRow, y: CGFloat, width: CGFloat, rowH: CGFloat) -> NSView {
        let row = NSView(frame: NSRect(x: 6, y: y + 3, width: width - 12, height: rowH - 6))
        row.wantsLayer = true
        row.layer?.cornerRadius = 8
        row.identifier = NSUserInterfaceItemIdentifier(it.id)
        rowViews[it.id] = row
        if !multi, it.id == selectedId { row.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor }

        let iv = NSImageView(frame: NSRect(x: 12, y: (rowH - 6 - 30) / 2, width: 30, height: 30))
        iv.image = it.icon; iv.imageScaling = .scaleProportionallyUpOrDown
        row.addSubview(iv)

        let hasSub = !it.subtitle.isEmpty
        let title = NSTextField(labelWithString: it.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.frame = NSRect(x: 54, y: hasSub ? (rowH - 6) / 2 - 1 : (rowH - 6 - 18) / 2, width: width - 12 - 54 - 44, height: 18)
        row.addSubview(title)
        if hasSub {
            let sub = NSTextField(labelWithString: it.subtitle)
            sub.font = .systemFont(ofSize: 11); sub.textColor = .secondaryLabelColor
            sub.frame = NSRect(x: 54, y: (rowH - 6) / 2 - 18, width: width - 12 - 54 - 44, height: 15)
            row.addSubview(sub)
        }
        if multi {
            let cb = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            cb.state = .on
            cb.frame = NSRect(x: width - 12 - 34, y: (rowH - 6 - 20) / 2, width: 24, height: 20)
            row.addSubview(cb); checks[it.id] = cb
        }
        let g = NSClickGestureRecognizer(target: self, action: #selector(rowTapped(_:)))
        row.addGestureRecognizer(g)
        return row
    }

    @objc private func rowTapped(_ g: NSClickGestureRecognizer) {
        guard let row = g.view, let id = row.identifier?.rawValue else { return }
        if multi {
            if g.location(in: row).x >= row.bounds.width - 38 { return }   // direct checkbox click toggles itself
            if let cb = checks[id] { cb.state = (cb.state == .on) ? .off : .on }
        } else {
            if let prev = selectedId, let pv = rowViews[prev] { pv.layer?.backgroundColor = nil }
            selectedId = id
            rowViews[id]?.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
        }
    }
    @objc private func okTapped() { NSApp.stopModal(withCode: .OK) }
    @objc private func cancelTapped() { NSApp.stopModal(withCode: .cancel) }
}
