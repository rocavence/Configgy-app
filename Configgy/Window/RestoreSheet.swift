import SwiftUI

/// An unpacked snapshot waiting to be restored; its scratch folder goes away with it.
final class RestoreSession: @unchecked Sendable {
    let temp: String
    let root: String
    let workspaces: [(uuid: String, label: String)]

    init(snapshot: Snapshot) throws {
        temp = (NSTemporaryDirectory() as NSString).appendingPathComponent("configgy-restore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: temp, withIntermediateDirectories: true)
        do {
            root = try BackupService.unpack(snapshot, into: temp)
        } catch {
            try? FileManager.default.removeItem(atPath: temp)
            throw error
        }
        workspaces = ZenWorkspaces.list(in: root)
    }

    deinit { try? FileManager.default.removeItem(atPath: temp) }

    func plan(for target: BackupTarget, workspaces: Set<String>?) throws -> RestorePlan {
        if let workspaces, let zen = target as? ZenTarget, let profile = zen.profile {
            return try ZenWorkspaces.mergePlan(snapshot: root, profile: profile, uuids: workspaces, output: temp + "/merged-\(UUID().uuidString)")
        }
        return try target.restorePlan(from: root)
    }
}

/// Restore, in three steps: pick a backup (grouped by Mac), see exactly what
/// changes, then apply. The current files are saved first.
struct RestoreSheet: View {
    let model: AppModel
    let target: BackupTarget
    /// A snapshot picked on the timeline: skips straight to the preview.
    var initial: Snapshot? = nil
    let done: () -> Void

    private enum Step { case choose, loading, review, running, finished }

    @State private var step: Step = .choose
    @State private var snapshots: [Snapshot] = []
    @State private var selected: Snapshot?
    @State private var session: RestoreSession?
    @State private var onlyWorkspaces = false
    @State private var chosenWorkspaces: Set<String> = []
    @State private var plan: RestorePlan?
    @State private var changes: ChangeSet?
    @State private var error: String?
    @State private var summary = ""
    @State private var notes: [String] = []
    @State private var askQuit = false
    @AppStorage(Accent.key) private var accent: Accent = .configgy

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s16) {
            HStack(spacing: Spacing.s12) {
                Image(nsImage: AppIcons.icon(for: target.bundleID)).resizable().frame(width: 32, height: 32).accessibilityHidden(true)
                Text("Restore \(target.name)").textStyle(.heading).foregroundStyle(Palette.ink)
            }
            content
            if let error {
                Text(error).textStyle(.body).foregroundStyle(Palette.bad).fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
        .padding(Spacing.s24)
        .frame(width: 580, height: 520)
        .tint(accent.color)
        .task {
            snapshots = target.store.list().reversed()
            selected = initial ?? snapshots.first
            if initial != nil { await load() }
        }
        .alert(String(localized: "Quit Zen to restore?"), isPresented: $askQuit) {
            Button(String(localized: "Quit Zen and Restore")) { Task { await apply(quittingZen: true) } }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("Zen has to be closed while its files are replaced. It reopens when the restore is done.")
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .choose:
            Text("Which backup?").textStyle(.subheading).foregroundStyle(Palette.ink)
            List(selection: $selected) {
                ForEach(hosts, id: \.self) { host in
                    Section(host == model.context.host ? String(localized: "\(host) (this Mac)") : host) {
                        ForEach(snapshots.filter { $0.host == host }) { snapshot in
                            snapshotRow(snapshot).tag(Optional(snapshot))
                        }
                    }
                }
            }
            .listStyle(.inset)
            .frame(maxHeight: .infinity)
        case .loading, .running:
            VStack(spacing: Spacing.s12) {
                ProgressView()
                Text(step == .loading ? "Checking the backup…" : "Restoring…").textStyle(.body).foregroundStyle(Palette.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .review:
            review
        case .finished:
            VStack(alignment: .leading, spacing: Spacing.s12) {
                HStack(spacing: Spacing.s8) {
                    IconView(.checkCircle, weight: .filled, size: 20).foregroundStyle(Palette.good)
                    Text(summary).textStyle(.body).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(notes, id: \.self) { Text($0).textStyle(.body).foregroundStyle(Palette.warning).fixedSize(horizontal: false, vertical: true) }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var review: some View {
        if target is ZenTarget, let session {
            Picker("", selection: $onlyWorkspaces) {
                Text("Everything").tag(false)
                Text("Only Some Workspaces").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .onChange(of: onlyWorkspaces) { recompute() }
            if onlyWorkspaces {
                Text("Chosen workspaces join Zen's current ones (or replace ones with the same name); everything else stays.")
                    .textStyle(.caption).foregroundStyle(Palette.muted)
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.s4) {
                        ForEach(session.workspaces, id: \.uuid) { workspace in
                            Toggle(workspace.label, isOn: Binding(
                                get: { chosenWorkspaces.contains(workspace.uuid) },
                                set: { on in
                                    if on { chosenWorkspaces.insert(workspace.uuid) } else { chosenWorkspaces.remove(workspace.uuid) }
                                    recompute()
                                }))
                            .toggleStyle(.checkbox)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
        }
        if let changes {
            Text(changeSummary(changes)).textStyle(.body).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(changes.modified, id: \.self) { change("~", $0, Palette.warning) }
                ForEach(changes.added, id: \.self) { change("+", $0, Palette.good) }
                if !changes.rejected.isEmpty {
                    Section(String(localized: "Skipped: secrets, or outside this target")) {
                        ForEach(changes.rejected, id: \.self) { change("✗", $0, Palette.faint) }
                    }
                }
            }
            .listStyle(.inset)
            .frame(maxHeight: .infinity)
        }
    }

    private var buttons: some View {
        HStack {
            if step == .review {
                Button(String(localized: "Back")) { step = .choose; error = nil }
            }
            Spacer()
            if step == .finished {
                Button(String(localized: "Done"), action: done).keyboardShortcut(.defaultAction)
            } else {
                Button(String(localized: "Cancel"), action: done).keyboardShortcut(.cancelAction)
                    .disabled(step == .running)
                switch step {
                case .choose:
                    Button(String(localized: "Next")) { Task { await load() } }
                        .keyboardShortcut(.defaultAction).disabled(selected == nil)
                case .review:
                    Button(String(localized: "Restore")) { startApply() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(changes?.isEmpty ?? true)
                default:
                    EmptyView()
                }
            }
        }
    }

    private var hosts: [String] {
        var seen: [String] = []
        for s in snapshots where !seen.contains(s.host) { seen.append(s.host) }
        return seen
    }

    private func snapshotRow(_ snapshot: Snapshot) -> some View {
        HStack {
            Text(snapshot.date.map { RelativeTime.describe($0) } ?? snapshot.name).textStyle(.body)
            Spacer()
            if let files = snapshot.meta?.files { Text("\(files) files").textStyle(.caption).foregroundStyle(Palette.muted) }
            if let workspaces = snapshot.meta?.summary?.workspaces, !workspaces.isEmpty {
                Text(workspaces.prefix(3).joined(separator: " · ")).textStyle(.caption).foregroundStyle(Palette.muted).lineLimit(1)
            }
        }
        .help(snapshot.date.map { RelativeTime.full($0) } ?? snapshot.name)
    }

    private func change(_ mark: String, _ path: String, _ color: Color) -> some View {
        HStack(spacing: Spacing.s8) {
            Text(mark).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(color).frame(width: 14)
            Text(model.context.abbreviate(path)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.ink)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    private func changeSummary(_ changes: ChangeSet) -> String {
        if changes.isEmpty { return String(localized: "This backup matches what's on this Mac. Nothing to restore.") }
        return String(localized: "\(changes.modified.count) files will be replaced and \(changes.added.count) added. Configgy saves the current versions first.")
    }

    // MARK: Actions

    private func load() async {
        guard let selected else { return }
        step = .loading
        error = nil
        do {
            let session = try await Task.detached { try RestoreSession(snapshot: selected) }.value
            self.session = session
            onlyWorkspaces = false
            chosenWorkspaces = []
            recompute()
            step = .review
        } catch {
            self.error = error.localizedDescription
            step = .choose
        }
    }

    private func recompute() {
        guard let session else { return }
        let workspaces: Set<String>? = onlyWorkspaces ? chosenWorkspaces : nil
        if onlyWorkspaces && chosenWorkspaces.isEmpty {
            plan = RestorePlan()
            changes = ChangeSet()
            return
        }
        do {
            let plan = try session.plan(for: target, workspaces: workspaces)
            self.plan = plan
            changes = BackupService.preview(plan)
            error = nil
        } catch {
            self.error = error.localizedDescription
            changes = nil
        }
    }

    private func startApply() {
        if target.appToClose != nil, ZenTarget.isRunning { askQuit = true } else { Task { await apply(quittingZen: false) } }
    }

    private func apply(quittingZen: Bool) async {
        guard let plan, let selected else { return }
        step = .running
        error = nil
        let isZen = target is ZenTarget
        if isZen { model.setZenRestoring(true) }
        defer { if isZen { model.setZenRestoring(false) } }
        if quittingZen, !(await model.quitZen()) {
            error = String(localized: "Zen didn't quit, so nothing was changed.")
            step = .review
            return
        }
        let target = target, context = model.context
        do {
            let outcome = try await Task.detached { try BackupService.apply(plan, target: target, label: selected.name, context: context) }.value
            var extra: [String] = []
            if let claude = target as? ClaudeTarget {
                extra = await Task.detached { claude.reinstallPlugins() }.value
            }
            if isZen {
                StatusFile.update(context.home) { status in
                    if !onlyWorkspaces { status.zenCurrent = selected.name }
                    status.zenDismissed = target.store.newest()?.name
                }
                if quittingZen { model.openZen() }
            }
            summary = String(localized: "Restored \(outcome.written) files from \(selected.host), \(selected.date.map { RelativeTime.describe($0) } ?? selected.name).")
            if !outcome.rejected.isEmpty { extra.append(String(localized: "\(outcome.rejected.count) files were skipped: secrets, or outside this target.")) }
            notes = extra
            step = .finished
            model.refresh()
        } catch {
            self.error = error.localizedDescription
            step = .review
            model.refresh()
        }
    }
}

/// Backups that still hold secret files: remove those files (the default) or delete the backups.
struct FindingsSheet: View {
    let model: AppModel
    let done: () -> Void
    @State private var working = false
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s16) {
            Text("Secret files in older backups").textStyle(.heading).foregroundStyle(Palette.ink)
            Text("These backups were made before Configgy filtered secrets. Removing the files keeps the rest of each backup. Either way, also sign out and back in to the apps listed, so the old logins stop working, and empty the cloud folder's deleted-files history.")
                .textStyle(.body).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(model.findings) { finding in
                    Section("\(finding.targetName) · \(finding.snapshot.name)") {
                        ForEach(finding.paths.prefix(8), id: \.self) { Text($0).font(.system(size: 12, design: .monospaced)) }
                        if finding.paths.count > 8 { Text("and \(finding.paths.count - 8) more").textStyle(.caption).foregroundStyle(Palette.muted) }
                    }
                }
            }
            .listStyle(.inset)
            HStack {
                Button(String(localized: "Delete These Backups…"), role: .destructive) { confirmDelete = true }.disabled(working)
                Spacer()
                Button(String(localized: "Close"), action: done).keyboardShortcut(.cancelAction)
                Button(String(localized: "Remove Secret Files")) { run(delete: false) }
                    .keyboardShortcut(.defaultAction).disabled(working)
            }
        }
        .padding(Spacing.s24)
        .frame(width: 600, height: 500)
        .alert(String(localized: "Delete \(model.findings.count) backups?"), isPresented: $confirmDelete) {
            Button(String(localized: "Delete"), role: .destructive) { run(delete: true) }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("They can't be recovered.")
        }
    }

    private func run(delete: Bool) {
        working = true
        Task {
            await model.resolveFindings(model.findings, delete: delete)
            working = false
            if model.findings.isEmpty { done() }
        }
    }
}
