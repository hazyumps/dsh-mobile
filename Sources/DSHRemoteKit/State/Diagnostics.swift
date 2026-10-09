import Foundation

/// What a screen knows about one resource it is showing.
///
/// SPEC §3 requires this to be tracked **separately from the transport**: "A ready
/// socket is not proof that the workspace list, transcript, or pending controls are
/// current." The connection can be perfectly healthy while a session list failed, and
/// the two facts must not be collapsed into one status — a failure to load one
/// resource must not relabel a working host as unavailable.
///
/// The five cases are the spec's own list. ``empty`` and ``current`` are deliberately
/// distinct: an empty successful workspace and a workspace that has not loaded yet are
/// different screens, and so is a failed load.
public enum ResourceState: Sendable, Hashable {
    /// Loaded, and the host reported nothing.
    case empty
    /// A load is in flight and there is nothing to show yet.
    case loading
    /// Loaded, and this is what the host currently says.
    case current
    /// Showing what was loaded before, while a refresh is in flight or after one failed.
    case stale(reason: String?)
    /// The load failed. `reason` is for the user; it never reaches diagnostics.
    case failed(reason: String)

    /// The case name only, for a diagnostic line.
    ///
    /// A `reason` is user-facing text that can embed a host path or a message quoting
    /// session content, so it is never the thing recorded. This is the narrow door
    /// between "what the screen says" and "what is safe to keep".
    public var diagnosticName: String {
        switch self {
        case .empty: "empty"
        case .loading: "loading"
        case .current: "current"
        case .stale: "stale"
        case .failed: "failed"
        }
    }

    /// Whether the resource has data worth showing while something else happens.
    public var hasData: Bool {
        switch self {
        case .empty, .loading, .failed: false
        case .current, .stale: true
        }
    }

    // MARK: - Transitions
    //
    // The five states are only worth having if a store moves between them correctly, and
    // the rule that matters is one SPEC §3 and §4 both state: **a failed or in-flight
    // refresh must not throw away what is already on screen.** Writing that as three
    // transitions rather than as a `switch` at each call site is what stops the next store
    // from collapsing "failed with data" into "failed".

    /// The state a completed load leaves.
    ///
    /// - Parameter itemCount: how many items the host returned. Zero is a *successful*
    ///   empty result, which SPEC §4 keeps distinct from a load that has not happened.
    public static func afterSuccess(itemCount: Int) -> ResourceState {
        itemCount == 0 ? .empty : .current
    }

    /// The state a failed load leaves, keeping whatever was already showing.
    ///
    /// With data on screen the failure is a staleness mark, not a blank screen: the cached
    /// list stays and only its freshness changes. Without data there is nothing to keep, so
    /// it is a real failure.
    public func afterFailure(reason: String) -> ResourceState {
        hasData ? .stale(reason: reason) : .failed(reason: reason)
    }

    /// The state at the start of a refresh, keeping whatever was already showing.
    ///
    /// A refresh with data behind it is `stale` with no reason yet — nothing has gone
    /// wrong, the data is simply not the newest. Without data it is a first load.
    public var whileLoading: ResourceState {
        hasData ? .stale(reason: nil) : .loading
    }
}

/// One diagnosable event, built so that it cannot carry content.
///
/// SPEC §11 lists what diagnostics may record — a correlation UUID, endpoint or stream
/// kind, connection generation, resource state, status or error code, and durations —
/// and what they must exclude: authorization headers, pairing payloads and codes, raw
/// prompts, answers, uploads, signed URLs, and full private paths.
///
/// The exclusion is **structural rather than filtered**. There is no free-text field on
/// this type at all, so the only way to leak a prompt into a diagnostic is to add a
/// field that holds one, which is a visible change to this file rather than a missed
/// branch in a sanitiser. That is a deliberate trade: it makes a diagnostic line less
/// expressive than a log line, and the spec's list of exclusions is exactly why.
///
/// The one stringly field is ``errorCode``, because host error codes are not a closed
/// set. It is validated on the way in — see ``init(correlation:subject:generation:resource:state:status:errorCode:durationMilliseconds:)``.
public struct DiagnosticRecord: Sendable, Hashable, Codable {
    /// What the record is about. A name, never a URL: SPEC §11 excludes signed URLs, and
    /// a URL can carry a token in its query.
    public enum Subject: Sendable, Hashable, Codable {
        case endpoint(String)
        case stream(String)

        public var name: String {
            switch self {
            case .endpoint(let name), .stream(let name): name
            }
        }

        public var kind: String {
            switch self {
            case .endpoint: "endpoint"
            case .stream: "stream"
            }
        }
    }

    public var correlation: UUID
    public var subject: Subject
    /// Which connection generation produced this, so a stale-socket problem is visible.
    public var generation: UInt64?
    /// The resource name, e.g. `session/list` or `workspace/follow`.
    public var resource: String?
    /// The resource's state, as a case name.
    public var resourceState: String?
    public var status: Int?
    /// A validated host error code, or a placeholder when the host sent something that
    /// is not shaped like one.
    public var errorCode: String?
    public var durationMilliseconds: Int?
    public var recordedAt: Date

    /// Placeholder for an error code that is not shaped like a code.
    ///
    /// A host is free to put a path or a quoted message in `error.code`; the harness's
    /// own persistence failure quotes a storage path in its message. Rather than trust
    /// the field, anything that does not look like a namespaced code becomes this, so the
    /// export stays useful ("there was an error here") without carrying whatever was in
    /// it.
    public static let unshapedErrorCode = "<unshaped>"

    /// Characters a code *segment* is made of — `gateway/method-unavailable`,
    /// `session/upload-too-large`, `ASK_TIMED_OUT`.
    private static let codeSegmentAllowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."
    )

    /// The most segments a namespaced code has in this build, so a path cannot qualify by
    /// being long and slashy.
    private static let codeMaximumSegments = 3

    public init(
        correlation: UUID,
        subject: Subject,
        generation: UInt64? = nil,
        resource: String? = nil,
        state: ResourceState? = nil,
        status: Int? = nil,
        errorCode: String? = nil,
        durationMilliseconds: Int? = nil,
        recordedAt: Date = Date()
    ) {
        self.correlation = correlation
        self.subject = subject
        self.generation = generation
        self.resource = resource
        self.resourceState = state?.diagnosticName
        self.status = status
        self.errorCode = Self.shape(errorCode)
        self.durationMilliseconds = durationMilliseconds
        self.recordedAt = recordedAt
    }

    /// Keeps a code that is shaped like one and refuses anything else.
    ///
    /// Shape, not just alphabet. The first version of this checked only which characters
    /// were allowed, and `/Users/patrick/repo/homelab` sailed through: a slash is legal in
    /// `gateway/method-unavailable`, so a path and a namespaced code share an alphabet and
    /// only their *structure* separates them.
    ///
    /// So a code is one to three non-empty segments of letters, digits, `-`, `_` and `.`,
    /// separated by single slashes. A leading slash makes an empty first segment and is
    /// refused; four or more segments is a path; a space or a colon is prose or a URL.
    /// Length is bounded for the same reason the field is checked at all — an unbounded
    /// field is where a message ends up.
    static func shape(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        guard code.count <= 80 else { return unshapedErrorCode }

        let segments = code.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...codeMaximumSegments).contains(segments.count) else { return unshapedErrorCode }
        for segment in segments {
            guard !segment.isEmpty, segment.count <= 40 else { return unshapedErrorCode }
            guard segment.unicodeScalars.allSatisfy(codeSegmentAllowed.contains) else {
                return unshapedErrorCode
            }
        }
        return code
    }

    /// One line, for an export a person will read.
    public var line: String {
        var parts = ["\(subject.kind)=\(subject.name)"]
        if let generation { parts.append("gen=\(generation)") }
        if let resource { parts.append("resource=\(resource)") }
        if let resourceState { parts.append("state=\(resourceState)") }
        if let status { parts.append("status=\(status)") }
        if let errorCode { parts.append("error=\(errorCode)") }
        if let durationMilliseconds { parts.append("\(durationMilliseconds)ms") }
        return "\(correlation.uuidString) " + parts.joined(separator: " ")
    }
}

/// A bounded, in-memory set of diagnostic records with a previewable export.
///
/// SPEC §11: "Make diagnostic export explicit and previewable." Explicit is why nothing
/// here writes to disk or to the system log on its own — the records exist only in
/// memory until a caller asks for the text, which is the text it shows.
///
/// Bounded because a diagnostic log that grows without limit is its own outage, and the
/// ring keeps the most recent records, which are the ones a user is reporting.
public struct DiagnosticLog: Sendable {
    public let capacity: Int
    private var records: [DiagnosticRecord] = []

    public init(capacity: Int = 200) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { records.count }
    public var isEmpty: Bool { records.isEmpty }

    public mutating func record(_ record: DiagnosticRecord) {
        records.append(record)
        if records.count > capacity {
            records.removeFirst(records.count - capacity)
        }
    }

    public mutating func record(
        correlation: UUID,
        subject: DiagnosticRecord.Subject,
        generation: UInt64? = nil,
        resource: String? = nil,
        state: ResourceState? = nil,
        status: Int? = nil,
        errorCode: String? = nil,
        durationMilliseconds: Int? = nil,
        recordedAt: Date = Date()
    ) {
        record(DiagnosticRecord(
            correlation: correlation,
            subject: subject,
            generation: generation,
            resource: resource,
            state: state,
            status: status,
            errorCode: errorCode,
            durationMilliseconds: durationMilliseconds,
            recordedAt: recordedAt
        ))
    }

    public mutating func removeAll() {
        records.removeAll()
    }

    /// The text a user would see and could send. Newest last, so it reads as a timeline.
    public func export() -> String {
        records.map(\.line).joined(separator: "\n")
    }
}
