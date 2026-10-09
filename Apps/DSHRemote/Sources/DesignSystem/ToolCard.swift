import SwiftUI

/// A tool call in the transcript, collapsed and expanded.
///
/// UX spec "Conversation screen" → Tool cards: "A collapsed tool card shows a
/// familiar symbol, useful title, concise result summary, and state… Expansion
/// shows readable arguments and results… Large output starts with a bounded
/// preview and an explicit expansion control."
///
/// The collapsed summary is passed in, never composed here. The spec allows
/// "2 files checked" only when the host supplied enough result data to support
/// it, so the view has no idea how to write one.
///
/// Note the second, separate disclosure for large output: expanding the card
/// shows the bounded preview, and the preview has its own control. That mirrors
/// the spec's two levels rather than dumping everything at once.
struct ToolCard: View {
    let title: String
    var symbol: String = "wrench.and.screwdriver"
    var collapsedSummary: String?
    var state: DSHToolState = .unknown
    /// Readable arguments, shown label first so a long value wraps under it at
    /// large text sizes instead of being squeezed into one line.
    var arguments: [ToolField] = []
    var results: [ToolField] = []
    /// Characters of result text shown before the explicit expansion control.
    var previewLimit: Int = 700
    /// Seeded, not bound: the card owns its own disclosure, and a transcript
    /// that re-created the view on every stream chunk would otherwise snap a
    /// card shut while somebody is reading it. The gallery sets it so both
    /// forms can be seen side by side — and screenshotted on a machine where
    /// nothing can be tapped.
    var initiallyExpanded = false

    @State private var isExpanded: Bool
    @State private var showsFullOutput = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One label/value pair of a tool call. `isCode` selects the monospaced
    /// style the spec asks for paths and commands, and lets the value select
    /// without dragging the label into the selection.
    struct ToolField: Identifiable {
        let label: String
        let value: String
        var isCode = false
        var id: String { label }
    }

    init(
        title: String,
        symbol: String = "wrench.and.screwdriver",
        collapsedSummary: String? = nil,
        state: DSHToolState = .unknown,
        arguments: [ToolField] = [],
        results: [ToolField] = [],
        previewLimit: Int = 700,
        initiallyExpanded: Bool = false
    ) {
        self.title = title
        self.symbol = symbol
        self.collapsedSummary = collapsedSummary
        self.state = state
        self.arguments = arguments
        self.results = results
        self.previewLimit = previewLimit
        self.initiallyExpanded = initiallyExpanded
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                toggleExpansion()
            } label: {
                HStack(spacing: DSHMetrics.spaceCard) {
                    Image(systemName: symbol)
                        .foregroundStyle(state.tone.color)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: DSHMetrics.spaceSmall) {
                        Text(title.isEmpty ? "Tool call" : title)
                            .font(.dshCardTitle)
                            .foregroundStyle(DSHPalette.primaryText)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let collapsedSummary, !collapsedSummary.isEmpty {
                            Text(collapsedSummary)
                                .font(.dshSupporting)
                                .foregroundStyle(DSHPalette.secondaryText)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: DSHMetrics.space)
                    if state.showsIndicator {
                        DSHStatusChip(state.text, tone: state.tone, symbol: state.symbol)
                            .fixedSize()
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.footnote)
                        .foregroundStyle(DSHPalette.secondaryText)
                        .accessibilityHidden(true)
                }
                .padding(DSHMetrics.spaceCard)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(isExpanded ? "Collapses the details of this tool" : "Expands the details of this tool")

            if isExpanded {
                Divider()
                    .overlay(DSHPalette.divider)
                details
                    .padding(DSHMetrics.spaceCard)
                    .background(DSHPalette.elevatedSurface.opacity(0.45))
                    .transition(.opacity)
            }
        }
        .dshCard(isHighlighted: isExpanded)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: DSHMetrics.spaceCard) {
            ForEach(arguments) { field in
                detailRow(field, fallbackLabel: "Argument")
            }
            ForEach(results) { field in
                detailRow(field, fallbackLabel: "Result")
            }
            if arguments.isEmpty && results.isEmpty {
                // An expanded card with nothing to show says so, rather than
                // collapsing back on itself as if the tap did nothing.
                Text("This tool returned no details.")
                    .font(.dshSupporting)
                    .foregroundStyle(DSHPalette.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func detailRow(_ field: ToolField, fallbackLabel: String) -> some View {
        VStack(alignment: .leading, spacing: DSHMetrics.spaceSmall) {
            Text(field.label.isEmpty ? fallbackLabel : field.label)
                .font(.dshMetadata)
                .foregroundStyle(DSHPalette.secondaryText)
            // A long value gets the bounded preview and its own control, so a
            // 40 KB log cannot make the transcript unscrollable.
            if field.value.count > previewLimit && !showsFullOutput {
                Text(String(field.value.prefix(previewLimit)) + "…")
                    .font(field.isCode ? Font.dshCode : Font.dshSupporting)
                    .foregroundStyle(DSHPalette.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(showsFullOutput ? "Show less" : "Show full output") {
                    showsFullOutput = true
                }
                .font(.dshMetadata)
                // `.link` is a macOS-only ButtonStyle; on iOS the tint below is
                // what distinguishes this from the surrounding text.
                .buttonStyle(.plain)
                .foregroundStyle(DSHPalette.primaryActionText)
            } else {
                Text(field.value)
                    .font(field.isCode ? Font.dshCode : Font.dshSupporting)
                    .foregroundStyle(DSHPalette.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if field.value.count > previewLimit {
                    Button("Show less") {
                        showsFullOutput = false
                    }
                    .font(.dshMetadata)
                    // `.link` is a macOS-only ButtonStyle; on iOS the tint below is
                // what distinguishes this from the surrounding text.
                .buttonStyle(.plain)
                    .foregroundStyle(DSHPalette.primaryActionText)
                }
            }
        }
    }

    private func toggleExpansion() {
        if reduceMotion {
            isExpanded.toggle()
        } else {
            withAnimation(.snappy(duration: 0.18)) { isExpanded.toggle() }
        }
    }
}

/// Tool state vocabulary, separate from the session's because the words differ
/// ("Running" means a session; "Working" means one tool).
enum DSHToolState: Equatable {
    case working
    case succeeded
    case failed
    case unknown

    var text: String {
        switch self {
        case .working: "Working"
        case .succeeded: "Done"
        case .failed: "Failed"
        case .unknown: "No result yet"
        }
    }

    var tone: DSHTone {
        switch self {
        case .working: .action
        case .succeeded: .success
        case .failed: .error
        case .unknown: .neutral
        }
    }

    var symbol: String? {
        switch self {
        case .working: "ellipsis.circle"
        case .succeeded: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        case .unknown: nil
        }
    }

    /// Unknown tools still get a card — the spec says they must not disappear —
    /// but they do not get a chip claiming a state nobody knows.
    var showsIndicator: Bool { self != .unknown }
}
