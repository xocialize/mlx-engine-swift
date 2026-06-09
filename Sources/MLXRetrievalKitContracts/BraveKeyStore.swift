//
//  BraveKeyStore.swift
//  MLXRetrievalKitContracts
//
//  Resolves the Brave Search API key. Reads, in order: the `BRAVE_API_KEY`
//  environment variable (handy for dev via the Xcode scheme), then UserDefaults
//  (set from a settings UI). Lives in the Foundation-only contracts so both the
//  settings UI (MLXEngineUI) and the RetrievalService read/write the same key.
//
//  Plaintext in prefs is acceptable for a dev / bring-your-own-key story; the
//  Keychain is the production hardening step.
//

import Foundation

public enum BraveKeyStore {
    public static let defaultsKey = "MLXEngine.BraveAPIKey"
    public static let environmentKey = "BRAVE_API_KEY"

    public static func load() -> String? {
        if let env = ProcessInfo.processInfo.environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }
        let stored = UserDefaults.standard.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (stored?.isEmpty == false) ? stored : nil
    }

    public static func save(_ value: String) {
        UserDefaults.standard.set(
            value.trimmingCharacters(in: .whitespacesAndNewlines), forKey: defaultsKey)
    }

    public static var hasKey: Bool { load() != nil }
}
