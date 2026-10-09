import DSHRemoteKit
import SwiftUI

/// One session's usage, from the host's projections and nothing else.
///
/// SPEC §10 scopes this surface tightly: "Session-level usage only where durable assistant
/// events or verified projections supply it. No verified host-wide usage endpoint here; do not
/// treat account balance as token usage or estimate totals from a partial transcript." Every
/// figure below is a projection value the host sent, and a figure it did not send is absent
/// rather than zero.
///
/// There is no stream for this — the spec assumes none — so it reads on entry and on
/// pull-to-refresh.
struct UsageView: View {
    @Environment(AppModel.self) private var model

    /// The session to report on. Nil when no conversation is open, which is a real state: with
    /// nothing selected there is no session usage to show, and host-wide totals do not exist.
    var sessionId: String?
    var title: String = "Usage"

    private var usage: SessionUsage? {
        sessionId.flatMap { model.usage(for: $0) }
    }

    private var isLoaded: Bool {
        guard let sessionId else { return false }
        return model.hasProjections(for: sessionId)
    }

    var body: some View {
        List {
            if sessionId == nil {
                Section {
                    Text("Open a session to see its usage. This harness reports usage per session, not per host.")
                        .font(.dshSupporting)
                        .foregroundStyle(DSHPalette.secondaryText)
                }
            } else if !isLoaded {
                Section {
                    HStack(spacing: DSHMetrics.space) {
                        ProgressView().controlSize(.small)
                        Text("Reading…").foregroundStyle(DSHPalette.secondaryText)
                    }
                }
            } else if let usage, !usage.isEmpty {
                tokensSection(usage.tokens)
                if !usage.timing.isEmpty { timingSection(usage.timing) }
                if !usage.context.isEmpty { contextSection(usage.context) }
            } else {
                Section {
                    Text("This harness has not reported usage for this session.")
                        .font(.dshSupporting)
                        .foregroundStyle(DSHPalette.secondaryText)
                }
            }

            Section {
                EmptyView()
            } footer: {
                Text("Reported by the harness for this session. Tokens are its own counts; nothing here is estimated from the transcript or from an account balance.")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            if let sessionId { await model.loadProjections(for: sessionId) }
        }
        .task(id: sessionId) {
            // Read on entry, because there is no stream: SPEC §10 assumes none for these
            // surfaces and asks for a refresh when the screen is entered.
            if let sessionId, !isLoaded { await model.loadProjections(for: sessionId) }
        }
    }

    // MARK: - Sections

    private func tokensSection(_ tokens: SessionUsage.Tokens) -> some View {
        Section("Tokens") {
            if let total = tokens.total {
                LabeledContent("Total", value: Self.count(total))
            }
            if let input = tokens.totalInput {
                LabeledContent("Input", value: Self.count(input))
            }
            if let uncached = tokens.uncachedInput {
                LabeledContent("Input, uncached", value: Self.count(uncached))
            }
            if let cacheRead = tokens.cacheRead {
                LabeledContent("Cache read", value: Self.count(cacheRead))
            }
            if let cacheWrite = tokens.cacheWrite, cacheWrite > 0 {
                LabeledContent("Cache write", value: Self.count(cacheWrite))
            }
            if let output = tokens.output {
                LabeledContent("Output", value: Self.count(output))
            }
            if let rate = tokens.cacheHitRate {
                LabeledContent("From cache", value: rate.formatted(.percent.precision(.fractionLength(0))))
            }
        }
    }

    private func timingSection(_ timing: SessionUsage.Timing) -> some View {
        Section("Timing") {
            if let turns = timing.turns { LabeledContent("Turns", value: "\(turns)") }
            if let steps = timing.steps { LabeledContent("Steps", value: "\(steps)") }
            if let milliseconds = timing.llmMilliseconds {
                LabeledContent("Model time", value: Self.duration(milliseconds))
            }
            if let milliseconds = timing.toolMilliseconds, milliseconds > 0 {
                LabeledContent("Tool time", value: Self.duration(milliseconds))
            }
            if let milliseconds = timing.firstTokenMilliseconds {
                LabeledContent("First token", value: Self.duration(milliseconds))
            }
            if let speed = timing.tokensPerSecond {
                LabeledContent(
                    "Decode",
                    value: "\(speed.formatted(.number.precision(.fractionLength(1)))) tok/s"
                )
            }
        }
    }

    private func contextSection(_ context: SessionUsage.Context) -> some View {
        Section("Context") {
            if let fill = context.fill, let window = context.contextWindow {
                VStack(alignment: .leading, spacing: DSHMetrics.spaceSmall) {
                    ProgressView(value: fill)
                    Text("\(Self.count(context.pressureTokens ?? 0)) of \(Self.count(window)) tokens (\(fill.formatted(.percent.precision(.fractionLength(0)))))")
                        .font(.dshMetadata)
                        .foregroundStyle(DSHPalette.secondaryText)
                }
                .padding(.vertical, DSHMetrics.spaceSmall)
            }
            if let system = context.systemTokens {
                LabeledContent("System", value: Self.count(system))
            }
            if let tools = context.toolsTokens {
                LabeledContent("Tools", value: Self.count(tools))
            }
            if let messages = context.messageTokens {
                LabeledContent("Messages", value: Self.count(messages))
            }
            if let projected = context.projectedTokens {
                LabeledContent("Projected next", value: Self.count(projected))
            }
            if let fits = context.projectsWithinWindow, !fits {
                Label("The harness projects this session past its context window.", systemImage: "exclamationmark.triangle")
                    .font(.dshMetadata)
                    .foregroundStyle(DSHPalette.attention)
            }
        }
    }

    // MARK: - Formatting

    /// Grouped digits: a token count is read for its magnitude, and 286720 is not.
    static func count(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    static func duration(_ milliseconds: Int) -> String {
        if milliseconds < 1_000 { return "\(milliseconds) ms" }
        let seconds = Double(milliseconds) / 1000
        if seconds < 60 { return "\(seconds.formatted(.number.precision(.fractionLength(1)))) s" }
        return Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
    }
}
