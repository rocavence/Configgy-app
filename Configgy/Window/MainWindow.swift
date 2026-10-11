import SwiftUI

/// The one window: every target on a shared timeline of its backups.
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
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "Configgy"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 480)
        window.contentView = host
        window.delegate = self
        window.setFrameAutosaveName("ConfiggyTimeline")
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

/// How far back the timeline reaches.
enum TimelineRange: Int, CaseIterable, Identifiable {
    case week = 7, month = 30, quarter = 90

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) * 86_400 }
    var title: String { String(localized: "\(rawValue) days") }
}

/// Layout shared by the axis and every lane, so dots line up across rows.
enum TimelineMetrics {
    static let labelWidth: CGFloat = 230
    static let actionWidth: CGFloat = 112
    static let rowHeight: CGFloat = 64
    static let laneHeight: CGFloat = 18
    static let laneInset: CGFloat = 16
    /// Room at the left of every lane for the "older backups" marker; the plot starts after it.
    static let edgeGutter: CGFloat = 72
}

struct MainView: View {
    @Bindable var model: AppModel
    var openSettings: () -> Void
    @AppStorage("Configgy.timelineRange") private var range: TimelineRange = .month
    @AppStorage(Accent.key) private var accent: Accent = .configgy
    @State private var restoring: RestoreRequest?
    @State private var removing: TargetRow?
    @State private var reviewingFindings = false
    @State private var askQuitZen = false

    struct RestoreRequest: Identifiable {
        let row: TargetRow
        let snapshot: Snapshot?
        var id: String { row.key + (snapshot?.name ?? "") }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            notices
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    TimelineAxis(range: range)
                        .padding(.bottom, Spacing.s4)
                    if model.rows.isEmpty {
                        Note(String(localized: "Nothing is backed up yet. Add something below."))
                            .padding(.horizontal, Spacing.s8)
                    }
                    ForEach(model.rows) { row in
                        TimelineRow(row: row, range: range, host: model.context.host, busy: model.busy.contains(row.key),
                                    pick: { snapshot in restoring = RestoreRequest(row: row, snapshot: snapshot) },
                                    backup: { startBackup(row) },
                                    restoreLatest: { restoring = RestoreRequest(row: row, snapshot: nil) },
                                    remove: row.key == "claude" ? nil : { removing = row })
                        Palette.hairline.frame(height: 1).opacity(0.6)
                    }
                    if !model.rows.isEmpty {
                        Text("Hover a dot to see a backup; click or drag along a line to restore one.")
                            .textStyle(.caption).foregroundStyle(Palette.faint)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, Spacing.s12)
                    }
                    suggestions
                        .padding(.top, Spacing.s32)
                }
                .padding(.horizontal, Spacing.s24)
                .padding(.bottom, Spacing.s24)
            }
            .scrollIndicators(.automatic)
            footer
        }
        .frame(minWidth: 820, minHeight: 480)
        .background(Palette.background.ignoresSafeArea())
        .tint(accent.color)
        .sheet(item: $restoring) { request in
            if let target = model.target(request.row.key) {
                RestoreSheet(model: model, target: target, initial: request.snapshot) { restoring = nil }
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
                if let row = model.rows.first(where: { $0.key == "zen" }) { restoring = RestoreRequest(row: row, snapshot: model.zenOffer) }
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

    // MARK: Top bar

    /// Sits in the title bar, right of the traffic lights.
    private var topBar: some View {
        HStack(spacing: Spacing.s12) {
            Text(verbatim: "Configgy").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink)
            OverallStatus(model: model)
            Spacer(minLength: Spacing.s16)
            Picker("", selection: $range) {
                ForEach(TimelineRange.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .accessibilityLabel(Text("Timeline range"))
            HStack(spacing: Spacing.s4) {
                ToolbarIcon(.export, String(localized: "Back Up Everything Now")) { Task { await model.backupAll() } }
                    .disabled(model.location != .ok || !model.busy.isEmpty)
                addMenu
                ToolbarIcon(.setting2, String(localized: "Settings"), action: openSettings)
            }
        }
        .padding(.leading, 84)
        .padding(.trailing, Spacing.s16)
        .frame(height: 52)
    }

    private var addMenu: some View {
        Menu {
            if model.zenSuggested {
                Button("Zen Browser") { model.addZen() }
            }
            ForEach(model.suggestions, id: \.def.id) { suggestion in
                Button(suggestion.def.name) { model.addSuggestion(suggestion) }
            }
            if model.zenSuggested || !model.suggestions.isEmpty { Divider() }
            Button(String(localized: "Add Folder…"), action: addFolder)
        } label: {
            IconView(.plus, size: 16).foregroundStyle(Palette.ink.opacity(0.75)).frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(String(localized: "Add"))
        .accessibilityLabel(Text("Add"))
    }

    // MARK: Notices

    @ViewBuilder
    private var notices: some View {
        let items = noticeItems
        if !items.isEmpty {
            VStack(spacing: Spacing.s8) {
                ForEach(items, id: \.text) { item in
                    Banner(icon: .warning, tone: item.tone, text: item.text, action: item.action, perform: item.perform)
                }
            }
            .padding(.horizontal, Spacing.s24)
            .padding(.bottom, Spacing.s12)
        }
    }

    private struct NoticeItem {
        let tone: Color
        let text: String
        let action: String
        let perform: () -> Void
    }

    private var noticeItems: [NoticeItem] {
        var items: [NoticeItem] = []
        switch model.location {
        case .ok: break
        case .notChosen:
            items.append(.init(tone: Palette.warning, text: String(localized: "Choose where to keep backups."), action: String(localized: "Choose…"), perform: openSettings))
        case .missing(let path):
            items.append(.init(tone: Palette.bad, text: String(localized: "The backup folder isn't there: \(model.context.abbreviate(path)). Nothing is backed up until it's back or you choose another."),
                               action: String(localized: "Choose…"), perform: openSettings))
        case .notWritable:
            items.append(.init(tone: Palette.bad, text: String(localized: "Configgy needs Full Disk Access to write to the backup folder. Add Configgy in the list that opens, then quit and reopen it."),
                               action: String(localized: "Grant Access…"), perform: { model.openFullDiskAccess() }))
        }
        if !model.findings.isEmpty {
            items.append(.init(tone: Palette.warning,
                               text: String(localized: "\(model.findings.count) backups in the folder contain secret files (logins, keys or tokens) from before Configgy filtered them."),
                               action: String(localized: "Review…"), perform: { reviewingFindings = true }))
        }
        return items
    }

    // MARK: Suggestions and footer

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
        .padding(.horizontal, Spacing.s8)
    }

    private var footer: some View {
        HStack(spacing: Spacing.s8) {
            if let base = model.context.base, model.location == .ok {
                IconView(.cloud, size: 13).foregroundStyle(Palette.good)
                Text("\(BackupLocation.provider(of: base, home: model.context.home).title) · \(model.context.abbreviate(base))")
                    .lineLimit(1).truncationMode(.middle)
                    .help(base)
            }
            if model.settings.zenEnabled {
                Text(verbatim: "·").foregroundStyle(Palette.faint)
                Text(model.settings.zenAutoBackup ? "Zen backs up when you quit it" : "Zen automatic backup is off")
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
        .background(.bar)
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

// MARK: - Status

/// "Everything is protected" with a dot, or how many need attention.
private struct OverallStatus: View {
    let model: AppModel

    var body: some View {
        let failed = model.rows.contains { $0.health == .failed } || (model.location != .ok && model.location != .notChosen)
        let attention = model.rows.filter { $0.health != .protected }.count
        let (color, text): (Color, String) =
            failed ? (Palette.bad, String(localized: "Something failed"))
            : attention > 0 ? (Palette.warning, String(localized: "\(attention) need attention"))
            : model.rows.isEmpty ? (Palette.faint, String(localized: "Nothing protected yet"))
            : (Palette.good, String(localized: "Everything is protected"))
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).textStyle(.body).foregroundStyle(Palette.muted)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ToolbarIcon: View {
    let icon: Reicon
    let label: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    init(_ icon: Reicon, _ label: String, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            IconView(icon, size: 16)
                .foregroundStyle(Palette.ink.opacity(isEnabled ? 0.75 : 0.3))
                .frame(width: 30, height: 28)
                .background(hovering && isEnabled ? Palette.hover : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(Text(label))
    }
}

// MARK: - Timeline

enum TimelineGeometry {
    /// Where a date falls on a lane `width` wide: now at the right edge.
    static func x(for date: Date, now: Date, range: TimelineRange, width: CGFloat) -> CGFloat {
        width * CGFloat(1 - now.timeIntervalSince(date) / range.seconds)
    }

    /// Midnight of each labelled day: daily for a week, weekly for a month, monthly for a quarter.
    static func ticks(range: TimelineRange, now: Date) -> [Date] {
        let step = range == .week ? 1 : range == .month ? 7 : 30
        let today = Calendar.current.startOfDay(for: now)
        return stride(from: 0, to: range.rawValue, by: step).compactMap {
            Calendar.current.date(byAdding: .day, value: -$0, to: today)
        }
    }
}

/// Day labels across the top, aligned with the lanes.
private struct TimelineAxis: View {
    let range: TimelineRange

    var body: some View {
        HStack(spacing: 0) {
            Spacer().frame(width: TimelineMetrics.labelWidth)
            GeometryReader { geo in
                let now = Date()
                ZStack(alignment: .topLeading) {
                    ForEach(TimelineGeometry.ticks(range: range, now: now), id: \.self) { date in
                        let g = TimelineMetrics.edgeGutter
                        let x = g + TimelineGeometry.x(for: date, now: now, range: range, width: geo.size.width - g)
                        Text(label(date, now: now))
                            .textStyle(.caption).foregroundStyle(Palette.faint).monospacedDigit()
                            .fixedSize()
                            .position(x: min(max(x, TimelineMetrics.edgeGutter + 12), geo.size.width - 18), y: 8)
                    }
                }
            }
            .frame(height: 16)
            .padding(.horizontal, TimelineMetrics.laneInset)
            Spacer().frame(width: TimelineMetrics.actionWidth)
        }
        .padding(.top, Spacing.s8)
    }

    private func label(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? String(localized: "Today")
            : date.formatted(.dateTime.month(.defaultDigits).day())
    }
}

/// One target: who it is and how it's doing on the left, its backups along
/// the timeline (one lane per Mac), and its actions on the right.
private struct TimelineRow: View {
    let row: TargetRow
    let range: TimelineRange
    let host: String
    let busy: Bool
    let pick: (Snapshot) -> Void
    let backup: () -> Void
    let restoreLatest: () -> Void
    let remove: (() -> Void)?
    @State private var hovering = false

    private var lanes: [(host: String, snapshots: [Snapshot])] {
        var hosts = Array(Set(row.snapshots.map(\.host))).sorted()
        if let mine = hosts.firstIndex(of: host) { hosts.insert(hosts.remove(at: mine), at: 0) }
        if hosts.isEmpty { hosts = [host] }
        return hosts.map { h in (h, row.snapshots.filter { $0.host == h }) }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            label.frame(width: TimelineMetrics.labelWidth, alignment: .leading)
            VStack(spacing: Spacing.s8) {
                ForEach(lanes, id: \.host) { lane in
                    TimelineLane(snapshots: lane.snapshots, host: lane.host, isThisMac: lane.host == host,
                                 showsHost: lanes.count > 1 || lane.host != host, range: range,
                                 health: row.health, busy: busy && lane.host == host, pick: pick)
                }
            }
            actions.frame(width: TimelineMetrics.actionWidth, alignment: .trailing)
        }
        .padding(.vertical, Spacing.s12)
        .frame(minHeight: TimelineMetrics.rowHeight)
        .background(hovering ? Palette.hover.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .onHover { hovering = $0 }
        .contextMenu {
            Button(String(localized: "Back Up"), action: backup)
            Button(String(localized: "Restore…"), action: restoreLatest).disabled(row.newest == nil)
            if let remove {
                Divider()
                Button(row.key == "zen" ? String(localized: "Stop Backing Up Zen…") : String(localized: "Remove…"), role: .destructive, action: remove)
            }
        }
    }

    private var label: some View {
        HStack(spacing: Spacing.s12) {
            Image(nsImage: AppIcons.icon(for: row.bundleID)).resizable().frame(width: 32, height: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                HStack(spacing: 5) {
                    Circle().fill(row.health.color).frame(width: 6, height: 6)
                    Text(statusLine).textStyle(.caption)
                        .foregroundStyle(row.health == .protected ? Palette.muted : row.health.color)
                        .lineLimit(1)
                }
                .help(row.reason)
            }
        }
        .padding(.leading, Spacing.s8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(row.name), \(row.health.title), \(row.reason)"))
    }

    /// The newest backup's time when all is well; otherwise the reason.
    private var statusLine: String {
        if busy { return String(localized: "Backing up…") }
        if row.health == .protected, let date = row.newest?.date { return RelativeTime.describe(date) }
        return row.reason
    }

    private var actions: some View {
        HStack(spacing: Spacing.s4) {
            Button(action: backup) {
                Text("Back Up").textStyle(.bodyEmphasis).foregroundStyle(.accentText)
                    .padding(.horizontal, Spacing.s12).frame(height: 26)
                    .background(.tint.opacity(hovering ? 0.16 : 0.10), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .opacity(busy ? 0.4 : 1)
            Menu {
                Button(String(localized: "Restore…"), action: restoreLatest).disabled(row.newest == nil)
                if let remove {
                    Divider()
                    Button(row.key == "zen" ? String(localized: "Stop Backing Up Zen…") : String(localized: "Remove…"), role: .destructive, action: remove)
                }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.muted).frame(width: 22, height: 26).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .opacity(hovering ? 1 : 0.35)
            .accessibilityLabel(Text("More actions for \(row.name)"))
        }
    }
}

/// One Mac's backups of one target as dots on a hairline. Hover shows a
/// backup; click or drag picks one to restore.
private struct TimelineLane: View {
    let snapshots: [Snapshot]
    let host: String
    let isThisMac: Bool
    let showsHost: Bool
    let range: TimelineRange
    let health: TargetRow.Health
    let busy: Bool
    let pick: (Snapshot) -> Void
    @State private var focused: Snapshot?
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Point { let snapshot: Snapshot; let x: CGFloat }

    var body: some View {
        GeometryReader { geo in
            let now = Date()
            let width = geo.size.width
            let mid = TimelineMetrics.laneHeight / 2
            let g = TimelineMetrics.edgeGutter
            let points = visible(now: now, width: width)
            let earlier = snapshots.count - points.count
            ZStack(alignment: .topLeading) {
                // Faint guides under each labelled day, so dots compare across rows.
                ForEach(TimelineGeometry.ticks(range: range, now: now), id: \.self) { day in
                    Rectangle().fill(Palette.hairline.opacity(0.6))
                        .frame(width: 1, height: TimelineMetrics.laneHeight + 14)
                        .offset(x: g + TimelineGeometry.x(for: day, now: now, range: range, width: width - g), y: -7)
                }
                // The lane, brighter toward now; dashed while there's nothing on it.
                if snapshots.isEmpty {
                    Path { p in p.move(to: CGPoint(x: g, y: mid)); p.addLine(to: CGPoint(x: width, y: mid)) }
                        .stroke(Palette.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                } else {
                    LinearGradient(colors: [Palette.hairline.opacity(0.5), Palette.hairline.opacity(1.6)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: width - g, height: 1)
                        .offset(x: g, y: mid)
                }
                // Today.
                Rectangle().fill(.accentGraphic.opacity(0.5)).frame(width: 1, height: TimelineMetrics.laneHeight)
                    .offset(x: width - 1)
                if showsHost {
                    Text(isThisMac ? String(localized: "This Mac") : host)
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.faint)
                        .fixedSize()
                        .offset(x: g, y: -10)
                }
                if let older = olderNewest(now: now, width: width), earlier > 0 {
                    EdgeMarker(snapshot: older, count: earlier, isThisMac: isThisMac, focused: focused == older) { pick(older) }
                        .fixedSize()
                        .position(x: g / 2 - 2, y: mid)
                }
                ForEach(points, id: \.snapshot.name) { point in
                    dot(for: point.snapshot)
                        .position(x: point.x, y: mid)
                }
                if busy {
                    Circle().fill(.accentGraphic).frame(width: 9, height: 9)
                        .scaleEffect(pulse ? 1.7 : 1).opacity(pulse ? 0.15 : 0.9)
                        .position(x: width - 4, y: mid)
                        .onAppear { if !reduceMotion { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { pulse = true } } }
                } else if isThisMac, health == .failed {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(Palette.bad)
                        .position(x: width - 5, y: mid)
                }
                if let focused, let x = points.first(where: { $0.snapshot == focused })?.x ?? (focused == olderNewest(now: now, width: width) ? g / 2 : nil) {
                    Callout(snapshot: focused)
                        .fixedSize()
                        .position(x: min(max(x, 100), width - 100), y: -14)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .frame(width: width, height: TimelineMetrics.laneHeight, alignment: .topLeading)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    focused = location.x < g && earlier > 0 ? olderNewest(now: now, width: width) : nearest(points, to: location.x)
                case .ended: focused = nil
                }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    focused = value.location.x < g && earlier > 0
                        ? olderNewest(now: now, width: width)
                        : nearest(points, to: value.location.x, within: 40)
                }
                .onEnded { _ in if let focused { pick(focused) } })
            .animation(.easeOut(duration: 0.12), value: focused)
        }
        .frame(height: TimelineMetrics.laneHeight)
        .padding(.horizontal, TimelineMetrics.laneInset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(isThisMac ? String(localized: "Backups on this Mac") : String(localized: "Backups on \(host)")))
    }

    /// The newest backup older than the range, shown at the lane's left edge.
    private func olderNewest(now: Date, width: CGFloat) -> Snapshot? {
        snapshots.last { s in s.date.map { now.timeIntervalSince($0) > range.seconds } ?? true }
    }

    private func visible(now: Date, width: CGFloat) -> [Point] {
        snapshots.compactMap { s in
            guard let date = s.date else { return nil }
            let g = TimelineMetrics.edgeGutter
            let x = TimelineGeometry.x(for: date, now: now, range: range, width: width - g)
            return x >= 0 ? Point(snapshot: s, x: min(g + x, width - 5)) : nil
        }
    }

    private func nearest(_ points: [Point], to x: CGFloat, within limit: CGFloat = 14) -> Snapshot? {
        points.min { abs($0.x - x) < abs($1.x - x) }.flatMap { abs($0.x - x) <= limit ? $0.snapshot : nil }
    }

    @ViewBuilder
    private func dot(for snapshot: Snapshot) -> some View {
        let isFocused = focused == snapshot
        let size: CGFloat = isFocused ? 11 : 8
        Group {
            if isThisMac {
                Circle().fill(.accentGraphic)
            } else {
                Circle().strokeBorder(.accentGraphic, lineWidth: 1.5).background(Circle().fill(Palette.background))
            }
        }
        .frame(width: size, height: size)
        .overlay { if isFocused { Circle().stroke(.accentGraphic.opacity(0.3), lineWidth: 4).frame(width: size + 6, height: size + 6) } }
        .accessibilityElement()
        .accessibilityLabel(Text(Callout.describe(snapshot)))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { pick(snapshot) }
    }
}

/// "‹ 9/30 · 3": backups older than the range, at the lane's left edge. Click restores the newest of them.
private struct EdgeMarker: View {
    let snapshot: Snapshot
    let count: Int
    let isThisMac: Bool
    let focused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 8, weight: .bold))
                Text(label).font(.system(size: 10.5, weight: .medium)).monospacedDigit()
            }
            .foregroundStyle(focused ? AnyShapeStyle(.accentText) : AnyShapeStyle(Palette.muted))
            .padding(.horizontal, 7).frame(height: 18)
            .background(Palette.background, in: Capsule())
            .overlay(Capsule().strokeBorder(focused ? AnyShapeStyle(.accentGraphic) : AnyShapeStyle(Palette.hairline.opacity(1.6))))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: "\(count) earlier backups; newest \(Callout.describe(snapshot))")))
    }

    private var label: String {
        let date = snapshot.date.map { $0.formatted(.dateTime.month(.defaultDigits).day()) } ?? "?"
        return count > 1 ? "\(date) · \(count)" : date
    }
}

/// The floating label over a focused dot.
private struct Callout: View {
    let snapshot: Snapshot

    var body: some View {
        Text(Self.describe(snapshot))
            .textStyle(.caption).foregroundStyle(Palette.ink)
            .padding(.horizontal, Spacing.s8).padding(.vertical, 3)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.hairline))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }

    static func describe(_ snapshot: Snapshot) -> String {
        var parts = [snapshot.date.map { RelativeTime.describe($0) } ?? snapshot.name, snapshot.host]
        if let files = snapshot.meta?.files { parts.append(String(localized: "\(files) files")) }
        return parts.joined(separator: " · ")
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

// MARK: - Shared pieces

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
