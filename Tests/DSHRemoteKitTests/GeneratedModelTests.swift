import CryptoKit
import DSHRemoteKit
import Foundation
import XCTest

/// Decode coverage for `Sources/DSHRemoteKit/Generated`, driven entirely by
/// `Protocol/examples/manifest.json` and the generated registry.
///
/// Three things are asserted, and each one fails if the generation drifts:
///
/// 1. **The inventory.** The V1 endpoint list is written out by hand below. A
///    generator run that silently drops an endpoint, or that stops producing an
///    example for a schema it still uses, fails here.
/// 2. **The bytes.** Every generated file is hashed in the manifest. A
///    hand-edit of `Generated/`, of `Protocol/examples/`, or of the registry
///    fails here, which is what makes "regenerate it" the only way to change
///    those files.
/// 3. **The decodes.** Every generated declaration is decoded from its own
///    example and must succeed, and then the example is mutated and must fail.
///    A type whose required keys are not enforced, or an example that is
///    vacuous, fails here.
final class GeneratedModelTests: XCTestCase {

    // MARK: - The contract

    /// `namespace/method` for every endpoint V1 needs, by hand, from the build
    /// brief. Deliberately not derived from the manifest: this is the one place
    /// the generator's endpoint selection is checked against a human's reading.
    private static let v1Endpoints: Set<String> = [
        "session/list",
        "session/create",
        "session/follow",
        "session/page",
        "session/prompt",
        "session/cancel",
        "session/rename",
        "session/control",
        "session/projections",
        "session/modelCatalog",
        "session/selectModel",
        "session/attachment",
        "commands/list",
        "commands/execute",
        "llm/listProviders",
        "llm/listConfigurableProviders",
        "llm/discoverModels",
        "agentPresets/list",
        "agentPresets/read",
        "agentPresets/select",
        "permissionPresets/catalog",
        "workspace/follow",
        "goals/get",
        "goals/create",
        "goals/edit",
        "goals/pause",
        "goals/resume",
        "goals/complete",
        "goals/clear",
        "userQuestions/answer",
        "userQuestions/attachWait",
    ]

    /// Endpoints whose result the generator deliberately does not model, because
    /// `Sources/DSHRemoteKit/Models/StreamFrames.swift` already does. The
    /// response alias must point at the hand-written type.
    private static let excludedResultSchemas: [String: String] = [
        "schemas/dsh-api-session-controller.types.SessionFollowFrame.json": "MuxFrameValue"
    ]

    // MARK: - Paths

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static var examplesDirectory: URL {
        repoRoot.appending(path: "Protocol/examples")
    }

    private static var manifestURL: URL {
        examplesDirectory.appending(path: "manifest.json")
    }

    private func data(at path: String) throws -> Data {
        try Data(contentsOf: Self.repoRoot.appending(path: path))
    }

    private func manifest() throws -> Manifest {
        try JSONDecoder().decode(Manifest.self, from: data(at: "Protocol/examples/manifest.json"))
    }

    // MARK: - 1. Inventory

    func testGeneratedEndpointsAreExactlyTheV1Surface() throws {
        let manifest = try manifest()
        let generated = Set(manifest.endpoints.map(\.method))
        XCTAssertEqual(
            generated,
            Self.v1Endpoints,
            "the generator's endpoint set is not the V1 surface"
        )
    }

    func testEveryEndpointHasARequestAndAResultType() throws {
        let manifest = try manifest()
        for endpoint in manifest.endpoints {
            XCTAssertFalse(
                endpoint.argumentsType.isEmpty,
                "\(endpoint.method) has no arguments type"
            )
            XCTAssertFalse(
                endpoint.responseType.isEmpty,
                "\(endpoint.method) has no response type"
            )
            XCTAssertFalse(endpoint.mode.isEmpty, "\(endpoint.method) has no mode")
            XCTAssertNotNil(
                endpoint.httpPath,
                "\(endpoint.method) has no http path"
            )
        }
    }

    func testEveryEndpointParameterAndResultSchemaWasGenerated() throws {
        let manifest = try manifest()
        let known = Set(manifest.schemas.map(\.schema))
        let excluded = Set(manifest.excludedSchemas.map(\.schema))
        for endpoint in manifest.endpoints {
            XCTAssertTrue(
                known.contains(endpoint.resultSchema) || excluded.contains(endpoint.resultSchema),
                "\(endpoint.method): result schema \(endpoint.resultSchema) was neither generated nor excluded"
            )
            for parameter in endpoint.parameters {
                XCTAssertTrue(
                    known.contains(parameter.schema),
                    "\(endpoint.method).\(parameter.wire): schema \(parameter.schema) has no generated type"
                )
            }
        }
    }

    /// The one result the generator refuses to model must still be reachable,
    /// through the hand-written type, and it must be reachable for exactly the
    /// endpoints recorded.
    func testExcludedResultsPointAtTheHandWrittenTypes() throws {
        let manifest = try manifest()
        for excluded in manifest.excludedSchemas {
            XCTAssertEqual(
                excluded.swiftType,
                Self.excludedResultSchemas[excluded.schema],
                "\(excluded.schema) was excluded from a hand-written type this test does not know"
            )
            let users = manifest.endpoints.filter { $0.resultSchema == excluded.schema }
            XCTAssertFalse(users.isEmpty, "\(excluded.schema) is excluded but unused")
            for endpoint in users {
                XCTAssertEqual(
                    endpoint.responseTarget,
                    excluded.swiftType,
                    "\(endpoint.method) does not point at \(excluded.swiftType)"
                )
            }
        }
        // And the reverse: nothing the test knows about went missing.
        for schema in Self.excludedResultSchemas.keys {
            XCTAssertTrue(
                manifest.excludedSchemas.contains { $0.schema == schema },
                "\(schema) is no longer excluded"
            )
        }
    }

    /// The generator has an explicit rule for the two descriptor translation
    /// caveats that reach this surface. `x-dsh-mayBeAbsent` must make the
    /// response alias optional; a result schema that admits `null` must too.
    func testAbsentAndNullableResultsKeepTheOptionalAlias() throws {
        let manifest = try manifest()
        for endpoint in manifest.endpoints {
            let expected = endpoint.responseMayBeAbsent || endpoint.responseNullable
            XCTAssertEqual(
                endpoint.responseAlias.hasSuffix("?"),
                expected,
                "\(endpoint.method): responseAlias `\(endpoint.responseAlias)` does not match "
                    + "mayBeAbsent=\(endpoint.responseMayBeAbsent) nullable=\(endpoint.responseNullable)"
            )
            XCTAssertTrue(
                endpoint.responseAlias.hasPrefix(endpoint.responseTarget),
                "\(endpoint.method): responseAlias \(endpoint.responseAlias) does not extend "
                    + "responseTarget \(endpoint.responseTarget)"
            )
        }
        let absent = Set(
            manifest.endpoints.filter(\.responseMayBeAbsent).map(\.method)
        )
        XCTAssertEqual(
            absent,
            ["commands/execute", "goals/get"],
            "the set of `_undefined()`-optional results changed"
        )
    }

    // MARK: - The captures

    /// The recorded `session/list` request. It is the only capture that pins the
    /// argument wrapping for a V1 endpoint, so it is the only outside evidence
    /// that the generated `Arguments` types have the wire shape SPEC §6.2
    /// describes: `payload.args` holds the named parameter, here `_request`.
    func testCapturedSessionListRequestDecodesIntoTheGeneratedArguments() throws {
        let bytes = try data(at: "Fixtures/rpc-request.json")
        let request = try JSONDecoder().decode(
            RPCRequest<SessionListArguments>.self,
            from: bytes
        )
        XCTAssertEqual(request.method, "session/list")
        XCTAssertEqual(request.path, "/api/session/list")
        XCTAssertNil(request.payload.args.request.cursor)

        // `_request` is the key the gateway accepts, so a re-encode must produce
        // it rather than the Swift property name.
        let reencoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(request)
        )
        let payload = try XCTUnwrap(
            (reencoded as? [String: Any])?["payload"] as? [String: Any]
        )
        let args = try XCTUnwrap(payload["args"] as? [String: Any])
        XCTAssertEqual(Array(args.keys), ["_request"])
    }

    /// The recorded `session/list` response. This is the only captured V1
    /// result, so it is the only place the generated types are checked against
    /// bytes the host actually sent rather than against the schema those types
    /// were derived from.
    func testCapturedSessionListResponseDecodesIntoTheGeneratedResult() throws {
        let bytes = try data(at: "Fixtures/rpc-response-session-list.json")
        let response = try JSONDecoder().decode(
            RPCResponse<SessionListValue>.self,
            from: bytes
        )
        let value = try XCTUnwrap(response.result.value)
        XCTAssertFalse(value.items.isEmpty)
        let row = try XCTUnwrap(value.items.first)
        XCTAssertEqual(row.sessionId, "session-0001")
        XCTAssertEqual(row.updatedAt, 1_791_412_735_279)
        XCTAssertEqual(row.agentAvailable, true)
        XCTAssertEqual(row.running, true)
        XCTAssertEqual(row.blank, false)
        XCTAssertEqual(row.projections?.kind, "sequenced")
        XCTAssertEqual(row.projections?.asOfSeq, 995)

        // The same bytes through the hand-written row, so the generated wrapper
        // and `SessionSummary` agree on every capture row rather than only on
        // paper.
        let handWritten = try JSONDecoder().decode(
            RPCResponse<SessionListResult>.self,
            from: bytes
        )
        let handWrittenRows = try XCTUnwrap(handWritten.result.value?.items)
        XCTAssertEqual(handWrittenRows.map(\.sessionId), value.items.map(\.sessionId))
        XCTAssertEqual(handWrittenRows.map(\.updatedAt), value.items.map(\.updatedAt))
        XCTAssertEqual(handWrittenRows.map(\.running), value.items.map(\.running))
    }

    // MARK: - 2. Bytes

    func testEveryGeneratedFileMatchesItsRecordedHash() throws {
        let manifest = try manifest()
        XCTAssertFalse(manifest.fileHashes.isEmpty, "the manifest records no hashes")
        for (path, expected) in manifest.fileHashes.sorted(by: { $0.key < $1.key }) {
            let bytes = try data(at: path)
            let actual = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(
                actual,
                expected,
                "\(path) does not match the manifest: run Tools/generate-models.py"
            )
        }
    }

    func testExampleDirectoryHoldsExactlyTheGeneratedExamples() throws {
        let manifest = try manifest()
        let expected = Set(
            manifest.fileHashes.keys.filter { $0.hasPrefix("Protocol/examples/") }
        )
        var found: Set<String> = []
        let enumerator = FileManager.default.enumerator(
            at: Self.examplesDirectory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        while let url = enumerator?.nextObject() as? URL {
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isFile else { continue }
            let relative = "Protocol/examples/"
                + url.pathComponents.dropFirst(Self.examplesDirectory.pathComponents.count)
                    .joined(separator: "/")
            if relative == "Protocol/examples/manifest.json" { continue }
            found.insert(relative)
        }
        XCTAssertEqual(
            found,
            expected,
            "Protocol/examples has stale or missing files: run Tools/generate-models.py"
        )
    }

    // MARK: - 3. Decodes

    /// Every example on disk in `Protocol/examples` decodes into the root type
    /// of the schema it was generated for.
    func testEveryExampleFileDecodesIntoItsRootType() throws {
        let manifest = try manifest()
        let cases = Dictionary(
            uniqueKeysWithValues: generatedModelCases().map { ($0.swiftType, $0) }
        )
        XCTAssertFalse(manifest.schemas.isEmpty)
        for schema in manifest.schemas {
            guard let modelCase = cases[schema.rootType] else {
                XCTFail("no generated case for \(schema.rootType) (\(schema.schema))")
                continue
            }
            let bytes = try data(at: "Protocol/" + schema.example)
            XCTAssertNoThrow(
                try modelCase.decode(bytes),
                "\(schema.example) does not decode into \(schema.rootType)"
            )
            // The file is the root declaration's own example, so the bytes the
            // registry carries and the bytes on disk must be the same document.
            let onDisk = try JSONDecoder().decode(JSONValue.self, from: bytes)
            let recorded = try JSONDecoder().decode(
                JSONValue.self,
                from: Data(modelCase.exampleJSON.utf8)
            )
            XCTAssertEqual(
                onDisk,
                recorded,
                "\(schema.example) is not the example the registry carries"
            )
        }
    }

    /// The registry is generated, so it can only drift against the manifest if
    /// the generator emits them from different data. Check they agree.
    func testGeneratedRegistryMatchesTheManifest() throws {
        let manifest = try manifest()
        let cases = generatedModelCases()
        XCTAssertEqual(
            cases.count,
            manifest.models.count,
            "the registry and the manifest disagree on how many declarations exist"
        )
        for (modelCase, model) in zip(cases, manifest.models) {
            XCTAssertEqual(modelCase.swiftType, model.swiftType)
            XCTAssertEqual(modelCase.kind, model.kind)
            XCTAssertEqual(modelCase.typeSymbol, model.typeSymbol)
            XCTAssertEqual(modelCase.schema, model.schema)
            XCTAssertEqual(modelCase.exampleFile, model.exampleFile)
            XCTAssertEqual(modelCase.examplePointer, model.examplePointer)
            XCTAssertEqual(modelCase.requiredPointers, model.requiredPointers)
            switch (modelCase.mutation, model.mutation.op) {
            case (.none, "none"), (.delete, "delete"), (.replace, "replace"):
                XCTAssertEqual(
                    pointer(of: modelCase.mutation),
                    model.mutation.pointer,
                    "\(model.swiftType): registry mutation pointer differs from the manifest"
                )
            default:
                XCTFail(
                    "\(model.swiftType): registry mutation \(modelCase.mutation) does not "
                        + "match manifest op \(model.mutation.op)"
                )
            }
        }
    }

    /// The registry must name every generated declaration — and no type twice.
    func testRegistryNamesEveryGeneratedDeclarationOnce() throws {
        let cases = generatedModelCases()
        XCTAssertFalse(cases.isEmpty)
        let names = cases.map(\.swiftType)
        XCTAssertEqual(
            names.count,
            Set(names).count,
            "two generated declarations share a Swift name"
        )
    }

    /// Decode every declaration from its example, then check the example really
    /// carries the schema-required keys, then break it and require the failure.
    func testEveryGeneratedDeclarationDecodesItsExampleAndRejectsItsMutation() throws {
        var deletions = 0
        var replacements = 0
        for modelCase in generatedModelCases() {
            let context = "\(modelCase.swiftType) (\(modelCase.schema)\(modelCase.examplePointer ?? ""))"
            let bytes = Data(modelCase.exampleJSON.utf8)
            let base: JSONValue
            do {
                base = try JSONDecoder().decode(JSONValue.self, from: bytes)
            } catch {
                XCTFail("\(context): the registry's example is not JSON: \(error)")
                continue
            }

            // 1. The example decodes. This is the decode the generation must support.
            XCTAssertNoThrow(
                try modelCase.decode(bytes),
                "\(context): the example does not decode"
            )

            // 2. The example carries every key the schema marks required.
            for pointer in modelCase.requiredPointers {
                XCTAssertNoThrow(
                    _ = try Self.value(at: pointer, in: base),
                    "\(context): the example is missing required key \(pointer)"
                )
            }

            // 3. Break it. The decode must now fail, or the type enforces nothing.
            let mutated: JSONValue
            switch modelCase.mutation {
            case .none(let reason):
                XCTFail("\(context): no decode-proving mutation could be derived — \(reason)")
                continue
            case .delete(let pointer):
                deletions += 1
                do {
                    mutated = try Self.deleting(at: pointer, in: base)
                } catch {
                    XCTFail("\(context): cannot delete \(pointer): \(error)")
                    continue
                }
            case .replace(let pointer, let json):
                replacements += 1
                let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
                do {
                    mutated = try Self.replacing(at: pointer, with: value, in: base)
                } catch {
                    XCTFail("\(context): cannot replace \(pointer): \(error)")
                    continue
                }
            }
            let mutatedBytes = try JSONEncoder().encode(mutated)
            XCTAssertThrowsError(
                try modelCase.decode(mutatedBytes),
                "\(context): the mutation \(modelCase.mutation) still decoded"
            )
        }
        XCTAssertGreaterThan(deletions, 0, "no declaration proved a required key")
        XCTAssertGreaterThan(replacements, 0, "no declaration proved a typed leaf")
    }

    // MARK: - Manifest shape

    private func pointer(of mutation: GeneratedMutation) -> String? {
        switch mutation {
        case .none: nil
        case .delete(let pointer): pointer
        case .replace(let pointer, _): pointer
        }
    }

    /// A generator warning means a declaration was emitted without an example to
    /// prove it. That is exactly the hole this test exists to close.
    func testGeneratorRecordedNoWarnings() throws {
        let manifest = try manifest()
        XCTAssertEqual(manifest.warnings, [], "the generator reported warnings")
    }

    // MARK: - JSON Pointer

    private enum PointerError: Error, CustomStringConvertible {
        case missing(pointer: String)
        case notNavigable(pointer: String)

        var description: String {
            switch self {
            case .missing(let pointer): "no value at \(pointer)"
            case .notNavigable(let pointer): "\(pointer) is not inside an object or array"
            }
        }
    }

    private static func tokens(of pointer: String) -> [String] {
        guard pointer.hasPrefix("/") else { return [] }
        return pointer.dropFirst()
            .split(separator: "/", omittingEmptySubsequences: false)
            .map {
                $0.replacingOccurrences(of: "~1", with: "/")
                    .replacingOccurrences(of: "~0", with: "~")
            }
    }

    private static func value(at pointer: String, in root: JSONValue) throws -> JSONValue {
        var node = root
        for token in tokens(of: pointer) {
            switch node {
            case .object(let object):
                guard let next = object[token] else { throw PointerError.missing(pointer: pointer) }
                node = next
            case .array(let array):
                guard let index = Int(token), array.indices.contains(index) else {
                    throw PointerError.missing(pointer: pointer)
                }
                node = array[index]
            default:
                throw PointerError.notNavigable(pointer: pointer)
            }
        }
        return node
    }

    private static func replacing(
        at pointer: String,
        with newValue: JSONValue,
        in root: JSONValue
    ) throws -> JSONValue {
        try replacing(tokens: tokens(of: pointer), with: newValue, in: root, pointer: pointer)
    }

    private static func replacing(
        tokens: [String],
        with newValue: JSONValue,
        in node: JSONValue,
        pointer: String
    ) throws -> JSONValue {
        guard let head = tokens.first else { return newValue }
        let rest = Array(tokens.dropFirst())
        switch node {
        case .object(var object):
            guard let child = object[head] else { throw PointerError.missing(pointer: pointer) }
            object[head] = try replacing(tokens: rest, with: newValue, in: child, pointer: pointer)
            return .object(object)
        case .array(var array):
            guard let index = Int(head), array.indices.contains(index) else {
                throw PointerError.missing(pointer: pointer)
            }
            array[index] = try replacing(
                tokens: rest,
                with: newValue,
                in: array[index],
                pointer: pointer
            )
            return .array(array)
        default:
            throw PointerError.notNavigable(pointer: pointer)
        }
    }

    private static func deleting(at pointer: String, in root: JSONValue) throws -> JSONValue {
        let parts = tokens(of: pointer)
        guard !parts.isEmpty else { throw PointerError.notNavigable(pointer: pointer) }
        return try deleting(tokens: parts, in: root, pointer: pointer)
    }

    private static func deleting(
        tokens: [String],
        in node: JSONValue,
        pointer: String
    ) throws -> JSONValue {
        guard let head = tokens.first else { throw PointerError.notNavigable(pointer: pointer) }
        let rest = Array(tokens.dropFirst())
        switch node {
        case .object(var object):
            if rest.isEmpty {
                guard object.removeValue(forKey: head) != nil else {
                    throw PointerError.missing(pointer: pointer)
                }
                return .object(object)
            }
            guard let child = object[head] else { throw PointerError.missing(pointer: pointer) }
            object[head] = try deleting(tokens: rest, in: child, pointer: pointer)
            return .object(object)
        case .array(var array):
            guard let index = Int(head), array.indices.contains(index) else {
                throw PointerError.missing(pointer: pointer)
            }
            if rest.isEmpty {
                array.remove(at: index)
                return .array(array)
            }
            array[index] = try deleting(tokens: rest, in: array[index], pointer: pointer)
            return .array(array)
        default:
            throw PointerError.notNavigable(pointer: pointer)
        }
    }
}

// MARK: - Manifest

struct Manifest: Decodable {
    let note: String
    let generatedBy: String
    let harnessVersion: String
    let hostProtocolVersion: Int
    let endpoints: [ManifestEndpoint]
    let schemas: [ManifestSchema]
    let models: [ManifestModel]
    let excludedSchemas: [ManifestExcluded]
    let generatedSchemas: [String]
    let warnings: [String]
    let fileHashes: [String: String]
}

struct ManifestEndpoint: Decodable {
    let method: String
    let namespace: String
    let name: String
    let mode: String
    let httpPath: String?
    let group: String
    let argumentsType: String
    let responseType: String
    let responseTarget: String
    let responseAlias: String
    let responseNullable: Bool
    let responseMayBeAbsent: Bool
    let parameters: [ManifestParameter]
    let resultSchema: String
    let resultTypeSymbol: String
}

struct ManifestParameter: Decodable {
    let wire: String
    let swiftName: String
    let typeSymbol: String
    let swiftType: String
    let schema: String
    let acceptsUndefined: Bool
    let source: String?
}

struct ManifestSchema: Decodable {
    let schema: String
    let example: String
    let rootType: String
    let nullable: Bool
    let typeSymbol: String
}

struct ManifestModel: Decodable {
    let swiftType: String
    let kind: String
    let typeSymbol: String
    let schema: String
    let exampleFile: String
    let examplePointer: String?
    let sourceFile: String
    let nullable: Bool
    let mayBeAbsent: Bool
    let requiredPointers: [String]
    let mutation: ManifestMutation
}

struct ManifestMutation: Decodable {
    let op: String
    let pointer: String?
    let value: JSONValue?
}

struct ManifestExcluded: Decodable {
    let schema: String
    let swiftType: String
    let reason: String
}
