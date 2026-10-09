import Foundation

// The `$events` vocabulary, as established by the installed gateway source
// (`dsh-api-gateway/lib/index.js`, harness `0.2.0-rc.2`) rather than by a capture:
// every shape below is read off the code that produces it. This is the one place in
// `Models/` whose authority is source rather than `Fixtures/`, so each case records
// the exact construction it was read from.
//
// `$events` is not an ordinary Remote endpoint. `TypertGateway.openWireStream`
// intercepts the endpoint name and routes it to `openRemoteEvents`, which is why it
// appears in no descriptor and takes no arguments:
//
//     if (endpoint === "$events") { releaseUplink(uplink); return this.openRemoteEvents(payload, signal); }
//
// and `openRemoteEvents` refuses anything but an empty `args`:
//
//     ... Reflect.ownKeys(payload.args).length !== 0) throw new TypertGatewayError(
//         "gateway/arguments-invalid", REMOTE_EVENT_STREAM_ENDPOINT,
//         "forwarded Remote event stream requires an empty args object")
//
// That is a hard error, not an ignored filter — so a client that tries to scope
// `$events` by agent loses the whole stream. Events arrive for the host and the
// client scopes their *presentation* using the delivered `agentId` (SPEC §4).

/// One value delivered on the `$events` stream.
///
/// The four modelled cases are `ready`, `emit`, `waterfall`, and `cancel`. Everything
/// else is kept whole in ``unknown(type:value:)``: SPEC §5 requires an unrecognised
/// shape to stay readable rather than fail the stream, and a host that adds a fifth
/// event kind must not take the socket down with it.
public enum RemoteEvent: Sendable, Hashable {
    /// The first frame, and the proof that the host event source is there.
    ///
    /// ```js
    /// yield { ...REMOTE_EVENT_STREAM_READY, clientId, host: registration.host };
    /// //   REMOTE_EVENT_STREAM_READY = { type: "ready" }
    /// ```
    ///
    /// `clientId` addresses every later `$events/result`, which is why
    /// ``ConnectionCoordinator/firstReadyFrame(in:streamId:)`` already refuses a ready
    /// frame without one. The router sees this only if the connection handshake left it
    /// in the stream; normally the handshake consumes it.
    case ready(clientId: String, host: JSONValue?)

    /// A broadcast event with no reply channel.
    ///
    /// ```js
    /// broadcastRemoteEvent(frame) {
    ///     const wire = { type: "emit", event: frame.event, args: frame.args };
    /// ```
    ///
    /// `emit` never carries an `eventId`: it is host-wide notification, not a request
    /// awaiting an answer, so nothing may be submitted in response to one.
    case emit(event: String, args: JSONValue)

    /// A request awaiting a reply on `/api/$events/result`.
    ///
    /// ```js
    /// frame: { type: "waterfall", event: source.event, eventId: id,
    ///          agentId: source.context.agentId, request: projected.request }
    /// ```
    ///
    /// `agentId` is the session the request belongs to — the only session scope on the
    /// frame. A waterfall whose `agentId` matches nothing the user is looking at must not
    /// be attached to whichever conversation happens to be visible (SPEC §8).
    case waterfall(RemoteWaterfall)

    /// Retires a delivery. Carries no reason and implies none.
    ///
    /// ```js
    /// finishRemoteEvent(pending) {
    ///     ...
    ///     const cancellation = { type: "cancel", eventId: pending.id };
    ///     for (const client of clients) client.queue.push(cancellation);
    /// }
    /// ```
    ///
    /// Note the call site: `finishRemoteEvent` is reached from **both**
    /// `settleRemoteEvent` (answered, including by another client) and
    /// `cancelRemoteEvent` (aborted). A `cancel` frame therefore means "this delivery is
    /// over", never "the user rejected it" — the same frame arrives when a request was
    /// successfully answered elsewhere.
    case cancel(eventId: String)

    /// A value this build does not model, kept whole — `type` included — so nothing the
    /// host sent is dropped and no field is guessed.
    case unknown(type: String, value: JSONValue)

    /// The wire discriminator, verbatim.
    public var typeName: String {
        switch self {
        case .ready: Self.readyRawValue
        case .emit: Self.emitRawValue
        case .waterfall: Self.waterfallRawValue
        case .cancel: Self.cancelRawValue
        case .unknown(let type, _): type
        }
    }

    public static let readyRawValue = "ready"
    public static let emitRawValue = "emit"
    public static let waterfallRawValue = "waterfall"
    public static let cancelRawValue = "cancel"

    public var waterfall: RemoteWaterfall? {
        if case .waterfall(let value) = self { value } else { nil }
    }

    /// The event ID this value correlates against, for the kinds that have one.
    ///
    /// `emit` has none by construction, and `ready`/`unknown` have nothing to correlate.
    public var eventId: String? {
        switch self {
        case .waterfall(let waterfall): waterfall.eventId
        case .cancel(let eventId): eventId
        case .ready, .emit, .unknown: nil
        }
    }

    /// The session an event belongs to, where the frame carries one.
    ///
    /// Only `waterfall` is scoped. `emit` is host-wide by construction, so nil here means
    /// "not scoped by the host", which a consumer must not read as "belongs to the
    /// visible session".
    public var agentId: String? {
        switch self {
        case .waterfall(let waterfall): waterfall.agentId
        case .ready, .emit, .cancel, .unknown: nil
        }
    }
}

/// A `waterfall` request: what the host wants answered, and how to address the answer.
///
/// Split out from ``RemoteEvent`` because the request body's shape depends on `event`
/// (`approval/request` and `user-questions/request` share no fields), so it stays
/// ``JSONValue`` — the same policy ``DurableEventEnvelope/data`` follows.
public struct RemoteWaterfall: Sendable, Hashable {
    /// The namespaced event name, e.g. `approval/request` or `user-questions/request`.
    /// Open-ended: an unlisted name must stay readable (SPEC §5).
    public var event: String
    /// Correlates the reply on `/api/$events/result`. Unique per delivery within a host.
    public var eventId: String
    /// The session this request belongs to. Never empty — the host rejects a scoped event
    /// without a non-empty Agent identity:
    ///
    /// ```js
    /// if (!isRemoteEventAgentId(source.context.agentId))
    ///     throw new TypeError("typert gateway: scoped Remote events require a non-empty Agent identity");
    /// ```
    public var agentId: String
    /// The request payload, lossless and untrusted in shape.
    public var request: JSONValue

    public init(event: String, eventId: String, agentId: String, request: JSONValue) {
        self.event = event
        self.eventId = eventId
        self.agentId = agentId
        self.request = request
    }
}

// MARK: - Decoding

extension RemoteEvent {
    /// Decodes one `$events` item value.
    ///
    /// Never fails. A frame whose `type` this build does not model, or a modelled type
    /// missing a field required to *address* it, becomes ``unknown(type:value:)`` rather
    /// than an error: the value is retained losslessly, so SPEC §6.9 can still show what
    /// the host said, and one unreadable frame cannot end the stream.
    ///
    /// The asymmetry is deliberate. A `cancel` missing its `eventId` cannot retire
    /// anything, so it has no useful modelled form; a `waterfall` missing its `eventId`
    /// cannot be answered, and is likewise kept whole. Both remain visible instead of
    /// being silently dropped or decoded into a half-populated value.
    public init(jsonValue: JSONValue) {
        guard let object = jsonValue.objectValue,
              let type = object["type"]?.stringValue
        else {
            self = .unknown(type: "", value: jsonValue)
            return
        }

        switch type {
        case Self.readyRawValue:
            // `clientId` is the whole point of the frame (it addresses every later
            // result), so a ready frame without one is not partly usable.
            guard let clientId = object["clientId"]?.stringValue, !clientId.isEmpty else {
                self = .unknown(type: type, value: jsonValue)
                return
            }
            self = .ready(clientId: clientId, host: object["host"])

        case Self.emitRawValue:
            guard let event = object["event"]?.stringValue else {
                self = .unknown(type: type, value: jsonValue)
                return
            }
            // `args` is required by the wire (`{type, event, args}`), but a broadcast with
            // no payload is still a readable notification, so an absent one decodes as
            // null rather than voiding the event.
            self = .emit(event: event, args: object["args"] ?? .null)

        case Self.waterfallRawValue:
            guard let event = object["event"]?.stringValue,
                  let eventId = object["eventId"]?.stringValue, !eventId.isEmpty,
                  let agentId = object["agentId"]?.stringValue
            else {
                self = .unknown(type: type, value: jsonValue)
                return
            }
            self = .waterfall(RemoteWaterfall(
                event: event,
                eventId: eventId,
                agentId: agentId,
                request: object["request"] ?? .null
            ))

        case Self.cancelRawValue:
            guard let eventId = object["eventId"]?.stringValue, !eventId.isEmpty else {
                self = .unknown(type: type, value: jsonValue)
                return
            }
            self = .cancel(eventId: eventId)

        default:
            self = .unknown(type: type, value: jsonValue)
        }
    }

    /// Decodes a modelled mux value into an event, where the value's shape allows it.
    ///
    /// A `$events` frame reaches ``MuxFrameValue`` as ``MuxFrameValue/unknown(type:value:)``
    /// — that union models the `session/follow` values (`snapshot`, `event`,
    /// `assistant-stream`), and SPEC §5 keeps anything else whole. Those three are
    /// therefore *not* events and return nil, which lets a caller tell "a frame that is
    /// not an event" from "an event this build does not model".
    public init?(_ value: MuxFrameValue) {
        switch value {
        case .snapshot, .event, .assistantStream:
            return nil
        case .unknown:
            guard let raw = value.unknownValue else { return nil }
            self.init(jsonValue: raw)
        }
    }
}

extension MuxFrameValue {
    /// The event on this value, when it is one.
    public var remoteEvent: RemoteEvent? { RemoteEvent(self) }
}
