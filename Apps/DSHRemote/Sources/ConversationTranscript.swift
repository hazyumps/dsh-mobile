import DSHRemoteKit
import SwiftUI
import UIKit

/// The conversation body: everything a conversation shows, rendered from one snapshot.
///
/// Plain data and closures, with no store and no networking — the same contract the
/// component gallery relies on, and what lets the debug screen draw a real conversation
/// on a machine with no host.
///
/// UX spec "Conversation screen" fixes the shape: user messages are compact graphite
/// bubbles toward the trailing edge, assistant prose sits directly on the canvas,
/// reasoning is collapsed behind a disclosure, tool cards are quiet until opened, and
/// only the composer is pinned to the bottom.
struct ConversationTranscript: View {
    let snapshot: ConversationSnapshot
    var isStale = false
    var isSubmitting = false
    var onLoadOlder: (() -> Void)?
    var onRetry: (() -> Void)?
    var onAnswer: (([DecisionCard.Answer]) -> Void)?
    /// Pending approvals for this conversation, from the `$events` router rather than from
    /// the transcript: a durable `tool/call` record says what happened, not what is still
    /// waiting (SPEC §8). The closure is `(eventId, isAllow)`.
    var approvals: [InteractionRequest] = []
    var onApproval: ((String, Bool) -> Void)?
    /// Live question deliveries from `$events`, which are the authority for *controls*.
    ///
    /// The durable fold below is history: a `tool/call` record says a question was asked, not
    /// that it can still be answered. SPEC §8 gets this the other way round from the way it
    /// looks — the live waterfall is what a card may act on, and answering it goes through
    /// `$events/result` rather than the continued channel.
    /// Loads one attachment's pixels. Nil when the screen has no reader, in which case an
    /// image is listed by name rather than drawn.
    var loadImage: ((String) async -> DisplayImage?)?
    /// Whether the host's own event stream is shown inline.
    ///
    /// Off by default, and that is the point: nearly every durable event is a card of its own —
    /// turn and step boundaries, tool calls, tool results, injected context — so the transcript
    /// read as machinery with the conversation buried in it. The chat stream shows messages and
    /// the controls that need an answer; everything else is one toggle away, which is where the
    /// desktop keeps it too.
    var showsTelemetry = false
    var liveQuestions: [InteractionRequest] = []
    var onAnswerLive: ((String, [DecisionCard.Answer]) -> Void)?

    /// One durable event that is not a message, in the order it arrived.
    private struct Activity: Identifiable {
        let id: String
        let title: String
        let summary: String?
        let details: String?
        let eventType: String
    }

    private enum Row: Identifiable {
        case message(ConversationMessage)
        case activity(Activity)

        var id: String {
            switch self {
            case .message(let message): message.id
            case .activity(let activity): activity.id
            }
        }

        /// Ordering authority: the durable sequence, with a live attempt last because it
        /// has no sequence yet.
        var order: Int64 {
            switch self {
            case .message(let message): Self.sequence(of: message.id) ?? .max
            case .activity(let activity): Self.sequence(of: activity.id) ?? .max
            }
        }

        private static func sequence(of id: String) -> Int64? {
            guard id.hasPrefix("seq:") else { return nil }
            return Int64(id.dropFirst("seq:".count))
        }
    }

    private var rows: [Row] {
        let messages = snapshot.messages.map(Row.message)
        let activities = showsTelemetry
            ? Self.activities(from: snapshot.unmodelledEvents).map(Row.activity)
            : []
        return (messages + activities).sorted { $0.order < $1.order }
    }

    /// How many event cards the telemetry toggle is holding back.
    var telemetryCount: Int { snapshot.unmodelledEvents.count }

    var body: some View {
        VStack(alignment: .leading, spacing: DSHMetrics.spaceCard) {
            historyControls

            if snapshot.hasGap {
                // SPEC §7: a hole in the history is said out loud rather than shown as a
                // conversation that looks continuous.
                Label("Some of this conversation is missing.", systemImage: "exclamationmark.triangle")
                    .font(.dshMetadata)
                    .foregroundStyle(DSHPalette.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(rows) { row in
                switch row {
                case .message(let message):
                    MessageRow(message: message, loadImage: loadImage)
                case .activity(let activity):
                    ToolCard(
                        title: activity.title,
                        collapsedSummary: activity.summary,
                        state: .unknown,
                        results: activity.details.map { [ToolCard.ToolField(label: "Output", value: $0)] } ?? []
                    )
                }
            }

            if snapshot.isStreaming {
                HStack(spacing: DSHMetrics.space) {
                    ProgressView()
                    Text("Working…").foregroundStyle(DSHPalette.secondaryText)
                }
                .font(.dshMetadata)
            }

            decisions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - History

    @ViewBuilder
    private var historyControls: some View {
        if snapshot.isLoadingOlder {
            HStack(spacing: DSHMetrics.space) {
                ProgressView()
                Text("Loading older history…").foregroundStyle(DSHPalette.secondaryText)
            }
            .font(.dshMetadata)
        } else if let pageError = snapshot.pageError {
            VStack(alignment: .leading, spacing: DSHMetrics.spaceSmall) {
                Text("Couldn’t load older history")
                    .font(.dshMetadata)
                    .foregroundStyle(DSHPalette.error)
                Text(pageError)
                    .font(.dshMetadata)
                    .foregroundStyle(DSHPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { onLoadOlder?() }
                    .font(.dshMetadata)
                    .foregroundStyle(DSHPalette.primaryActionText)
            }
        } else if snapshot.canLoadOlder {
            Button("Load older messages") { onLoadOlder?() }
                .font(.dshMetadata)
                .foregroundStyle(DSHPalette.primaryActionText)
                .frame(minHeight: DSHMetrics.minimumHitTarget)
        }
    }

    // MARK: - Decisions

    /// Pending questions, batched by the call that asked them.
    ///
    /// SPEC §8 keys a group by `(host, session, callId)` and this is that grouping: one
    /// call that asked three questions is one card with three items, not three cards that
    /// could be answered separately.
    @ViewBuilder
    private var decisions: some View {
        let groups = Dictionary(grouping: snapshot.pendingQuestions, by: \.callId)
        // One question, one card. The durable fold and the live `$events` delivery both know
        // about a question the host is waiting on, and rendering both put the same card on
        // screen twice — the same question, asked twice, side by side.
        //
        // Keyed on the question's own id rather than the call id: the waterfall for a question
        // carries no `callId` (only the durable `tool/call` does), so matching on calls left
        // both sides unkeyed and deduped nothing. The question id is on both.
        let liveQuestionIds = Set(
            liveQuestions
                .filter(\.state.isActionable)
                .flatMap { QuestionBatch(request: $0.request)?.questions.map(\.id) ?? [] }
        )
        ForEach(groups.keys.sorted(), id: \.self) { callId in
            // A card is only history once nothing live is answering it.
            let questions = (groups[callId] ?? []).filter { !liveQuestionIds.contains($0.id) }
            if !questions.isEmpty {
                DecisionCard(
                    content: .question(DecisionCard.Question(
                        header: questions.count == 1 ? questions[0].header : "\(questions.count) questions",
                        items: questions.map(Self.item(from:))
                    )),
                    isStale: isStale,
                    isSubmitting: isSubmitting,
                    footnote: isStale ? "This request is no longer confirmed open. It is kept as history." : nil,
                    onSubmit: onAnswer
                )
            }
        }

        ForEach(liveQuestions) { request in
            if let batch = QuestionBatch(request: request.request), !batch.questions.isEmpty {
                DecisionCard(
                    content: .question(DecisionCard.Question(
                        header: batch.questions.count == 1
                            ? batch.questions[0].header
                            : "\(batch.questions.count) questions",
                        items: batch.questions.map { question in
                            DecisionCard.Item(
                                id: question.id,
                                prompt: question.question,
                                options: question.options.map(\.label),
                                allowsMultipleSelection: question.multiSelect,
                                allowsCustomAnswer: false,
                                customAnswerPlaceholder: nil
                            )
                        }
                    )),
                    isStale: !request.state.isActionable,
                    isSubmitting: isSubmitting,
                    footnote: Self.footnote(for: request),
                    onSubmit: { answers in onAnswerLive?(request.id, answers) }
                )
            }
        }

        ForEach(approvals) { request in
            DecisionCard(
                content: .approval(Self.approval(from: request.request)),
                isStale: !request.state.isActionable,
                isSubmitting: isSubmitting,
                footnote: Self.footnote(for: request),
                onAllowOnce: { onApproval?(request.id, true) },
                onReject: { onApproval?(request.id, false) }
            )
        }
    }

    /// The approval's own fields, read from the request rather than composed.
    ///
    /// SPEC §8: show "the supplied tool name/reason and available details"; never fabricate
    /// a command that the request and the history do not both contain. This host sends
    /// `{toolName, callId, reason}` and nothing else, so an absent field renders as absent.
    static func approval(from request: JSONValue) -> DecisionCard.Approval {
        DecisionCard.Approval(
            reason: request["reason"]?.stringValue,
            action: request["toolName"]?.stringValue ?? "An action",
            scope: request["callId"]?.stringValue.map { "Call \($0)" },
            details: request["command"]?.stringValue
        )
    }

    private static func footnote(for request: InteractionRequest) -> String? {
        switch request.state {
        case .pending: nil
        case .submitting: "Sending…"
        case .uncertain: "That may not have been sent. It will not be retried."
        case .settled: "This request is closed. The card is kept as history."
        }
    }

    private static func item(from question: PendingQuestion) -> DecisionCard.Item {
        DecisionCard.Item(
            id: question.id,
            prompt: question.question,
            options: question.options.map(\.label),
            allowsMultipleSelection: question.allowsMultiple,
            allowsCustomAnswer: false,
            customAnswerPlaceholder: nil
        )
    }

    // MARK: - Non-message events

    /// Durable events with no message of their own, as generic cards.
    ///
    /// Deliberately not a tool-call parser. The installed capture holds no tool-call
    /// event, so any field name this invented — a command, a path, a file count — would
    /// be a guess presented as a fact, and the UX spec allows a summary only when the
    /// host supplied the data to support it. What is known is the event's own type and,
    /// where the payload carries readable strings, those: everything else stays in the
    /// expansion rather than being paraphrased.
    private static func activities(from events: [DurableEventEnvelope]) -> [Activity] {
        events.map { event in
            Activity(
                id: "seq:\(event.seq)",
                title: Self.title(for: event),
                summary: event.data["name"]?.stringValue,
                details: Self.details(for: event),
                eventType: event.type
            )
        }
    }

    private static func title(for event: DurableEventEnvelope) -> String {
        // A `user/message` here is host-injected content — a human one would have become a
        // message — so it is titled by the host's own `source.kind` ("agent-instructions",
        // "runtime-context", "skill-catalog"). Calling that "User Message" would be the same
        // misattribution, one layer down.
        if event.type == "user/message",
           let kind = event.data["source"]?["kind"]?.stringValue,
           kind != "user" {
            return readable(kind)
        }
        return readable(event.type)
    }

    /// A namespaced wire string, made readable without inventing a meaning:
    /// `turn/start` becomes "Turn start", `agent-instructions` becomes "Agent instructions".
    private static func readable(_ wire: String) -> String {
        let words = wire
            .split(whereSeparator: { $0 == "/" || $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return words.isEmpty ? wire : words.joined(separator: " ")
    }

    /// A bounded, exact rendering of the payload. It is the host's own JSON, so it is
    /// safe to show verbatim — unlike a paraphrase, it cannot be wrong.
    private static func details(for event: DurableEventEnvelope) -> String? {
        guard let encoded = try? JSONEncoder().encode(event.data),
              let text = String(data: encoded, encoding: .utf8),
              text != "{}"
        else { return nil }
        return text
    }
}

/// One message: a graphite bubble toward the trailing edge for the user, prose on the
/// canvas for the assistant.
private struct MessageRow: View {
    let message: ConversationMessage
    /// Loads one attachment's pixels; nil leaves an image listed by name rather than drawn.
    var loadImage: ((String) async -> DisplayImage?)?

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: DSHMetrics.spaceGroup) }
            VStack(alignment: .leading, spacing: DSHMetrics.space) {
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    ReasoningDisclosure(text: reasoning)
                }
                MessageBody(text: message.text)
                if !message.attachments.isEmpty {
                    // The files the message actually carried. SPEC §9 retires the receipt into
                    // a durable part, so this is what the host recorded, not a guess.
                    ForEach(message.attachments) { attachment in
                        if attachment.isImage, let id = attachment.attachmentId, let loadImage {
                            AttachmentThumbnail(attachment: attachment) { await loadImage(id) }
                        } else {
                            Label(attachment.name, systemImage: "paperclip")
                                .font(.dshMetadata)
                                .foregroundStyle(DSHPalette.secondaryText)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(message.role == .user ? DSHMetrics.spaceCard : 0)
            .background(message.role == .user ? DSHPalette.elevatedSurface : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: DSHMetrics.cardCornerRadius, style: .continuous))
            .opacity(message.isProvisional ? 0.85 : 1)
            if message.role == .assistant { Spacer(minLength: 0) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message.role == .user ? "You" : "Assistant")
    }
}

/// Reasoning, collapsed. SPEC §7: optional detail the host supplied, never synthesised
/// from ordinary text and never mixed into the answer.
private struct ReasoningDisclosure: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: DSHMetrics.spaceSmall) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: DSHMetrics.spaceSmall + 2) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .accessibilityHidden(true)
                    Text("Reasoning")
                        .font(.dshMetadata)
                }
                .foregroundStyle(DSHPalette.secondaryText)
                .frame(minHeight: DSHMetrics.minimumHitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Hides the model's reasoning" : "Shows the model's reasoning")

            if isExpanded {
                Text(text)
                    .font(.dshMetadata)
                    .foregroundStyle(DSHPalette.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Message text: prose, with fenced code blocks rendered as code.
///
/// The prose half stays inline-only **on purpose, and this is the third attempt**. Full
/// block parsing renders headings and lists properly but swallows the line breaks,
/// turning a structured answer into one wall of text — measurably worse to read than the
/// literal markers it replaced. Fenced code is the exception that earns block handling:
/// it is the one construct where the whitespace *is* the content.
struct MessageBody: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: DSHMetrics.space) {
            ForEach(Array(MarkdownBlocks.parse(text).enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, inline: Self.inline)
            }
        }
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// A fenced code block: monospaced, horizontally scrollable, with its own Copy action.
private struct CodeBlock: View {
    let language: String?
    let code: String

    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DSHMetrics.space) {
                Text(language?.uppercased() ?? "CODE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(DSHPalette.secondaryText)
                Spacer(minLength: DSHMetrics.space)
                Button {
                    UIPasteboard.general.string = code
                    didCopy = true
                } label: {
                    Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DSHPalette.primaryActionText)
                .accessibilityLabel(didCopy ? "Copied" : "Copy this code")
            }
            .padding(.horizontal, DSHMetrics.spaceCard)
            .padding(.top, DSHMetrics.space)

            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.dshCode)
                    .foregroundStyle(DSHPalette.primaryText)
                    .textSelection(.enabled)
                    .padding(DSHMetrics.spaceCard)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSHPalette.elevatedSurface)
        .clipShape(RoundedRectangle(cornerRadius: DSHMetrics.spaceCard, style: .continuous))
    }
}

/// Draws one markdown block.
///
/// Inline styling (bold, italic, code spans, links) is the platform's job — `Text` renders an
/// `AttributedString` from inline markdown well. What the platform will not do is decide that
/// `- item` is a list or that `|---|` makes a table, so those decisions arrive here as blocks
/// and this draws them.
private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    /// Inline markdown parsing, shared with the message body so a bold word looks the same
    /// inside a list item as in a paragraph.
    let inline: (String) -> AttributedString

    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(inline(text))
                .font(.dshMessageBody)
                .foregroundStyle(DSHPalette.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level, let text):
            Text(inline(text))
                .font(Self.headingFont(level))
                .foregroundStyle(DSHPalette.primaryText)
                .textSelection(.enabled)
                // Space above so a heading reads as one, except when it opens the message.
                .padding(.top, level <= 2 ? DSHMetrics.space : DSHMetrics.spaceSmall)
                .fixedSize(horizontal: false, vertical: true)

        case .bullet(let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: DSHMetrics.spaceSmall) {
                Text("•")
                    .font(.dshMessageBody)
                    .foregroundStyle(DSHPalette.secondaryText)
                Text(inline(text))
                    .font(.dshMessageBody)
                    .foregroundStyle(DSHPalette.primaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * DSHMetrics.spaceGroup)

        case .numbered(let depth, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: DSHMetrics.spaceSmall) {
                Text("\(marker).")
                    .font(.dshMessageBody)
                    .foregroundStyle(DSHPalette.secondaryText)
                    .monospacedDigit()
                Text(inline(text))
                    .font(.dshMessageBody)
                    .foregroundStyle(DSHPalette.primaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * DSHMetrics.spaceGroup)

        case .quote(let text):
            HStack(alignment: .top, spacing: DSHMetrics.space) {
                // A rule in the palette rather than a `Divider`: it marks the quote without
                // competing with the card edges around it.
                Rectangle()
                    .fill(DSHPalette.divider)
                    .frame(width: 3)
                Text(inline(text))
                    .font(.dshMessageBody)
                    .foregroundStyle(DSHPalette.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .rule:
            Divider().overlay(DSHPalette.divider)

        case .code(let language, let text):
            CodeBlock(language: language, code: text)

        case .table(let headers, let rows):
            MarkdownTable(headers: headers, rows: rows, inline: inline)
        }
    }

    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .dshCardTitle
        case 2: .dshSupporting.weight(.semibold)
        default: .dshMessageBody.weight(.semibold)
        }
    }
}

/// A markdown table, drawn as a real grid.
///
/// Horizontally scrollable rather than squeezed: a harness table with four columns and long
/// cell text is unreadable when wrapped into a phone's width, and a scroll keeps the columns
/// lined up with their headers.
private struct MarkdownTable: View {
    let headers: [String]
    let rows: [[String]]
    let inline: (String) -> AttributedString

    private var columnCount: Int {
        max(headers.count, rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                row(headers, isHeader: true)
                Divider().overlay(DSHPalette.divider)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                    row(cells, isHeader: false)
                    if index < rows.count - 1 {
                        Divider().overlay(DSHPalette.divider)
                    }
                }
            }
            .background(DSHPalette.elevatedSurface)
            .clipShape(RoundedRectangle(cornerRadius: DSHMetrics.spaceSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DSHMetrics.spaceSmall, style: .continuous)
                    .strokeBorder(DSHPalette.cardEdge, lineWidth: 1)
            )
        }
    }

    private func row(_ cells: [String], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<columnCount, id: \.self) { column in
                let value = column < cells.count ? cells[column] : ""
                Text(inline(value))
                    .font(isHeader ? .dshMetadata.weight(.semibold) : .dshMetadata)
                    .foregroundStyle(isHeader ? DSHPalette.primaryText : DSHPalette.secondaryText)
                    .multilineTextAlignment(.leading)
                    .frame(minWidth: 110, alignment: .leading)
                    .padding(.horizontal, DSHMetrics.spaceCard)
                    .padding(.vertical, DSHMetrics.spaceSmall + 2)
                if column < columnCount - 1 {
                    Rectangle()
                        .fill(DSHPalette.divider)
                        .frame(width: 1)
                }
            }
        }
    }
}
