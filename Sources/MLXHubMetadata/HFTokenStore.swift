// HFTokenStore.swift — the Hugging Face access token: ONE resolution chain, Keychain-backed.
//
// Why this exists (AB-A-0016 ask 3). The engine had two *different* token resolutions and no
// place a GUI app could put a token at all:
//
//   • `HubMetadataClient` read `HF_TOKEN` **once, at init** — so a token entered in Settings after
//     the engine was constructed never took effect, and a listing could authenticate while the
//     download that followed did not.
//   • `WeightMaterializer` read `HF_TOKEN`, then `~/.cache/huggingface/token`, per request.
//   • **Both fallbacks are dead inside an App Sandbox**: the container has its own home, so
//     `~/.cache/huggingface/token` resolves to a path the `huggingface-cli` never wrote, and no
//     sandboxed app inherits a shell's environment. A sandboxed consumer therefore had *no* way to
//     authenticate — which is not a cosmetic gap: gated repos 401, and anonymous hub traffic is
//     rate-limited per **shared source IP** rather than per user, which is exactly the throttling
//     that turns a 60 GB materialization into an afternoon.
//
// The Keychain is the one credential store that works in a sandbox, survives relaunch, and is not
// a plaintext file in a backup. This type owns it, and both hub call sites resolve through it **at
// request time** so a token entered mid-session takes effect on the next request.
//
// Resolution order — `HF_TOKEN` / `HUGGING_FACE_HUB_TOKEN` env, then Keychain, then the CLI token
// file. Env is first so a scheme variable or a CI secret is still an unambiguous override (and so
// every machine that works today keeps working, byte for byte). The Keychain outranks the CLI file
// because it is a deliberate act in *this* app, while the file is whatever `huggingface-cli login`
// last left behind.
//
// A Keychain that cannot be read is **never** an error to the caller: `resolve()` falls through to
// the next source and, finding nothing, returns nil — an anonymous download that would have
// succeeded must not fail because a credential lookup did. `save()` does propagate, because a
// settings UI that says "Saved" without saving is worse than an error.

import Foundation
import Security

// MARK: - Keychain seam

/// The Keychain operations `HFTokenStore` needs, injectable so the resolution chain is testable
/// without a real Keychain (which an unsigned test binary may not have — see `SystemKeychain`).
public protocol KeychainStoring: Sendable {
    /// The stored secret, or nil when the item is absent.
    func read(service: String, account: String) throws -> String?
    /// Create or replace the item.
    func write(_ value: String, service: String, account: String) throws
    /// Remove the item; absence is success, not an error.
    func delete(service: String, account: String) throws
}

/// A `SecItem` call that failed, carrying the raw `OSStatus` so a host can log something
/// actionable (`errSecMissingEntitlement` = -34018 is the one that actually shows up).
public struct KeychainError: Error, LocalizedError, Equatable {
    public let status: OSStatus
    public let operation: String

    public init(status: OSStatus, operation: String) {
        self.status = status
        self.operation = operation
    }

    public var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "Keychain \(operation) failed: \(detail) (\(status))."
    }
}

/// The live Keychain.
///
/// **Two keychains, deliberately.** Every item prefers the modern *data-protection* keychain
/// (`kSecUseDataProtectionKeychain`), which is what a signed, sandboxed app must use — items are
/// scoped to the app and there are no ACL prompts. That keychain requires an application-identifier
/// entitlement, so an unsigned or ad-hoc-signed binary (a `swift test` bundle, a dev CLI) is refused
/// and falls through to the legacy file-based keychain, which it can use. Shipping apps take the
/// first path; developers get a working second one. See `preferenceOrder` for the asymmetry that
/// makes searching *both* mandatory rather than tidy.
public struct SystemKeychain: KeychainStoring {

    public init() {}

    /// The two keychains, in preference order: modern first.
    ///
    /// Both are searched on read and cleared on delete, and this is not belt-and-braces — it is a
    /// bug the live round-trip test caught. The two `SecItem` calls fail *asymmetrically* in an
    /// unentitled process: `SecItemAdd` answers `errSecMissingEntitlement`, so a write falls
    /// through to the legacy keychain and succeeds there, while `SecItemCopyMatching` answers
    /// plain `errSecItemNotFound` — the data-protection keychain really is empty for this process.
    /// A read that treated "not found" as final therefore never looked where the write had landed,
    /// and the token silently vanished between Save and the next launch.
    private static let preferenceOrder = [true, false]

    /// Statuses that mean "look in the other keychain", not "the answer is no".
    private static func shouldTryNext(_ status: OSStatus) -> Bool {
        status == errSecItemNotFound || status == errSecMissingEntitlement
            || status == errSecNotAvailable || status == errSecInteractionNotAllowed
    }

    private static func base(service: String, account: String,
                             dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Omitted (not set to false) for the legacy pass: macOS defaults to the file keychain.
        if dataProtection { query[kSecUseDataProtectionKeychain as String] = true }
        return query
    }

    public func read(service: String, account: String) throws -> String? {
        var firstHardFailure: OSStatus?
        for dataProtection in Self.preferenceOrder {
            var query = Self.base(service: service, account: account, dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess {
                return (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
            }
            if !Self.shouldTryNext(status), firstHardFailure == nil { firstHardFailure = status }
        }
        // A real failure is reported; "neither keychain has it" is simply nil.
        if let firstHardFailure { throw KeychainError(status: firstHardFailure, operation: "read") }
        return nil
    }

    public func write(_ value: String, service: String, account: String) throws {
        let data = Data(value.utf8)
        var lastFailure: OSStatus = errSecSuccess
        for dataProtection in Self.preferenceOrder {
            let query = Self.base(service: service, account: account, dataProtection: dataProtection)
            // Update before add: it preserves the attributes the item was created with and avoids
            // the window in which a delete-then-add has removed the only copy.
            let updated = SecItemUpdate(query as CFDictionary,
                                        [kSecValueData as String: data] as CFDictionary)
            if updated == errSecSuccess { return }
            if updated != errSecItemNotFound, !Self.shouldTryNext(updated) {
                throw KeychainError(status: updated, operation: "write")
            }

            var insert = query
            insert[kSecValueData as String] = data
            // Materialization can run while the screen is locked; `WhenUnlocked` would turn a long
            // download into a failed one the moment the display sleeps.
            if dataProtection {
                insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            }
            let added = SecItemAdd(insert as CFDictionary, nil)
            if added == errSecSuccess { return }
            lastFailure = added
            guard Self.shouldTryNext(added) else {
                throw KeychainError(status: added, operation: "write")
            }
        }
        throw KeychainError(status: lastFailure, operation: "write")
    }

    public func delete(service: String, account: String) throws {
        // Both, unconditionally: leaving a copy in the keychain `read` falls back to would make
        // "Remove" look like it did nothing.
        var firstHardFailure: OSStatus?
        for dataProtection in Self.preferenceOrder {
            let status = SecItemDelete(
                Self.base(service: service, account: account,
                          dataProtection: dataProtection) as CFDictionary)
            if status == errSecSuccess || Self.shouldTryNext(status) { continue }
            if firstHardFailure == nil { firstHardFailure = status }
        }
        if let firstHardFailure {
            throw KeychainError(status: firstHardFailure, operation: "delete")
        }
    }
}

// MARK: - The token store

/// Resolves — and stores — the Hugging Face access token used for hub metadata and weight
/// downloads.
///
/// Production call sites use ``shared``; tests construct an instance with a fake keychain and a
/// fixed environment so the resolution order is provable offline.
public struct HFTokenStore: Sendable {

    /// Where a resolved token came from. Worth surfacing: when `HF_TOKEN` is exported, a token
    /// saved in Settings is silently outranked, and an app that cannot say so leaves the user
    /// re-typing a token that was never the problem.
    public enum Source: Sendable, Equatable {
        /// An environment variable, named.
        case environment(String)
        /// This app's Keychain item.
        case keychain
        /// The `huggingface-cli login` token file, at the path it was read from.
        case cliFile(URL)

        public var describing: String {
            switch self {
            case .environment(let name): return "\(name) environment variable"
            case .keychain: return "Keychain"
            case .cliFile(let url): return url.path
            }
        }
    }

    /// A token and where it came from. Deliberately **not** `Codable` and never printed raw:
    /// `description` masks the secret so an incidental log line cannot leak it.
    public struct Resolution: Sendable, Equatable, CustomStringConvertible {
        public let token: String
        public let source: Source

        public init(token: String, source: Source) {
            self.token = token
            self.source = source
        }

        public var description: String { "\(HFTokenStore.mask(token)) (\(source.describing))" }
    }

    public enum TokenError: Error, LocalizedError, Equatable {
        case empty
        case invalidCharacters

        public var errorDescription: String? {
            switch self {
            case .empty: return "The token is empty."
            case .invalidCharacters:
                return "The token contains characters that cannot appear in an HTTP header "
                    + "(whitespace, control characters, or non-ASCII). Paste the token only."
            }
        }
    }

    /// Keychain coordinates. `service` is bundle-neutral on purpose — the engine ships into several
    /// host apps and the token is the same hub credential in each.
    public static let service = "co.xocialize.mlxengine.huggingface"
    public static let account = "access-token"

    /// Checked in order. Both spellings are read by `huggingface_hub` itself.
    public static let environmentKeys = ["HF_TOKEN", "HUGGING_FACE_HUB_TOKEN"]

    private let keychain: any KeychainStoring
    private let environment: @Sendable () -> [String: String]
    private let cliTokenFileOverride: URL?

    /// - Parameters:
    ///   - keychain: the credential store; the default is the live one.
    ///   - environment: read **lazily**, per resolution — a shared instance constructed at process
    ///     start must not freeze a snapshot of the environment.
    ///   - cliTokenFileOverride: pins the CLI token file (tests); nil resolves the upstream
    ///     convention (`HF_TOKEN_PATH`, else `$HF_HOME/token`, else `~/.cache/huggingface/token`).
    public init(keychain: any KeychainStoring = SystemKeychain(),
                environment: @escaping @Sendable () -> [String: String]
                    = { ProcessInfo.processInfo.environment },
                cliTokenFileOverride: URL? = nil) {
        self.keychain = keychain
        self.environment = environment
        self.cliTokenFileOverride = cliTokenFileOverride
    }

    /// The process-wide store the engine's hub call sites resolve through.
    public static let shared = HFTokenStore()

    // MARK: resolution

    /// The token and its origin, or nil when no source has one.
    ///
    /// Never throws: a Keychain that cannot be read is treated as a Keychain with nothing in it.
    public func resolve() -> Resolution? {
        let env = environment()
        for key in Self.environmentKeys {
            if let raw = env[key], let token = try? Self.normalized(raw) {
                return Resolution(token: token, source: .environment(key))
            }
        }
        // `try?` on a throwing `String?` flattens to `String?`, which is exactly right here:
        // "the Keychain refused us" and "the Keychain is empty" both mean try the next source.
        if let token = try? keychainToken() {
            return Resolution(token: token, source: .keychain)
        }
        if let file = cliTokenFile(env),
           let raw = try? String(contentsOf: file, encoding: .utf8),
           let token = try? Self.normalized(raw) {
            return Resolution(token: token, source: .cliFile(file))
        }
        return nil
    }

    /// Just the token — what an `Authorization: Bearer` header needs.
    public func token() -> String? { resolve()?.token }

    /// The token as a provider closure, for the call sites that take one
    /// (`WeightMaterializer`, `HubMetadataClient`, `MLXServeEngine`). Resolving through a closure
    /// rather than a captured `String?` is the whole point: a token saved in Settings takes effect
    /// on the next request instead of the next launch.
    public func provider() -> @Sendable () -> String? {
        let store = self
        return { store.token() }
    }

    // MARK: keychain-backed storage

    /// The Keychain item's token, or nil when unset. Throws only on a real Keychain failure, so a
    /// settings UI can tell "no token" from "this process cannot reach the Keychain".
    public func keychainToken() throws -> String? {
        guard let raw = try keychain.read(service: Self.service, account: Self.account) else {
            return nil
        }
        return try? Self.normalized(raw)
    }

    /// Whether a token is stored in the Keychain, independent of what `resolve()` would pick.
    public var hasKeychainToken: Bool { (try? keychainToken()) != nil }

    /// Validate and store `raw` in the Keychain, replacing any existing token.
    /// - Throws: ``TokenError`` when the text cannot be a header value; ``KeychainError`` when the
    ///   Keychain refuses the write.
    @discardableResult
    public func save(_ raw: String) throws -> String {
        let token = try Self.normalized(raw)
        try keychain.write(token, service: Self.service, account: Self.account)
        return token
    }

    /// Remove the Keychain token. Does not touch the environment or the CLI file — `resolve()` may
    /// legitimately keep returning a token afterwards, and the UI should say so.
    public func clear() throws {
        try keychain.delete(service: Self.service, account: Self.account)
    }

    // MARK: helpers

    /// Trim, then reject anything that cannot ride in an `Authorization` header. A pasted token
    /// carrying a newline is the common case: `URLRequest.setValue` would drop or mangle the
    /// header and the download would 401 with nothing to look at.
    public static func normalized(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TokenError.empty }
        guard trimmed.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            throw TokenError.invalidCharacters
        }
        return trimmed
    }

    /// A loggable form: enough to tell two tokens apart, never enough to use one.
    public static func mask(_ token: String) -> String {
        guard token.count > 12 else { return String(repeating: "•", count: 8) }
        return "\(token.prefix(6))…\(token.suffix(4))"
    }

    /// The `huggingface-cli login` token file, following upstream's own precedence.
    /// **Sandboxed hosts: this resolves inside the container and will not be the user's file** —
    /// which is why the Keychain exists.
    private func cliTokenFile(_ env: [String: String]) -> URL? {
        if let override = cliTokenFileOverride { return override }
        if let path = env["HF_TOKEN_PATH"], !path.isEmpty { return URL(fileURLWithPath: path) }
        if let home = env["HF_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home).appendingPathComponent("token")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/token")
    }
}
