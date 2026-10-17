import Foundation

/// One attachment chosen for a draft, before or after it reaches the host.
///
/// Only a reference: nothing here holds a bookmark or a security scope. The copy out of the
/// picker's security-scoped location is made by `AttachmentStaging.stage`, which holds the scope
/// "only long enough to copy the file" (SPEC §5, §3.6). Since #66 that copy lasts one upload and
/// is discarded once it settles; no staged copy is persisted with a draft yet, so
/// `storedRelativePath` and `byteCount` are not written by the import path.
public struct DraftAttachment: Sendable, Hashable, Codable, Identifiable {
    public enum Preparation: String, Sendable, Codable {
        /// Copied into app storage, not yet sent.
        case prepared
        /// An upload is in flight. A draft that reloads in this state is *uncertain*, not
        /// failed: the upload may have completed while the app was suspended.
        case uploading
        /// The host accepted it and returned the receipt a prompt cites.
        case uploaded
        /// Preparation or upload failed. The bytes are kept so the user need not re-pick.
        case failed
    }

    public var id: UUID
    public var name: String
    public var preparation: Preparation
    /// Where the bytes were copied to, relative to the draft store's directory.
    ///
    /// Relative rather than absolute so a store directory that moves — a restored backup,
    /// a changed container path — does not invalidate every attachment.
    public var storedRelativePath: String?
    public var byteCount: Int
    /// The host's receipt once ``preparation`` is ``uploaded``. This is what a prompt
    /// cites: SPEC §9 requires `{type:"file",receiptId}` and says an `attachmentId` is not
    /// a substitute.
    public var receiptId: String?
    public var failureReason: String?

    public init(
        id: UUID = UUID(),
        name: String,
        preparation: Preparation = .prepared,
        storedRelativePath: String? = nil,
        byteCount: Int = 0,
        receiptId: String? = nil,
        failureReason: String? = nil
    ) {
        self.id = id
        self.name = name
        self.preparation = preparation
        self.storedRelativePath = storedRelativePath
        self.byteCount = byteCount
        self.receiptId = receiptId
        self.failureReason = failureReason
    }
}

/// The identity of one human submission, which outlives the attempt to deliver it.
///
/// SPEC §5: a retry of an uncertain send reuses the original request ID with the same
/// content, because the host deduplicates on exactly that value. Persisting it here is what
/// makes that possible across a relaunch.
public struct DraftSubmission: Sendable, Hashable, Codable {
    public var requestId: String
    /// The draft revision this submission captured. Acceptance clears only this revision's
    /// content; text typed while the send was pending must survive.
    public var revision: Int

    public init(requestId: String, revision: Int) {
        self.requestId = requestId
        self.revision = revision
    }
}

/// One draft, with the revision that makes clearing it safe.
public struct Draft: Sendable, Hashable, Codable {
    /// A new-session draft has no session id yet, so it is scoped to a workspace instead.
    public var workspaceId: String?
    public var text: String
    /// Monotonically increasing. Bumped by every edit, so a late acceptance cannot clear
    /// text the user typed after submitting.
    public var revision: Int
    public var agentPreset: String?
    public var modelProvider: String?
    public var model: String?
    public var reasoningEffort: String?
    public var attachments: [DraftAttachment]
    /// Present while a submission is unresolved. Cleared once it is settled.
    public var submission: DraftSubmission?
    /// The identity this new-session draft will be created with.
    ///
    /// SPEC §5 makes the *phone* supply the session identity, and makes reusing it the thing
    /// that turns an unknown create outcome into a recoverable one — so it has to outlive the
    /// attempt. A relaunch that minted a fresh identity would leave the first session behind
    /// and make a second one, which is exactly the duplicate the rule exists to prevent.
    public var proposedSessionId: String?

    public init(
        workspaceId: String? = nil,
        text: String = "",
        revision: Int = 0,
        agentPreset: String? = nil,
        modelProvider: String? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil,
        attachments: [DraftAttachment] = [],
        submission: DraftSubmission? = nil,
        proposedSessionId: String? = nil
    ) {
        self.workspaceId = workspaceId
        self.text = text
        self.revision = revision
        self.agentPreset = agentPreset
        self.modelProvider = modelProvider
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.attachments = attachments
        self.submission = submission
        self.proposedSessionId = proposedSessionId
    }

    public var isEmpty: Bool {
        text.isEmpty && attachments.isEmpty
    }

    /// Whether anything about this draft has been sent and not yet resolved.
    public var hasUnresolvedSubmission: Bool { submission != nil }
}

extension Draft: CustomStringConvertible {
    /// Redacted on purpose.
    ///
    /// A synthesised description would print the text, and SPEC §5 forbids draft text
    /// reaching routine diagnostics. Implementing this rather than relying on synthesis is
    /// what makes "a draft cannot leak through a log line" true rather than hopeful — an
    /// interpolated `\(draft)` anywhere now yields a character count.
    public var description: String {
        let size = text.isEmpty ? "empty" : "\(text.count) chars"
        return "Draft(revision: \(revision), text: \(size), attachments: \(attachments.count), "
            + "unresolvedSubmission: \(hasUnresolvedSubmission))"
    }
}

/// Which draft a value belongs to.
///
/// SPEC §5 is explicit that a workspace key alone is not enough: "Using only a workspace key
/// would let two new drafts overwrite each other." So a new-session draft carries its own
/// identity, and an existing-session draft is keyed by the session.
public struct DraftKey: Sendable, Hashable, Codable {
    public enum Owner: Sendable, Hashable, Codable {
        case session(String)
        case newSession(UUID)

        /// The on-disk key. Stable across a rename of the case, and readable in a file.
        public var storageKey: String {
            switch self {
            case .session(let id): "session:\(id)"
            case .newSession(let id): "new:\(id.uuidString)"
            }
        }

        init?(storageKey: String) {
            if storageKey.hasPrefix("session:") {
                self = .session(String(storageKey.dropFirst("session:".count)))
            } else if storageKey.hasPrefix("new:") {
                guard let id = UUID(uuidString: String(storageKey.dropFirst("new:".count))) else {
                    return nil
                }
                self = .newSession(id)
            } else {
                return nil
            }
        }
    }

    public var hostId: UUID
    public var owner: Owner

    public init(hostId: UUID, owner: Owner) {
        self.hostId = hostId
        self.owner = owner
    }
}

/// Where the app was, restored separately from any draft.
///
/// SPEC §5: "Persist navigation separately: last host, workspace, session, and optional
/// scroll anchor." Separate because a navigation change is not an edit and must not bump a
/// draft revision.
public struct DraftNavigation: Sendable, Hashable, Codable {
    public var workspaceId: String?
    public var sessionId: String?
    /// A stable message or event id, not an offset, so it survives a refreshed transcript.
    public var scrollAnchor: String?

    public init(workspaceId: String? = nil, sessionId: String? = nil, scrollAnchor: String? = nil) {
        self.workspaceId = workspaceId
        self.sessionId = sessionId
        self.scrollAnchor = scrollAnchor
    }
}

/// Why a draft could not be saved.
public struct DraftStoreError: Error, Sendable, Hashable {
    public var operation: String
    public var reason: String
}

/// Durable drafts, per host and per session or new-session identity.
///
/// SPEC §5's storage contract, and the UX specification's persistence table. The rules that
/// shape the type:
///
/// - **Revisions are what makes acceptance safe.** Every edit bumps `revision`, and
///   ``clearSubmitted(revision:for:)`` clears only if the revision still matches. Text typed
///   while a send was pending therefore survives the acceptance of the older content.
/// - **A failed write never destroys the text.** The in-memory draft is the source of truth
///   while the app runs; a persistence failure is reported and the text stays. That is what
///   ``saveError`` and the thrown ``DraftStoreError`` are for.
/// - **Writes are debounced**, with ``flush()`` for the moments that cannot wait — a
///   submission, and anything the app does on the way to the background.
/// - **File protection is requested on every write.** It is a no-op on macOS and real on
///   iOS; see the wiring specification.
/// - **Draft text never reaches diagnostics.** Nothing here logs, and nothing here is
///   `CustomStringConvertible`, so a draft cannot be interpolated into a message by accident.
public actor DraftStore {
    /// The default debounce. SPEC §5 asks for a "short debounce"; the exact value is not a
    /// contract, and a submission flushes regardless.
    public static let defaultDebounce = Duration.milliseconds(400)

    private let directory: URL
    private let debounce: Duration
    private let write: @Sendable (Data, URL) throws -> Void

    private var drafts: [DraftKey: Draft] = [:]
    private var navigation: [UUID: DraftNavigation] = [:]
    private var pendingWrite: Task<Void, Never>?
    /// The last failure, so a caller can say saving failed without losing the text.
    public private(set) var saveError: DraftStoreError?

    /// - Parameters:
    ///   - directory: where drafts live. Injected so tests use a temporary directory.
    ///   - debounce: how long to wait before writing an edit.
    ///   - write: the write itself, injected so a test can force a failure.
    public init(
        directory: URL,
        debounce: Duration = DraftStore.defaultDebounce,
        write: @escaping @Sendable (Data, URL) throws -> Void = DraftStore.writeAtomically
    ) {
        self.directory = directory
        self.debounce = debounce
        self.write = write
        // Static rather than an isolated method: an actor's `init` cannot call one, and
        // reading the files before `self` is usable is exactly what this needs to do.
        let loaded = Self.loadAll(in: directory)
        self.drafts = loaded.drafts
        self.navigation = loaded.navigation
    }

    // MARK: - Reading

    public func draft(for key: DraftKey) -> Draft {
        drafts[key] ?? Draft()
    }

    /// Every draft for one host, for a debug screen or a diagnostic count. Never for display.
    public func draftCount(hostId: UUID) -> Int {
        drafts.keys.filter { $0.hostId == hostId }.count
    }

    public func navigation(for hostId: UUID) -> DraftNavigation {
        navigation[hostId] ?? DraftNavigation()
    }

    // MARK: - Editing

    /// Replaces the text and bumps the revision.
    ///
    /// Returns the stored draft so a caller can read the revision it must later present.
    @discardableResult
    public func setText(_ text: String, for key: DraftKey) -> Draft {
        var draft = draft(for: key)
        draft.text = text
        draft.revision += 1
        drafts[key] = draft
        scheduleWrite()
        return draft
    }

    /// Records the staged mode and model for a draft, without touching its text.
    @discardableResult
    public func setSelection(
        agentPreset: String?,
        modelProvider: String?,
        model: String?,
        reasoningEffort: String?,
        for key: DraftKey
    ) -> Draft {
        var draft = draft(for: key)
        draft.agentPreset = agentPreset
        draft.modelProvider = modelProvider
        draft.model = model
        draft.reasoningEffort = reasoningEffort
        draft.revision += 1
        drafts[key] = draft
        scheduleWrite()
        return draft
    }

    @discardableResult
    public func setAttachments(_ attachments: [DraftAttachment], for key: DraftKey) -> Draft {
        var draft = draft(for: key)
        draft.attachments = attachments
        draft.revision += 1
        drafts[key] = draft
        scheduleWrite()
        return draft
    }

    /// Records the identity a new-session draft will be created with.
    ///
    /// Written **before** the create request goes out, so a crash or a lost response leaves
    /// the identity on disk rather than only in memory.
    @discardableResult
    public func setProposedSessionId(_ sessionId: String, for key: DraftKey) -> Draft {
        var draft = draft(for: key)
        draft.proposedSessionId = sessionId
        drafts[key] = draft
        scheduleWrite()
        return draft
    }

    /// Records the workspace a new-session draft belongs to.
    @discardableResult
    public func setWorkspace(_ workspaceId: String, for key: DraftKey) -> Draft {
        var draft = draft(for: key)
        draft.workspaceId = workspaceId
        drafts[key] = draft
        scheduleWrite()
        return draft
    }

    /// Records the submission, capturing the revision it is sending.
    ///
    /// SPEC §5: "Capture a submission's draft revision. Acceptance clears only that
    /// revision's submitted content."
    @discardableResult
    public func beginSubmission(requestId: String, for key: DraftKey) -> DraftSubmission {
        var draft = draft(for: key)
        let submission = DraftSubmission(requestId: requestId, revision: draft.revision)
        draft.submission = submission
        drafts[key] = draft
        scheduleWrite()
        return submission
    }

    /// Clears the submitted content of one submission, and only if it is still what was sent.
    ///
    /// Returns whether anything was cleared. `false` means the user typed something newer
    /// while the send was in flight, and that newer text is left exactly as it is — which is
    /// the behaviour SPEC §5 and the UX specification both require.
    @discardableResult
    public func clearSubmitted(revision: Int, for key: DraftKey) -> Bool {
        guard var draft = drafts[key] else { return false }
        // The draft must still be the one that was sent, and its text must not have moved on.
        guard draft.submission?.revision == revision else { return false }
        guard draft.revision == revision else {
            // Newer work exists. Drop the resolved submission but keep the content.
            draft.submission = nil
            drafts[key] = draft
            scheduleWrite()
            return false
        }
        draft.text = ""
        draft.attachments = []
        draft.submission = nil
        draft.revision += 1
        drafts[key] = draft
        scheduleWrite()
        return true
    }

    /// Forgets a submission that turned out not to be deliverable, keeping the text.
    @discardableResult
    public func abandonSubmission(for key: DraftKey) -> Draft {
        var draft = draft(for: key)
        draft.submission = nil
        drafts[key] = draft
        scheduleWrite()
        return draft
    }

    @discardableResult
    public func setNavigation(_ value: DraftNavigation, for hostId: UUID) -> DraftNavigation {
        navigation[hostId] = value
        scheduleWrite()
        return value
    }

    // MARK: - Removing

    public func remove(_ key: DraftKey) {
        drafts[key] = nil
        scheduleWrite()
    }

    /// Forgets one host's drafts and navigation. Nothing here revokes anything at the
    /// relay — SPEC §6.3 keeps forgetting a host and revoking a device separate.
    public func remove(hostId: UUID) {
        for key in drafts.keys where key.hostId == hostId { drafts[key] = nil }
        navigation[hostId] = nil
        scheduleWrite()
    }

    public func removeAll() {
        drafts.removeAll()
        navigation.removeAll()
        scheduleWrite()
    }

    // MARK: - Persisting

    /// Writes any debounced edit immediately.
    ///
    /// Called at a submission and at lifecycle transitions, where waiting for a debounce
    /// could lose the edit to a suspension.
    ///
    /// - Throws: ``DraftStoreError``. The in-memory draft is unchanged on failure.
    public func flush() throws {
        pendingWrite?.cancel()
        pendingWrite = nil
        try writeNow()
    }

    private func scheduleWrite() {
        pendingWrite?.cancel()
        let delay = debounce
        pendingWrite = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.writeDebounced()
        }
    }

    private func writeDebounced() {
        do {
            try writeNow()
        } catch {
            // Deliberately swallowed here: a debounced write has no caller to throw to, so
            // it records the failure for the next `flush()` or reader to report instead of
            // dropping the edit or the error.
            saveError = error as? DraftStoreError ?? DraftStoreError(
                operation: "save", reason: String(describing: error)
            )
        }
    }

    private func writeNow() throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let draftsData = try encoder.encode(DraftsFile(drafts: encodedDrafts()))
            try write(draftsData, Self.fileURL(for: "drafts", in: directory))

            let navigationData = try encoder.encode(NavigationFile(navigation: encodedNavigation()))
            try write(navigationData, Self.fileURL(for: "navigation", in: directory))
            saveError = nil
        } catch let error as DraftStoreError {
            saveError = error
            throw error
        } catch {
            let failure = DraftStoreError(operation: "save", reason: String(describing: error))
            saveError = failure
            throw failure
        }
    }

    // MARK: - The file format

    /// Drafts are stored with the owner as a string key rather than as an encoded enum, so
    /// a file stays readable and a future case does not invalidate every existing draft.
    private struct DraftsFile: Codable {
        var drafts: [String: Draft]
    }

    private struct NavigationFile: Codable {
        var navigation: [String: DraftNavigation]
    }

    private func encodedDrafts() -> [String: Draft] {
        var encoded: [String: Draft] = [:]
        // An otherwise-empty draft is still worth writing when it holds a submission or a
        // proposed session identity. The identity in particular: it is the only record that
        // a session may already exist on the host, so dropping it on relaunch is precisely
        // how a retry becomes a duplicate.
        for (key, draft) in drafts
        where !draft.isEmpty || draft.submission != nil || draft.proposedSessionId != nil {
            encoded["\(key.hostId.uuidString)/\(key.owner.storageKey)"] = draft
        }
        return encoded
    }

    private func encodedNavigation() -> [String: DraftNavigation] {
        var encoded: [String: DraftNavigation] = [:]
        for (hostId, value) in navigation {
            encoded[hostId.uuidString] = value
        }
        return encoded
    }


    static func loadAll(
        in directory: URL
    ) -> (drafts: [DraftKey: Draft], navigation: [UUID: DraftNavigation]) {
        let decoder = JSONDecoder()
        var drafts: [DraftKey: Draft] = [:]
        var navigation: [UUID: DraftNavigation] = [:]

        if let data = try? Data(contentsOf: fileURL(for: "drafts", in: directory)),
           let file = try? decoder.decode(DraftsFile.self, from: data) {
            for (composite, draft) in file.drafts {
                guard let key = decodeKey(composite) else { continue }
                drafts[key] = draft
            }
        }
        if let data = try? Data(contentsOf: fileURL(for: "navigation", in: directory)),
           let file = try? decoder.decode(NavigationFile.self, from: data) {
            for (hostId, value) in file.navigation {
                guard let id = UUID(uuidString: hostId) else { continue }
                navigation[id] = value
            }
        }
        return (drafts, navigation)
    }

    static func decodeKey(_ composite: String) -> DraftKey? {
        let parts = composite.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let hostId = UUID(uuidString: String(parts[0])),
              let owner = DraftKey.Owner(storageKey: String(parts[1]))
        else { return nil }
        return DraftKey(hostId: hostId, owner: owner)
    }

    static func fileURL(for name: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(name).json", isDirectory: false)
    }

    /// The real write: atomic, and requesting file protection.
    ///
    /// A single store file rather than one per draft, because the whole set is rewritten
    /// together and a dozen tiny files would be a dozen chances to half-apply a change.
    public static let writeAtomically: @Sendable (Data, URL) throws -> Void = { data, url in
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            // Compiles on macOS and is a no-op there; genuine on iOS. SPEC §5 asks for iOS
            // file protection, and the app is the only thing that ships this.
            try data.write(to: url, options: [
                .atomic,
                .completeFileProtectionUntilFirstUserAuthentication,
            ])
        } catch {
            throw DraftStoreError(operation: "write", reason: String(describing: error))
        }
    }
}
