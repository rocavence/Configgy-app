import SwiftUI

/// The one window: whether your settings are safe, and the one thing to do if not.
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
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
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
    @AppStorage(Accent.key) private var accent: Accent = .configgy
    @State private var restoring: TargetRow?
    @State private var removing: TargetRow?
    @State private var reviewingFindings = false
    @State private var askQuitZen = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.s24) {
                    StatusHero(model: model, backupAll: { Task { await model.backupAll() } }, openSettings: openSettings,
                               reviewFindings: { reviewingFindings = true })
                    // The hero shows one thing; a secret-files warning must never be hidden behind another.
                    if !model.findings.isEmpty, !StatusHero.isAboutFindings(model) {
                        Banner(icon: .warning, tone: Palette.warning,
                               text: String(localized: "\(model.findings.count) backups in the folder contain secret files (logins, keys or tokens) from before Configgy filtered them."),
                               action: String(localized: "Review…")) { reviewingFindings = true }
                    }
                    if !model.rows.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                                if index > 0 { Palette.hairline.frame(height: 1).padding(.leading, 60) }
                                TargetLine(row: row, busy: model.busy.contains(row.key),
                                           backup: { startBackup(row) },
                                           restore: { restoring = row },
                                           remove: row.key == "claude" ? nil : { removing = row })
                            }
                        }
                        .padding(.vertical, Spacing.s4)
                        .background(Palette.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.hairline))
                    }
                    suggestions
                }
                .padding(.horizontal, Spacing.s32)
                .padding(.top, Spacing.s8)
                .padding(.bottom, Spacing.s32)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            footer
        }
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
                restoring = model.rows.first { $0.key == "zen" }
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

    /// Sits in the title bar, right of the traffic lights.
    private var topBar: some View {
        HStack(spacing: Spacing.s8) {
            Text(verbatim: "Configgy").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.muted)
            Spacer()
            addMenu
            ToolbarIcon(.setting2, String(localized: "Settings"), action: openSettings)
        }
        .padding(.leading, 84)
        .padding(.trailing, Spacing.s16)
        .frame(height: 44)
    }

    private var addMenu: some View {
        Menu {
            if model.zenSuggested { Button("Zen Browser") { model.addZen() } }
            ForEach(model.suggestions, id: \.def.id) { suggestion in
                Button(suggestion.def.name) { model.addSuggestion(suggestion) }
            }
            if model.zenSuggested || !model.suggestions.isEmpty { Divider() }
            Button(String(localized: "Add Folder…"), action: addFolder)
        } label: {
            IconView(.plus, size: 16).foregroundStyle(Palette.muted).frame(width: 30, height: 28).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(String(localized: "Add"))
        .accessibilityLabel(Text("Add"))
    }

    @ViewBuilder
    private var suggestions: some View {
        VStack(alignment: .leading, spacing: Spacing.s12) {
            Text("Also worth protecting").textStyle(.micro).textCase(.uppercase).foregroundStyle(Palette.muted)
            ChipLayout(spacing: Spacing.s8) {
                if model.zenSuggested {
                    SuggestionChip(name: "Zen Browser", bundleID: ZenTarget.bundleID,
                                   help: String(localized: "Settings, extensions and workspaces; backs up each time you quit Zen.")) { model.addZen() }
                }
                ForEach(model.suggestions, id: \.def.id) { s in
                    SuggestionChip(name: s.def.name, bundleID: s.def.app, help: s.note.isEmpty ? s.def.paths.joined(separator: "\n") : s.note) {
                        model.addSuggestion(s)
                    }
                }
                SuggestionChip(name: String(localized: "Add Folder…"), bundleID: nil, icon: .folderAdd, help: nil, action: addFolder)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Spacing.s8) {
            if let base = model.context.base, model.location == .ok {
                IconView(.cloud, size: 13).foregroundStyle(Palette.good)
                Text("\(BackupLocation.provider(of: base, home: model.context.home).title) · \(model.context.abbreviate(base))")
                    .lineLimit(1).truncationMode(.middle).help(base)
            }
            Spacer()
            Button(String(localized: "Backup Folder")) { model.openBackupFolder() }.disabled(model.context.base == nil)
            Text(verbatim: "·").foregroundStyle(Palette.faint)
            Button(String(localized: "Log")) { model.openLog() }
        }
        .buttonStyle(.plain)
        .textStyle(.caption)
        .foregroundStyle(Palette.muted)
        .padding(.horizontal, Spacing.s24)
        .frame(height: 34)
        .overlay(alignment: .top) { Palette.hairline.frame(height: 1) }
    }

    private func startBackup(_ row: TargetRow) {
        if row.key == "zen", ZenTarget.isRunning { askQuitZen = true } else { Task { await model.backup(row.key) } }
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
    }
}

// MARK: - The answer first

/// One sentence that answers "are my settings safe?", and the one thing to do if not.
private struct StatusHero: View {
    let model: AppModel
    let backupAll: () -> Void
    let openSettings: () -> Void
    let reviewFindings: () -> Void

    private enum Mood { case good, attention, bad, empty }

    /// Whether the hero is currently the secret-files warning (so it isn't shown twice).
    static func isAboutFindings(_ model: AppModel) -> Bool {
        model.location == .ok && !model.rows.isEmpty && !model.findings.isEmpty
            && !model.rows.contains { $0.health == .failed }
    }

    private struct Summary {
        let mood: Mood
        let title: String
        let detail: String
        let action: String?
        let perform: (() -> Void)?
    }

    private var summary: Summary {
        let rows = model.rows
        switch model.location {
        case .notChosen:
            return Summary(mood: .attention, title: String(localized: "Choose where to keep backups"),
                           detail: String(localized: "Nothing is backed up until Configgy has a folder to put backups in."),
                           action: String(localized: "Choose…"), perform: openSettings)
        case .missing(let path):
            return Summary(mood: .bad, title: String(localized: "The backup folder isn't available"),
                           detail: String(localized: "\(model.context.abbreviate(path)) is missing. Check that the cloud app is running, or choose another folder."),
                           action: String(localized: "Choose…"), perform: openSettings)
        case .notWritable:
            return Summary(mood: .bad, title: String(localized: "Configgy can't save backups yet"),
                           detail: String(localized: "It needs Full Disk Access. Add Configgy in the list that opens, then quit and reopen it."),
                           action: String(localized: "Grant Access…"), perform: { model.openFullDiskAccess() })
        case .ok:
            break
        }
        if rows.isEmpty {
            return Summary(mood: .empty, title: String(localized: "Nothing is protected yet"),
                           detail: String(localized: "Add the apps whose settings you'd hate to lose."), action: nil, perform: nil)
        }
        let failed = rows.filter { $0.health == .failed }
        if !failed.isEmpty {
            return Summary(mood: .bad,
                           title: failed.count == 1 ? String(localized: "\(failed[0].name) didn't back up") : String(localized: "\(failed.count) backups failed"),
                           detail: failed[0].reason, action: String(localized: "Try Again"), perform: backupAll)
        }
        if !model.findings.isEmpty {
            return Summary(mood: .attention, title: String(localized: "Some old backups hold secret files"),
                           detail: String(localized: "\(model.findings.count) backups from before 1.0 include logins or keys. Remove those files to keep the rest."),
                           action: String(localized: "Review…"), perform: reviewFindings)
        }
        let pending = rows.filter { $0.health == .attention }
        if !pending.isEmpty {
            return Summary(mood: .attention,
                           title: pending.count == 1 ? String(localized: "\(pending[0].name) isn't backed up") : String(localized: "\(pending.count) items aren't backed up"),
                           detail: pending.count == 1 ? pending[0].reason : pending.map(\.name).joined(separator: "、"),
                           action: String(localized: "Back Up Now"), perform: backupAll)
        }
        if !rows.contains(where: { $0.health == .protected }) {
            return Summary(mood: .empty, title: String(localized: "Nothing to back up on this Mac"),
                           detail: String(localized: "None of the protected apps are set up here. Restore one to bring its settings to this Mac."),
                           action: nil, perform: nil)
        }
        let latest = rows.filter { $0.health == .protected }.compactMap { $0.newest?.date }.max()
        let place = model.context.base.map { BackupLocation.provider(of: $0, home: model.context.home).title } ?? ""
        return Summary(mood: .good, title: String(localized: "Your settings are backed up"),
                       detail: latest.map { String(localized: "Last backup \(RelativeTime.describe($0).lowercasedIfEnglish), in \(place).") } ?? "",
                       action: nil, perform: nil)
    }

    var body: some View {
        let s = summary
        HStack(alignment: .center, spacing: Spacing.s20) {
            ZStack {
                Circle().fill(color(s.mood).opacity(0.14)).frame(width: 64, height: 64)
                Image(systemName: symbol(s.mood)).font(.system(size: 28, weight: .semibold)).foregroundStyle(color(s.mood))
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.s4) {
                Text(s.title).font(.system(size: 22, weight: .semibold)).tracking(-0.3).foregroundStyle(Palette.ink)
                if !s.detail.isEmpty {
                    Text(s.detail).textStyle(.body).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Spacing.s16)
            if let action = s.action, let perform = s.perform {
                PrimaryButton(title: action, action: perform).disabled(!model.busy.isEmpty)
            } else if s.mood == .good {
                Button(String(localized: "Back Up Now"), action: backupAll)
                    .buttonStyle(.plain).textStyle(.bodyEmphasis).foregroundStyle(.accentText)
                    .disabled(!model.busy.isEmpty)
            }
        }
        .padding(.vertical, Spacing.s16)
        .accessibilityElement(children: .combine)
    }

    private func color(_ mood: Mood) -> Color {
        switch mood {
        case .good: Palette.good
        case .attention: Palette.warning
        case .bad: Palette.bad
        case .empty: Palette.muted
        }
    }

    private func symbol(_ mood: Mood) -> String {
        switch mood {
        case .good: "checkmark"
        case .attention: "exclamationmark"
        case .bad: "xmark"
        case .empty: "plus"
        }
    }
}

/// The filled accent button: the one thing to do now.
private struct PrimaryButton: View {
    let title: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @AppStorage(Accent.key) private var accent: Accent = .configgy
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title).textStyle(.bodyEmphasis).foregroundStyle(accent.onAccent)
                .padding(.horizontal, Spacing.s16).frame(height: 30)
                .background(.tint, in: Capsule())
                .brightness(hovering ? 0.04 : 0)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.5)
        .onHover { hovering = $0 }
    }
}

/// One target in plain words: what it is, when it was last backed up, and what to do.
private struct TargetLine: View {
    let row: TargetRow
    let busy: Bool
    let backup: () -> Void
    let restore: () -> Void
    let remove: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Spacing.s12) {
            Image(nsImage: AppIcons.icon(for: row.bundleID)).resizable().frame(width: 36, height: 36).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Palette.ink)
                HStack(spacing: 5) {
                    if busy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: row.health.symbol).font(.system(size: 11)).foregroundStyle(row.health.color)
                    }
                    Text(sentence).textStyle(.body)
                        .foregroundStyle(row.health == .protected || row.health == .unavailable ? Palette.muted : row.health.color)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                if let history {
                    Text(history).textStyle(.caption).foregroundStyle(Palette.faint)
                }
            }
            Spacer(minLength: Spacing.s12)
            if row.newest != nil {
                Button(String(localized: "Restore…"), action: restore)
                    .buttonStyle(.plain).textStyle(.body).foregroundStyle(Palette.muted)
                    .padding(.horizontal, Spacing.s8)
                    .disabled(busy)
            }
            if row.health == .unavailable {
                EmptyView()
            } else if row.health == .protected {
                Button(action: backup) {
                    Text("Back Up").textStyle(.bodyEmphasis).foregroundStyle(.accentText)
                        .padding(.horizontal, Spacing.s12).frame(height: 28)
                        .background(.tint.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain).disabled(busy).opacity(busy ? 0.4 : 1)
            } else {
                PrimaryButton(title: row.health == .failed ? String(localized: "Try Again") : String(localized: "Back Up"), action: backup)
                    .disabled(busy)
            }
            if let remove {
                Menu {
                    Button(row.key == "zen" ? String(localized: "Stop Backing Up Zen…") : String(localized: "Remove…"), role: .destructive, action: remove)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.muted).frame(width: 22, height: 28).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .opacity(hovering ? 1 : 0.5)
                .accessibilityLabel(Text("More actions for \(row.name)"))
            } else {
                Color.clear.frame(width: 22, height: 28)   // keeps buttons aligned across rows
            }
        }
        .padding(.horizontal, Spacing.s12)
        .padding(.vertical, Spacing.s12)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
    }

    /// "Backed up today 14:55." / the reason it needs attention.
    private var sentence: String {
        if busy { return String(localized: "Backing up…") }
        if row.health == .protected, let date = row.newest?.date {
            return String(localized: "Backed up \(RelativeTime.describe(date).lowercasedIfEnglish).")
        }
        return row.reason
    }

    /// "10 backups you can restore, from this Mac and Roca-Work."
    private var history: String? {
        let total = row.mine + row.others
        guard total > 0 else { return nil }
        let macs = Set(row.snapshots.map(\.host))
        return macs.count > 1
            ? String(localized: "\(total) backups you can restore, from \(macs.count) Macs")
            : String(localized: "\(total) backups you can restore")
    }
}

private struct ToolbarIcon: View {
    let icon: Reicon
    let label: String
    let action: () -> Void
    @State private var hovering = false

    init(_ icon: Reicon, _ label: String, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            IconView(icon, size: 16).foregroundStyle(Palette.muted)
                .frame(width: 30, height: 28)
                .background(hovering ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(Text(label))
    }
}

// MARK: - Suggestions

private struct ChipLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
        }
        return CGSize(width: width, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

private struct SuggestionChip: View {
    let name: String
    let bundleID: String?
    var icon: Reicon? = nil
    let help: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    IconView(icon, size: 14).foregroundStyle(Palette.muted).frame(width: 18, height: 18)
                } else {
                    Image(nsImage: AppIcons.icon(for: bundleID)).resizable().frame(width: 18, height: 18)
                }
                Text(name).textStyle(.body).foregroundStyle(Palette.ink)
                Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(hovering ? AnyShapeStyle(.accentText) : AnyShapeStyle(Palette.faint))
            }
            .padding(.leading, 6).padding(.trailing, 10)
            .frame(height: 30)
            .background(hovering ? Palette.hover : Palette.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairline))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? "")
        .accessibilityLabel(Text("Add \(name)"))
    }
}

extension TargetRow.Health {
    var title: String {
        switch self {
        case .protected: String(localized: "Protected")
        case .attention: String(localized: "Needs Attention")
        case .failed: String(localized: "Failed")
        case .unavailable: String(localized: "Not on This Mac")
        }
    }

    var color: Color {
        switch self {
        case .protected: Palette.good
        case .attention: Palette.warning
        case .failed: Palette.bad
        case .unavailable: Palette.faint
        }
    }

    var symbol: String {
        switch self {
        case .protected: "checkmark.circle.fill"
        case .attention: "exclamationmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .unavailable: "minus.circle.fill"
        }
    }
}

extension String {
    /// "Backed up today 00:15" reads better than "Backed up Today 00:15" in English.
    var lowercasedIfEnglish: String {
        Locale.current.language.languageCode?.identifier == "en" ? prefix(1).lowercased() + dropFirst() : self
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
