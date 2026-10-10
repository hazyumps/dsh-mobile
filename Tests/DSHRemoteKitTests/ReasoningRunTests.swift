import Foundation
import Testing

@testable import DSHRemoteKit

/// A turn that thinks in several steps should read as one piece of thinking.
///
/// Reported from the phone: a long turn arrived as four collapsed "Reasoning" rows stacked down
/// the transcript, one per step, with the answer somewhere below them.
@Suite("Reasoning runs")
struct ReasoningRunTests {

    private func message(
        id: String,
        text: String = "",
        reasoning: String?,
        attachments: [MessageAttachment] = []
    ) -> ConversationMessage {
        ConversationMessage(
            id: id, role: .assistant, text: text, isProvisional: false,
            reasoning: reasoning, attachments: attachments
        )
    }

    @Test("consecutive reasoning-only steps become one row")
    func consecutiveStepsMerge() {
        let collapsed = ConversationBuilder.collapsingReasoningRuns([
            message(id: "seq:1", reasoning: "First I look at the pricing."),
            message(id: "seq:2", reasoning: "Then at who else has it."),
            message(id: "seq:3", reasoning: "Then I check the licence."),
        ])

        #expect(collapsed.count == 1)
        #expect(collapsed[0].id == "seq:1", "the row on screen should keep its identity")
        let reasoning = collapsed[0].reasoning ?? ""
        for fragment in ["First I look at the pricing.", "Then at who else has it.", "Then I check the licence."] {
            #expect(reasoning.contains(fragment), "a step's reasoning was dropped: \(fragment)")
        }
    }

    @Test("the answer ends the run")
    func answerEndsTheRun() {
        let collapsed = ConversationBuilder.collapsingReasoningRuns([
            message(id: "seq:1", reasoning: "Thinking."),
            message(id: "seq:2", reasoning: "More thinking."),
            message(id: "seq:3", text: "Here is the answer.", reasoning: nil),
            message(id: "seq:4", reasoning: "A later turn's thinking."),
        ])

        #expect(collapsed.count == 3)
        #expect(collapsed[1].text == "Here is the answer.")
        // The run after the answer is its own row, not absorbed into the one before it.
        #expect(collapsed[2].reasoning == "A later turn's thinking.")
    }

    @Test("a message with anything in it is never absorbed")
    func nothingVisibleIsEverDropped() {
        let attachment = MessageAttachment(
            attachmentId: "sha256:abc", name: "probe.png", mediaType: "image/png",
            byteCount: 100, pixelWidth: 10, pixelHeight: 10
        )
        let collapsed = ConversationBuilder.collapsingReasoningRuns([
            message(id: "seq:1", reasoning: "Thinking."),
            message(id: "seq:2", reasoning: "And a picture.", attachments: [attachment]),
        ])

        #expect(collapsed.count == 2, "a message carrying an attachment was merged away")
    }

    @Test("a user message with no text is not a reasoning run")
    func userMessagesAreNotMerged() {
        let user = ConversationMessage(
            id: "seq:1", role: .user, text: "", isProvisional: false, reasoning: "not a thing"
        )
        let collapsed = ConversationBuilder.collapsingReasoningRuns([user, user])

        #expect(collapsed.count == 2)
    }
}
