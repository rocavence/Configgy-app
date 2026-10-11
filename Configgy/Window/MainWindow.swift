import SwiftUI

/// The one window: what's protected, what could be, and the actions on each.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    var openSettings: () -> Void = {} {
        didSet { host.rootView = MainView(model: model, openSettings: openSettings) }
    }
    private let model: AppModel
    private let host: NSHostingView<MainView>

    init(model: AppModel) {
        self.model = model
        host = NSHostingView(rootView: MainView(model: model, openSettings: {}))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "Configgy"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 480)
        window.contentView = host
        window.delegate = self
        window.setFrameAutosaveName("ConfiggyMain")
    }

    func show(activate: Bool = true) {
        model.refresh()
        if !window.isVisible { window.center() }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        if activate { NSApp.activate() }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func snapshot() -> NSBitmapImageRep? { window.contentView?.snapshot() }
    func close() { window.close() }
}

struct MainView: View {
    @Bindable var model: AppModel
    var openSettings: () -> Void
    @State private var tab = 0
    @State private var restoring: TargetRow?
    @State private var removing: TargetRow?
    @State private var reviewingFindings = false
    @State private var askQuitZen = false
    @AppStorage(Accent.key) private var accent: Accent = .configgy

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            banners
            Picker("", selection: $tab) {
                Text("Protected").tag(0)
                Text("Suggestions").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.horizontal, Spacing.s24)
            .padding(.vertical, Spacing.s12)
            ScrollView {
                LazyVStack(spacing: Spacing.s8) {
                    if tab == 0 { protectedList } else { suggestionList }
                }
                .padding(.horizontal, Spacing.s24)
                .padding(.bottom, Spacing.s24)
            }
            .scrollIndicators(.automatic)
        }
        .padding(.top, Spacing.s32)
        .frame(minWidth: 640, minHeight: 480)
        .background(Palette.background.ignoresSafeArea())
        .tint(accent.color)
        .sheet(item: $restoring) { row in
            if let target = model.target(row.key) {
                RestoreSheet(model: model, target: target) { restoring = nil }
            }
        }
        .sheet(isPresented: $reviewingFindings) {
            FindingsSheet(model: model) { reviewingFindings = false }
        }
        .confirmationDialog(removeTitle, isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { row in
            Button(String(localized: "Remove from List")) { model.remove(row.key, scope: .listOnly) }
            if row.mine > 0 {
                Button(String(localized: "Also Delete This Mac's \(row.mine) Backups"), role: .destructive) { model.remove(row.key, scope: .thisMac) }
            }
            if row.others > 0 {
                Button(String(localized: "Also Delete All \(row.mine + row.others) Backups, Including Other Macs'"), role: .destructive) {
                    model.remove(row.key, scope: .everywhere)
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: { _ in
            Text("Backups stay in the folder unless you choose to delete them. Deleted backups can't be recovered.")
        }
        .alert(String(localized: "Zen is still open"), isPresented: $askQuitZen) {
            Button(String(localized: "Quit Zen and Back Up")) {
                Task {
                    if await model.quitZen() {
                        await model.backup("zen")
                        model.openZen()
                    }
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(model.settings.zenAutoBackup
                 ? "Zen has to be closed to back it up. Configgy also backs it up by itself each time you quit Zen."
                 : "Zen has to be closed to back it up. It reopens when the backup is done.")
        }
        .alert(String(localized: "A newer Zen backup is available"), isPresented: Binding(get: { model.zenOffer != nil }, set: { if !$0 { model.zenOffer = nil } })) {
            Button(String(localized: "Restore…")) {
                if let zenRow = model.rows.first(where: { $0.key == "zen" }) { restoring = zenRow }
                model.zenOffer = nil
            }
            Button(String(localized: "Not Now"), role: .cancel) { model.dismissZenOffer() }
        } message: {
            if let offer = model.zenOffer {
                Text("Made on \(offer.host), \(offer.date.map { RelativeTime.describe($0) } ?? offer.name). Restoring quits Zen first.")
            }
        }
    }

    private var removeTitle: String {
        guard let removing else { return "" }
        return removing.key == "zen" ? String(localized: "Stop backing up Zen?") : String(localized: "Remove \(removing.name)?")
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s8) {
            Text(verbatim: "Configgy").textStyle(.title).foregroundStyle(Palette.ink)
            Text(verbatim: "v\(UpdateChecker.current)").textStyle(.caption).foregroundStyle(Palette.faint)
            Spacer()
            HStack(spacing: Spacing.s8) {
                if tab == 1 {
                    PillButton(String(localized: "Add Folder…"), icon: .folderAdd, action: addFolder)
                }
                PillButton(String(localized: "Backup Folder"), icon: .folder) { model.openBackupFolder() }
                    .disabled(model.context.base == nil)
                PillButton(String(localized: "Log"), icon: .documentText) { model.openLog() }
                PillButton(String(localized: "Settings"), icon: .setting2, action: openSettings)
            }
        }
        .padding(.horizontal, Spacing.s24)
        .padding(.bottom, Spacing.s8)
    }

    @ViewBuilder
    private var banners: some View {
        VStack(spacing: Spacing.s8) {
            locationBanner
            if !model.findings.isEmpty {
                Banner(icon: .warning, tone: Palette.warning,
                       text: String(localized: "\(model.findings.count) backups in the folder contain secret files (logins, keys or tokens) from before Configgy filtered them."),
                       action: String(localized: "Review…")) { reviewingFindings = true }
            }
            if model.settings.zenEnabled {
                HStack(spacing: Spacing.s8) {
                    IconView(model.settings.zenAutoBackup ? .checkCircle : .warning, size: 13)
                        .foregroundStyle(model.settings.zenAutoBackup ? Palette.good : Palette.muted)
                    Text(model.settings.zenAutoBackup ? "Zen backs up by itself each time you quit it." : "Zen automatic backup is off.")
                        .textStyle(.caption).foregroundStyle(Palette.muted)
                    Spacer()
                }
                .padding(.horizontal, Spacing.s4)
            }
        }
        .padding(.horizontal, Spacing.s24)
    }

    @ViewBuilder
    private var locationBanner: some View {
        switch model.location {
        case .ok:
            if let base = model.context.base {
                HStack(spacing: Spacing.s8) {
                    IconView(.cloud, size: 13).foregroundStyle(Palette.good)
                    Text("\(BackupLocation.provider(of: base, home: model.context.home).title) · \(model.context.abbreviate(base))")
                        .textStyle(.caption).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, Spacing.s4)
                .help(base)
            }
        case .notChosen:
            Banner(icon: .warning, tone: Palette.warning, text: String(localized: "Choose where to keep backups."),
                   action: String(localized: "Choose…"), perform: openSettings)
        case .missing(let path):
            Banner(icon: .warning, tone: Palette.bad,
                   text: String(localized: "The backup folder isn't there: \(model.context.abbreviate(path)). Nothing is backed up until it's back or you choose another."),
                   action: String(localized: "Choose…"), perform: openSettings)
        case .notWritable:
            Banner(icon: .warning, tone: Palette.bad,
                   text: String(localized: "Configgy needs Full Disk Access to write to the backup folder. Add Configgy in the list that opens, then quit and reopen it."),
                   action: String(localized: "Grant Access…")) { model.openFullDiskAccess() }
        }
    }

    // MARK: Lists

    @ViewBuilder
    private var protectedList: some View {
        if model.rows.isEmpty {
            Note(String(localized: "Nothing is backed up yet. Add something under Suggestions."))
        }
        ForEach(model.rows) { row in
            TargetCard(row: row, busy: model.busy.contains(row.key),
                       backup: { startBackup(row) },
                       restore: { restoring = row },
                       remove: row.key == "claude" ? nil : { removing = row })
        }
    }

    @ViewBuilder
    private var suggestionList: some View {
        if model.zenSuggested {
            SuggestionCard(name: "Zen Browser", bundleID: ZenTarget.bundleID,
                           note: String(localized: "Settings, extensions and workspaces; backs up each time you quit Zen.")) { model.addZen() }
        }
        ForEach(model.suggestions, id: \.def.id) { suggestion in
            SuggestionCard(name: suggestion.def.name, bundleID: suggestion.def.app,
                           note: suggestion.note.isEmpty ? suggestion.def.paths.joined(separator: "  ") : suggestion.note) {
                model.addSuggestion(suggestion)
            }
        }
        if model.suggestions.isEmpty && !model.zenSuggested {
            Note(String(localized: "No more common settings found on this Mac. Use Add Folder to pick your own."))
        }
    }

    private func startBackup(_ row: TargetRow) {
        if row.key == "zen", ZenTarget.isRunning {
            askQuitZen = true
        } else {
            Task { await model.backup(row.key) }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: model.context.home)
        panel.message = String(localized: "Choose settings files or folders to back up together.")
        panel.prompt = String(localized: "Choose")
        guard panel.runModal() == .OK, let first = panel.urls.first else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Name this backup")
        alert.informativeText = String(localized: "Secret files (keys, tokens, .env) inside are never copied.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = first.deletingPathExtension().lastPathComponent
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Add"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        model.addFolders(panel.urls, name: name.isEmpty ? first.lastPathComponent : name)
        tab = 0
    }
}

// MARK: - Cards

struct TargetCard: View {
    let row: TargetRow
    let busy: Bool
    let backup: () -> Void
    let restore: () -> Void
    let remove: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Spacing.s12) {
            Image(nsImage: AppIcons.icon(for: row.bundleID)).resizable().frame(width: 40, height: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.s4) {
                HStack(spacing: Spacing.s8) {
                    Text(row.name).textStyle(.subheading).foregroundStyle(Palette.ink)
                    HealthChip(health: row.health)
                }
                Text(row.reason).textStyle(.caption).foregroundStyle(row.health == .failed ? Palette.bad : Palette.muted)
                    .lineLimit(2)
                if let newest = row.newest, let date = newest.date {
                    Text(detail(newest, date)).textStyle(.caption).foregroundStyle(Palette.faint)
                        .help(RelativeTime.full(date))
                }
                if busy { ProgressView().progressViewStyle(.linear).frame(maxWidth: 220) }
            }
            Spacer(minLength: Spacing.s8)
            PillButton(String(localized: "Back Up"), icon: .export, action: backup).disabled(busy)
            PillButton(String(localized: "Restore…"), icon: .timeBack, action: restore).disabled(busy || row.newest == nil)
            if let remove {
                Menu {
                    Button(row.key == "zen" ? String(localized: "Stop Backing Up Zen…") : String(localized: "Remove…"), action: remove)
                } label: {
                    IconView(.trash, size: 14).foregroundStyle(Palette.muted).frame(width: 28, height: 28)
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(Text("More actions for \(row.name)"))
            }
        }
        .padding(Spacing.s12)
        .background(hovering ? Palette.hover : Palette.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.hairline))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(row.name), \(row.health.title), \(row.reason)"))
    }

    private func detail(_ snapshot: Snapshot, _ date: Date) -> String {
        var parts = [RelativeTime.describe(date), snapshot.host]
        if let files = snapshot.meta?.files { parts.append(String(localized: "\(files) files")) }
        parts.append(String(localized: "\(row.mine + row.others) total"))
        return parts.joined(separator: " · ")
    }
}

extension TargetRow.Health {
    var title: String {
        switch self {
        case .protected: String(localized: "Protected")
        case .attention: String(localized: "Needs Attention")
        case .failed: String(localized: "Failed")
        }
    }

    var color: Color {
        switch self {
        case .protected: Palette.good
        case .attention: Palette.warning
        case .failed: Palette.bad
        }
    }

    var icon: Reicon {
        switch self {
        case .protected: .shieldCheck
        case .attention, .failed: .warning
        }
    }
}

struct HealthChip: View {
    let health: TargetRow.Health

    var body: some View {
        HStack(spacing: Spacing.s4) {
            IconView(health.icon, weight: .filled, size: 11)
            Text(health.title).textStyle(.caption)
        }
        .foregroundStyle(health.color)
        .padding(.horizontal, Spacing.s8)
        .padding(.vertical, Spacing.s2)
        .background(health.color.opacity(0.14), in: Capsule())
    }
}

struct SuggestionCard: View {
    let name: String
    let bundleID: String?
    let note: String
    let add: () -> Void

    var body: some View {
        HStack(spacing: Spacing.s12) {
            Image(nsImage: AppIcons.icon(for: bundleID)).resizable().frame(width: 40, height: 40).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.s4) {
                Text(name).textStyle(.subheading).foregroundStyle(Palette.ink)
                Text(note).textStyle(.caption).foregroundStyle(Palette.muted).lineLimit(2).truncationMode(.middle)
            }
            Spacer(minLength: Spacing.s8)
            PillButton(String(localized: "Add"), icon: .plus, action: add)
        }
        .padding(Spacing.s12)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.hairline))
        .accessibilityElement(children: .combine)
    }
}

/// A full-width notice with one action: a faint wash of its tone, all four sides alike.
struct Banner: View {
    let icon: Reicon
    let tone: Color
    let text: String
    let action: String
    let perform: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.s12) {
            IconView(icon, weight: .filled, size: 16).foregroundStyle(tone)
            Text(text).textStyle(.body).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.s8)
            PillButton(action, action: perform)
        }
        .padding(Spacing.s12)
        .background(tone.opacity(0.10), in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

/// Real app icons by bundle ID; a Terminal icon for plain config files.
enum AppIcons {
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor
    static func icon(for bundleID: String?) -> NSImage {
        let key = bundleID ?? "com.apple.Terminal"
        if let cached = cache[key] { return cached }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key)
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        let image = url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .application)
        cache[key] = image
        return image
    }
}

extension NSView {
    func snapshot() -> NSBitmapImageRep? {
        layoutSubtreeIfNeeded()
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        return rep
    }
}
