import Foundation
import Testing
@testable import DSHRemoteKit

// Slice A's completion evidence, at the router boundary:
//   "No lost post-ready event; host isolation; …"
// plus the cancel semantics SPEC §8 warns about, because getting those wrong is how an
// answered approval becomes a phantom "the user rejected it".

@Suite("Remote event router")
struct RemoteEventRouterTests {
    // MARK: - Doubles

    private actor EndReporter {
        private(set) var errors: [String] = []
        func report(_ error: any Error) { errors.append("\(error)") }
    }

    private actor EventRecorder {
        private(set) var events: [RemoteEvent] = []
        private(set) var ended = false
        func record(_ event: RemoteEvent) { events.append(event) }
        func end() { ended = true }
        var eventIds: [String] { events.compactMap(\.eventId) }
    }

    private func item(
        _ value: JSONValue,
        streamId: String = "events-1"
    ) throws -> MuxStreamItem {
        let json = JSONValue.object([
            "type": .string("item"),
            "streamId": .string(streamId),
            "value": value,
        ])
        let frame = try JSONDecoder().decode(MuxFrame.self, from: JSONEncoder().encode(json))
        return MuxStreamItem(streamId: streamId, frame: frame)
    }

    private func waterfall(_ eventId: String, event: String = "approval/request") -> JSONValue {
        .object([
            "type": .string("waterfall"),
            "event": .string(event),
            "eventId": .string(eventId),
            "agentId": .string("session-1"),
            "request": .object(["toolName": .string("bash")]),
        ])
    }

    private func makeRouter(
        generation: ConnectionCoordinator.Generation = 1,
        reporter: EndReporter? = nil
    ) -> RemoteEventRouter {
        RemoteEventRouter(
            identity: .init(generation: generation, clientId: "client-\(generation)"),
            onEnded: { error in await reporter?.report(error) }
        )
    }

    /// A test-held stream plus its router, already consuming.
    private func started(
        generation: ConnectionCoordinator.Generation = 1,
        reporter: EndReporter? = nil
    ) async -> (
        router: RemoteEventRouter,
        continuation: AsyncThrowingStream<MuxStreamItem, any Error>.Continuation
    ) {
        let (stream, continuation) = AsyncThrowingStream<MuxStreamItem, any Error>.makeStream()
        let router = makeRouter(generation: generation, reporter: reporter)
        await router.start(stream)
        return (router, continuation)
    }

    private func pump(
        _ stream: AsyncStream<RemoteEvent>,
        into recorder: EventRecorder
    ) -> Task<Void, Never> {
        Task {
            for await event in stream { await recorder.record(event) }
            await recorder.end()
        }
    }

    private func eventually(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return await condition()
    }

    // MARK: - Not losing the first event

    @Test("an event arriving before any store mounts is delivered to the first subscriber")
    func bufferedEventIsNotLost() async throws {
        let (router, continuation) = await started()

        // The host delivers pending events *before* the ready frame it was opened for, so
        // this is the ordinary case, not a race.
        continuation.yield(try item(waterfall("event-1")))
        #expect(await eventually { await router.pendingDeliveries.count == 1 })

        let recorder = EventRecorder()
        let pumping = pump(await router.events(), into: recorder)

        #expect(await eventually { await recorder.events.count == 1 })
        #expect(await recorder.eventIds == ["event-1"])
        #expect(await router.droppedBeforeAttach == 0)

        pumping.cancel()
        continuation.finish()
        await router.cancel()
    }

    @Test("the buffered prefix goes to the first subscriber only")
    func bufferIsHandedOverOnce() async throws {
        let (router, continuation) = await started()
        continuation.yield(try item(waterfall("event-1")))
        #expect(await eventually { await router.pendingDeliveries.count == 1 })

        let first = EventRecorder(), second = EventRecorder()
        let firstPump = pump(await router.events(), into: first)
        #expect(await eventually { await first.events.count == 1 })

        // Two screens showing the same approval is the duplicate-decision hazard SPEC §3.5
        // rules out, so a later subscriber gets live events only.
        let secondPump = pump(await router.events(), into: second)
        continuation.yield(try item(waterfall("event-2")))

        #expect(await eventually { await second.events.count == 1 })
        #expect(await second.eventIds == ["event-2"])
        #expect(await first.eventIds == ["event-1", "event-2"])

        firstPump.cancel()
        secondPump.cancel()
        continuation.finish()
        await router.cancel()
    }

    @Test("the pre-attach buffer is bounded and records that it dropped frames")
    func preAttachBufferIsBounded() async throws {
        let (router, continuation) = await started()

        let overflow = RemoteEventRouter.preAttachCapacity + 3
        for index in 0..<overflow {
            continuation.yield(try item(waterfall("event-\(index)")))
        }
        #expect(await eventually { await router.droppedBeforeAttach == 3 })

        let recorder = EventRecorder()
        let pumping = pump(await router.events(), into: recorder)
        #expect(await eventually {
            await recorder.events.count == RemoteEventRouter.preAttachCapacity
        })
        // The *newest* frames survive, because the oldest are the ones already superseded.
        #expect(await recorder.eventIds.last == "event-\(overflow - 1)")

        pumping.cancel()
        continuation.finish()
        await router.cancel()
    }

    // MARK: - Cancel semantics

    @Test("a waterfall is answerable until a cancel retires it")
    func cancelRetiresCorrelation() async throws {
        let (router, continuation) = await started()
        let recorder = EventRecorder()
        let pumping = pump(await router.events(), into: recorder)

        continuation.yield(try item(waterfall("event-1")))
        #expect(await eventually { await router.isDelivered("event-1") })

        continuation.yield(try item(.object([
            "type": .string("cancel"),
            "eventId": .string("event-1"),
        ])))
        #expect(await eventually { await router.isDelivered("event-1") == false })
        // The consumer still *sees* the cancel: it is what tells a screen to stop offering
        // an answer, and it closes over the request that may have been settled elsewhere.
        #expect(await recorder.events.count == 2)

        pumping.cancel()
        continuation.finish()
        await router.cancel()
    }

    @Test("a cancel is not a rejection: the same frame arrives when another client answered")
    func cancelCarriesNoVerdict() async throws {
        let (router, continuation) = await started()
        let recorder = EventRecorder()
        let pumping = pump(await router.events(), into: recorder)

        continuation.yield(try item(waterfall("event-1")))
        continuation.yield(try item(.object([
            "type": .string("cancel"),
            "eventId": .string("event-1"),
        ])))
        #expect(await eventually { await recorder.events.count == 2 })

        // The router models the frame as a retirement and nothing more. `cancel` carries no
        // reason on the wire (`{type:"cancel",eventId}`), so nothing here may invent one.
        #expect(await recorder.events[1] == .cancel(eventId: "event-1"))
        #expect(await router.pendingDeliveries.isEmpty)

        pumping.cancel()
        continuation.finish()
        await router.cancel()
    }

    // MARK: - One consumer

    @Test("a second start is refused, so two iterators never split the stream")
    func secondStartIsRefused() async throws {
        let (router, continuation) = await started()
        #expect(await eventually { await router.isRunning })

        // The second call returns immediately rather than competing for frames.
        let (other, otherContinuation) = AsyncThrowingStream<MuxStreamItem, any Error>.makeStream()
        await router.start(other)
        otherContinuation.yield(try item(waterfall("from-the-second-stream")))

        let recorder = EventRecorder()
        let pumping = pump(await router.events(), into: recorder)
        continuation.yield(try item(waterfall("from-the-first-stream")))

        #expect(await eventually { await recorder.events.count == 1 })
        #expect(await recorder.eventIds == ["from-the-first-stream"])

        pumping.cancel()
        continuation.finish()
        otherContinuation.finish()
        await router.cancel()
    }

    // MARK: - Termination

    @Test("a logical stream end is reported once so recovery runs")
    func logicalEndReports() async throws {
        let reporter = EndReporter()
        let (router, continuation) = await started(reporter: reporter)

        continuation.finish()
        #expect(await eventually { await reporter.errors.count == 1 })
        // Reported exactly once: a second report would schedule a second reconnect.
        #expect(await reporter.errors.count == 1)
        await router.cancel()
    }

    @Test("cancelling stops the consumer, retires deliveries, and reports nothing")
    func cancelIsSilent() async throws {
        let reporter = EndReporter()
        let (router, continuation) = await started(reporter: reporter)
        let recorder = EventRecorder()
        let pumping = pump(await router.events(), into: recorder)

        continuation.yield(try item(waterfall("event-1")))
        #expect(await eventually { await router.isDelivered("event-1") })

        // The behaviour under test: `cancel()` alone must stop the loop. A caller that had
        // to cancel a task as well could get the order wrong and hang.
        await router.cancel()

        // Nothing delivered by a retired generation can be answered.
        #expect(await router.pendingDeliveries.isEmpty)
        #expect(await recorder.ended)
        #expect(await reporter.errors.isEmpty)
        pumping.cancel()
    }

    @Test("cancelling before the consumer starts is safe")
    func cancelBeforeStart() async {
        let router = makeRouter()
        await router.cancel()
        #expect(await router.isDelivered("event-1") == false)

        // A late start after cancellation is refused rather than reviving the router.
        let (stream, continuation) = AsyncThrowingStream<MuxStreamItem, any Error>.makeStream()
        await router.start(stream)
        #expect(await router.isRunning == false)
        continuation.finish()
    }

    @Test("an error frame ends the stream with what the host said")
    func errorFrameStops() async throws {
        let reporter = EndReporter()
        let (router, continuation) = await started(reporter: reporter)

        let json = JSONValue.object([
            "type": .string("error"),
            "streamId": .string("events-1"),
            "error": .object([
                "code": .string("gateway/service-unavailable"),
                "message": .string("event source unavailable"),
            ]),
        ])
        let frame = try JSONDecoder().decode(MuxFrame.self, from: JSONEncoder().encode(json))
        continuation.yield(MuxStreamItem(streamId: "events-1", frame: frame))

        #expect(await eventually { await reporter.errors.count == 1 })
        let errors = await reporter.errors
        #expect(errors.first?.contains("gateway/service-unavailable") == true)
        await router.cancel()
    }
}

// MARK: - Generation isolation, through the coordinator

@Suite("Event routing and generation isolation")
@MainActor
struct RemoteEventGenerationTests {
    private func coordinator(_ transport: StubRelayTransport) -> ConnectionCoordinator {
        ConnectionCoordinator(
            origin: .init(baseURL: URL(string: "https://relay.test")!, authorization: .bearer("saved-token")),
            makeTransport: { _ in transport }
        )
    }

    private func ready(_ socket: StubRelaySocket, generation: UInt64) async throws {
        try await socket.push(json: .object([
            "type": .string("item"),
            "streamId": .string(ConnectionCoordinator.eventsStreamID(for: generation)),
            "value": .object(["type": .string("ready"), "clientId": .string("client-\(generation)")]),
        ]))
    }

    /// A `waterfall` on the given generation's `$events` stream.
    ///
    /// The stream ID matters: `MuxClient` drops an item for a stream it has no
    /// subscription for, so a frame addressed to generation 1 can never reach
    /// generation 2's router.
    private func waterfallEvent(
        _ eventId: String,
        generation: UInt64
    ) -> JSONValue {
        .object([
            "type": .string("item"),
            "streamId": .string(ConnectionCoordinator.eventsStreamID(for: generation)),
            "value": .object([
                "type": .string("waterfall"),
                "event": .string("approval/request"),
                "eventId": .string(eventId),
                "agentId": .string("session-1"),
                "request": .object(["toolName": .string("bash")]),
            ]),
        ])
    }

    private func eventually(_ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return await condition()
    }

    @Test("there is no router until a host is ready")
    func noRouterWhileOffline() async {
        let transport = StubRelayTransport(sockets: [StubRelaySocket()])
        let coordinator = coordinator(transport)
        #expect(await coordinator.remoteEvents() == nil)
    }

    @Test("a post-ready event reaches a subscriber instead of being discarded")
    func postReadyEventIsDelivered() async throws {
        let socket = StubRelaySocket()
        let transport = StubRelayTransport(sockets: [socket])
        try await ready(socket, generation: 1)
        // Queued *before* the handshake completes: this is the frame the old drain loop
        // threw away, and the whole reason SPEC §2 replaced it.
        try await socket.push(json: waterfallEvent("event-1", generation: 1))

        let coordinator = coordinator(transport)
        _ = try await coordinator.connect()
        let router = try #require(await coordinator.remoteEvents())

        let recorder = EventRecorder()
        let pump = Task {
            for await event in await router.events() { await recorder.record(event) }
        }
        #expect(await eventually { await recorder.eventIds == ["event-1"] })
        #expect(await router.isDelivered("event-1"))
        pump.cancel()
        await coordinator.shutdown()
    }

    @Test("reconnecting retires the old router so a stale generation cannot answer")
    func reconnectRetiresOldRouter() async throws {
        let first = StubRelaySocket(), second = StubRelaySocket()
        let transport = StubRelayTransport(sockets: [first, second])
        try await ready(first, generation: 1)
        try await first.push(json: waterfallEvent("event-1", generation: 1))
        try await ready(second, generation: 2)

        let coordinator = coordinator(transport)
        _ = try await coordinator.connect()
        let old = try #require(await coordinator.remoteEvents())
        #expect(await eventually { await old.isDelivered("event-1") })

        let retired = RetiredFlag()
        let pump = Task {
            for await _ in await old.events() {}
            await retired.mark()
        }

        // A reconnect burns a generation and replaces the router outright.
        _ = try await coordinator.connect()
        let current = try #require(await coordinator.remoteEvents())
        #expect(current.identity.generation == 2)
        #expect(current.identity.clientId == "client-2")

        // The old generation's subscriber is closed, and its pending approval is gone, so
        // no screen can submit an answer against a connection that no longer exists.
        #expect(await eventually { await retired.value })
        #expect(await old.pendingDeliveries.isEmpty)

        // The host replays the same eventId to the new client, and the new generation
        // accepts it — no event-ID comparison is needed to notice the replay.
        try await second.push(json: waterfallEvent("event-1", generation: 2))
        #expect(await eventually { await current.isDelivered("event-1") })
        pump.cancel()
        await coordinator.shutdown()
    }

    @Test("shutdown closes subscribers and retires deliveries")
    func shutdownClosesSubscribers() async throws {
        let socket = StubRelaySocket()
        let transport = StubRelayTransport(sockets: [socket])
        try await ready(socket, generation: 1)
        try await socket.push(json: waterfallEvent("event-1", generation: 1))
        let coordinator = coordinator(transport)
        _ = try await coordinator.connect()
        let router = try #require(await coordinator.remoteEvents())

        let retired = RetiredFlag()
        let pump = Task {
            for await _ in await router.events() {}
            await retired.mark()
        }
        #expect(await eventually { await router.isDelivered("event-1") })

        await coordinator.shutdown()
        #expect(await eventually { await retired.value })
        #expect(await router.pendingDeliveries.isEmpty)
        #expect(await coordinator.remoteEvents() == nil)
        #expect(await socket.closeCount == 1)
        pump.cancel()
    }
}

/// A one-way flag a test task can set and the test can read.
private actor RetiredFlag {
    private(set) var value = false
    func mark() { value = true }
}

/// Collects events off a subscriber stream for the `@MainActor` suite.
private actor EventRecorder {
    private(set) var events: [RemoteEvent] = []
    func record(_ event: RemoteEvent) { events.append(event) }
    var eventIds: [String] { events.compactMap(\.eventId) }
}
