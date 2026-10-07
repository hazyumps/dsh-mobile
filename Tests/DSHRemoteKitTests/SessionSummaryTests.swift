import Foundation
import Testing

@testable import DSHRemoteKit

/// The whole `session/list` capture, decoded through the generic response envelope.
func capturedSessionList() throws -> RPCResponse<SessionListResult> {
    try Fixtures.decode(RPCResponse<SessionListResult>.self, .rpcSessionList)
}

@Test("rpc-response-session-list.json decodes as an ok response carrying items")
func sessionListDecodes() throws {
    let response = try capturedSessionList()

    #expect(response.type == .serverResponse)
    #expect(response.rpcId == "fixture-capture")
    #expect(response.result.ok == true)
    #expect(response.result.error == nil)

    let items = try #require(response.result.value?.items)
    #expect(items.map(\.sessionId) == ["session-0001", "session-0002", "session-0003"])

    let object = try Fixtures.object(.rpcSessionList)
    #expect(Set(object.keys) == ["type", "rpcId", "result"])
    #expect(Set(try #require(object["result"]?.objectValue).keys) == ["ok", "value"])
    #expect(Set(try #require(object["result"]?["value"]?.objectValue).keys) == ["items"])
}

@Test("every captured item exposes exactly the seven documented keys")
func sessionItemShapeMatchesCapture() throws {
    let object = try Fixtures.object(.rpcSessionList)
    let rawItems = try #require(object["result"]?["value"]?["items"]?.arrayValue)
    #expect(rawItems.count == 3)

    let documented: Set<String> = [
        "agentAvailable", "blank", "cwd", "projections", "running", "sessionId", "updatedAt",
    ]
    for raw in rawItems {
        #expect(Set(try #require(raw.objectValue).keys) == documented)
    }
}

@Test("SessionSummary carries the per-row flags the session list renders")
func sessionSummaryFlags() throws {
    let items = try #require(try capturedSessionList().result.value?.items)

    #expect(items[0].updatedAt == 1_791_412_735_279)
    #expect(items[0].agentAvailable == true)
    #expect(items[0].running == true)
    #expect(items[0].blank == false)
    #expect(items[0].cwd == "redacted")

    #expect(items[1].running == false)
    #expect(items[1].blank == false)

    // The third row is a session with no prompt yet.
    #expect(items[2].running == false)
    #expect(items[2].blank == true)
    #expect(items[2].agentAvailable == true)
    #expect(items[2].updatedAt == 1_791_411_965_314)
}

@Test("projections expose the sequenced watermark and the projected title")
func sessionProjectionsDecode() throws {
    let items = try #require(try capturedSessionList().result.value?.items)

    #expect(items.map { $0.projections?.kind } == ["sequenced", "sequenced", "sequenced"])
    #expect(items.map(\.title) == ["redacted", "redacted", "redacted"])
    #expect(items[0].projections?.asOfSeq == 995)
    #expect(items[1].projections?.asOfSeq == 54)
    #expect(items[2].projections?.asOfSeq == 3)
    #expect(items[0].title == items[0].projections?.values?.title)
}

@Test("the projection fields Stage 1 renders decode")
func projectionValuesDecode() throws {
    let values = try #require(try capturedSessionList().result.value?.items.first?.projections?.values)

    #expect(values.agentPreset == "standard")
    #expect(values.permissions?.currentValue == "workspace-write")
    #expect(values.plan?.active == false)
    #expect(values.plan?.pending == false)

    #expect(values.tokenUsage?.uncachedInputTokens == 254_283)
    #expect(values.tokenUsage?.outputTokens == 193_911)
    #expect(values.tokenUsage?.cacheReadTokens == 28_142_720)
    #expect(values.tokenUsage?.cacheWriteTokens == 0)

    #expect(values.contextPressure?.pressureTokens == 357_086)
    #expect(values.contextPressure?.projectedTokens == 361_893)
    #expect(values.contextPressure?.contextWindow == 1_000_000)
    #expect(values.contextBreakdown?.systemTokens == 4_192)
    #expect(values.contextBreakdown?.toolsTokens == 36_501)
    #expect(values.contextBreakdown?.messageTokens == 265_846)

    #expect(values.sessionStats?.turns == 13)
    #expect(values.sessionStats?.steps == 129)
    #expect(values.sessionStats?.llmMs == 1_013_134)
    #expect(values.sessionStats?.toolMs == 430_013)
    #expect(values.sessionStats?.ttftMs == 243_804)
    #expect(values.sessionStats?.ttftSteps == 130)
    #expect(values.sessionStats?.decodeMs == 769_330)
    #expect(values.sessionStats?.decodeTokens == 193_911)

    #expect(values.sessionListMetadata?.blank == false)
    #expect(values.sessionListMetadata?.lastPromptAt == 1_791_412_735_279)

    // SPEC §3.6 host limits, before the app cap.
    #expect(values.imageLimits?.maxImageBytes == 20_971_520)
    #expect(values.imageLimits?.maxImagesPerMessage == 20)
    #expect(values.imageLimits?.maxMessageImageBytes == 209_715_200)
    #expect(values.imageLimits?.maxImagePixels == 64_000_000)
    #expect(values.imageLimits?.maxImageDimension == 8_192)
    #expect(values.imageLimits?.mediaTypes == ["image/png", "image/jpeg"])

    #expect(values.subagentTiming?.settledMs == 0)
    #expect(values.subagentCatalog == [])
    #expect(values.userQuestions?.active == [])
    #expect(values.userQuestions?.settled == [])
    #expect(values.inbox?.nextTurn == [])
    #expect(values.inbox?.nextStep == [])

    let outline = try #require(values.turnOutline)
    #expect(outline.count == 2)
    #expect(outline.first?.turn == 1)
    #expect(outline.first?.seq == 13)
    // Prompt and response text is redacted in the fixture: this repo carries wire shapes,
    // not transcripts. See the sanitisation note in the package README.
    #expect(outline.first?.prompt == "redacted")
    #expect(outline.first?.response == "redacted")
}

@Test("model selection decodes, including the null form for a new session")
func modelSelectionDecodesBothShapes() throws {
    let items = try #require(try capturedSessionList().result.value?.items)

    let used = try #require(items[0].projections?.values?.modelSelection)
    #expect(used.lastUsed?.provider == "deepseek-official")
    #expect(used.lastUsed?.model == "redacted")
    #expect(used.lastUsed?.reasoningEffort == "high")
    #expect(used.next?.provider == "deepseek-official")
    #expect(used.next?.reasoningEffort == "high")

    // The third session has the keys present but null.
    let fresh = try #require(items[2].projections?.values?.modelSelection)
    #expect(fresh.lastUsed == nil)
    #expect(fresh.next == nil)
}

@Test("a null or empty projection object decodes as missing fields")
func sparseProjectionsDecode() throws {
    let items = try #require(try capturedSessionList().result.value?.items)
    let values = try #require(items[2].projections?.values)

    // `goal`, `subagent`, and `todos` are null in every captured item.
    #expect(values.goal == nil)
    #expect(values.subagent == nil)
    #expect(values.todos == nil)

    // Item 3's contextPressure is `{}`, so nothing inside it may be required.
    #expect(items[1].projections?.values?.contextPressure?.contextWindow == 1_000_000)
    let sparse = try #require(values.contextPressure)
    #expect(sparse.pressureTokens == nil)
    #expect(sparse.projectedTokens == nil)
    #expect(sparse.contextWindow == nil)

    #expect(values.sessionListMetadata?.blank == true)
    #expect(values.sessionListMetadata?.lastPromptAt == nil)
    #expect(values.turnOutline == [])
}

@Test("an unrecognised projections kind and unknown fields decode")
func unknownProjectionFieldsTolerated() throws {
    var object = try Fixtures.object(.rpcSessionList)
    var items = try #require(object["result"]?["value"]?["items"]?.arrayValue)

    var first = try #require(items[0].objectValue)
    var projections = try #require(first["projections"]?.objectValue)
    projections["kind"] = .string("watermarked")
    projections["futureWatermark"] = .object(["a": .int(1)])
    var values = try #require(projections["values"]?.objectValue)
    values["brandNewProjection"] = .array([.string("x"), .null])
    projections["values"] = .object(values)
    first["projections"] = .object(projections)
    first["unseenRowKey"] = .int(42)
    items[0] = .object(first)

    object["result"] = .object([
        "ok": .bool(true),
        "value": .object(["items": .array(items)]),
    ])
    let response = try JSONDecoder().decode(
        RPCResponse<SessionListResult>.self,
        from: JSONEncoder().encode(JSONValue.object(object))
    )

    let row = try #require(response.result.value?.items.first)
    #expect(row.projections?.kind == "watermarked")
    #expect(row.sessionId == "session-0001")
    #expect(row.title == "redacted")
    #expect(row.projections?.asOfSeq == 995)
    // The unrecognised projection is dropped by the typed model but was not fatal.
    #expect(try #require(row.projections?.values?.turnOutline).count == 2)
}
