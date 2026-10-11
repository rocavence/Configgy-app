import SwiftUI

/// First run: where backups go, Full Disk Access if that folder needs it, what
/// to protect, and what's never backed up.
struct OnboardingView: View {
    let model: AppModel
    var finish: () -> Void
    @State private var picked: Set<String> = []
    @State private var seeded = false
    @AppStorage(Accent.key) private var accent: Accent = .configgy

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s20) {
            HStack(spacing: Spacing.s12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.s2) {
                    Text("Welcome to Configgy").textStyle(.heading).foregroundStyle(Palette.ink).accessibilityAddTraits(.isHeader)
                    Text("Three things, about a minute.").textStyle(.body).foregroundStyle(Palette.muted)
                }
            }

            step(1, String(localized: "Where should backups go?"),
                 String(localized: "A folder your cloud app syncs, so your other Macs see the same backups.")) {
                HStack(spacing: Spacing.s8) {
                    ForEach(BackupLocation.Provider.allCases.filter { $0 != .custom }, id: \.self) { provider in
                        let path = BackupLocation.detect(provider, home: model.context.home)
                        choice(provider.title, selected: path != nil && model.context.base == path, enabled: path != nil) {
                            if let path { model.chooseLocation(path) }
                        }
                    }
                    LocationMenuButton(model: model)
                }
                if let base = model.context.base {
                    Text(model.context.abbreviate(base)).textStyle(.caption).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
                }
            }

            if case .notWritable = model.location {
                step(2, String(localized: "Allow access to that folder"),
                     String(localized: "macOS asks for Full Disk Access before an app can write to Dropbox. Add Configgy in the list that opens, turn it on, then quit and reopen Configgy.")) {
                    HStack(spacing: Spacing.s8) {
                        PillButton(String(localized: "Open Full Disk Access"), icon: .shieldCheck) { model.openFullDiskAccess() }
                        PillButton(String(localized: "Check Again"), icon: .refresh) { model.refresh() }
                    }
                }
            }

            step(model.location == .ok || model.location == .notChosen ? 2 : 3, String(localized: "What should be protected?"),
                 String(localized: "You can add or remove these later.")) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.s4) {
                        ForEach(candidates, id: \.id) { item in
                            Toggle(isOn: Binding(get: { picked.contains(item.id) }, set: { on in
                                if on { picked.insert(item.id) } else { picked.remove(item.id) }
                            })) {
                                HStack(spacing: Spacing.s8) {
                                    Image(nsImage: AppIcons.icon(for: item.bundleID)).resizable().frame(width: 20, height: 20)
                                    Text(item.name).textStyle(.body)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .disabled(item.id == "claude")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 140)
            }

            HStack(alignment: .top, spacing: Spacing.s8) {
                IconView(.shieldCheck, size: 14).foregroundStyle(Palette.good)
                Text("Never backed up: logins, passwords, cookies, keys, tokens, .env files and browsing sessions.")
                    .textStyle(.caption).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(action: done) {
                    Text("Start Protecting").textStyle(.bodyEmphasis).foregroundStyle(accent.onAccent)
                        .padding(.horizontal, Spacing.s20).frame(height: 32)
                        .background(.tint, in: RoundedRectangle(cornerRadius: Radius.ui, style: .continuous))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(model.context.base == nil)
                .opacity(model.context.base == nil ? 0.45 : 1)
            }
        }
        .padding(Spacing.s32)
        .frame(width: 600)
        .background(Palette.background.ignoresSafeArea())
        .tint(accent.color)
        .onAppear {
            guard !seeded else { return }
            seeded = true
            picked = ["claude"]
            if model.zenInstalled { picked.insert("zen") }
            for t in model.targets { picked.insert(t.key) }
        }
    }

    private struct Candidate { let id: String; let name: String; let bundleID: String? }

    private var candidates: [Candidate] {
        var list = [Candidate(id: "claude", name: "Claude Code", bundleID: "com.anthropic.claudefordesktop")]
        if model.zenInstalled { list.append(Candidate(id: "zen", name: "Zen Browser", bundleID: ZenTarget.bundleID)) }
        let current = Set(TargetCatalog.load(model.context.home).map(\.id))
        for def in TargetCatalog.load(model.context.home) { list.append(Candidate(id: "t:" + def.id, name: def.name, bundleID: def.app)) }
        for s in TargetCatalog.discover(home: model.context.home) where !current.contains(s.def.id) {
            list.append(Candidate(id: "t:" + s.def.id, name: s.def.name, bundleID: s.def.app))
        }
        return list
    }

    private func done() {
        model.updateSettings { s in
            s.zenEnabled = picked.contains("zen")
            s.onboarded = true
        }
        let current = TargetCatalog.load(model.context.home)
        var defs = current.filter { picked.contains("t:" + $0.id) }
        for s in TargetCatalog.discover(home: model.context.home) where picked.contains("t:" + s.def.id) && !defs.contains(where: { $0.id == s.def.id }) {
            defs.append(s.def)
        }
        TargetCatalog.save(defs, home: model.context.home)
        model.refresh()
        finish()
    }

    private func step<Content: View>(_ n: Int, _ title: String, _ detail: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: Spacing.s12) {
            Text(verbatim: "\(n)").textStyle(.bodyEmphasis).foregroundStyle(.accentText)
                .frame(width: 24, height: 24).background(.tint.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: Spacing.s8) {
                Text(title).textStyle(.subheading).foregroundStyle(Palette.ink)
                Text(detail).textStyle(.body).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                content()
            }
        }
    }

    private func choice(_ title: String, selected: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).textStyle(.bodyEmphasis)
                .foregroundStyle(selected ? AnyShapeStyle(accent.onAccent) : AnyShapeStyle(.accentText))
                .padding(.horizontal, Spacing.s12).frame(height: 30)
                .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.12)),
                            in: RoundedRectangle(cornerRadius: Radius.ui, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(enabled ? "" : String(localized: "\(title) isn't set up on this Mac."))
    }
}

private struct LocationMenuButton: View {
    let model: AppModel

    var body: some View {
        Button(String(localized: "Other Folder…")) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.directoryURL = URL(fileURLWithPath: model.context.home)
            panel.message = String(localized: "Choose a folder that syncs to the cloud. Configgy keeps its backups in a Configgy folder inside it.")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            model.chooseLocation(url.lastPathComponent == "Configgy" ? url.path : url.path + "/Configgy")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.accentText)
        .textStyle(.bodyEmphasis)
        .padding(.horizontal, Spacing.s12).frame(height: 30)
        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.ui, style: .continuous))
    }
}

@MainActor
final class OnboardingWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: AppModel
    var onFinish: () -> Void = {}
    var onClose: () -> Void = {}

    init(model: AppModel) { self.model = model }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.window?.contentView = nil
            self?.window = nil
            self?.onClose()
        }
    }

    func show(activate: Bool = true) {
        window?.close()
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = String(localized: "Welcome to Configgy")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: OnboardingView(model: model) { [weak self] in
            self?.window?.close()
            self?.onFinish()
        })
        window.setContentSize(window.contentView!.fittingSize)
        window.center()
        window.makeKeyAndOrderFront(nil)
        if activate { NSApp.activate() }
        self.window = window
    }

    func close() { window?.close() }
    func snapshot() -> NSBitmapImageRep? { window?.contentView?.snapshot() }
    var nsWindow: NSWindow? { window }
}
