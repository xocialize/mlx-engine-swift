//
//  ModelStorageSettingsView.swift
//  MLXEngineUI
//
//  A reusable settings panel for managing where MLXEngine stores its models.
//  Adapted from the MarqueeStudio "Project Panel — Reusable" design and built
//  entirely from `MarqueeColor` / `MarqueeFont` tokens so it drops cleanly into
//  any consuming app's settings surface.
//

import MLXToolKit
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Model

/// Snapshot of the model-storage status shown in the panel's STORAGE section.
public struct ModelStorageStatus: Sendable, Equatable {
    public var isReady: Bool
    public var location: String
    public var diskUsed: String
    public var modelsInstalled: Int
    public var freeSpace: String
    public var lastScan: String

    public init(
        isReady: Bool = true,
        location: String = "~/…/MLXEngine/Models",
        diskUsed: String = "—",
        modelsInstalled: Int = 0,
        freeSpace: String = "—",
        lastScan: String = "—"
    ) {
        self.isReady = isReady
        self.location = location
        self.diskUsed = diskUsed
        self.modelsInstalled = modelsInstalled
        self.freeSpace = freeSpace
        self.lastScan = lastScan
    }
}

/// Deletes one repo's weights, or throws explaining why it can't.
///
/// **The engine owns this, not the UI** (MS-4). `MLXEngineUI` deliberately does not depend on
/// `MLXServeCore`, and deletion must respect residency — `ModelStore.remove(repo:)` is unguarded and
/// would happily delete weights out from under a loaded package. So the app injects
/// `MLXServeEngine.deleteWeights(repo:)` here, which refuses with `EngineError.weightsInUse` while a
/// resident package draws on the repo. Leave it `nil` and the panel shows no delete affordance at
/// all — better than offering an unsafe one.
///
/// Deliberately **not** actor-isolated: the engine is an actor and the handler is awaited from the
/// panel, so it must be callable from any isolation. Wired from the app as
/// `WeightDeleteHandler { try await engine.deleteWeights(repo: $0) }`.
public struct WeightDeleteHandler: Sendable {
    private let body: @Sendable (String) async throws -> Void

    public init(_ body: @Sendable @escaping (String) async throws -> Void) {
        self.body = body
    }

    public func callAsFunction(_ repo: String) async throws {
        try await body(repo)
    }
}

/// Backing state for `ModelStorageSettingsView`. Consuming apps can supply their
/// own instance to observe edits and react to Apply/Reset.
///
/// Persistence: the applied folder is stored as a **security-scoped app-scope
/// bookmark** (requires the `files.bookmarks.app-scope` and
/// `files.user-selected.read-write` entitlements in a sandboxed app). The bookmark
/// is resolved on init, so access to a previously-chosen folder survives relaunch.
///
/// Isolated to the main actor: it is a SwiftUI observable view model, only ever held as `@State` by
/// the panels in this module. Explicit isolation (rather than a nonisolated class that hops) is what
/// lets the disk scan return its results without sending a non-`Sendable` model across an isolation
/// boundary — see `refreshStatus()`.
@MainActor
@Observable
public final class ModelStorageModel {
    /// The currently-applied storage path.
    public var appliedPath: String
    /// The in-progress edit shown in the field.
    public var draftPath: String
    /// Status metrics shown in the lower section.
    public var status: ModelStorageStatus
    /// The repos materialized in the applied folder, largest first. Empty until a folder is granted.
    public var installed: [ModelStore.InstalledModel] = []
    /// Set when a delete attempt failed — shown inline (typically "in use by a loaded package").
    public var deleteError: String?
    /// The repo a delete is in flight for, so the row can disable itself.
    public var deletingRepo: String?

    /// UserDefaults key under which the app-scope bookmark data is stored.
    private let bookmarkDefaultsKey: String
    /// The folder the user picked in this session (carries its security scope).
    private var selectedURL: URL?
    /// The URL we currently hold an access grant on (must be balanced on change).
    private var accessedURL: URL?

    /// Injected guarded deleter (MS-4). `nil` hides the delete affordance entirely.
    private let deleteHandler: WeightDeleteHandler?

    public init(
        path: String = "~/Library/Application Support/MLXEngine/Models",
        status: ModelStorageStatus = ModelStorageStatus(),
        bookmarkDefaultsKey: String = "MLXEngine.ModelStorageBookmark",
        deleteHandler: WeightDeleteHandler? = nil
    ) {
        self.appliedPath = path
        self.draftPath = path
        self.status = status
        self.bookmarkDefaultsKey = bookmarkDefaultsKey
        self.deleteHandler = deleteHandler
        restoreBookmark()
        refreshStatus()
    }

    /// Whether the panel should offer per-model deletion — only when the app wired a guarded
    /// deleter and we hold access to the folder.
    public var canDelete: Bool { deleteHandler != nil && resolvedModelsDirectory != nil }

    /// Delete one repo's weights through the injected engine handler, then re-scan.
    ///
    /// Failures are surfaced, not swallowed: the common one is the engine refusing while a resident
    /// package still draws on the repo, and the user needs to be told that rather than watch a row
    /// silently not disappear.
    public func delete(repo: String) async {
        guard let deleteHandler else { return }
        deleteError = nil
        deletingRepo = repo
        do {
            try await deleteHandler(repo)
        } catch {
            deleteError = "Couldn’t delete \(repo): \(error.localizedDescription)"
        }
        deletingRepo = nil
        refreshStatus()
    }

    /// The resolved, access-active models folder (from a restored or applied security-scoped
    /// bookmark), or `nil` if none has been chosen. Pass this into a package's configuration so
    /// weights materialize here rather than in the default cache.
    public var resolvedModelsDirectory: URL? { accessedURL }

    /// Re-scans the current models folder (call after weights are materialized) so Disk Used /
    /// Models Installed reflect new content.
    public func refresh() { refreshStatus() }

    /// Whether Apply should be enabled (there is a non-empty, changed draft).
    public var hasPendingChange: Bool {
        !draftPath.isEmpty && draftPath != appliedPath
    }

    /// Commits the draft path, persisting (and beginning access to) the chosen
    /// folder when one was picked this session.
    public func apply() {
        if let url = selectedURL {
            beginAccess(to: url)
            storeBookmark(for: url)
        }
        appliedPath = draftPath
        status.location = draftPath
        status.isReady = true
        refreshStatus()
    }

    public func reset() {
        draftPath = appliedPath
        selectedURL = nil
    }

    /// Presents a folder picker (macOS) and stores the selection as the draft.
    public func chooseFolder() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            selectedURL = url
            draftPath = url.path
        }
        #endif
    }

    // MARK: - Security-scoped bookmark persistence

    private func beginAccess(to url: URL) {
        #if canImport(AppKit)
        if let current = accessedURL, current != url {
            current.stopAccessingSecurityScopedResource()
        }
        if url.startAccessingSecurityScopedResource() {
            accessedURL = url
        }
        #endif
    }

    private func storeBookmark(for url: URL) {
        #if canImport(AppKit)
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: bookmarkDefaultsKey)
        } catch {
            // Entitlement missing or folder no longer reachable — the picker still
            // works for this session; we just can't persist the grant.
            NSLog("MLXEngineUI: failed to create app-scope bookmark: \(error)")
        }
        #endif
    }

    private func restoreBookmark() {
        #if canImport(AppKit)
        guard let data = UserDefaults.standard.data(forKey: bookmarkDefaultsKey) else { return }
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            beginAccess(to: url)
            selectedURL = url
            appliedPath = url.path
            draftPath = url.path
            status.location = url.path
            if isStale { storeBookmark(for: url) }
        } catch {
            NSLog("MLXEngineUI: failed to resolve app-scope bookmark: \(error)")
        }
        #endif
    }

    // MARK: - Live storage metrics

    /// Recomputes the STORAGE section from disk: volume free space (cheap, on the
    /// main actor) and the models folder's on-disk size (scanned off the main
    /// actor so a large folder never blocks the UI). `modelsInstalled` is left as
    /// a placeholder until the first model integration.
    public func refreshStatus() {
        // Free space — read from the chosen folder when we have access, otherwise
        // from the app's own container (always reachable under the sandbox); both
        // sit on the same volume, so the capacity figure is representative.
        let volumeURL = accessedURL ?? Self.defaultContainerURL()
        if let url = volumeURL,
           let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            status.freeSpace = Self.formatBytes(capacity)
        } else {
            status.freeSpace = "—"
        }

        // Disk used + model count — only meaningful for a folder we can actually read.
        guard let folder = accessedURL else {
            status.diskUsed = "—"
            status.modelsInstalled = 0
            status.lastScan = "—"
            installed = []
            return
        }
        // The walk runs off the main actor (a large store is deep), but only the folder URL goes out
        // and only Sendable results come back — the model itself never crosses an isolation
        // boundary, which is why this class is `@MainActor` rather than nonisolated-and-hopping.
        Task { [weak self] in
            let scan = await Task.detached { Self.scanFolder(at: folder) }.value
            let models = await Task.detached { ModelStore.installedModels(at: folder) }.value
            guard let self else { return }
            status.diskUsed = Self.formatBytes(scan.bytes)
            status.modelsInstalled = scan.models
            status.lastScan = "now"
            installed = models
        }
    }

    /// A row's size, formatted for display.
    public func formattedSize(of model: ModelStore.InstalledModel) -> String {
        Self.formatBytes(model.bytes)
    }

    /// The app's sandbox container Application Support directory (always reachable).
    nonisolated private static func defaultContainerURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    /// Filename of the per-package marker the engine/Model Manager writes at a package's
    /// root once its weights are materialized. Counting markers (rather
    /// than guessing at directory shapes) avoids over-counting multi-component pipelines and
    /// stays decoupled from Hugging Face cache internals. Interim: once `MLXServeCore`'s Model
    /// Manager exists, the UI should read its in-memory index instead of scanning disk.
    nonisolated public static let packageMarkerName = "mlx-package.json"

    /// Walks `url` once for the panel's Disk Used + Models Installed readings.
    ///
    /// Delegates to `ModelStore.usage(at:)` — the store owns its own layout and accounting,
    /// including the MS-4 symlink/hard-link dedup an HF cache tree requires.
    nonisolated private static func scanFolder(at url: URL) -> (bytes: Int64, models: Int) {
        let usage = ModelStore.usage(at: url)
        return (usage.bytes, usage.installedPackages)
    }

    /// Formats a byte count using the file-size convention (e.g. "12.4 GB").
    nonisolated private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - View

/// The reusable model-storage settings panel.
public struct ModelStorageSettingsView: View {
    @State private var model: ModelStorageModel
    /// The row awaiting confirmation. Deleting weights is irreversible and can mean a multi-GB
    /// re-download, so it is never one click.
    @State private var pendingDeletion: ModelStore.InstalledModel?

    /// Creates the panel with a fresh model using default demo values.
    public init() {
        _model = State(initialValue: ModelStorageModel())
    }

    /// Creates the panel bound to a caller-provided model.
    public init(model: ModelStorageModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Models")
                .font(MarqueeFont.pageTitle)
                .foregroundStyle(MarqueeColor.textPrimary)
                .padding(.bottom, 28)

            sectionHeader("MODEL STORAGE")
                .padding(.bottom, 12)

            storageGroup

            Text("Models are downloaded and cached in this folder.")
                .font(MarqueeFont.caption)
                .foregroundStyle(MarqueeColor.textMuted)
                .padding(.top, 12)

            HStack(spacing: 8) {
                Spacer()
                Button("Reset") { model.reset() }
                    .buttonStyle(MarqueeButtonStyle(.secondary))
                    .disabled(!model.hasPendingChange)
                Button("Apply") { model.apply() }
                    .buttonStyle(MarqueeButtonStyle(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.hasPendingChange)
            }
            .padding(.top, 16)

            HStack {
                sectionHeader("STORAGE")
                Spacer()
                readyPill
            }
            .padding(.top, 28)
            .padding(.bottom, 12)

            statusGroup

            if model.canDelete && !model.installed.isEmpty {
                sectionHeader("INSTALLED MODELS")
                    .padding(.top, 28)
                    .padding(.bottom, 12)

                installedGroup

                if let error = model.deleteError {
                    Text(error)
                        .font(MarqueeFont.caption)
                        .foregroundStyle(MarqueeColor.textPrimary)
                        .padding(.top, 10)
                }
            }
        }
        .padding(MarqueeMetric.panelPadding)
        .frame(width: 520, alignment: .leading)
        .background(MarqueeColor.bgPrimary)
        .confirmationDialog(
            pendingDeletion.map { "Delete \($0.repo)?" } ?? "",
            isPresented: Binding(get: { pendingDeletion != nil },
                                 set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            if let target = pendingDeletion {
                Button("Delete \(model.formattedSize(of: target))", role: .destructive) {
                    pendingDeletion = nil
                    Task { await model.delete(repo: target.repo) }
                }
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("The weights are removed from this folder. Using the model again re-downloads them.")
        }
    }

    // MARK: Sections

    private var storageGroup: some View {
        HStack(spacing: 12) {
            Text("Model Path")
                .font(MarqueeFont.bodyMedium)
                .foregroundStyle(MarqueeColor.textPrimary)
            Spacer()
            Text(model.draftPath)
                .font(MarqueeFont.body)
                .foregroundStyle(MarqueeColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: MarqueeMetric.controlHeight)
                .background(MarqueeColor.bgInput)
                .clipShape(RoundedRectangle(cornerRadius: MarqueeMetric.controlCornerRadius))
            Button("Choose…") { model.chooseFolder() }
                .buttonStyle(MarqueeButtonStyle(.secondary))
        }
        .padding(16)
        .background(MarqueeColor.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: MarqueeMetric.groupCornerRadius))
    }

    private var statusGroup: some View {
        VStack(spacing: 0) {
            statusRow("Location", model.status.location)
            divider
            statusRow("Disk Used", model.status.diskUsed)
            divider
            statusRow("Models Installed", "\(model.status.modelsInstalled)")
            divider
            statusRow("Free Space", model.status.freeSpace)
            divider
            statusRow("Last Scan", model.status.lastScan)
        }
        .background(MarqueeColor.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: MarqueeMetric.groupCornerRadius))
    }

    /// Per-model rows with a guarded delete (MS-4). Only rendered when the app injected a deleter,
    /// so the panel never offers an unguarded deletion path.
    private var installedGroup: some View {
        VStack(spacing: 0) {
            ForEach(Array(model.installed.enumerated()), id: \.element.id) { index, item in
                if index > 0 { divider }
                installedRow(item)
            }
        }
        .background(MarqueeColor.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: MarqueeMetric.groupCornerRadius))
    }

    private func installedRow(_ item: ModelStore.InstalledModel) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.repo)
                    .font(MarqueeFont.bodyMedium)
                    .foregroundStyle(MarqueeColor.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !item.hasMarker {
                    Text("incomplete — no install marker")
                        .font(MarqueeFont.caption)
                        .foregroundStyle(MarqueeColor.textMuted)
                }
            }
            Spacer()
            Text(model.formattedSize(of: item))
                .font(MarqueeFont.body)
                .foregroundStyle(MarqueeColor.textSecondary)
                .monospacedDigit()
            Button("Delete…") { pendingDeletion = item }
                .buttonStyle(MarqueeButtonStyle(.secondary))
                .disabled(model.deletingRepo != nil)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: MarqueeMetric.rowHeight)
        .padding(.vertical, item.hasMarker ? 0 : 6)
    }

    // MARK: Components

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(MarqueeFont.sectionHeader)
            .tracking(0.5)
            .foregroundStyle(MarqueeColor.textSecondary)
    }

    private func statusRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(MarqueeFont.bodyMedium)
                .foregroundStyle(MarqueeColor.textPrimary)
            Spacer()
            Text(value)
                .font(MarqueeFont.body)
                .foregroundStyle(MarqueeColor.textSecondary)
        }
        .padding(.horizontal, 16)
        .frame(height: MarqueeMetric.rowHeight)
    }

    private var divider: some View {
        Rectangle()
            .fill(MarqueeColor.bgElevated)
            .frame(height: 1)
            .padding(.horizontal, 16)
    }

    private var readyPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.status.isReady ? MarqueeColor.success : MarqueeColor.warning)
                .frame(width: 6, height: 6)
            Text(model.status.isReady ? "Ready" : "Scanning")
                .font(MarqueeFont.caption)
                .foregroundStyle(MarqueeColor.textPrimary)
        }
        .padding(.horizontal, 12)
        .frame(height: 22)
        .background(MarqueeColor.bgElevated)
        .clipShape(Capsule())
    }
}

// MARK: - Button style

/// Matches the Marquee button matrix: a prominent blue primary and an elevated
/// secondary, both dimming when pressed and fading when disabled.
public struct MarqueeButtonStyle: ButtonStyle {
    public enum Kind { case primary, secondary }

    private let kind: Kind
    @Environment(\.isEnabled) private var isEnabled

    public init(_ kind: Kind) { self.kind = kind }

    public func makeBody(configuration: Configuration) -> some View {
        let background = kind == .primary ? MarqueeColor.accentBlue : MarqueeColor.bgElevated
        let foreground = kind == .primary ? Color.white : MarqueeColor.textPrimary
        return configuration.label
            .font(MarqueeFont.bodyMedium)
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .frame(height: MarqueeMetric.controlHeight)
            .background(background.opacity(configuration.isPressed ? 0.7 : 1.0))
            .clipShape(RoundedRectangle(cornerRadius: MarqueeMetric.controlCornerRadius))
            .opacity(isEnabled ? 1.0 : 0.4)
    }
}

#Preview {
    ModelStorageSettingsView()
}
