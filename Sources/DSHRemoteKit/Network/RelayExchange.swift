import Foundation

/// The shared "send it, classify what came back, retry only what SPEC §6.9 says
/// is retryable" step.
///
/// One implementation behind the RPC client, the binary-upload endpoint, the
/// event result, and the pairing claim, because the SPEC §6.9 table is a property
/// of *talking to the relay* rather than of any one endpoint. What differs per
/// caller is the request body and what a 2xx body means — neither of which is
/// this type's business.
struct RelayExchange: Sendable {
    var transport: any RelayTransport
    var sleeper: any RelaySleeper
    var clock: any EpochClock
    var retryPolicy: RPCFailureRetryPolicy

    init(
        transport: any RelayTransport,
        sleeper: any RelaySleeper = TaskRelaySleeper(),
        clock: any EpochClock = SystemEpochClock(),
        retryPolicy: RPCFailureRetryPolicy = .default
    ) {
        self.transport = transport
        self.sleeper = sleeper
        self.clock = clock
        self.retryPolicy = retryPolicy
    }

    /// Performs the exchange, retrying a 429 or 502 within the policy's budget.
    ///
    /// Returns any 2xx response. Every other status is thrown as a
    /// ``DshRPCError`` — including 200-with-a-business-refusal, which is *not* a
    /// status question and is therefore left to the caller (SPEC §6.2: "An HTTP
    /// 200 does not establish business success").
    ///
    /// - Parameter endpoint: the endpoint as the relay names it (`session/list`),
    ///   used for ``DshRPCError/capabilityUnavailable(endpoint:)`` and messages.
    func perform(_ request: RelayHTTPRequest, endpoint: String) async throws -> RelayHTTPResponse {
        var attempt = 0
        while true {
            attempt += 1
            let response = try await sendOnce(request)

            switch response.status {
            case 200..<300:
                return response

            case 401:
                throw DshRPCError.relayedAuthenticationFailure(
                    relayError: Self.relayError(from: response.body),
                    status: response.status
                )

            case 403:
                throw DshRPCError.credentialRejected(
                    relayError: Self.relayError(from: response.body),
                    status: response.status
                )

            case 404:
                // SPEC §6.9: an optional capability this host does not have. Not
                // retried, and not folded into a generic client error, because
                // SPEC §6.8 keys exactly this status to the upload fallback.
                throw DshRPCError.capabilityUnavailable(endpoint: endpoint)

            case 429:
                let seconds = HTTPRetryAfter.seconds(
                    from: response.header("Retry-After"),
                    now: Date(timeIntervalSince1970: Double(clock.epochMillis()) / 1000)
                ) ?? retryPolicy.defaultRetryAfterSeconds
                guard attempt < retryPolicy.maxAttempts else {
                    throw DshRPCError.rateLimited(retryAfterSeconds: seconds, attempts: attempt)
                }
                try await sleeper.sleep(seconds: seconds)

            case 502:
                // SPEC §6.9: "harness unavailable behind relay; bounded retry".
                guard attempt < retryPolicy.maxAttempts else {
                    throw DshRPCError.harnessUnavailable(attempts: attempt)
                }
                try await sleeper.sleep(seconds: retryPolicy.backoff(attempt: attempt))

            default:
                throw DshRPCError.unexpectedStatus(status: response.status, endpoint: endpoint)
            }
        }
    }

    /// One attempt, with a transport failure classified into the same error type
    /// so callers never see two error domains.
    private func sendOnce(_ request: RelayHTTPRequest) async throws -> RelayHTTPResponse {
        do {
            return try await transport.send(request)
        } catch let error as RelayTransportError {
            switch error {
            case .offline:
                throw DshRPCError.transportInterruption(detail: error.safeDescription)
            case .tlsPinMismatch(let detail):
                throw DshRPCError.certificateChanged(detail: detail)
            case .webSocketRejected(let failure):
                throw failure
            case .cancelled:
                throw DshRPCError.cancelled
            case .other(let detail):
                throw DshRPCError.transportInterruption(detail: detail)
            }
        } catch let error as DshRPCError {
            throw error
        } catch is CancellationError {
            throw DshRPCError.cancelled
        } catch {
            throw DshRPCError.transportInterruption(
                detail: RelayTransportError.classify(error).safeDescription
            )
        }
    }

    /// Decodes the relay's refusal body when the peer sent one. Absent is normal:
    /// the body shape is only proven for the pairing route (SPEC §6.3).
    static func relayError(from body: Data) -> RelayErrorResponse? {
        guard !body.isEmpty else { return nil }
        return try? JSONDecoder().decode(RelayErrorResponse.self, from: body)
    }
}

// MARK: - Shared URL building

enum RelayURL {
    /// Resolves a relay path against the host origin.
    ///
    /// `URL(string:relativeTo:)` rather than `URL.appending(path:)`, because the
    /// latter percent-encodes and `$events/result` must reach the wire as
    /// `/api/$events/result` (SPEC §6.7). `$` is an RFC 3986 sub-delim and legal
    /// in a path; nothing here needs escaping.
    static func resolve(_ path: String, against baseURL: URL) throws -> URL {
        guard let url = URL(string: path, relativeTo: baseURL), url.host != nil else {
            throw DshRPCError.protocolIncompatible(reason: "cannot resolve \(path) against the host origin")
        }
        return url
    }

    /// Builds a URL with query items, letting `URLComponents` do the encoding so a
    /// filename with a space, `&`, or `#` survives (SPEC §6.8: "Encode query values
    /// correctly").
    static func resolve(_ path: String, against baseURL: URL, queryItems: [URLQueryItem]) throws -> URL {
        let resolved = try resolve(path, against: baseURL)
        guard !queryItems.isEmpty else { return resolved }
        guard var components = URLComponents(url: resolved, resolvingAgainstBaseURL: true) else {
            throw DshRPCError.protocolIncompatible(reason: "cannot add query items to \(path)")
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw DshRPCError.protocolIncompatible(reason: "cannot build a URL for \(path)")
        }
        return url
    }
}
