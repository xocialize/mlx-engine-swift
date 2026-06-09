//
//  WebSearchPreferences.swift
//  MLXRetrievalKitContracts
//
//  Shared persisted web-search settings (enabled flag + retrieval depth), so the
//  settings UI and the grounding consumer read the same UserDefaults keys.
//

import Foundation

public enum WebSearchPreferences {
    public static let enabledKey = "MLXEngine.WebSearchEnabled"
    public static let profileKey = "MLXEngine.WebSearchProfile"

    /// Whether grounding is on. (A key must also be present for retrieval to run.)
    public static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// The retrieval depth profile to use when grounding.
    public static var profile: RetrievalProfile {
        get {
            UserDefaults.standard.string(forKey: profileKey)
                .flatMap(RetrievalProfile.init(rawValue:)) ?? .conversational
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: profileKey) }
    }
}
