import Foundation

// The read-only surfaces the drawer's secondary panels need — the schedule catalog and
// the host's plugin inventory — reading through two seams this codebase already has:
// ``CapabilityLedger`` (SPEC §10) decides whether an endpoint is worth asking at all, and
// ``ResourceState`` (SPEC §3) records how fresh each section is.
//
// Two wire shapes here have a silent failure mode, and each gets its own decode rather
// than a struct of optional fields:
//
// * `schedule/catalog` returns a **bare array** of a union, and the arms do not share
//   timing parameters (`Protocol/schemas/dsh-schedule.schedule.catalog.result.json`,
//   `x-dsh-rawExpression`). A flat struct with every arm's key optional would read an
//   `at` entry's stray `afterSeconds` as if it meant something, so ``ScheduleEntry``
//   dispatches on `kind` first and reads only that arm's keys.
// * `pluginInventory/list`'s `meta.title` and `meta.description` are each a **union of a
//   string and a `Record<string, string>`**
//   (`Protocol/schemas/dsh-host-plugin-inventory.types.PluginInventorySnapshot.json`).
//   Decoding them as `String` renders nothing for every plugin that ships translations,
//   so ``LocalizedText`` models both forms and prefers `en`.

// MARK: - schedule/catalog

/// How a schedule repeats, the `kind` discriminant of `schedule/catalog`'s union.
///
/// The descriptor's union has six arms. The drawer shows ``after``, ``at`` and ``every``;
/// ``daily``, ``weekly`` and ``cron`` are modelled as well, because dropping an arm's own
/// timing key would show a schedule with no schedule in it.
public enum ScheduleKind: Sendable, Hashable {
    case after
    case at
    case every
    case daily
    case weekly
    case cron
    /// A `kind` this build does not know. Its timing parameter is left unread rather than
    /// guessed at from a sibling arm's key, and the entry still decodes — SPEC §5: an
    /// unknown wire value must stay readable.
    case other(String)

    public init(wireValue: String) {
        switch wireValue {
        case "after": self = .after
        case "at": self = .at
        case "every": self = .every
        case "daily": self = .daily
        case "weekly": self = .weekly
        case "cron": self = .cron
        default: self = .other(wireValue)
        }
    }

    public var wireValue: String {
        switch self {
        case .after: "after"
        case .at: "at"
        case .every: "every"
        case .daily: "daily"
        case .weekly: "weekly"
        case .cron: "cron"
        case .other(let value): value
        }
    }
}

/// Whether a schedule is armed, from the shared part of every catalog arm.
public enum ScheduleStatus: Sendable, Hashable {
    case active
    case inactive
    /// A status this build does not know, kept rather than refused.
    case other(String)

    public init(wireValue: String) {
        switch wireValue {
        case "active": self = .active
        case "inactive": self = .inactive
        default: self = .other(wireValue)
        }
    }

    public var wireValue: String {
        switch self {
        case .active: "active"
        case .inactive: "inactive"
        case .other(let value): value
        }
    }
}

/// One delivery: `schedule/catalog`'s `lastDelivery`, or one `schedule/history` record.
///
/// The three keys both shapes share are required; `prompt` is the one key only a history
/// record carries (`"prompt": string().optional()` in
/// `dsh-schedule.client.ScheduleDeliveryHistoryResult.json`), while `lastDelivery` is
/// typed as exactly `{scheduledAt, deliveredAt, messageId}`.
public struct ScheduleDelivery: Sendable, Hashable, Codable {
    public var scheduledAt: String
    public var deliveredAt: String
    public var messageId: String
    /// Present on a history record only.
    public var prompt: String?
}

/// One entry of `schedule/catalog` or `schedule/list`.
///
/// Deliberately one type for both, because both are the same union of the same arms; the
/// difference is which half of the intersection the descriptor gives them, and that shows
/// up as the optional ``sessionId``/``status``/``lastDelivery`` trio below.
public struct ScheduleEntry: Sendable, Hashable, Identifiable, Codable {
    public var id: String
    public var kind: ScheduleKind
    public var title: String
    public var prompt: String
    public var scheduledAt: String

    /// ``ScheduleKind/after`` only. Never read for another arm, so an `at` entry that
    /// carries a stray `afterSeconds` does not report one.
    public var afterSeconds: Double?
    /// ``ScheduleKind/every`` only.
    public var everySeconds: Double?
    /// ``ScheduleKind/daily`` and ``ScheduleKind/weekly``.
    public var time: String?
    /// ``ScheduleKind/daily``, ``ScheduleKind/weekly`` and ``ScheduleKind/cron``.
    public var timeZone: String?
    /// ``ScheduleKind/weekly``.
    public var weekdays: [Double]?
    /// ``ScheduleKind/cron``.
    public var expression: String?

    /// Present in a `schedule/catalog` entry only.
    ///
    /// The descriptor intersects each catalog arm with `{sessionId, status, lastDelivery?}`
    /// but leaves the `schedule/list` arm as the bare scheduling object, so a list entry
    /// has no session id and no status. Nil means the host did not say — not "inactive".
    public var sessionId: String?
    public var status: ScheduleStatus?
    public var lastDelivery: ScheduleDelivery?

    enum CodingKeys: String, CodingKey {
        case id, kind, title, prompt, scheduledAt
        case afterSeconds, everySeconds, time, timeZone, weekdays, expression
        case sessionId, status, lastDelivery
    }

    /// Reads `kind` first, then only that arm's keys.
    ///
    /// This ordering is the whole point: with a flat `decodeIfPresent` over every key, an
    /// `at` entry carrying `afterSeconds` would decode as an `after` schedule and the row
    /// would render a countdown that the host never armed.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = ScheduleKind(wireValue: try container.decode(String.self, forKey: .kind))
        title = try container.decode(String.self, forKey: .title)
        prompt = try container.decode(String.self, forKey: .prompt)
        scheduledAt = try container.decode(String.self, forKey: .scheduledAt)

        switch kind {
        case .after:
            afterSeconds = try container.decodeIfPresent(Double.self, forKey: .afterSeconds)
        case .every:
            everySeconds = try container.decodeIfPresent(Double.self, forKey: .everySeconds)
        case .daily:
            time = try container.decodeIfPresent(String.self, forKey: .time)
            timeZone = try container.decodeIfPresent(String.self, forKey: .timeZone)
        case .weekly:
            time = try container.decodeIfPresent(String.self, forKey: .time)
            timeZone = try container.decodeIfPresent(String.self, forKey: .timeZone)
            weekdays = try container.decodeIfPresent([Double].self, forKey: .weekdays)
        case .cron:
            expression = try container.decodeIfPresent(String.self, forKey: .expression)
            timeZone = try container.decodeIfPresent(String.self, forKey: .timeZone)
        case .at, .other:
            break
        }

        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        status = try container.decodeIfPresent(String.self, forKey: .status).map(ScheduleStatus.init(wireValue:))
        lastDelivery = try container.decodeIfPresent(ScheduleDelivery.self, forKey: .lastDelivery)
    }

    /// `Codable` rather than `Decodable` because that is the constraint ``DshRpcClient``
    /// puts on a result type; nothing here writes to the wire.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind.wireValue, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(scheduledAt, forKey: .scheduledAt)
        try container.encodeIfPresent(afterSeconds, forKey: .afterSeconds)
        try container.encodeIfPresent(everySeconds, forKey: .everySeconds)
        try container.encodeIfPresent(time, forKey: .time)
        try container.encodeIfPresent(timeZone, forKey: .timeZone)
        try container.encodeIfPresent(weekdays, forKey: .weekdays)
        try container.encodeIfPresent(expression, forKey: .expression)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(status?.wireValue, forKey: .status)
        try container.encodeIfPresent(lastDelivery, forKey: .lastDelivery)
    }
}

// MARK: - schedule/list and schedule/history arguments

/// `schedule/list`'s one wire parameter, `request`, holding `{sessionId}`.
///
/// Named to match `Generated/Endpoints.swift`'s convention: the descriptor's parameter
/// name is the property name, verbatim.
public struct ScheduleListRequest: Codable, Sendable, Hashable {
    public var sessionId: String

    public init(sessionId: String) {
        self.sessionId = sessionId
    }
}

public struct ScheduleListArguments: Codable, Sendable, Hashable {
    public var request: ScheduleListRequest

    public init(request: ScheduleListRequest) {
        self.request = request
    }
}

/// `schedule/history`'s `request`, holding `{sessionId, id, limit, before?}`.
public struct ScheduleHistoryRequest: Codable, Sendable, Hashable {
    public var sessionId: String
    public var id: String
    /// `number()` on the wire.
    public var limit: Int
    /// The cursor from a previous page's `nextBefore`.
    public var before: String?

    public init(sessionId: String, id: String, limit: Int, before: String? = nil) {
        self.sessionId = sessionId
        self.id = id
        self.limit = limit
        self.before = before
    }
}

public struct ScheduleHistoryArguments: Codable, Sendable, Hashable {
    public var request: ScheduleHistoryRequest

    public init(request: ScheduleHistoryRequest) {
        self.request = request
    }
}

// MARK: - schedule/history

/// How many records the host keeps, from the history page's `retention`.
public struct ScheduleRetention: Sendable, Hashable, Codable {
    /// `number()` on the wire, so `Double` rather than a guess at an integer.
    public var days: Double
    public var records: Double
}

/// A page of deliveries, the success arm of `schedule/history`.
public struct ScheduleHistoryPage: Sendable, Hashable, Codable {
    public var id: String
    public var records: [ScheduleDelivery]
    /// True when older records exist but the host could not read them.
    public var earlierRecordsUnavailable: Bool
    /// True when older records were pruned by retention, which is why the page is short.
    public var earlierRecordsPruned: Bool
    public var retention: ScheduleRetention
    /// The cursor for the next page, or nil at the end of the history.
    public var nextBefore: String?
}

/// The `schedule/history` result, which is a union: a page, or a refusal.
///
/// A refusal is the host *answering* — it decided the id or the cursor was wrong — so it
/// is a value and not a failed section. Kept distinct from a transport error for the same
/// reason ``SelectionRefusal`` is.
public enum ScheduleHistoryResult: Sendable, Hashable {
    case records(ScheduleHistoryPage)
    case refused(id: String, code: String)

    /// The host's codes, from the descriptor's refusal arm.
    public static let scheduleNotFoundCode = "schedule_not_found"
    public static let deliveryCursorNotFoundCode = "delivery_cursor_not_found"
}

extension ScheduleHistoryResult: Codable {
    private enum Keys: String, CodingKey {
        case id, code, records
    }

    /// Discriminates on the presence of `records`, which only the success arm has. The
    /// refusal arm carries no marker beyond the absence of the page's keys.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        if container.contains(.records) {
            self = .records(try ScheduleHistoryPage(from: decoder))
        } else {
            self = .refused(
                id: try container.decode(String.self, forKey: .id),
                code: try container.decode(String.self, forKey: .code)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .records(let page):
            try page.encode(to: encoder)
        case .refused(let id, let code):
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(id, forKey: .id)
            try container.encode(code, forKey: .code)
        }
    }
}

// MARK: - pluginInventory/list

/// A host-supplied display string that may be translated.
///
/// The descriptor types `meta.title` and `meta.description` as
/// `union([string(), intersection(object({"en": string()}), record(string(), string()))])`.
/// Modelling only the string arm is the trap: a plugin that ships translations sends an
/// object, a `String` decode fails, and the row renders with no name at all.
public enum LocalizedText: Sendable, Hashable {
    case plain(String)
    case localized([String: String])

    /// What to show: the plain string, else `en`, else any translation.
    ///
    /// The fallback is sorted by key rather than taken in dictionary order, so a plugin
    /// with no English shows the same language on every launch.
    public var preferredText: String? {
        switch self {
        case .plain(let text):
            return text
        case .localized(let translations):
            if let english = translations["en"] { return english }
            return translations.keys.sorted().first.flatMap { translations[$0] }
        }
    }
}

extension LocalizedText: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let plain = try? container.decode(String.self) {
            self = .plain(plain)
        } else {
            self = .localized(try container.decode([String: String].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .plain(let text): try container.encode(text)
        case .localized(let translations): try container.encode(translations)
        }
    }
}

/// A plugin's fiber phase, one of the descriptor's six literal values.
public enum PluginFiberPhase: Sendable, Hashable {
    /// The wire's `null`: this entry has no fiber.
    case absent
    case failed
    case pending
    case active
    case loading
    case unloading
    /// A phase this build does not know. Kept rather than refused, because a host that
    /// adds a seventh phase must not fail the whole inventory read.
    case other(String)

    public init(wireValue: String?) {
        switch wireValue {
        case .none: self = .absent
        case .some("failed"): self = .failed
        case .some("pending"): self = .pending
        case .some("active"): self = .active
        case .some("loading"): self = .loading
        case .some("unloading"): self = .unloading
        case .some(let value): self = .other(value)
        }
    }

    public var wireValue: String? {
        switch self {
        case .absent: nil
        case .failed: "failed"
        case .pending: "pending"
        case .active: "active"
        case .loading: "loading"
        case .unloading: "unloading"
        case .other(let value): value
        }
    }
}

extension PluginFiberPhase: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = PluginFiberPhase(
            wireValue: container.decodeNil() ? nil : try container.decode(String.self)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wireValue {
            try container.encode(wireValue)
        } else {
            try container.encodeNil()
        }
    }
}

/// A plugin's `meta`: display text plus the host's own failure note.
public struct PluginMeta: Sendable, Hashable, Codable {
    public var title: LocalizedText?
    public var description: LocalizedText?
    public var icon: String?
    /// The host's explanation when the plugin itself is broken.
    public var error: String?

    enum CodingKeys: String, CodingKey {
        case title, description, icon, error
    }

    /// Decodes each text union leniently: a `title` this build cannot read costs the
    /// title, not the entry, and certainly not the whole inventory.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try? container.decodeIfPresent(LocalizedText.self, forKey: .title)
        description = try? container.decodeIfPresent(LocalizedText.self, forKey: .description)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

/// One plugin the host loaded.
public struct PluginEntry: Sendable, Hashable, Identifiable, Codable {
    /// The host's entry id. Kept under its wire name; ``id`` is the `Identifiable` alias.
    public var entryId: String
    public var moduleName: String
    public var enabled: Bool
    public var fiberPhase: PluginFiberPhase
    public var meta: PluginMeta?

    public var id: String { entryId }

    enum CodingKeys: String, CodingKey {
        case entryId, moduleName, enabled, fiberPhase, meta
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entryId = try container.decode(String.self, forKey: .entryId)
        moduleName = try container.decode(String.self, forKey: .moduleName)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        // The descriptor marks `fiberPhase` required but nullable, so a missing key is
        // read as the same "no fiber" the wire's `null` means rather than failing.
        fiberPhase = try container.decodeIfPresent(PluginFiberPhase.self, forKey: .fiberPhase) ?? .absent
        meta = try? container.decodeIfPresent(PluginMeta.self, forKey: .meta)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(entryId, forKey: .entryId)
        try container.encode(moduleName, forKey: .moduleName)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(fiberPhase, forKey: .fiberPhase)
        try container.encodeIfPresent(meta, forKey: .meta)
    }
}

/// The `pluginInventory/list` result.
public struct PluginInventory: Sendable, Hashable {
    /// Whether the host offers enable/disable at all.
    ///
    /// Optional on the wire, and absent is **not** true — see ``offersManagementControls``.
    /// Unverified: no capture of `pluginInventory/list` exists in `Protocol/examples`, so
    /// "absent means no management" is read from the key's optionality rather than from an
    /// example where the host omitted it.
    public var managementAvailable: Bool?
    public var entries: [PluginEntry]
    /// Kept lossless rather than half-typed.
    ///
    /// The shape *is* captured — the descriptor types this as a preset roster whose rows
    /// carry their own `meta` union and a three-valued `enabled` — but this read-only
    /// surface presents entries, not preset grouping, so the roster is preserved as
    /// ``JSONValue`` array elements instead of a guessed-at subset.
    public var agentPresets: [JSONValue]

    /// Whether a control for enabling or disabling a plugin may be shown.
    ///
    /// False when the host says false *and* when it says nothing: this unit is read-only
    /// anyway, so an absent flag must not be read as permission.
    public var offersManagementControls: Bool { managementAvailable == true }
}

extension PluginInventory: Codable {
    enum CodingKeys: String, CodingKey {
        case managementAvailable, entries, agentPresets
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        managementAvailable = try container.decodeIfPresent(Bool.self, forKey: .managementAvailable)
        entries = try container.decode([PluginEntry].self, forKey: .entries)
        agentPresets = try container.decodeIfPresent([JSONValue].self, forKey: .agentPresets) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(managementAvailable, forKey: .managementAvailable)
        try container.encode(entries, forKey: .entries)
        try container.encode(agentPresets, forKey: .agentPresets)
    }
}

// MARK: - Reading

/// What one gated read did.
///
/// Three outcomes rather than `throws`, because a read has a third possibility that an
/// error cannot express: the ledger already knows the host lacks the endpoint, so no
/// request was made and nothing failed. Folding that into a thrown error or into an empty
/// result would be exactly the confusion ``CapabilityState`` exists to prevent.
public enum SecondaryReadOutcome: Sendable, Hashable {
    /// The host answered. `itemCount` is how many entries the section now holds; zero is a
    /// successful empty result, not a missing one.
    case loaded(itemCount: Int)
    /// The ledger says the host does not implement this endpoint, so nothing was sent.
    case gated(reason: String)
    /// The request was made and failed. Whatever the section already had is kept.
    case failed(reason: String)
}

/// One section's loaded value and how fresh that is.
///
/// Per section rather than one shared state, because SPEC §3 keeps each resource's state
/// separate: a failed plugin read must not blank a schedule list that already loaded, and
/// the transitions below are the only place that rule is written.
private struct Section<Value: Sendable>: Sendable {
    var value: Value?
    /// Nil until a read has been attempted. A never-attempted resource is not the same as
    /// an empty one, and ``ResourceState`` has no case for it.
    var state: ResourceState?

    mutating func beginLoad() {
        state = (state ?? .loading).whileLoading
    }

    mutating func finishSuccess(_ value: Value, itemCount: Int) {
        self.value = value
        state = .afterSuccess(itemCount: itemCount)
    }

    mutating func finishFailure(reason: String) {
        state = (state ?? .loading).afterFailure(reason: reason)
    }
}

/// Reads the schedule catalog, a session's schedule list and delivery history, and the
/// host's plugin inventory, gating each on ``CapabilityLedger``.
///
/// An actor because four sections share one ledger and one connection. The client is
/// injected rather than reached through `ConnectionCoordinator`, so this type has no
/// opinion about connection ownership and can be exercised offline.
public actor SecondaryReadStore {
    /// `namespace/method`, straight from `Protocol/endpoints.json`.
    /// The shipped experimental service, absent from the desktop profile's bundle list —
    /// every call on this host answers 404.
    public static let scheduleCatalogMethod = "schedule/catalog"
    public static let scheduleListMethod = "schedule/list"
    public static let scheduleHistoryMethod = "schedule/history"
    /// The plugin the profile actually loads, and the one the Scheduled tasks screen reads.
    /// Verified live on 2026-10-12: `{"tasks":[…]}` with three real tasks.
    public static let scheduledTasksListMethod = "scheduledTasks/list"
    public static let pluginInventoryMethod = "pluginInventory/list"

    private let makeClient: @Sendable () -> DshRpcClient
    private var ledger: CapabilityLedger

    private var catalogSection = Section<[ScheduleEntry]>()
    private var listSection = Section<[ScheduleEntry]>()
    private var historySection = Section<ScheduleHistoryResult>()
    private var taskSection = Section<[ScheduledTask]>()
    private var pluginSection = Section<PluginInventory>()

    /// - Parameter ledger: seeded by the caller so a capability learned on another screen
    ///   (or restored from a previous connection) still suppresses this store's requests.
    public init(
        makeClient: @escaping @Sendable () -> DshRpcClient,
        ledger: CapabilityLedger = CapabilityLedger()
    ) {
        self.makeClient = makeClient
        self.ledger = ledger
    }

    // MARK: - State

    public var capabilityLedger: CapabilityLedger { ledger }

    /// Notes the host version, which forgets capabilities learned against another build.
    public func noteHostVersion(_ version: String?) {
        ledger.noteHostVersion(version)
    }

    /// The last successfully read catalog. Empty is "the host lists none"; whether a read
    /// has happened at all is ``scheduleCatalogState``.
    public var scheduleCatalog: [ScheduleEntry] { catalogSection.value ?? [] }
    public var scheduleCatalogState: ResourceState? { catalogSection.state }

    public var scheduleList: [ScheduleEntry] { listSection.value ?? [] }
    public var scheduleListState: ResourceState? { listSection.state }

    /// The last history answer, page or refusal.
    public var scheduleHistory: ScheduleHistoryResult? { historySection.value }
    public var scheduleHistoryState: ResourceState? { historySection.state }

    /// The last successfully read task list from `scheduledTasks/list`. Empty is "the host
    /// has no tasks"; whether a read has happened at all is ``scheduledTasksState``.
    public var scheduledTasks: [ScheduledTask] { taskSection.value ?? [] }
    public var scheduledTasksState: ResourceState? { taskSection.state }

    /// Nil until a plugin read has succeeded — distinct from an inventory with no entries.
    public var pluginInventory: PluginInventory? { pluginSection.value }
    public var pluginInventoryState: ResourceState? { pluginSection.state }

    // MARK: - Reads

    /// Reads `schedule/catalog`. Takes no arguments; the result is a bare array.
    @discardableResult
    public func loadScheduleCatalog() async -> SecondaryReadOutcome {
        let endpoint = Self.scheduleCatalogMethod
        if let gated = gate(endpoint) { return gated }
        catalogSection.beginLoad()
        do {
            let response = try await makeClient().call(
                endpoint, args: RPCEmptyRequest(), returning: [ScheduleEntry].self
            )
            guard let entries = response.result.value else {
                throw DshRPCError.protocolIncompatible(reason: "schedule/catalog returned no catalog")
            }
            ledger.recordSuccess(of: endpoint)
            catalogSection.finishSuccess(entries, itemCount: entries.count)
            return .loaded(itemCount: entries.count)
        } catch {
            return fail(error, endpoint: endpoint, section: &catalogSection)
        }
    }

    /// Reads one session's schedules.
    @discardableResult
    public func loadScheduleList(sessionId: String) async -> SecondaryReadOutcome {
        let endpoint = Self.scheduleListMethod
        if let gated = gate(endpoint) { return gated }
        listSection.beginLoad()
        do {
            let response = try await makeClient().call(
                endpoint,
                args: ScheduleListArguments(request: ScheduleListRequest(sessionId: sessionId)),
                returning: [ScheduleEntry].self
            )
            guard let entries = response.result.value else {
                throw DshRPCError.protocolIncompatible(reason: "schedule/list returned no schedules")
            }
            ledger.recordSuccess(of: endpoint)
            listSection.finishSuccess(entries, itemCount: entries.count)
            return .loaded(itemCount: entries.count)
        } catch {
            return fail(error, endpoint: endpoint, section: &listSection)
        }
    }

    /// Reads one schedule's delivery history.
    ///
    /// - Parameter before: the cursor from the previous page's `nextBefore`.
    @discardableResult
    public func loadScheduleHistory(
        sessionId: String,
        id: String,
        limit: Int,
        before: String? = nil
    ) async -> SecondaryReadOutcome {
        let endpoint = Self.scheduleHistoryMethod
        if let gated = gate(endpoint) { return gated }
        historySection.beginLoad()
        do {
            let response = try await makeClient().call(
                endpoint,
                args: ScheduleHistoryArguments(request: ScheduleHistoryRequest(
                    sessionId: sessionId, id: id, limit: limit, before: before
                )),
                returning: ScheduleHistoryResult.self
            )
            guard let result = response.result.value else {
                throw DshRPCError.protocolIncompatible(reason: "schedule/history returned no history")
            }
            ledger.recordSuccess(of: endpoint)
            // A refusal carries no records. `itemCount` counts deliveries only; the
            // refusal code is in the value, not smuggled into the resource state.
            var itemCount = 0
            if case .records(let page) = result { itemCount = page.records.count }
            historySection.finishSuccess(result, itemCount: itemCount)
            return .loaded(itemCount: itemCount)
        } catch {
            return fail(error, endpoint: endpoint, section: &historySection)
        }
    }

    /// Reads `scheduledTasks/list`. Takes no arguments; the result wraps its array in a
    /// `tasks` key, unlike `schedule/catalog`'s bare array.
    @discardableResult
    public func loadScheduledTasks() async -> SecondaryReadOutcome {
        let endpoint = Self.scheduledTasksListMethod
        if let gated = gate(endpoint) { return gated }
        taskSection.beginLoad()
        do {
            let response = try await makeClient().call(
                endpoint, args: RPCEmptyRequest(), returning: ScheduledTaskList.self
            )
            guard let list = response.result.value else {
                throw DshRPCError.protocolIncompatible(reason: "scheduledTasks/list returned no list")
            }
            ledger.recordSuccess(of: endpoint)
            taskSection.finishSuccess(list.tasks, itemCount: list.tasks.count)
            return .loaded(itemCount: list.tasks.count)
        } catch {
            return fail(error, endpoint: endpoint, section: &taskSection)
        }
    }

    /// Reads `pluginInventory/list`. Takes no arguments.
    @discardableResult
    public func loadPluginInventory() async -> SecondaryReadOutcome {
        let endpoint = Self.pluginInventoryMethod
        if let gated = gate(endpoint) { return gated }
        pluginSection.beginLoad()
        do {
            let response = try await makeClient().call(
                endpoint, args: RPCEmptyRequest(), returning: PluginInventory.self
            )
            guard let inventory = response.result.value else {
                throw DshRPCError.protocolIncompatible(reason: "pluginInventory/list returned no inventory")
            }
            ledger.recordSuccess(of: endpoint)
            pluginSection.finishSuccess(inventory, itemCount: inventory.entries.count)
            return .loaded(itemCount: inventory.entries.count)
        } catch {
            return fail(error, endpoint: endpoint, section: &pluginSection)
        }
    }

    // MARK: - Gating and failures

    /// Whether a read may be attempted, and why not when it may not.
    ///
    /// Only ``CapabilityState/unavailable(reason:)`` stops a request. `unknown` attempts,
    /// and so does `failed`: SPEC §10 makes failure no evidence about whether the endpoint
    /// exists, so treating it as absence would hide a working feature after one bad call.
    private func gate(_ endpoint: String) -> SecondaryReadOutcome? {
        let capability = ledger.state(of: endpoint)
        guard capability.isAbsent else { return nil }
        if case .unavailable(let reason) = capability { return .gated(reason: reason) }
        // `isAbsent` is only true for `unavailable`; spelled out rather than force-unwrapped.
        return .gated(reason: "the host does not implement \(endpoint)")
    }

    /// Records a failed read in the ledger and the section, and returns the outcome.
    ///
    /// The section keeps whatever it already had: ``ResourceState/afterFailure(reason:)``
    /// turns a failure with data into a staleness mark rather than a blank screen.
    private func fail<Value: Sendable>(
        _ error: any Error,
        endpoint: String,
        section: inout Section<Value>
    ) -> SecondaryReadOutcome {
        let failure = (error as? DshRPCError)
            ?? .protocolIncompatible(reason: String(describing: error))
        // A cancellation is classified as no evidence at all, so this leaves a known-good
        // capability alone.
        ledger.record(failure, of: endpoint)
        // `readableReason` is nil only for `.cancelled`, which is the one failure with no
        // user-facing sentence of its own.
        let reason = failure.readableReason ?? "the read was cancelled"
        section.finishFailure(reason: reason)
        return .failed(reason: reason)
    }
}
