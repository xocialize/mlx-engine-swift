//
//  ModelStorageSettingsView.swift
//  MLXEngineUI
//
//  A reusable settings panel for managing where MLXEngine stores its models.
//  Adapted from the MarqueeStudio "Project Panel — Reusable" design and built
//  entirely from `MarqueeColor` / `MarqueeFont` tokens so it drops cleanly into
//  any consuming app's settings surface.
//

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

/// Backing state for `ModelStorageSettingsView`. Consuming apps can supply their
/// own instance to observe edits and react to Apply/Reset.
///
/// Persistence: the applied folder is stored as a **security-scoped app-scope
/// bookmark** (requires the `files.bookmarks.app-scope` and
/// `files.user-selected.read-write` entitlements in a sandboxed app). The bookmark
/// is resolved on init, so access to a previously-chosen folder survives relaunch.
@MainActor
@Observable
public final class ModelStorageModel {
    /// The currently-applied storage path.
    public var appliedPath: String
    /// The in-progress edit shown in the field.
    public var draftPath: String
    /// Status metrics shown in the lower section.
    public var status: ModelStorageStatus

    /// UserDefaults key under which the app-scope bookmark data is stored.
    private let bookmarkDefaultsKey: String
    /// The folder the user picked in this session (carries its security scope).
    private var selectedURL: URL?
    /// The URL we currently hold an access grant on (must be balanced on change).
    private var accessedURL: URL?

    public init(
        path: String = "~/Library/Application Support/MLXEngine/Models",
        status: ModelStorageStatus = ModelStorageStatus(),
        bookmarkDefaultsKey: String = "MLXEngine.ModelStorageBookmark"
    ) {
        self.appliedPath = path
        self.draftPath = path
        self.status = status
        self.bookmarkDefaultsKey = bookmarkDefaultsKey
        restoreBookmark()
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
            return
        }
        Task.detached { [weak self] in
            let scan = Self.scanFolder(at: folder)
            let formatted = Self.formatBytes(scan.bytes)
            await MainActor.run {
                guard let self else { return }
                self.status.diskUsed = formatted
                self.status.modelsInstalled = scan.models
                self.status.lastScan = "now"
            }
        }
    }

    /// The app's sandbox container Application Support directory (always reachable).
    nonisolated private static func defaultContainerURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    /// Filename of the per-package marker the engine/Model Manager writes at a package's
    /// root once its weights are materialized and SHA256-verified. Counting markers (rather
    /// than guessing at directory shapes) avoids over-counting multi-component pipelines and
    /// stays decoupled from Hugging Face cache internals. Interim: once `MLXServeCore`'s Model
    /// Manager exists, the UI should read its in-memory index instead of scanning disk.
    nonisolated public static let packageMarkerName = "mlx-package.json"

    /// Walks `url` once, summing on-disk allocated size of regular files and counting installed
    /// packages (files named `packageMarkerName`).
    nonisolated private static func scanFolder(at url: URL) -> (bytes: Int64, models: Int) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: nil
        ) else { return (0, 0) }

        var total: Int64 = 0
        var models = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            if fileURL.lastPathComponent == packageMarkerName { models += 1 }
            if let allocated = values.totalFileAllocatedSize {
                total += Int64(allocated)
            } else if let size = values.fileSize {
                total += Int64(size)
            }
        }
        return (total, models)
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
        }
        .padding(MarqueeMetric.panelPadding)
        .frame(width: 520, alignment: .leading)
        .background(MarqueeColor.bgPrimary)
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
