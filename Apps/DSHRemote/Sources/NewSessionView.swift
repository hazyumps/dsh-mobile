import DSHRemoteKit
import SwiftUI

/// New session: the four decisions that place the work, then the words.
///
/// The composer used to sit inside Home's scrolling page, which put the mode and model
/// controls above it and the project picker in a drawer. Here the same four choices are one
/// list read top to bottom — host, project, preset, model — above the field, which is the
/// shape that makes "what is this about to do" answerable before anything is typed.
///
/// SPEC §5 still governs the transaction: opening this screen creates nothing, and the host
/// hears about it only when Send is pressed.
struct NewSessionView: View {
    @Environment(AppModel.self) private var model

    /// Called with the session id once the first prompt has landed, so Home can show it.
    let onCreated: (String) -> Void

    @State private var draft = ""
    @State private var isWorkspacePickerOpen = false
    /// Bumped once on appear when a debug launch asked for the cursor.
    @State private var focusRequest = 0
    @FocusState private var isFocused: Bool

    private var browse: BrowseState { model.browse }

    private var workspace: BrowseWorkspace? {
        browse.workspace(id: model.selectedWorkspaceId) ?? browse.workspaces.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                contextRows
                Divider()
                    .overlay(DSHPalette.divider)
                    .padding(.vertical, DSHMetrics.spaceCard)
                composer
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DSHMetrics.pageMargin)
            .padding(.bottom, DSHMetrics.spaceCard)
        }
        // Bottom-anchored: the block sits on the keyboard the way the composer it replaces
        // sat on the bottom of the screen, and scrolls normally when the text size makes it
        // taller than the space.
        .defaultScrollAnchor(.bottom)
        .background(DSHPalette.canvas)
        .dismissesKeyboardOnDownwardDrag()
        .navigationTitle("New session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text("New session")
                        .font(.dshConversationTitle)
                    // Stated on the screen that creates things, because it is the question
                    // this screen raises: what happens when I press this?
                    Text("Nothing reaches the host until you send")
                        .font(.caption2)
                        .foregroundStyle(DSHPalette.secondaryText)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .sheet(isPresented: $isWorkspacePickerOpen) {
            WorkspacePickerView(
                workspaces: browse.workspaces,
                selectedId: model.selectedWorkspaceId,
                select: { workspaceId in
                    model.selectWorkspace(workspaceId)
                    isWorkspacePickerOpen = false
                },
                cancel: { isWorkspacePickerOpen = false }
            )
        }
        .task {
            if model.catalog == nil { await model.loadModelCatalog() }
            #if DEBUG
            // Debug builds only: seed and focus, so the state a phone reaches by tapping is
            // reachable on a machine that cannot tap.
            if let seeded = ProcessInfo.processInfo.environment["DSH_DRAFT"] { draft = seeded }
            if ProcessInfo.processInfo.environment["DSH_FOCUS"] != nil {
                try? await Task.sleep(for: .seconds(1))
                focusRequest += 1
            }
            #endif
        }
    }

    // MARK: - Context

    private var contextRows: some View {
        // Leading, not the default centre: a stack whose children are full-width hides the
        // difference until one of them is not, and then the short one floats in the middle.
        VStack(alignment: .leading, spacing: 0) {
            hostRow
            // A plain button and the searchable sheet rather than a menu: a host with a
            // hundred workspaces cannot be chosen from a menu, and the sheet already exists.
            Button {
                isWorkspacePickerOpen = true
            } label: {
                DSHContextLabel(
                    title: "Project",
                    symbol: "folder",
                    value: workspace?.title ?? "Choose a project"
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Project. \(workspace?.title ?? "none selected").")
            .accessibilityHint("Chooses the project to work in")
            ModelModeControls(
                style: .rows,
                catalog: model.catalog,
                isLoading: model.catalogState == .loading,
                failure: {
                    if case .failed(let reason) = model.catalogState { return reason }
                    return nil
                }(),
                selectedMode: model.effectiveMode,
                selectedModel: model.effectiveModel,
                isModeStaged: model.stagedMode != nil,
                isModelStaged: model.stagedModel != nil,
                onSelectMode: { model.stageMode($0) },
                onSelectModel: { model.stageModel($0) },
                onRefresh: { Task { await model.loadModelCatalog() } }
            )
        }
    }

    /// The host is a menu, not a sheet: there are one or two of them.
    private var hostRow: some View {
        DSHContextRow(
            title: "Host",
            symbol: "laptopcomputer",
            value: model.selectedHost?.displayName ?? "No host"
        ) {
            ForEach(model.hosts) { host in
                Button(host.displayName) { Task { await model.select(host) } }
            }
            if model.hosts.isEmpty {
                Text("No hosts paired")
            }
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: DSHMetrics.spaceSmall) {
            if let error = model.newSessionError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.dshMetadata)
                    .foregroundStyle(DSHPalette.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Composer(
                text: $draft,
                canSend: sendBlockedReason == nil,
                sendBlockedReason: sendBlockedReason,
                isSending: model.isStartingSession,
                placeholder: "Ask DeepSeek…",
                focusRequest: focusRequest,
                onSend: { text in Task { await start(text) } }
            )
        }
    }

    /// Why Send is not available, or `nil` when it is.
    private var sendBlockedReason: String? {
        if !model.status.isUsable { return "Offline — reconnect to send." }
        if model.selectedWorkspaceId == nil { return "Choose a project first." }
        return nil
    }

    /// Starts the session with the first prompt, and clears the field only if the prompt was
    /// accepted — the transaction owns the rest (SPEC §5).
    private func start(_ text: String) async {
        guard let workspaceId = model.selectedWorkspaceId else { return }
        guard let started = await model.startSession(workspaceId: workspaceId, text: text) else { return }
        draft = ""
        onCreated(started)
    }
}

/// The workspace selector: a searchable list of the host's registry.
///
/// A sheet rather than a menu because the registry can be long, and because the
/// identifier it returns is the host's own — never one derived from a title or a
/// phone-side directory (SPEC §4).
struct WorkspacePickerView: View {
    let workspaces: [BrowseWorkspace]
    let selectedId: String?
    let select: (String) -> Void
    let cancel: () -> Void

    @State private var query = ""

    private var matches: [BrowseWorkspace] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return workspaces }
        return workspaces.filter { $0.title.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(matches) { workspace in
                    Button {
                        select(workspace.id)
                    } label: {
                        HStack(spacing: DSHMetrics.space) {
                            Image(systemName: "folder")
                                .foregroundStyle(DSHPalette.secondaryText)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(workspace.title)
                                    .foregroundStyle(DSHPalette.primaryText)
                                if let path = workspace.path, !path.isEmpty {
                                    Text(path)
                                        .font(.dshMetadata)
                                        .foregroundStyle(DSHPalette.secondaryText)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            Spacer(minLength: DSHMetrics.space)
                            if workspace.id == selectedId {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(DSHPalette.primaryActionText)
                                    .accessibilityLabel("Selected")
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Filter projects")
            .navigationTitle("Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                }
            }
            .overlay {
                if matches.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
    }
}
