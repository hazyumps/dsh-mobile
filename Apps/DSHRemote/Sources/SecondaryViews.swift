import DSHRemoteKit
import SwiftUI

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

/// The host's schedule catalog, read-only.
///
/// SPEC §10 gates task creation and editing as later work, and this host currently answers
/// **404 for every `schedule/*` endpoint** even though the scheduled-tasks plugin is loaded —
/// so what this screen mostly has to do is say that honestly rather than offer controls the
/// host would refuse.
struct SchedulesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            ForEach(model.schedules) { entry in
                ScheduleRow(entry: entry)
            }
        }
        .navigationTitle("Scheduled tasks")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // The catalog is host-wide and has no stream, so it is read on entry and on
            // pull-to-refresh (SPEC §10).
            await model.loadSchedules()
        }
        .refreshable { await model.loadSchedules() }
        .overlay {
            CapabilityOverlay(
                report: model.schedulesReport,
                isEmpty: model.schedules.isEmpty,
                what: "scheduled tasks",
                retry: { await model.loadSchedules() }
            )
        }
    }
}

private struct ScheduleRow: View {
    let entry: ScheduleEntry

    /// The timing this arm actually carries.
    ///
    /// SPEC §10: `after` carries `afterSeconds`, `every` carries `everySeconds`, `at` carries
    /// neither, and the other arms carry their own keys — so this reads the union instead of
    /// one arm's parameter as if it covered all of them.
    private var timing: String {
        switch entry.kind {
        case .after:
            entry.afterSeconds.map { "\(Int($0)) seconds after the previous run" } ?? "After the previous run"
        case .every:
            entry.everySeconds.map { "Every \(Int($0)) seconds" } ?? "Repeating"
        case .at:
            [entry.time, entry.timeZone].compactMap { $0 }.joined(separator: " ")
        case .daily:
            entry.time ?? "Daily"
        case .weekly:
            [entry.time, entry.weekdays?.map { String(Int($0)) }.joined(separator: ", ")]
                .compactMap { $0 }.joined(separator: " on ")
        case .cron:
            entry.expression ?? "Cron"
        case .other(let kind):
            // Named, not guessed: an arm this build does not know has a timing key this
            // build does not read.
            "\(kind) (not shown by this build)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DSHMetrics.spaceSmall) {
            HStack(spacing: DSHMetrics.space) {
                Text(entry.title.isEmpty ? "Untitled task" : entry.title)
                    .font(.dshCardTitle)
                    .foregroundStyle(DSHPalette.primaryText)
                    .lineLimit(2)
                Spacer(minLength: DSHMetrics.space)
                if let status = entry.status {
                    DSHStatusChip(
                        status == .active ? "Active" : status == .inactive ? "Inactive" : status.wireValue,
                        tone: status == .active ? .success : .neutral
                    )
                    .fixedSize()
                }
            }
            Text(timing)
                .font(.dshSupporting)
                .foregroundStyle(DSHPalette.secondaryText)
            Text(entry.scheduledAt)
                .font(.dshMetadata)
                .foregroundStyle(DSHPalette.secondaryText)
            if let delivery = entry.lastDelivery {
                Label(
                    "Last delivered \(delivery.deliveredAt)",
                    systemImage: "paperplane"
                )
                .font(.dshMetadata)
                .foregroundStyle(DSHPalette.secondaryText)
            }
        }
        .padding(.vertical, DSHMetrics.spaceSmall)
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
