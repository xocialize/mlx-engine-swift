import XCTest
import Security
@testable import MLXHubMetadata

/// The Hugging Face token chain (AB-A-0016 ask 3 + the Keychain feature it implies).
///
/// The order is the whole contract — env, then Keychain, then the CLI token file — so these tests
/// pin each rung *and* every way the chain must refuse to break: a Keychain that cannot be read is
/// a Keychain with nothing in it, never a failed download.
final class HFTokenStoreTests: XCTestCase {

    // MARK: fixtures

    private final class FakeKeychain: KeychainStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: String] = [:]
        /// Set to make every operation fail, modelling an unentitled process.
        var failure: OSStatus?

        private func key(_ service: String, _ account: String) -> String { "\(service)|\(account)" }

        func read(service: String, account: String) throws -> String? {
            if let failure { throw KeychainError(status: failure, operation: "read") }
            lock.lock(); defer { lock.unlock() }
            return items[key(service, account)]
        }

        func write(_ value: String, service: String, account: String) throws {
            if let failure { throw KeychainError(status: failure, operation: "write") }
            lock.lock(); defer { lock.unlock() }
            items[key(service, account)] = value
        }

        func delete(service: String, account: String) throws {
            if let failure { throw KeychainError(status: failure, operation: "delete") }
            lock.lock(); defer { lock.unlock() }
            items[key(service, account)] = nil
        }
    }

    private func tokenFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hf-token-\(UUID().uuidString)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func store(keychain: FakeKeychain = FakeKeychain(),
                       environment: [String: String] = [:],
                       cliTokenFile: URL? = nil) -> HFTokenStore {
        HFTokenStore(keychain: keychain,
                     environment: { environment },
                     // A nil override would resolve the real ~/.cache/huggingface/token and make
                     // these tests depend on whoever last ran `huggingface-cli login`.
                     cliTokenFileOverride: cliTokenFile ?? URL(fileURLWithPath: "/nonexistent/token"))
    }

    // MARK: order

    func testEnvironmentOutranksEverythingElse() throws {
        let keychain = FakeKeychain()
        try keychain.write("hf_keychain_token", service: HFTokenStore.service,
                           account: HFTokenStore.account)
        let file = try tokenFile("hf_cli_token")

        let resolved = store(keychain: keychain,
                             environment: ["HF_TOKEN": "hf_env_token"],
                             cliTokenFile: file).resolve()

        XCTAssertEqual(resolved?.token, "hf_env_token")
        XCTAssertEqual(resolved?.source, .environment("HF_TOKEN"))
    }

    func testKeychainOutranksTheCLITokenFile() throws {
        let keychain = FakeKeychain()
        try keychain.write("hf_keychain_token", service: HFTokenStore.service,
                           account: HFTokenStore.account)
        let file = try tokenFile("hf_cli_token")

        let resolved = store(keychain: keychain, cliTokenFile: file).resolve()

        XCTAssertEqual(resolved?.token, "hf_keychain_token")
        XCTAssertEqual(resolved?.source, .keychain)
    }

    func testTheCLITokenFileIsTheLastResort() throws {
        let file = try tokenFile("hf_cli_token\n")
        let resolved = store(cliTokenFile: file).resolve()

        XCTAssertEqual(resolved?.token, "hf_cli_token", "the file's trailing newline must be trimmed")
        XCTAssertEqual(resolved?.source, .cliFile(file))
    }

    func testNoSourceResolvesToAnonymous() {
        XCTAssertNil(store().resolve())
        XCTAssertNil(store().token())
    }

    func testBothUpstreamEnvironmentSpellingsAreRead() {
        XCTAssertEqual(store(environment: ["HUGGING_FACE_HUB_TOKEN": "hf_b"]).resolve()?.token, "hf_b")
        // HF_TOKEN is upstream's primary and wins when both are set.
        XCTAssertEqual(
            store(environment: ["HF_TOKEN": "hf_a", "HUGGING_FACE_HUB_TOKEN": "hf_b"])
                .resolve()?.token,
            "hf_a")
    }

    // MARK: degradation

    func testAnUnreachableKeychainFallsThroughInsteadOfFailing() throws {
        let keychain = FakeKeychain()
        keychain.failure = errSecMissingEntitlement       // -34018, the unsigned-binary case
        let file = try tokenFile("hf_cli_token")

        let subject = store(keychain: keychain, cliTokenFile: file)

        // The point: an anonymous-or-file download that would have worked must not be broken by a
        // credential lookup that could not run.
        XCTAssertEqual(subject.resolve()?.token, "hf_cli_token")
        XCTAssertFalse(subject.hasKeychainToken)
    }

    func testSaveSurfacesAKeychainFailureRatherThanClaimingSuccess() {
        let keychain = FakeKeychain()
        keychain.failure = errSecMissingEntitlement
        XCTAssertThrowsError(try store(keychain: keychain).save("hf_token")) { error in
            XCTAssertEqual((error as? KeychainError)?.status, errSecMissingEntitlement)
        }
    }

    // MARK: storage

    func testSaveTrimsAndClearRemoves() throws {
        let keychain = FakeKeychain()
        let subject = store(keychain: keychain)

        try subject.save("  hf_padded_token\n")
        XCTAssertEqual(subject.resolve()?.token, "hf_padded_token")
        XCTAssertTrue(subject.hasKeychainToken)

        try subject.clear()
        XCTAssertNil(subject.resolve())
        XCTAssertFalse(subject.hasKeychainToken)
    }

    func testClearLeavesTheEnvironmentAlone() throws {
        let subject = store(environment: ["HF_TOKEN": "hf_env_token"])
        try subject.clear()
        // Removing the saved token does not make the engine anonymous when a variable is exported —
        // the settings panel has to be able to say so.
        XCTAssertEqual(subject.resolve()?.token, "hf_env_token")
    }

    // MARK: validation

    func testATokenThatCannotRideInAHeaderIsRefused() {
        let subject = store()
        for bad in ["", "   ", "hf_token with spaces", "hf_token\nX-Injected: 1", "hf_tökén"] {
            XCTAssertThrowsError(try subject.save(bad), "should refuse \(bad.debugDescription)")
        }
        // And the two refusals are distinguishable, because the settings panel says different
        // things for "you pasted nothing" and "you pasted the whole curl command".
        XCTAssertThrowsError(try HFTokenStore.normalized("   ")) {
            XCTAssertEqual($0 as? HFTokenStore.TokenError, .empty)
        }
        XCTAssertThrowsError(try HFTokenStore.normalized("hf_a b")) {
            XCTAssertEqual($0 as? HFTokenStore.TokenError, .invalidCharacters)
        }
        XCTAssertEqual(try HFTokenStore.normalized(" hf_ok\n"), "hf_ok")
    }

    func testMaskingNeverRevealsTheToken() {
        let token = "hf_abcdefghijklmnopqrstuvwxyz"
        let masked = HFTokenStore.mask(token)
        XCTAssertFalse(masked.contains(token))
        XCTAssertTrue(masked.hasPrefix("hf_abc"))
        // A short token gives up nothing at all.
        XCTAssertEqual(HFTokenStore.mask("hf_short"), "••••••••")
        // The `Resolution` description is what an incidental log line would print.
        let described = HFTokenStore.Resolution(token: token, source: .keychain).description
        XCTAssertFalse(described.contains(token))
        XCTAssertTrue(described.contains("Keychain"))
    }

    // MARK: the provider seam

    func testTheProviderReResolvesRatherThanCapturingAValue() throws {
        let keychain = FakeKeychain()
        let subject = store(keychain: keychain)
        let provider = subject.provider()

        XCTAssertNil(provider(), "no token yet")
        try subject.save("hf_entered_in_settings")
        // The reason this is a closure: a token entered mid-session has to take effect on the next
        // request, not the next launch.
        XCTAssertEqual(provider(), "hf_entered_in_settings")
    }

    // MARK: the real Keychain — opt-in

    /// Round-trips through the actual `SecItem` API. Skipped by default: an unsigned test binary
    /// may be refused the data-protection keychain, and on a developer's Mac this writes a real
    /// item. Run with `MLXENGINE_LIVE_KEYCHAIN=1 swift test --filter LiveKeychain`.
    func testLiveKeychainRoundTrip() throws {
        guard ProcessInfo.processInfo.environment["MLXENGINE_LIVE_KEYCHAIN"] == "1" else {
            throw XCTSkip("Set MLXENGINE_LIVE_KEYCHAIN=1 to exercise the real Keychain.")
        }
        let keychain = SystemKeychain()
        let service = "co.xocialize.mlxengine.tests"
        let account = "round-trip-\(UUID().uuidString)"

        XCTAssertNil(try keychain.read(service: service, account: account))
        try keychain.write("hf_live_value", service: service, account: account)
        XCTAssertEqual(try keychain.read(service: service, account: account), "hf_live_value")
        try keychain.write("hf_replaced", service: service, account: account)
        XCTAssertEqual(try keychain.read(service: service, account: account), "hf_replaced")
        try keychain.delete(service: service, account: account)
        XCTAssertNil(try keychain.read(service: service, account: account))
        // Deleting what is not there is success, not an error.
        XCTAssertNoThrow(try keychain.delete(service: service, account: account))
    }
}
