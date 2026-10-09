import Testing
import Foundation

import DSHRemoteKit

/// Loads the captured bytes in the repository's `Fixtures/` directory.
///
/// Paths resolve from `#filePath`, so this works under `swift test` from any working
/// directory and needs no resource bundle.
enum Fixtures {
    /// One captured file. Raw values are the file names in `Fixtures/`.
    enum File: String, CaseIterable {
        case pairingPayload = "pairing-payload.json"
        case pairingClaimResponse = "pairing-claim-response.json"
        case rpcRequest = "rpc-request.json"
        case rpcSessionList = "rpc-response-session-list.json"
        case rpcTypedError = "rpc-response-typed-error.json"
        case forbiddenUnpaired = "forbidden-unpaired.json"
        case muxStreamFrames = "mux-stream-frames.json"
        case relaySPKIPin = "relay-spki-pin.json"
    }

    static let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests/DSHRemoteKitTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // package root
        .appendingPathComponent("Fixtures", isDirectory: true)

    static func data(_ file: File) throws -> Data {
        let url = directory.appendingPathComponent(file.rawValue)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw FixtureError.missingFile(url.path)
        }
        return data
    }

    static func decode<T: Decodable>(_ type: T.Type, _ file: File) throws -> T {
        try JSONDecoder().decode(type, from: data(file))
    }

    /// The captured object, as loose key/value pairs, for tests that assert on the raw
    /// wire keys rather than on the Swift model.
    static func object(_ file: File) throws -> [String: JSONValue] {
        guard let object = try JSONDecoder().decode(JSONValue.self, from: data(file)).objectValue else {
            throw FixtureError.notAnObject(file.rawValue)
        }
        return object
    }

    /// The captured bytes with top-level keys replaced and/or removed, used to prove
    /// that an unrecognised key or value decodes instead of failing (SPEC §5).
    ///
    /// `setting` writes values verbatim, so ``JSONValue/null`` stays a JSON null; use
    /// `removing` to drop a key entirely.
    static func mutatedObject(
        _ file: File,
        setting: [String: JSONValue] = [:],
        removing: [String] = []
    ) throws -> [String: JSONValue] {
        var object = try object(file)
        for key in removing { object[key] = nil }
        for (key, value) in setting { object[key] = value }
        return object
    }

    static func mutatedData(
        _ file: File,
        setting: [String: JSONValue] = [:],
        removing: [String] = []
    ) throws -> Data {
        try encode(object: mutatedObject(file, setting: setting, removing: removing))
    }

    static func decode<T: Decodable>(
        _ type: T.Type,
        mutatedFrom file: File,
        setting: [String: JSONValue] = [:],
        removing: [String] = []
    ) throws -> T {
        try JSONDecoder().decode(
            type,
            from: mutatedData(file, setting: setting, removing: removing)
        )
    }

    static func encode(object: [String: JSONValue]) throws -> Data {
        try JSONEncoder().encode(JSONValue.object(object))
    }

    enum FixtureError: Error, CustomStringConvertible {
        case missingFile(String)
        case notAnObject(String)

        var description: String {
            switch self {
            case .missingFile(let path): "fixture not found at \(path)"
            case .notAnObject(let name): "fixture \(name) is not a JSON object"
            }
        }
    }
}

/// The follow id is per subscription; fixture ids must match the actual open.
func followStreamID(on socket: StubRelaySocket) async throws -> String {
    for text in await socket.sentTexts.reversed() {
        let frame = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        if frame["endpoint"]?.stringValue == "session/follow" {
            return try #require(frame["streamId"]?.stringValue)
        }
    }
    throw FixtureError.noFollowStream
}

private enum FixtureError: Error { case noFollowStream }
