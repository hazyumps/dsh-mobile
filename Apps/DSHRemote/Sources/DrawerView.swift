import DSHRemoteKit
import SwiftUI

/// The harness panel: what this phone is connected to, and everything you configure about it.
///
/// This is the half of the old drawer that was never the problem. Administration is rare and
/// wide — a slide-over is the right shape for it, and it fits: ten rows, four of which a
/// person touches once. The workspace tree and the session list were the clutter, and they
/// are gone from here, because work belongs on a screen with room for it.
///
/// Settings is no longer a screen behind a row. Its sections are rows here, which is what
/// "the sidebar is for the harness" means in practice: there is one place, and it is this
/// one. The four rows that need a screen of their own push one.
struct DrawerView: View {
    /// Where a row goes. Home owns the navigation stack, so the drawer names a destination
    /// and closes; it does not push.
    enum Destination: Hashable {
        case modelDefaults
        case plugins
        case usage
        case schedules
        case hosts
        case thisPhone
        case reminders
        case diagnostics
    }

    @Environment(AppModel.self) private var model

    let close: () -> Void
    let open: (Destination) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            hostCard
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    section("Harness")
                    row("Model & mode", symbol: "slider.horizontal.3", value: modelModeValue, destination: .modelDefaults)
                    row("Plugins", symbol: "puzzlepiece.extension", value: pluginsValue, destination: .plugins)
                    row("Usage", symbol: "chart.bar", value: usageValue, destination: .usage)
                    row("Scheduled tasks", symbol: "calendar.badge.clock", value: schedulesValue, destination: .schedules)
                    row("Diagnostics", symbol: "waveform.path.ecg", value: diagnosticsValue, destination: .diagnostics)

                    section("Host")
                    row("Hosts & pairing", symbol: "laptopcomputer.and.iphone", value: hostsValue, destination: .hosts)
                    row("This phone", symbol: "iphone", value: model.deviceName, destination: .thisPhone)
                    row("Reminders", symbol: "bell", value: remindersValue, destination: .reminders)

                    section("About")
                    versionRow
                }
                .padding(.bottom, DSHMetrics.spaceGroup)
            }
        }
        .background(DSHPalette.navigationSurface)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(DSHPalette.divider)
                .frame(width: 1)
                .ignoresSafeArea(edges: .vertical)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DSHMetrics.space) {
            DSHBrandLockup()
            Spacer(minLength: DSHMetrics.space)
            DSHIconAction(label: "Close navigation", symbol: "xmark", action: close)
        }
        .padding(.horizontal, DSHMetrics.spaceCard)
        .padding(.top, DSHMetrics.spaceCard)
        .padding(.bottom, DSHMetrics.space)
    }

    /// Which harness this is, and how it is doing — the one fact the panel must never bury.
    ///
    /// It is the row that switches hosts, so it is a control and not a status strip; the
    /// connection state rides alongside rather than being a separate screen.
    private var hostCard: some View {
        Button {
            open(.hosts)
        } label: {
            HStack(spacing: DSHMetrics.space) {
                Circle()
                    .fill(DSHHostState(model.status).tone.color)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.selectedHost?.displayName ?? "No host")
                        .font(.dshCardTitle)
                        .foregroundStyle(DSHPalette.primaryText)
                        .lineLimit(1)
                    Text(hostDetail)
                        .font(.dshMetadata)
                        .foregroundStyle(DSHPalette.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: DSHMetrics.space)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(DSHPalette.secondaryText)
                    .accessibilityHidden(true)
            }
            .padding(DSHMetrics.spaceCard)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DSHPalette.card)
            .clipShape(RoundedRectangle(cornerRadius: DSHMetrics.spaceCard, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: DSHMetrics.spaceCard, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DSHMetrics.spaceCard)
        .accessibilityLabel("Host \(model.selectedHost?.displayName ?? "none"). \(hostDetail)")
        .accessibilityHint("Opens host selection and pairing")
    }

    private var hostDetail: String {
        let state = DSHHostState(model.status).text
        // A count of zero sessions is a measurement of an empty harness, and saying
        // "0 sessions" beside a host name reads as a failure to load.
        guard model.browse.sessionCount > 0 else { return state }
        let sessions = model.browse.sessionCount == 1 ? "1 session" : "\(model.browse.sessionCount) sessions"
        return "\(state) · \(sessions)"
    }

    // MARK: - Rows

    private func section(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.bold))
            .kerning(0.6)
            .foregroundStyle(DSHPalette.secondaryText)
            .padding(.horizontal, DSHMetrics.spaceCard + DSHMetrics.spaceSmall)
            .padding(.top, DSHMetrics.spaceGroup - DSHMetrics.spaceSmall)
            .padding(.bottom, DSHMetrics.spaceSmall)
    }

    /// One destination: symbol, name, and what is behind it — or nothing at all.
    ///
    /// The value is optional on purpose. A count this phone has not read yet is unknown, and
    /// "0" would be a measurement it did not make.
    private func row(_ title: String, symbol: String, value: String?, destination: Destination) -> some View {
        Button {
            open(destination)
        } label: {
            HStack(spacing: DSHMetrics.space) {
                Image(systemName: symbol)
                    .font(.body)
                    .foregroundStyle(DSHPalette.secondaryText)
                    .frame(width: 26, alignment: .leading)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.dshMessageBody)
                    .foregroundStyle(DSHPalette.primaryText)
                Spacer(minLength: DSHMetrics.space)
                if let value, !value.isEmpty {
                    Text(value)
                        .font(.dshMetadata)
                        .foregroundStyle(DSHPalette.secondaryText)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(DSHPalette.secondaryText)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, DSHMetrics.spaceCard + DSHMetrics.spaceSmall)
            .frame(minHeight: DSHMetrics.minimumHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value.map { "\(title). \($0)" } ?? title)
        .accessibilityAddTraits(.isButton)
    }

    /// The version, which goes nowhere.
    ///
    /// Read from the bundle rather than written here: a number in a view is a number that
    /// will be wrong after the next bump, and AGENTS.md makes `project.yml` the source.
    private var versionRow: some View {
        HStack(spacing: DSHMetrics.space) {
            Image(systemName: "info.circle")
                .font(.body)
                .foregroundStyle(DSHPalette.secondaryText)
                .frame(width: 26, alignment: .leading)
                .accessibilityHidden(true)
            Text("Version")
                .font(.dshMessageBody)
                .foregroundStyle(DSHPalette.primaryText)
            Spacer(minLength: DSHMetrics.space)
            Text(Self.version)
                .font(.dshMetadata)
                .foregroundStyle(DSHPalette.secondaryText)
        }
        .padding(.horizontal, DSHMetrics.spaceCard + DSHMetrics.spaceSmall)
        .frame(minHeight: DSHMetrics.minimumHitTarget)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Version \(Self.version)")
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        guard let build else { return short }
        return "\(short) (\(build))"
    }

    // MARK: - Values

    /// The model a new session would start on, or the preset when the model is not known.
    ///
    /// Deliberately one name and not both: "Standard mode · DeepSeek-V41-Flash" truncates to
    /// "Standard mode · …" in a row this narrow, which is the half that says the least. The
    /// screen behind this row shows the pair.
    private var modelModeValue: String? {
        model.effectiveModel?.name ?? model.effectiveMode?.label
    }

    private var pluginsValue: String? {
        guard let plugins = model.plugins else { return nil }
        let enabled = plugins.entries.count { $0.enabled }
        return "\(enabled) enabled"
    }

    /// Deliberately empty.
    ///
    /// SPEC §10: this harness exposes no host-wide usage or ledger endpoint, and a
    /// per-session figure presented beside "Usage" in a harness panel would be read as the
    /// account's. The screen behind this row says what it can and cannot show.
    private var usageValue: String? { nil }

    private var schedulesValue: String? {
        guard model.scheduledTasksReport.kind == .available else { return nil }
        return "\(model.scheduledTasks.count)"
    }

    private var diagnosticsValue: String? {
        model.diagnosticCount == 1 ? "1 record" : "\(model.diagnosticCount) records"
    }

    private var hostsValue: String? {
        switch model.hosts.count {
        case 0: nil
        case 1: "1 host"
        default: "\(model.hosts.count) hosts"
        }
    }

    private var remindersValue: String? {
        let authorization = model.taskNotifications.authorization.dshDescription
        guard model.taskNotifications.pendingCount > 0 else { return authorization }
        return "\(authorization) · \(model.taskNotifications.pendingCount) planned"
    }
}
