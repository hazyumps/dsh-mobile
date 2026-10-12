import DSHRemoteKit
import SwiftUI
import UIKit

/// The host's plugin inventory, read-only.
///
/// SPEC §10: this is the first useful surface, not the whole feature. It lists what is
/// installed with its state, and it does **not** offer enable, disable, install or remove —
/// those are mutations with consequences that need their own design and tests. The host's
/// `managementAvailable` is reported rather than acted on, so a control that does not exist
/// is absent instead of greyed.
struct PluginsView: View {
    @Environment(AppModel.self) private var model

    private var entries: [PluginEntry] {
        // Enabled first, then by the name a person sees. `sorted(by:)` rather than
        // `sorted(using:)`: the latter wants a `SortComparator`, and this is two plain rules
        // rather than one.
        let all: [PluginEntry] = model.plugins?.entries ?? []
        return all.sorted(by: { (left: PluginEntry, right: PluginEntry) -> Bool in
            if left.enabled != right.enabled { return left.enabled }
            return (left.meta?.title?.preferredText ?? left.moduleName).localizedCaseInsensitiveCompare(
                right.meta?.title?.preferredText ?? right.moduleName
            ) == .orderedAscending
        })
    }

    var body: some View {
        List {
            if let inventory = model.plugins {
                Section {
                    LabeledContent("Installed", value: "\(inventory.entries.count)")
                    LabeledContent("Enabled", value: "\(inventory.entries.filter(\.enabled).count)")
                    if let management = inventory.managementAvailable {
                        LabeledContent("Management", value: management ? "Available on the host" : "Not available")
                    }
                } footer: {
                    Text("Read-only. Enabling, disabling, or installing a plugin is not part of this app.")
                }
            }

            Section {
                ForEach(entries) { entry in
                    PluginRow(entry: entry)
                }
            }
        }
        .navigationTitle("Plugins")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model.plugins == nil { await model.loadPlugins() }
        }
        .refreshable { await model.loadPlugins() }
        .overlay {
            CapabilityOverlay(
                report: model.pluginsReport,
                isEmpty: entries.isEmpty,
                what: "the plugin inventory",
                retry: { await model.loadPlugins() }
            )
        }
    }
}

private struct PluginRow: View {
    let entry: PluginEntry

    private var title: String {
        entry.meta?.title?.preferredText ?? entry.moduleName
    }

    /// The phase, in the host's own words, and only when the plugin is running. A disabled
    /// plugin has no phase — showing "active" for one would be the lie the inventory exists
    /// to avoid.
    private var phaseText: String? {
        guard entry.enabled else { return nil }
        return entry.fiberPhase.wireValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSHMetrics.spaceSmall) {
            HStack(spacing: DSHMetrics.space) {
                Text(title)
                    .font(.dshCardTitle)
                    .foregroundStyle(DSHPalette.primaryText)
                    .lineLimit(2)
                Spacer(minLength: DSHMetrics.space)
                DSHStatusChip(
                    entry.enabled ? (phaseText ?? "Enabled") : "Disabled",
                    tone: entry.enabled ? .success : .neutral,
                    symbol: entry.enabled ? nil : "pause.circle"
                )
                .fixedSize()
            }
            Text(entry.moduleName)
                .font(.dshCode)
                .foregroundStyle(DSHPalette.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            if let description = entry.meta?.description?.preferredText, !description.isEmpty {
                Text(description)
                    .font(.dshMetadata)
                    .foregroundStyle(DSHPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = entry.meta?.error, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.dshMetadata)
                    .foregroundStyle(DSHPalette.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, DSHMetrics.spaceSmall)
    }
}

/// The host's scheduled tasks, read-only, and what the phone will do about them.
///
/// This screen used to read `schedule/catalog`, which 404s on this host because the bundle
/// that registers it is not in the profile's list — so it said "not available on this
/// harness" while the peer feature that *is* installed, `dsh-plugin-scheduled-tasks`, held
/// live tasks under `scheduledTasks/list` (PUSH-NOTIFICATIONS-SPEC §1).
///
/// SPEC §10 continues to gate creating and editing them.
struct SchedulesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            // Only worth saying once there is something to be reminded about: a host with no
            // scheduled tasks should not be told its notifications are off.
            if !model.taskNotifications.authorization.allowsDelivery,
               model.scheduledTasksReport.kind == .available {
                remindersSection
            }
            ForEach(model.scheduledTasks) { task in
                ScheduledTaskRow(task: task)
            }
        }
        .navigationTitle("Scheduled tasks")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // The list is host-wide and has no stream, so it is read on entry and on
            // pull-to-refresh (SPEC §10). Reading it is also what plans the reminders, so
            // this is not a second system to keep in step.
            await model.loadScheduledTasks()
        }
        .refreshable { await model.loadScheduledTasks() }
        .overlay {
            CapabilityOverlay(
                report: model.scheduledTasksReport,
                isEmpty: model.scheduledTasks.isEmpty,
                what: "scheduled tasks",
                retry: { await model.loadScheduledTasks() }
            )
        }
    }

    /// The one control this slice ships: permission for the reminders themselves.
    private var remindersSection: some View {
        Section {
            Button {
                Task {
                    if model.taskNotifications.authorization == .notDetermined {
                        await model.taskNotifications.requestAuthorization()
                    } else if let url = URL(string: UIApplication.openSettingsURLString) {
                        // Denied is only reversible in iOS Settings. There is no API to ask
                        // again: a second `requestAuthorization` returns the same refusal
                        // without showing anything, so offering it would be a dead button.
                        openURL(url)
                    }
                }
            } label: {
                Label(
                    model.taskNotifications.authorization == .notDetermined
                        ? "Turn on reminders"
                        : "Open iOS Settings",
                    systemImage: "bell.badge"
                )
            }
        } footer: {
            Text("DSH Remote can post a reminder when a task's next run is due. \(model.taskNotifications.authorization.dshDescription)")
        }
    }
}

/// One task.
///
/// Two facts are kept apart on purpose. "Next" comes from `schedule.scheduledAt`, which the
/// host advances after every run, so it is the *next* occurrence and not the last one. "Ran"
/// comes from `lastRun`, and it is the only thing here that says a run actually started — a
/// reminder fires whether or not the host was awake.
private struct ScheduledTaskRow: View {
    let task: ScheduledTask

    /// The timing this arm actually carries.
    ///
    /// The plugin's schedule record is the same six-arm union as `schedule/catalog`'s, so the
    /// same rule applies: read `kind` first, then only that arm's parameter. An `at` entry
    /// carrying a stray `afterSeconds` must not read as an `after` schedule.
    private var timing: String {
        switch task.schedule.kind {
        case .after:
            task.schedule.afterSeconds.map { "\(Int($0)) seconds after the previous run" } ?? "After the previous run"
        case .every:
            task.schedule.everySeconds.map { "Every \(Int($0)) seconds" } ?? "Repeating"
        case .at:
            // The instant itself is the "Next" line below; this only names the form, so an
            // arm that carries neither `time` nor `timeZone` still renders a sentence.
            ["Once", clock, task.schedule.timeZone].compactMap { $0 }.joined(separator: " · ")
        case .daily:
            ["Daily", clock, task.schedule.timeZone].compactMap { $0 }.joined(separator: " · ")
        case .weekly:
            ["Weekly", clock, task.schedule.timeZone, weekdays].compactMap { $0 }.joined(separator: " · ")
        case .cron:
            ["Cron", task.schedule.expression, task.schedule.timeZone].compactMap { $0 }.joined(separator: " · ")
        case .other(let kind):
            // Named, not guessed: an arm this build does not know has a timing key this
            // build does not read.
            "\(kind) (not shown by this build)"
        }
    }

    /// The stored wall clock, without the always-zero seconds and milliseconds.
    ///
    /// The host writes `07:00:00.000`. That is a literal clock field rather than an instant,
    /// so this is a trim and not a date parse — and a value that does not start `HH:mm` is
    /// passed through untouched rather than mangled into a time it is not.
    private var clock: String? {
        guard let raw = task.schedule.time else { return nil }
        let head = raw.prefix(5)
        guard head.count == 5 else { return raw }
        let parts = head.split(separator: ":")
        guard parts.count == 2, parts.allSatisfy({ Int($0) != nil }) else { return raw }
        return String(head)
    }

    /// ISO weekdays as the host numbers them, named for a reader.
    private var weekdays: String? {
        guard let days = task.schedule.weekdays, !days.isEmpty else { return nil }
        let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        return days.map { day in
            (1...7).contains(Int(day)) ? names[Int(day) - 1] : "\(Int(day))"
        }.joined(separator: ", ")
    }

    private var target: String {
        [task.target.model, task.target.effort]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSHMetrics.spaceSmall) {
            HStack(spacing: DSHMetrics.space) {
                Text(task.title.isEmpty ? "Untitled task" : task.title)
                    .font(.dshCardTitle)
                    .foregroundStyle(DSHPalette.primaryText)
                    .lineLimit(2)
                Spacer(minLength: DSHMetrics.space)
                DSHStatusChip(
                    task.enabled ? "Active" : "Inactive",
                    tone: task.enabled ? .success : .neutral
                )
                .fixedSize()
            }
            Text(timing)
                .font(.dshSupporting)
                .foregroundStyle(DSHPalette.secondaryText)
            if !target.isEmpty {
                Text(target)
                    .font(.dshMetadata)
                    .foregroundStyle(DSHPalette.secondaryText)
            }
            nextRun
            lastRun
        }
        .padding(.vertical, DSHMetrics.spaceSmall)
    }

    /// Absent is not zero: a task whose next occurrence will not parse is *unknown*, and says
    /// so rather than showing nothing where a time belongs.
    @ViewBuilder
    private var nextRun: some View {
        if let next = WireTimestamp.date(from: task.schedule.scheduledAt) {
            Label("Next \(next.formatted(date: .abbreviated, time: .shortened))", systemImage: "clock")
                .font(.dshMetadata)
                .foregroundStyle(DSHPalette.secondaryText)
        } else if !task.enabled {
            // Expected, not a defect: a disabled task keeps its last target.
            Label("Not scheduled", systemImage: "pause.circle")
                .font(.dshMetadata)
                .foregroundStyle(DSHPalette.secondaryText)
        } else {
            Label("Next run not reported", systemImage: "questionmark.circle")
                .font(.dshMetadata)
                .foregroundStyle(DSHPalette.secondaryText)
        }
    }

    @ViewBuilder
    private var lastRun: some View {
        if let run = task.lastRun {
            if run.ok {
                Label("Ran \(stamp(run.finishedAt))", systemImage: "checkmark.circle")
                    .font(.dshMetadata)
                    .foregroundStyle(DSHPalette.secondaryText)
            } else {
                // The one line most worth reading: a task that stopped starting is exactly
                // what a silent scheduler hides.
                Label(run.error.map { "Failed: \($0)" } ?? "Failed \(stamp(run.finishedAt))",
                      systemImage: "exclamationmark.triangle")
                    .font(.dshMetadata)
                    .foregroundStyle(DSHPalette.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Label("Never run", systemImage: "circle.dashed")
                .font(.dshMetadata)
                .foregroundStyle(DSHPalette.secondaryText)
        }
    }

    /// An ISO instant in the reader's locale, falling back to the host's own text rather than
    /// to a blank where a time belongs.
    private func stamp(_ iso: String) -> String {
        WireTimestamp.date(from: iso)?.formatted(date: .abbreviated, time: .shortened) ?? iso
    }
}

/// What a capability-gated screen shows when there is nothing to list.
///
/// The three cases are kept apart on purpose (SPEC §10): *unavailable* is the host saying it
/// has no such endpoint, *failed* is a read that went wrong, and *empty* is a successful read
/// of nothing. Only one of them is worth retrying.
private struct CapabilityOverlay: View {
    let report: SecondaryReport
    let isEmpty: Bool
    let what: String
    let retry: () async -> Void

    var body: some View {
        if !isEmpty { EmptyView() } else {
            switch report.kind {
            case .unknown, .loading:
                ProgressView("Reading \(what)…")
            case .available:
                ContentUnavailableView {
                    Label("Nothing here", systemImage: "tray")
                } description: {
                    Text("The harness reported no \(what).")
                }
            case .unavailable:
                ContentUnavailableView {
                    Label("Not available on this harness", systemImage: "slash.circle")
                } description: {
                    Text(report.detail ?? "The harness does not implement this.")
                }
            case .failed:
                ContentUnavailableView {
                    Label("Couldn’t read \(what)", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(report.detail ?? "The read failed.")
                } actions: {
                    Button("Try again") { Task { await retry() } }
                }
            }
        }
    }
}
