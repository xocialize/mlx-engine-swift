//
//  HuggingFaceSettingsView.swift
//  MLXEngineUI
//
//  The Hugging Face access-token panel. Companion to `ModelStorageSettingsView`: storage says
//  *where* weights land, this says *who* is asking for them.
//
//  Why a sandboxed app needs it. The engine resolves a token from three places — the `HF_TOKEN`
//  environment variable, this app's Keychain, and the `huggingface-cli` token file — and inside an
//  App Sandbox the first and third are both dead: no shell environment is inherited, and the
//  container has its own home so `~/.cache/huggingface/token` is a path the CLI never wrote. The
//  Keychain is the only one of the three that works, which makes this panel the *only* way a
//  shipped app can reach a gated repo or get a per-account rate limit instead of the anonymous
//  per-source-IP one.
//
//  The panel deliberately reports which source WON. A user who has `HF_TOKEN` exported and saves a
//  different token here would otherwise watch the saved one appear to do nothing.
//

import SwiftUI
import MLXHubMetadata

// MARK: - Model

@MainActor
@Observable
public final class HFTokenSettingsModel {

    public enum Verification: Equatable {
        case idle
        case verifying
        /// The hub confirmed the token, naming the account it belongs to.
        case verified(String)
        case failed(String)
    }

    /// The token being entered. A stored token is never read back into the field.
    public var draft: String = ""
    /// What the engine would use right now, and from where.
    public private(set) var resolved: HFTokenStore.Resolution?
    /// Whether a token specifically lives in this app's Keychain (independent of what wins).
    public private(set) var hasKeychainToken: Bool = false
    public private(set) var verification: Verification = .idle
    /// The last save/clear failure, if any — a Keychain that refuses a write must say so rather
    /// than let the panel claim success.
    public private(set) var storageError: String?

    private let store: HFTokenStore
    private let verifier: @Sendable (String) async throws -> HubIdentity

    /// - Parameters:
    ///   - store: the token store; the default is the one the engine resolves through.
    ///   - verifier: checks a token against the hub. Injectable so a host that must not make
    ///     network calls from its settings window can substitute its own (or a no-op).
    public init(store: HFTokenStore = .shared,
                verifier: @escaping @Sendable (String) async throws -> HubIdentity = { token in
                    try await HubMetadataClient().whoami(token: token)
                }) {
        self.store = store
        self.verifier = verifier
        refresh()
    }

    public func refresh() {
        resolved = store.resolve()
        hasKeychainToken = store.hasKeychainToken
    }

    public func save() {
        storageError = nil
        verification = .idle
        do {
            try store.save(draft)
            draft = ""
            refresh()
        } catch {
            storageError = error.localizedDescription
        }
    }

    public func clear() {
        storageError = nil
        verification = .idle
        do {
            try store.clear()
            draft = ""
            refresh()
        } catch {
            storageError = error.localizedDescription
        }
    }

    /// Ask the hub who the token belongs to. Checking here — rather than discovering it 40 minutes
    /// into a materialization — is the whole point: a wrong token and a gated repo both surface as
    /// the same 401 on a file the user never sees named.
    public func verify() async {
        let candidate = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = candidate.isEmpty ? resolved?.token : candidate
        guard let token else {
            verification = .failed("No token to verify.")
            return
        }
        verification = .verifying
        do {
            let identity = try await verifier(token)
            verification = .verified(identity.name)
        } catch HubMetadataError.unauthorized {
            verification = .failed("The hub rejected this token (expired, revoked, or wrong account).")
        } catch {
            verification = .failed(error.localizedDescription)
        }
    }

    /// True when an environment variable is outranking a token saved here — the one state where
    /// saving a token appears to do nothing at all.
    public var environmentShadowsKeychain: Bool {
        guard hasKeychainToken, let resolved else { return false }
        if case .environment = resolved.source { return true }
        return false
    }

    public var statusText: String {
        guard let resolved else { return "No token — downloads run anonymously" }
        switch resolved.source {
        case .keychain: return "Stored in this app's Keychain"
        case .environment(let name):
            return hasKeychainToken
                ? "\(name) is set and overrides the saved token"
                : "Using the \(name) environment variable"
        case .cliFile(let url): return "Using \(url.path)"
        }
    }
}

// MARK: - View

public struct HuggingFaceSettingsView: View {
    @State private var model: HFTokenSettingsModel

    public init(model: HFTokenSettingsModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Hugging Face")
                .font(MarqueeFont.pageTitle)
                .foregroundStyle(MarqueeColor.textPrimary)
                .padding(.bottom, 28)

            sectionHeader("ACCESS TOKEN")
                .padding(.bottom, 12)

            group

            Text("A token lets the engine download gated and private repositories, and lifts hub "
                + "rate limits from the shared anonymous pool to your own account. It is stored in "
                + "this Mac's Keychain and sent only to huggingface.co.")
                .font(MarqueeFont.caption)
                .foregroundStyle(MarqueeColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            if model.environmentShadowsKeychain {
                Text("The environment variable wins while it is set — unset it to use the saved "
                    + "token.")
                    .font(MarqueeFont.caption)
                    .foregroundStyle(MarqueeColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }

            if let storageError = model.storageError {
                Text(storageError)
                    .font(MarqueeFont.caption)
                    .foregroundStyle(MarqueeColor.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }

            Spacer()
        }
        .padding(MarqueeMetric.panelPadding)
        .frame(width: MarqueeMetric.panelWidth, alignment: .leading)
        .onAppear { model.refresh() }
    }

    private var group: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Token")
                    .font(MarqueeFont.bodyMedium)
                    .foregroundStyle(MarqueeColor.textPrimary)
                Spacer()
                SecureField(model.hasKeychainToken ? "•••• stored — enter to replace"
                                                   : "Paste a Hugging Face access token",
                            text: $model.draft)
                    .textFieldStyle(.plain)
                    .font(MarqueeFont.body)
                    .foregroundStyle(MarqueeColor.textPrimary)
                    .frame(width: 200)
                    .padding(.horizontal, 10)
                    .frame(height: MarqueeMetric.controlHeight)
                    .background(MarqueeColor.bgInput)
                    .clipShape(RoundedRectangle(cornerRadius: MarqueeMetric.controlCornerRadius))
                    .onSubmit { model.save() }
                Button("Save") { model.save() }
                    .buttonStyle(MarqueeButtonStyle(.primary))
                    .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .frame(height: 65)

            divider

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(model.statusText)
                    .font(MarqueeFont.caption)
                    .foregroundStyle(MarqueeColor.textSecondary)
                Spacer()
                Button("Verify") { Task { await model.verify() } }
                    .buttonStyle(MarqueeButtonStyle(.secondary))
                    .disabled(model.verification == .verifying
                              || (model.resolved == nil
                                  && model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                if model.hasKeychainToken {
                    Button("Remove") { model.clear() }
                        .buttonStyle(MarqueeButtonStyle(.secondary))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 52)

            if verificationText != nil {
                divider
                HStack(spacing: 6) {
                    Text(verificationText ?? "")
                        .font(MarqueeFont.caption)
                        .foregroundStyle(verificationColor)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 40)
            }
        }
        .background(MarqueeColor.bgSecondary)
        .clipShape(RoundedRectangle(cornerRadius: MarqueeMetric.groupCornerRadius))
    }

    private var statusColor: Color {
        guard let resolved = model.resolved else { return MarqueeColor.textMuted }
        if case .keychain = resolved.source { return MarqueeColor.success }
        return model.environmentShadowsKeychain ? MarqueeColor.warning : MarqueeColor.success
    }

    private var verificationText: String? {
        switch model.verification {
        case .idle: return nil
        case .verifying: return "Checking with huggingface.co…"
        case .verified(let name): return "Verified — signed in as \(name)."
        case .failed(let message): return message
        }
    }

    private var verificationColor: Color {
        switch model.verification {
        case .verified: return MarqueeColor.success
        case .failed: return MarqueeColor.error
        default: return MarqueeColor.textSecondary
        }
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
