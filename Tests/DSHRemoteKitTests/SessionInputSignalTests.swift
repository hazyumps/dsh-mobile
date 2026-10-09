import Foundation
import Testing

@testable import DSHRemoteKit

/// The "needs input" rule of SPEC §4, which is the one card behaviour with a documented trap.
@Suite("Session input signal")
struct SessionInputSignalTests {

    @Test("a pending inbox item means the session is waiting")
    func inboxWaits() {
        #expect(SessionInputSignal.isWaiting(
            inbox: .object(["next-turn": .array([.string("queued thing")]), "next-step": .array([])]),
            userQuestions: nil
        ))
        #expect(SessionInputSignal.isWaiting(
            inbox: .object(["next-turn": .array([]), "next-step": .array([.string("step")])]),
            userQuestions: nil
        ))
    }

    @Test("an active question means waiting; a settled one does not")
    func activeQuestionsWait() {
        #expect(SessionInputSignal.isWaiting(
            inbox: nil,
            userQuestions: .object(["active": .array([.string("q1")]), "settled": .array([])])
        ))
        // The mistake this exists to prevent: a session whose questions are all answered is
        // not waiting on anyone, and a badge driven by history would never clear.
        #expect(!SessionInputSignal.isWaiting(
            inbox: nil,
            userQuestions: .object(["active": .array([]), "settled": .array([.string("q1")])])
        ))
    }

    @Test("an empty or absent projection is not a badge")
    func nothingMeansNo() {
        // The live host reports exactly this shape for an idle session.
        #expect(!SessionInputSignal.isWaiting(
            inbox: .object(["next-turn": .array([]), "next-step": .array([])]),
            userQuestions: .object(["active": .array([]), "settled": .array([])])
        ))
        #expect(!SessionInputSignal.isWaiting(inbox: nil, userQuestions: nil))
        #expect(!SessionInputSignal.isWaiting(projections: nil))
        // Malformed data is "no" too: a badge that cannot be justified from the host's own
        // data is worse than a missing one.
        #expect(!SessionInputSignal.isWaiting(
            inbox: .object(["next-turn": .string("not an array")]),
            userQuestions: .object(["active": .string("nope")])
        ))
    }

    @Test("the projection map form reads the same two keys")
    func projectionMapForm() {
        #expect(SessionInputSignal.isWaiting(projections: [
            "inbox": .object(["next-turn": .array([.int(1)])]),
        ]))
        #expect(!SessionInputSignal.isWaiting(projections: [
            "title": .string("A session"),
            "modelSelection": .object([:]),
        ]))
    }
}
