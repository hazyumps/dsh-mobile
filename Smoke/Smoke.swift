// dsh-smoke — the live transport smoke test (SPEC §6.3, §6.4, §6.9).
//
// The SwiftUI app and the package tests exercise `ConnectionCoordinator` against
// `StubRelayTransport`; nothing there performs a TLS handshake, so the SPKI pinning
// path in `URLSessionRelayTransport` is never touched. This executable runs the real
// coordinator against a real relay from macOS, where no simulator is needed.
//
// It prints counts and booleans, never credentials or user content: the device token
// never appears in output (and is scrubbed from error text), the server `clientId` is
// reported by length only (SPEC §6.7 keeps it server-side state, not display text),
// and sessions are reported as counts rather than titles.

import Foundation
import DSHRemoteKit

#if canImport(Darwin)
import Darwin
#endif

@main
enum DSHRemoteSmoke {
    static func main() async {
        let code = await run()
        exit(code)
    }

    /// Every step, in order. Any throw leaves a non-zero exit code behind.
    private static func run() async -> Int32 {
        let options: Options
        do {
            options = try Options.parse(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            report(String(describing: error), token: nil)
            report("", token: nil)
            report(Options.usage, token: nil)
            return 2
        }

        report("origin: \(options.origin.absoluteString)", token: options.token)

        // The policy under test: the pin is the whole authority, and the platform chain
        // is explicitly not required — which is the only way a self-signed relay can be
        // reached at all (SPEC §3.2 step 3).
        let pinning = RelayPinningPolicy.pinned(options.pin)
        report(
            "pinning: expectedSPKIPin=set(\(options.pin.count) chars) requiresPlatformTrust=\(pinning.requiresPlatformTrust)",
            token: options.token
        )
        report("credential: bearer token present, \(options.token.count) chars", token: options.token)

        let origin = ConnectionCoordinator.Origin(
            baseURL: options.origin,
            authorization: .bearer(options.token),
            pinning: pinning
        )
        let coordinator = ConnectionCoordinator(origin: origin)

        // 1. connect() — socket establishment, `$events` open, then the ready frame.
        let connection: ConnectionCoordinator.Connection
        do {
            connection = try await coordinator.connect()
        } catch {
            let status = await coordinator.status
            let lastError = await coordinator.lastError
            report("connect: FAILED", token: options.token)
            report("status: \(status.rawValue) (\(status.label))", token: options.token)
            report(
                "error: \(lastError.map { String(describing: $0) } ?? String(describing: error))",
                token: options.token
            )
            _ = await coordinator.shutdown()
            return 1
        }

        let statusAfterConnect = await coordinator.status
        report("connect: OK", token: options.token)
        report(
            "status: \(statusAfterConnect.rawValue) (\(statusAfterConnect.label))",
            token: options.token
        )
        report("generation: \(connection.generation)", token: options.token)
        // Length only: the clientId is the host's address for this client, not something
        // to reproduce in a report.
        report(
            "clientId: \(connection.clientId.isEmpty ? "MISSING" : "present") (length \(connection.clientId.count))",
            token: options.token
        )
        guard statusAfterConnect == .connected, !connection.clientId.isEmpty else {
            report("connect: FAILED — ready frame did not produce a usable connection", token: options.token)
            _ = await coordinator.shutdown()
            return 1
        }

        // 2. sessions() — a unary RPC over the same origin, credential, and pin.
        let sessions: [SessionSummary]
        do {
            sessions = try await coordinator.sessions()
        } catch {
            let lastError = await coordinator.lastError
            report("sessions: FAILED", token: options.token)
            report(
                "error: \(lastError.map { String(describing: $0) } ?? String(describing: error))",
                token: options.token
            )
            _ = await coordinator.shutdown()
            return 1
        }
        let running = sessions.filter { $0.running == true }.count
        report("sessions: \(sessions.count) total, \(running) running", token: options.token)

        // 3. shutdown() — close every stream and the socket, then confirm the state.
        await coordinator.shutdown()
        let statusAfterShutdown = await coordinator.status
        report(
            "shutdown: status=\(statusAfterShutdown.rawValue) (\(statusAfterShutdown.label))",
            token: options.token
        )

        report("SMOKE OK", token: options.token)
        return 0
    }

    // MARK: - Output

    /// Writes one line to stdout, with the device token scrubbed out of anything that
    /// could echo it back (a URL or an error string).
    ///
    /// Through `FileHandle` rather than `print`, so a line reaches the terminal as it
    /// happens. `print` block-buffers when stdout is a pipe, which hides the last step
    /// reached when a run hangs — and a step that hangs past its budget is exactly the
    /// failure this tool exists to catch.
    private static func report(_ line: String, token: String?) {
        FileHandle.standardOutput.write(Data((redact(line, token: token) + "\n").utf8))
    }

    private static func report(error line: String, token: String?) {
        FileHandle.standardError.write(Data((redact(line, token: token) + "\n").utf8))
    }

    private static func redact(_ text: String, token: String?) -> String {
        guard let token, !token.isEmpty, text.contains(token) else { return text }
        return text.replacingOccurrences(of: token, with: "<redacted-device-token>")
    }
}

// MARK: - Arguments

/// `--origin <url>`, `--pin <base64>`, token from the environment (SPEC §6.3).
struct Options {
    var origin: URL
    var pin: String
    var token: String

    static let usage = """
    usage: dsh-smoke --origin <https://host:port> --pin <base64 SPKI SHA-256>
           device token is read from the environment variable DSH_DEVICE_TOKEN

      --origin   relay origin, e.g. https://127.0.0.1:3443 (https only, SPEC §3.2)
      --pin      expected pin: base64 SHA-256 over the DER SubjectPublicKeyInfo
                 (SPEC §6.3), as the relay publishes it and as `relay/pair` returns it
      --help     print this message

    The token is never printed; the clientId is reported by length only and sessions
    as counts, because both can carry the user's content.
    """

    enum ParseError: Error, CustomStringConvertible {
        case missing(String)
        case value(String)
        case notHTTPS(String)

        var description: String {
            switch self {
            case .missing(let name): "\(name) is required"
            case .value(let flag): "--\(flag) needs a value"
            case .notHTTPS(let scheme): "--origin must be https, got \(scheme)"
            }
        }
    }

    static func parse(arguments: [String]) throws -> Options {
        var origin: String?
        var pin: String?

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h":
                print(usage)
                exit(0)
            case "--origin", "--pin":
                let name = String(argument.dropFirst(2))
                guard index + 1 < arguments.count else { throw ParseError.value(name) }
                let value = arguments[index + 1]
                if name == "origin" { origin = value } else { pin = value }
                index += 2
            default:
                throw ParseError.value(argument)
            }
        }

        guard let originValue = origin else { throw ParseError.missing("--origin") }
        guard let pinValue = pin else { throw ParseError.missing("--pin") }
        guard let url = URL(string: originValue) else { throw ParseError.value("origin") }
        // SPEC §3.2: v1 pins the TLS origin; a plain-HTTP `plainUrl` is ignored.
        guard url.scheme?.lowercased() == "https" else {
            throw ParseError.notHTTPS(url.scheme ?? "none")
        }

        let environment = ProcessInfo.processInfo.environment
        guard let token = environment["DSH_DEVICE_TOKEN"], !token.isEmpty else {
            throw ParseError.missing("DSH_DEVICE_TOKEN (environment variable)")
        }

        return Options(origin: url, pin: pinValue, token: token)
    }
}
