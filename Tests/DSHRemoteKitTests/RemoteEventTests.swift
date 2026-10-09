import Foundation
import Testing
@testable import DSHRemoteKit

// The `$events` vocabulary is the one part of `Models/` whose authority is the installed
// host source rather than `Fixtures/`, so these tests assert the exact wire shapes the
// gateway constructs — `{type:"ready",clientId,host}`, `{type:"emit",event,args}`,
// `{type:"waterfall",event,eventId,agentId,request}`, `{type:"cancel",eventId}` — and
// that anything else survives decoding instead of failing the stream.

@Suite("Remote event decoding")
struct RemoteEventTests {
    private func event(_ json: JSONValue) -> RemoteEvent {
        RemoteEvent(jsonValue: json)
    }

    @Test("a ready frame carries the clientId that addresses every later result")
    func ready() {
        let decoded = event(.object([
            "type": .string("ready"),
            "clientId": .string("client-1"),
            "host": .object(["home": .string("/Users/example")]),
        ]))
        #expect(decoded.typeName == "ready")
        #expect(decoded == .ready(
            clientId: "client-1",
            host: .object(["home": .string("/Users/example")])
        ))
        #expect(decoded.eventId == nil)
    }

    @Test("a ready frame without a clientId is retained whole, not half-decoded")
    func readyWithoutClientId() {
        let json = JSONValue.object([
            "type": .string("ready"),
            "host": .object([:]),
        ])
        #expect(event(json) == .unknown(type: "ready", value: json))
    }

    @Test("an emit is a broadcast with no eventId, because nothing can be submitted for it")
    func emit() {
        let decoded = event(.object([
            "type": .string("emit"),
            "event": .string("session/updated"),
            "args": .object(["sessionId": .string("session-1")]),
        ]))
        #expect(decoded == .emit(
            event: "session/updated",
            args: .object(["sessionId": .string("session-1")])
        ))
        #expect(decoded.eventId == nil)
        #expect(decoded.agentId == nil)
    }

    @Test("a waterfall keeps its event, eventId, session scope, and request")
    func waterfall() {
        let request = JSONValue.object([
            "toolName": .string("bash"),
            "callId": .string("call-1"),
            "reason": .string("Run the requested test command"),
        ])
        let decoded = event(.object([
            "type": .string("waterfall"),
            "event": .string("approval/request"),
            "eventId": .string("event-1"),
            "agentId": .string("session-1"),
            "request": request,
        ]))
        #expect(decoded.waterfall == RemoteWaterfall(
            event: "approval/request",
            eventId: "event-1",
            agentId: "session-1",
            request: request
        ))
        #expect(decoded.eventId == "event-1")
        // The only session scope on the frame. A consumer must use it rather than the
        // conversation that happens to be visible.
        #expect(decoded.agentId == "session-1")
    }

    @Test("a waterfall that cannot be addressed is retained whole", arguments: [
        // no eventId: cannot be answered
        JSONValue.object([
            "type": .string("waterfall"),
            "event": .string("approval/request"),
            "agentId": .string("session-1"),
            "request": .object([:]),
        ]),
        // empty eventId: the host refuses empty identities on results
        JSONValue.object([
            "type": .string("waterfall"),
            "event": .string("approval/request"),
            "eventId": .string(""),
            "agentId": .string("session-1"),
            "request": .object([:]),
        ]),
        // no agentId: cannot be scoped to a conversation
        JSONValue.object([
            "type": .string("waterfall"),
            "event": .string("approval/request"),
            "eventId": .string("event-1"),
            "request": .object([:]),
        ]),
    ])
    func unaddressableWaterfall(_ json: JSONValue) {
        let decoded = event(json)
        guard case .unknown(let type, let value) = decoded else {
            Issue.record("expected an unknown value, got \(decoded)")
            return
        }
        #expect(type == "waterfall")
        // Retained losslessly, so a diagnostic can still show what the host sent.
        #expect(value == json)
    }

    @Test("a cancel carries only the eventId it retires")
    func cancel() {
        let decoded = event(.object([
            "type": .string("cancel"),
            "eventId": .string("event-1"),
        ]))
        #expect(decoded == .cancel(eventId: "event-1"))
        #expect(decoded.eventId == "event-1")
    }

    @Test("an unrecognised kind is kept whole rather than ending the stream")
    func unknownKind() {
        let json = JSONValue.object([
            "type": .string("something-new"),
            "payload": .array([.int(1), .bool(true)]),
        ])
        #expect(event(json) == .unknown(type: "something-new", value: json))
    }

    @Test("a value with no string type is not treated as a named event")
    func missingType() {
        let json = JSONValue.object(["clientId": .string("client-1")])
        #expect(event(json) == .unknown(type: "", value: json))
    }

    // MARK: - The mux bridge

    /// A `$events` frame reaches `MuxFrameValue` as its `unknown` case: that union models
    /// the `session/follow` values, and SPEC §5 keeps anything else whole. The bridge must
    /// read the event out of that case, and must *not* mistake a follow value for an event.

    private func value(_ json: JSONValue) throws -> MuxFrameValue {
        let frame = try JSONDecoder().decode(MuxFrame.self, from: JSONEncoder().encode(json))
        return try #require(frame.value)
    }

    @Test("a $events item value decodes through the mux frame bridge")
    func bridgeDecodesEvent() throws {
        let decoded = try value(.object([
            "type": .string("item"),
            "streamId": .string("events-1"),
            "value": .object([
                "type": .string("waterfall"),
                "event": .string("approval/request"),
                "eventId": .string("event-1"),
                "agentId": .string("session-1"),
                "request": .object([:]),
            ]),
        ]))
        #expect(decoded.remoteEvent?.eventId == "event-1")
        #expect(decoded.remoteEvent?.agentId == "session-1")
    }

    @Test("a session/follow value is not an event")
    func bridgeRejectsFollowValues() throws {
        let decoded = try value(.object([
            "type": .string("item"),
            "streamId": .string("follow-1"),
            "value": .object([
                "type": .string("assistant-stream"),
                "frame": .object(["type": .string("start")]),
            ]),
        ]))
        // Distinguishable from "an event this build does not model": nil means "not an
        // event at all".
        #expect(decoded.remoteEvent == nil)
    }
}
