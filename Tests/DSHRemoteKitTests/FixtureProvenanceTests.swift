import Foundation
import Testing

@testable import DSHRemoteKit

// SPEC §12 requires every fixture to state whether it is captured or synthetic, to carry
// the host version it came from, and to omit tokens and private content. Until now that
// was convention: three fixtures document their own origin (`mux-stream-frames.json` in a
// `note`, `relay-spki-pin.json` in a `source`), the rest say nothing, and nothing stopped
// the next capture from landing with a live device token in it.
//
// The declarations below are deliberately a separate list from `Fixtures.File` rather than
// a property on it. `Fixtures.File` describes the fixture set as the tests use it; this
// describes where each file came from. A new file therefore has to be declared in two
// places, and the completeness test below fails until the second one is filled in — which
// is the point, because the honest answer is not always "captured".

/// Where one fixture came from.
enum FixtureOrigin: Sendable {
    /// Recorded from a running host or relay. Requires naming the version, because a
    /// capture is only evidence for the build it came from (SPEC §1's evidence levels).
    case captured(host: String, proto: Int, basis: String)
    /// Built by hand to a shape established some other way — a specification sentence, a
    /// descriptor entry, or installed source. The `basis` is what makes it evidence
    /// rather than a guess, and it is required for the same reason.
    case synthetic(basis: String)

    var isCaptured: Bool {
        if case .captured = self { return true }
        return false
    }
}

enum FixtureProvenance {
    /// The version the captured fixtures were recorded from.
    ///
    /// Recorded once here rather than repeated per fixture so that a host upgrade is a
    /// single edit, and so the tests can assert every capture agrees on it.
    static let capturedHost = "0.2.0-rc.2"
    static let capturedProtocol = 4

    static let origins: [Fixtures.File: FixtureOrigin] = [
        // Protocol/README.md, "Against live captures": these two were recorded from the
        // running relay.
        .rpcSessionList: .captured(
            host: capturedHost,
            proto: capturedProtocol,
            basis: "Protocol/README.md: recorded from the running relay"
        ),
        .muxStreamFrames: .captured(
            host: capturedHost,
            proto: capturedProtocol,
            basis: "Protocol/README.md and the file's own note: 12 session/follow frames"
        ),
        .relaySPKIPin: .captured(
            host: capturedHost,
            proto: capturedProtocol,
            basis: "the file's own source field: relay-cert.pem, captured 2026-10-07"
        ),
        .rpcScheduledTasksList: .captured(
            host: capturedHost,
            proto: capturedProtocol,
            basis: "the file's own note: POST /api/scheduledTasks/list against the live relay, 2026-10-12, task text and ids redacted"
        ),
        .rpcSubagentRoster: .captured(
            host: capturedHost,
            proto: capturedProtocol,
            basis: "the file's own source: POST /api/session/projections and /api/session/list against the relay on 127.0.0.1:3443, 2026-10-15, ids, labels and titles redacted"
        ),

        // The rest are hand-built. The doc comments in `Sources/` say each is "proven by"
        // its fixture, which is the opposite direction: the fixture is how the test knows
        // the shape, not evidence that a host ever emitted it. Their contents agree —
        // RFC 5737 addresses, a canary fingerprint, a REDACted token.
        .pairingPayload: .synthetic(basis: "SPEC §6.3 pairing payload shape"),
        .pairingClaimResponse: .synthetic(basis: "SPEC §6.3 claim response shape"),
        .rpcRequest: .synthetic(basis: "SPEC §6.2 envelope shape"),
        .rpcTypedError: .synthetic(basis: "SPEC §6.9 typed error shape"),
        .forbiddenUnpaired: .synthetic(basis: "the relay's own 403 body, per SPEC §6.3"),
        // Issued over the captured key in relay-spki-pin.json by a throwaway issuer whose
        // key was deleted; the file's own `source` lists the openssl commands (#68).
        .relayTrustCertificates: .synthetic(
            basis: "certificates issued over the captured relay key; SPEC §6.3"
        ),
    ]
}

@Suite("Fixture provenance")
struct FixtureProvenanceTests {
    @Test("every fixture declares where it came from, and no declaration is orphaned")
    func declarationsAreComplete() {
        let declared = Set(FixtureProvenance.origins.keys)
        let present = Set(Fixtures.File.allCases)

        let undeclared = present.subtracting(declared)
        #expect(
            undeclared.isEmpty,
            "a fixture was added without stating its origin: \(undeclared.map(\.rawValue).sorted())"
        )
        #expect(
            declared.subtracting(present).isEmpty,
            "a declaration names a fixture that is not in Fixtures.File"
        )
    }

    @Test("every declaration carries the basis for believing it")
    func everyOriginStatesItsBasis() {
        for (file, origin) in FixtureProvenance.origins {
            let basis: String
            switch origin {
            case .captured(let host, let proto, let why):
                // A capture is only evidence for the build that produced it.
                #expect(!host.isEmpty, "\(file.rawValue) claims a capture without a host version")
                #expect(proto > 0, "\(file.rawValue) claims a capture without a protocol version")
                basis = why
            case .synthetic(let why):
                basis = why
            }
            #expect(!basis.isEmpty, "\(file.rawValue) declares an origin without saying why")
        }
    }

    @Test("every captured fixture agrees on the host and protocol it came from")
    func capturesAgreeOnVersion() {
        for (file, origin) in FixtureProvenance.origins {
            guard case .captured(let host, let proto, _) = origin else { continue }
            #expect(host == FixtureProvenance.capturedHost, "\(file.rawValue) disagrees on host version")
            #expect(proto == FixtureProvenance.capturedProtocol, "\(file.rawValue) disagrees on protocol")
        }
    }

    // MARK: - Redaction

    /// Keys whose value is a credential by definition, so its value must be a placeholder.
    ///
    /// Deliberately narrow. A one-time pairing code is also sensitive, but the existing
    /// fixture's is an all-digit value with a 2025 expiry beside an RFC 5737 address, and a
    /// rule loose enough to accept that would not catch much. Long-lived credentials are
    /// the ones worth failing a build over.
    private static let credentialKeys: Set<String> = [
        "token", "secret", "password", "authorization", "credential", "apikey", "privatekey",
    ]

    /// Prefixes of real credentials that must never appear.
    private static let credentialPrefixes = [
        "sk-", "ghp_", "gho_", "xoxb-", "xoxp-", "AKIA", "-----BEGIN",
    ]

    /// Which credential prefixes appear in `text`, as the start of a token.
    ///
    /// A bare `contains` is not enough, and the harness proved it: scheduled-task ids are
    /// `task-<uuid>`, so a faithful capture of one contains `sk-` inside `task-`, and a
    /// substring test condemns the id as an OpenAI key. Requiring the prefix to begin a token
    /// keeps the case the rule exists for — a leaked key is preceded by a quote, a space, an
    /// `=`, or nothing at all — while an identifier that merely ends in those letters is not
    /// evidence of anything. `credentialPrefixesAreCaughtAtTokenBoundaries` pins both halves.
    static func credentialPrefixes(in text: String) -> [String] {
        credentialPrefixes.filter { prefix in
            var search = text.startIndex
            while let range = text.range(of: prefix, range: search..<text.endIndex) {
                if range.lowerBound == text.startIndex { return true }
                let before = text[text.index(before: range.lowerBound)]
                // `-` and `_` count as inside a token as well: they are what an identifier is
                // made of, and a credential is a whole token of its own.
                if !before.isLetter, !before.isNumber, before != "-", before != "_" { return true }
                search = range.upperBound
            }
            return false
        }
    }

    private static func isPlaceholder(_ value: String) -> Bool {
        if value.isEmpty { return true }
        let upper = value.uppercased()
        return ["REDACTED", "PLACEHOLDER", "DUMMY", "EXAMPLE", "TEST", "NOTAREAL", "FAKE"]
            .contains { upper.contains($0) }
    }

    @Test("no fixture carries a credential in a credential-named key")
    func credentialKeysHoldPlaceholders() throws {
        for file in Fixtures.File.allCases {
            let raw = try Fixtures.data(file)
            var failures: [String] = []
            walk(try JSONDecoder().decode(JSONValue.self, from: raw)) { key, value in
                guard let key, Self.credentialKeys.contains(key.lowercased()) else { return }
                guard let text = value.stringValue else { return }
                if !Self.isPlaceholder(text) {
                    failures.append("\(key) is not a placeholder")
                }
            }
            #expect(failures.isEmpty, "\(file.rawValue): \(failures.joined(separator: ", "))")
        }
    }

    @Test("no fixture contains a credential-shaped string")
    func noCredentialShapedStrings() throws {
        for file in Fixtures.File.allCases {
            let text = String(decoding: try Fixtures.data(file), as: UTF8.self)
            let found = Self.credentialPrefixes(in: text)
            #expect(
                found.isEmpty,
                "\(file.rawValue) contains a credential-shaped string: \(found)"
            )
        }
    }

    /// The refinement above has to catch a leak and has to ignore an identifier, and a rule
    /// that only does the second is worse than no rule at all.
    @Test("the credential-prefix guard catches a real key and ignores an identifier that ends in one")
    func credentialPrefixesAreCaughtAtTokenBoundaries() {
        #expect(Self.credentialPrefixes(in: #"{"apiKey":"sk-live-abc123"}"#) == ["sk-"])
        #expect(Self.credentialPrefixes(in: "token=sk-abc123") == ["sk-"])
        #expect(Self.credentialPrefixes(in: "sk-abc123") == ["sk-"])
        #expect(Self.credentialPrefixes(in: "Authorization: Bearer -----BEGIN") == ["-----BEGIN"])
        #expect(Self.credentialPrefixes(in: "AKIAIOSFODNN7EXAMPLE") == ["AKIA"])

        // The false positive this exists for: `sk-` inside the ids the harness really emits.
        #expect(Self.credentialPrefixes(in: #""task-9da6985a-0cec-49e4-b7d9-b3edf602bbbe""#).isEmpty)
        #expect(Self.credentialPrefixes(in: "task-0001").isEmpty)
        #expect(Self.credentialPrefixes(in: "mask-note").isEmpty)
    }

    @Test("no fixture carries a private host path")
    func noPrivatePaths() throws {
        // SPEC §11 excludes full private paths from diagnostics, and a fixture is more
        // durable than a log line: it is committed. The captured fixtures redact IDs for
        // the same reason.
        for file in Fixtures.File.allCases {
            let text = String(decoding: try Fixtures.data(file), as: UTF8.self)
            for root in ["/Users/", "/home/"] {
                #expect(
                    !text.contains(root),
                    "\(file.rawValue) contains a private path under \(root)"
                )
            }
        }
    }

    /// Visits every string in a JSON tree with the key it was found under, where there is one.
    private func walk(_ value: JSONValue, key: String? = nil, visit: (String?, JSONValue) -> Void) {
        visit(key, value)
        switch value {
        case .object(let members):
            for (memberKey, member) in members { walk(member, key: memberKey, visit: visit) }
        case .array(let items):
            for item in items { walk(item, key: nil, visit: visit) }
        case .null, .bool, .string, .int, .double:
            return
        }
    }
}
