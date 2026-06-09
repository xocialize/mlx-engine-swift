//
//  EngineSettingsView.swift
//  MLXEngineUI
//
//  The shared engine settings surface: a sidebar (sections) + detail pane,
//  reusing the MarqueeStudio "macOS Settings" sidepanel design. Sections are
//  reusable engine-management panels (Model Storage, Web Search). App-specific
//  product UI does not belong here.
//

import SwiftUI
import MLXRetrievalKitContracts

// MARK: - Web Search settings model

@MainActor
@Observable
public final class WebSearchSettingsModel {
    public var enabled: Bool
    public var profile: RetrievalProfile
    /// Draft key being entered; the stored key is never surfaced back into the field.
    public var apiKeyDraft: String = ""
    public private(set) var hasStoredKey: Bool

    public init() {
        self.enabled = WebSearchPreferences.isEnabled
        self.profile = WebSearchPreferences.profile
        self.hasStoredKey = BraveKeyStore.hasKey
    }

    public func setEnabled(_ value: Bool) {
        enabled = value
        WebSearchPreferences.isEnabled = value
    }

    public func setProfile(_ value: RetrievalProfile) {
        profile = value
        WebSearchPreferences.profile = value
    }

    public func saveKey() {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        BraveKeyStore.save(trimmed)
        apiKeyDraft = ""
        hasStoredKey = BraveKeyStore.hasKey
    }

    public func clearKey() {
        BraveKeyStore.save("")
        apiKeyDraft = ""
        hasStoredKey = BraveKeyStore.hasKey
    }

    /// Whether grounding will actually run: enabled AND a key is present.
    public var isActive: Bool { enabled && hasStoredKey }
}

// MARK: - Engine settings (sidebar + detail)

public struct EngineSettingsView: View {
    enum SettingsSection: String, CaseIterable, Identifiable {
        case modelStorage = "Model Storage"
        case webSearch = "Web Search"
        var id: String { rawValue }
    }

    @State private var selection: SettingsSection = .modelStorage
    @State private var storage: ModelStorageModel
    @State private var webSearch: WebSearchSettingsModel

    public init(storage: ModelStorageModel) {
        _storage = State(initialValue: storage)
        _webSearch = State(initialValue: WebSearchSettingsModel())
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 200)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(MarqueeColor.bgSecondary)
            Rectangle().fill(MarqueeColor.bgElevated).frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(MarqueeColor.bgPrimary)
        }
        .frame(minWidth: 720, minHeight: 620)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsSection.allCases) { section in
                sidebarRow(section)
            }
            Spacer()
        }
        .padding(8)
    }

    private func sidebarRow(_ section: SettingsSection) -> some View {
        let isSelected = selection == section
        return Button {
            selection = section
        } label: {
            Text(section.rawValue)
                .font(MarqueeFont.bodyMedium)
                .foregroundStyle(isSelected ? Color.white : MarqueeColor.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(isSelected ? MarqueeColor.selectionBackground : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: MarqueeMetric.controlCornerRadius))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .modelStorage:
            ModelStorageSettingsView(model: storage)
        case .webSearch:
            WebSearchSettingsView(model: webSearch)
        }
    }
}

// MARK: - Web Search detail

public struct WebSearchSettingsView: View {
    @State private var model: WebSearchSettingsModel

    public init(model: WebSearchSettingsModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Web Search")
                .font(MarqueeFont.pageTitle)
                .foregroundStyle(MarqueeColor.textPrimary)
                .padding(.bottom, 28)

            sectionHeader("GROUNDING")
                .padding(.bottom, 12)

            group

            Text("Grounds answers in current web results via Brave Search. The key is stored "
                + "locally on this device.")
                .font(MarqueeFont.caption)
                .foregroundStyle(MarqueeColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            Spacer()
        }
        .padding(MarqueeMetric.panelPadding)
        .frame(width: 520, alignment: .leading)
    }

    private var group: some View {
        VStack(spacing: 0) {
            // Enable toggle
            HStack {
                Text("Enable web search")
                    .font(MarqueeFont.bodyMedium)
                    .foregroundStyle(MarqueeColor.textPrimary)
                Spacer()
                Toggle("", isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(MarqueeColor.accentBlue)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            divider

            // API key field
            HStack(spacing: 12) {
                Text("Brave API key")
                    .font(MarqueeFont.bodyMedium)
                    .foregroundStyle(MarqueeColor.textPrimary)
                Spacer()
                SecureField(model.hasStoredKey ? "•••• stored — enter to replace" : "Enter Brave API key",
                            text: $model.apiKeyDraft)
                    .textFieldStyle(.plain)
                    .font(MarqueeFont.body)
                    .foregroundStyle(MarqueeColor.textPrimary)
                    .frame(width: 200)
                    .padding(.horizontal, 10)
                    .frame(height: MarqueeMetric.controlHeight)
                    .background(MarqueeColor.bgInput)
                    .clipShape(RoundedRectangle(cornerRadius: MarqueeMetric.controlCornerRadius))
                    .onSubmit { model.saveKey() }
                Button("Save") { model.saveKey() }
                    .buttonStyle(MarqueeButtonStyle(.primary))
                    .disabled(model.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .frame(height: 65)

            divider

            // Depth picker
            HStack {
                Text("Depth")
                    .font(MarqueeFont.bodyMedium)
                    .foregroundStyle(MarqueeColor.textPrimary)
                Spacer()
                Picker("", selection: Binding(get: { model.profile }, set: { model.setProfile($0) })) {
                    ForEach(RetrievalProfile.allCases, id: \.self) { profile in
                        Text(profile.rawValue.capitalized).tag(profile)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 280)
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            divider

            // Status
            HStack(spacing: 6) {
                Circle()
                    .fill(model.isActive ? MarqueeColor.success
                          : (model.hasStoredKey ? MarqueeColor.warning : MarqueeColor.textMuted))
                    .frame(width: 6, height: 6)
                Text(statusText)
                    .font(MarqueeFont.caption)
                    .foregroundStyle(MarqueeColor.textSecondary)
                Spacer()
                if model.hasStoredKey {
                    Button("Clear key") { model.clearKey() }
                        .buttonStyle(MarqueeButtonStyle(.secondary))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
        }
        .background(MarqueeColor.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: MarqueeMetric.groupCornerRadius))
    }

    private var statusText: String {
        if model.isActive { return "Active — answers will be grounded" }
        if model.hasStoredKey { return "Key set · enable to activate" }
        return "No key — web search inactive"
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(MarqueeFont.sectionHeader)
            .tracking(0.5)
            .foregroundStyle(MarqueeColor.textSecondary)
    }

    private var divider: some View {
        Rectangle()
            .fill(MarqueeColor.bgElevated)
            .frame(height: 1)
            .padding(.horizontal, 16)
    }
}
