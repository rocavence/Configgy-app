import SwiftUI

enum SettingsPage: String, CaseIterable {
    case general, backup, exclusions, about

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .backup: String(localized: "Backup")
        case .exclusions: String(localized: "Exclusions")
        case .about: String(localized: "About")
        }
    }

    var icon: Reicon {
        switch self {
        case .general: .setting2
        case .backup: .archive
        case .exclusions: .filter
        case .about: .infoCircle
        }
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    var page: SettingsPage = .general
}

/// Hosts `SettingsView` with the traffic lights over the card.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    let navigation = SettingsNavigation()
    var onClose: () -> Void = {}
    var showGuide: () -> Void = {} {
        didSet { host.rootView = SettingsView(model: model, navigation: navigation, showGuide: showGuide) }
    }
    private let model: AppModel
    private let window: NSWindow
    private let host: NSHostingView<SettingsView>

    init(model: AppModel) {
        self.model = model
        host = NSHostingView(rootView: SettingsView(model: model, navigation: navigation, showGuide: {}))
        host.sizingOptions = []
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = String(localized: "Settings")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init()
        window.contentView = host
        window.delegate = self
        window.setFrame(NSRect(x: 0, y: 0, width: 900, height: 600), display: false)
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.window.contentView = nil
            self?.onClose()
        }
    }

    func show(_ page: SettingsPage, activate: Bool = true) {
        navigation.page = page
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        if activate { NSApp.activate() }
    }

    func close() { window.close() }
    func snapshot() -> NSBitmapImageRep? { window.contentView?.snapshot() }
    var nsWindow: NSWindow { window }
}

/// Flione's settings card: 900 × 600, 32 all round, a 184-wide column of
/// pages, a hairline, then the page 24 in from it.
struct SettingsView: View {
    let model: AppModel
    @Bindable var navigation: SettingsNavigation
    var showGuide: () -> Void
    @AppStorage(Accent.key) private var accent: Accent = .configgy

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Settings").textStyle(.title).foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, Spacing.s8)
                    .padding(.bottom, Spacing.s20)
                VStack(alignment: .leading, spacing: Spacing.s2) {
                    ForEach(SettingsPage.allCases, id: \.self) { page in
                        SidebarRow(page: page, selected: page == navigation.page, accent: accent) { navigation.page = page }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: 184, alignment: .leading)
            .padding(.trailing, Spacing.s16)

            Palette.hairline.frame(width: 1).padding(.vertical, -Spacing.s32)

            VStack(alignment: .leading, spacing: 0) {
                Text(navigation.page.title).textStyle(.heading).foregroundStyle(Palette.ink)
                    .frame(height: 36, alignment: .leading)
                    .padding(.bottom, Spacing.s4)
                ScrollView {
                    Group {
                        switch navigation.page {
                        case .general: GeneralPage(model: model, showGuide: showGuide)
                        case .backup: BackupPage(model: model)
                        case .exclusions: ExclusionsPage(model: model)
                        case .about: AboutPage(updates: model.updates)
                        }
                    }
                    .padding(.bottom, Spacing.s24)
                }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize)
                .mask {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 28)
                    }
                }
            }
            .padding(.leading, Spacing.s24)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Spacing.s32)
        .padding(.top, Spacing.s32 + Spacing.s8)
        .padding(.bottom, Spacing.s32)
        .frame(width: 900, height: 600)
        .background {
            ZStack {
                Palette.background
                RadialGradient(colors: [accent.color.opacity(0.08), .clear], center: .top, startRadius: 0, endRadius: 420)
            }
            .ignoresSafeArea()
        }
        .tint(accent.color)
    }
}

private struct SidebarRow: View {
    let page: SettingsPage
    let selected: Bool
    let accent: Accent
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.s8) {
                IconView(page.icon, weight: selected ? .filled : .outline, size: 16).frame(width: 20)
                Text(page.title).textStyle(selected ? .bodyEmphasis : .body).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? AnyShapeStyle(accent.onAccent) : AnyShapeStyle(Palette.ink.opacity(0.82)))
            .padding(.horizontal, Spacing.s8)
            .frame(height: 32)
            .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(hovering ? Palette.hover : .clear),
                        in: RoundedRectangle(cornerRadius: Radius.ui, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.ui, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - General

private struct GeneralPage: View {
    let model: AppModel
    var showGuide: () -> Void
    @State private var language = AppLanguage.saved
    @State private var loginEnabled = LoginItem.isEnabled
    @State private var loginError: String?
    @AppStorage(AppAppearance.key) private var appearance: AppAppearance = .system
    @AppStorage(Accent.key) private var accent: Accent = .configgy

    var body: some View {
        VStack(spacing: 0) {
            SettingRow(title: String(localized: "Language"),
                       detail: language == AppLanguage.launched ? nil : String(localized: "Takes effect when Configgy opens again.")) {
                HStack(spacing: Spacing.s8) {
                    if language != AppLanguage.launched {
                        PillButton(String(localized: "Reopen")) { AppLanguage.relaunch() }
                    }
                    PillMenu(title: String(localized: "Language"), selection: $language, options: AppLanguage.allCases.map { ($0, $0.title) })
                }
            }
            .onChange(of: language) { AppLanguage.save(language) }
            SettingRow(title: String(localized: "Appearance"), detail: String(localized: "For Configgy's windows.")) {
                PillMenu(title: String(localized: "Appearance"), selection: $appearance, options: AppAppearance.allCases.map { ($0, $0.title) })
            }
            .onChange(of: appearance) { AppAppearance.apply(appearance) }
            SettingRow(title: String(localized: "Accent Color"), detail: String(localized: "Marks what's chosen and what's on.")) {
                PillMenu(title: String(localized: "Accent Color"), selection: $accent, options: Accent.allCases.map { ($0, $0.title) })
            }
            SettingRow(title: String(localized: "Launch at Login"), detail: loginDetail) {
                HStack(spacing: Spacing.s8) {
                    if LoginItem.needsApproval || loginError != nil {
                        PillButton(String(localized: "Open Login Items")) { LoginItem.openSystemSettings() }
                    }
                    Toggle(isOn: Binding(get: { loginEnabled }, set: { on in
                        loginError = LoginItem.setEnabled(on)
                        loginEnabled = LoginItem.isEnabled
                    })) { Text("Launch at Login") }
                    .labelsHidden().toggleStyle(PillSwitchStyle())
                }
            }
            SettingRow(title: String(localized: "Setup Guide"), detail: String(localized: "Choose the backup folder and what to protect again.")) {
                PillButton(String(localized: "Show Guide"), action: showGuide)
            }
        }
    }

    private var loginDetail: String {
        if let loginError { return String(localized: "Couldn't turn this on: \(loginError)") }
        if LoginItem.needsApproval { return String(localized: "macOS is waiting for your OK in System Settings › Login Items.") }
        return String(localized: "Start Configgy when you log in, so Zen is backed up from the first time you quit it.")
    }
}

// MARK: - Backup

private struct BackupPage: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            SettingRow(title: String(localized: "Backup Folder"), detail: locationDetail) {
                LocationMenu(model: model)
            }
            SettingRow(title: String(localized: "Backups to Keep"),
                       detail: String(localized: "For each target, counted separately on each Mac. Older ones made on this Mac are deleted; other Macs' are never touched.")) {
                Stepper(value: Binding(get: { model.settings.keep }, set: { v in model.updateSettings { $0.keep = v } }), in: 3...50) {
                    Text("\(model.settings.keep)").textStyle(.bodyEmphasis).monospacedDigit().frame(minWidth: 28, alignment: .trailing)
                }
                .fixedSize()
            }
            if model.settings.zenEnabled {
                SettingToggle(title: String(localized: "Back Up Zen Automatically"),
                              detail: String(localized: "Each time you quit Zen, its settings and workspaces are backed up if they changed."),
                              isOn: Binding(get: { model.settings.zenAutoBackup }, set: { v in model.updateSettings { $0.zenAutoBackup = v } }))
            }
            SettingRow(title: String(localized: "Log"), detail: Log.file(home: model.context.home).replacingOccurrences(of: model.context.home, with: "~")) {
                PillButton(String(localized: "Open"), icon: .documentText) { model.openLog() }
            }
            SettingRow(title: String(localized: "Copies Saved Before Restoring"),
                       detail: String(localized: "Before each restore, the files it replaces are saved here (5 per target).")) {
                PillButton(String(localized: "Show"), icon: .folder) {
                    let dir = model.context.supportDir + "/before-restore"
                    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(URL(fileURLWithPath: dir))
                }
            }
        }
    }

    private var locationDetail: String {
        switch model.location {
        case .ok: return model.context.base.map(model.context.abbreviate) ?? ""
        case .notChosen: return String(localized: "Not chosen yet.")
        case .missing(let p): return String(localized: "Missing: \(model.context.abbreviate(p))")
        case .notWritable(let p): return String(localized: "Can't write to \(model.context.abbreviate(p)); grant Full Disk Access.")
        }
    }
}

/// Dropbox, iCloud Drive, Google Drive (when set up here), or any folder.
struct LocationMenu: View {
    let model: AppModel

    var body: some View {
        Menu {
            ForEach(BackupLocation.Provider.allCases.filter { $0 != .custom }, id: \.self) { provider in
                let path = BackupLocation.detect(provider, home: model.context.home)
                Button(path == nil ? String(localized: "\(provider.title) (not set up)") : provider.title) {
                    if let path { model.chooseLocation(path) }
                }
                .disabled(path == nil)
            }
            Divider()
            Button(String(localized: "Other Folder…")) { chooseFolder() }
        } label: {
            HStack(spacing: Spacing.s4) {
                Text(model.context.base.map { BackupLocation.provider(of: $0, home: model.context.home).title } ?? String(localized: "Choose…"))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .textStyle(.bodyEmphasis)
            .foregroundStyle(.accentText)
            .padding(.horizontal, Spacing.s12)
            .frame(height: 32)
            .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.ui, style: .continuous))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: model.context.home)
        panel.message = String(localized: "Choose a folder that syncs to the cloud. Configgy keeps its backups in a Configgy folder inside it.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.chooseLocation(url.lastPathComponent == "Configgy" ? url.path : url.path + "/Configgy")
    }
}

// MARK: - Exclusions

private struct ExclusionsPage: View {
    let model: AppModel
    @State private var newPattern = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Note(String(localized: "Configgy only copies files it knows are settings. Secret files are never copied, and are never written back from an older backup that still has them."))
            group(String(localized: "Never Backed Up"), String(localized: "Logins, keys, tokens, cookies, saved passwords and session history, for every target."),
                  Sensitive.filePatterns + Sensitive.directoryPatterns.map { $0 + "/" })
            group("Claude Code", String(localized: "From ~/.claude, only these, plus ~/.agents/skills:"),
                  ClaudeTarget.files + ClaudeTarget.folders.map { $0 + "/" } + ClaudeTarget.pluginFiles + ["projects/*/memory/"])
            group("Zen Browser", String(localized: "From the profile, only these:"), ZenTarget.files + ZenTarget.folders.map { $0 + "/" })

            VStack(alignment: .leading, spacing: Spacing.s8) {
                Text("Custom Folders").textStyle(.subheading).foregroundStyle(Palette.ink)
                Text("Also skipped inside folders you add. A trailing / means a folder with that name.").textStyle(.body).foregroundStyle(Palette.muted)
                FlowList(items: model.settings.folderExcludes) { pattern in
                    model.updateSettings { $0.folderExcludes.removeAll { $0 == pattern } }
                }
                HStack(spacing: Spacing.s8) {
                    TextField(String(localized: "Add a pattern, like *.log"), text: $newPattern)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                        .onSubmit(add)
                    PillButton(String(localized: "Add"), icon: .plus, action: add).disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                    PillButton(String(localized: "Reset")) { model.updateSettings { $0.folderExcludes = Sensitive.defaultFolderExcludes } }
                }
            }
            .padding(.vertical, Spacing.s16)
        }
    }

    private func add() {
        let pattern = newPattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return }
        model.updateSettings { if !$0.folderExcludes.contains(pattern) { $0.folderExcludes.append(pattern) } }
        newPattern = ""
    }

    private func group(_ title: String, _ detail: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s8) {
            Text(title).textStyle(.subheading).foregroundStyle(Palette.ink)
            Text(detail).textStyle(.body).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            FlowList(items: items, remove: nil)
        }
        .padding(.vertical, Spacing.s16)
        .overlay(alignment: .bottom) { Palette.hairline.frame(height: 1) }
    }
}

/// Patterns as small monospaced tags that wrap; removable when `remove` is given.
private struct FlowList: View {
    let items: [String]
    let remove: ((String) -> Void)?

    var body: some View {
        WrapLayout(spacing: Spacing.s4) {
            ForEach(items, id: \.self) { item in
                HStack(spacing: Spacing.s4) {
                    Text(item).font(.system(size: 11.5, design: .monospaced))
                    if let remove {
                        Button { remove(item) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Remove \(item)"))
                    }
                }
                .foregroundStyle(Palette.ink.opacity(0.85))
                .padding(.horizontal, Spacing.s8)
                .padding(.vertical, 3)
                .background(Palette.hover, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
    }
}

/// Lays children out left to right, wrapping to new lines.
private struct WrapLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 500
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

// MARK: - About

private struct AboutPage: View {
    let updates: UpdateChecker

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "") (\(info?["CFBundleVersion"] as? String ?? ""))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s24) {
            DeveloperCard().padding(.top, Spacing.s16)
            HStack(spacing: Spacing.s16) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.s4) {
                    Text(verbatim: "Configgy").textStyle(.subheading).foregroundStyle(Palette.ink)
                    Text("Your app settings, kept safe in your own cloud folder.").textStyle(.body).foregroundStyle(Palette.muted)
                    Text("Version \(version)").textStyle(.caption).foregroundStyle(Palette.faint)
                    updateRow.padding(.top, Spacing.s2)
                }
            }
            section(String(localized: "Why Configgy"), [
                String(localized: "Zen, Claude Code and a dozen small tools each keep their settings in their own corner of the Mac, and most of them never sync. Setting up a new Mac, or recovering from a bad change, meant redoing it all by hand."),
                String(localized: "Configgy keeps versioned copies of exactly those settings in a cloud folder you already have, never your logins or keys, and puts them back on any of your Macs with a preview of what will change."),
            ])
            VStack(alignment: .leading, spacing: Spacing.s12) {
                heading(String(localized: "Thanks"))
                credit("Reicon", url: "https://github.com/dqev/reicon", detail: String(localized: "The menu bar and window icons."))
                credit("XcodeGen", url: "https://github.com/yonaskolb/XcodeGen", detail: String(localized: "Generates the Xcode project."))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var updateRow: some View {
        HStack(spacing: Spacing.s8) {
            switch updates.state {
            case .checking:
                ProgressView().controlSize(.small)
                Text("Checking for updates…").textStyle(.caption).foregroundStyle(Palette.muted)
            case .available(let release):
                Text("Configgy \(release.version) is available").textStyle(.caption).foregroundStyle(Palette.ink)
                Button(String(localized: "Download")) { NSWorkspace.shared.open(release.page) }
                    .buttonStyle(.plain).foregroundStyle(.accentText).textStyle(.caption)
            case .upToDate:
                Text("Configgy is up to date.").textStyle(.caption).foregroundStyle(Palette.muted)
                checkButton
            case .failed:
                Text("Couldn't check for updates.").textStyle(.caption).foregroundStyle(Palette.muted)
                checkButton
            case .idle:
                checkButton
            }
        }
    }

    private var checkButton: some View {
        Button(String(localized: "Check for Updates")) { Task { await updates.check(manual: true) } }
            .buttonStyle(.plain).foregroundStyle(.accentText).textStyle(.caption)
    }

    private func heading(_ title: String) -> some View {
        Text(title).textStyle(.micro).textCase(.uppercase).foregroundStyle(Palette.muted)
    }

    private func section(_ title: String, _ paragraphs: [String]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s8) {
            heading(title)
            ForEach(paragraphs, id: \.self) { paragraph in
                Text(paragraph).textStyle(.body).foregroundStyle(Palette.ink.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            }
        }
    }

    private func credit(_ name: String, url: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s4) {
            Link(destination: URL(string: url)!) {
                HStack(spacing: Spacing.s4) {
                    Text(verbatim: name).textStyle(.bodyEmphasis)
                    IconView(.arrowUpRight, size: 11)
                }
                .foregroundStyle(.accentText)
            }
            .buttonStyle(.plain)
            Text(detail).textStyle(.body).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The author card shared with Flione, Wunder, Findly and Gamely.
private struct DeveloperCard: View {
    @State private var hovering = false

    var body: some View {
        Link(destination: URL(string: "https://github.com/rocavence")!) {
            HStack(spacing: Spacing.s12) {
                Image("DeveloperAvatar").resizable().frame(width: 42, height: 42).clipShape(Circle()).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.s2) {
                    Text(verbatim: "@rocavence").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
                    Text("Author · GitHub").font(.system(size: 12.5)).foregroundStyle(Palette.muted)
                }
            }
            .padding(.leading, Spacing.s8)
            .padding(.trailing, Spacing.s16)
            .padding(.vertical, Spacing.s8)
            .overlay(Capsule().strokeBorder(Palette.hairline))
            .background { if hovering { Capsule().fill(Palette.background).shadow(color: .black.opacity(0.2), radius: 12, y: 6) } }
            .offset(y: hovering ? -2 : 0)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.2), value: hovering)
        .accessibilityLabel("rocavence on GitHub")
    }
}
