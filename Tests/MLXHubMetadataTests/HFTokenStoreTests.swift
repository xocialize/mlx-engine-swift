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

        private var readCount = 0
        /// How many times anything asked the Keychain — what the opt-out switch must keep at 0.
        var reads: Int { lock.lock(); defer { lock.unlock() }; return readCount }

        private func key(_ service: String, _ account: String) -> String { "\(service)|\(account)" }

        func read(service: String, account: String) throws -> String? {
            lock.lock(); readCount += 1; lock.unlock()
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

    // MARK: a Keychain read that would hang (AB-T-0203)

    /// A legacy keychain whose read blocks until `answer()` — an access prompt nobody has clicked.
    /// The data-protection keychain is empty, as it is for an unsigned binary.
    private final class PromptingLegacyKeychain: @unchecked Sendable {
        private let lock = NSLock()
        private let prompt = DispatchSemaphore(value: 0)
        private let finished = DispatchSemaphore(value: 0)
        private var legacyCalls = 0
        let found: String

        init(found: String) { self.found = found }

        var legacyReads: Int { lock.lock(); defer { lock.unlock() }; return legacyCalls }

        func copyMatching(_ service: String, _ account: String, _ dataProtection: Bool) -> (OSStatus, Data?) {
            guard !dataProtection else { return (errSecItemNotFound, nil) }
            lock.lock(); legacyCalls += 1; lock.unlock()
            prompt.wait()                                   // the dialog is on screen
            defer { finished.signal() }
            return (errSecSuccess, Data(found.utf8))
        }

        /// Someone clicks Allow; returns once the abandoned read has its answer.
        func answer() {
            prompt.signal()
            finished.wait()
        }

        func keychain(deadline: TimeInterval) -> SystemKeychain {
            SystemKeychain(legacyReadDeadline: deadline) { self.copyMatching($0, $1, $2) }
        }
    }

    func testAPromptedLegacyReadIsAbandonedAtTheDeadline() throws {
        let legacy = PromptingLegacyKeychain(found: "hf_late")
        let keychain = legacy.keychain(deadline: 0.2)
        defer { legacy.answer() }                           // release the thread the test parked

        let started = Date()
        XCTAssertNil(try keychain.read(service: "s", account: "a"), "unavailable, not an error")
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 0.2)
        XCTAssertLessThan(elapsed, 1.5, "the read must give up at its deadline, not wait on the prompt")
    }

    // One unanswered prompt at a time: a second read must not raise another behind it.
    func testAWaitingPromptIsNotStackedByTheNextRead() throws {
        let legacy = PromptingLegacyKeychain(found: "hf_late")
        let keychain = legacy.keychain(deadline: 0.2)
        defer { legacy.answer() }
        XCTAssertNil(try keychain.read(service: "s", account: "a"))

        let started = Date()
        XCTAssertNil(try keychain.read(service: "s", account: "a"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.15, "no second wait")
        XCTAssertEqual(legacy.legacyReads, 1)
    }

    // An Allow that comes after the deadline is not wasted: the next read uses it.
    func testALateAnswerIsUsedByTheNextRead() throws {
        let legacy = PromptingLegacyKeychain(found: "hf_late")
        let keychain = legacy.keychain(deadline: 0.2)
        XCTAssertNil(try keychain.read(service: "s", account: "a"))
        legacy.answer()
        // The parked thread stores its result just after the fake returns, so poll briefly. A read
        // made in between returns nil without starting another prompt (legacyReads stays 1).
        var late: String?
        for _ in 0..<100 where late == nil {
            late = try keychain.read(service: "s", account: "a")
            if late == nil { Thread.sleep(forTimeInterval: 0.01) }
        }
        XCTAssertEqual(late, "hf_late")
        XCTAssertEqual(legacy.legacyReads, 1)
    }

    // The task's acceptance, end to end: resolve() returns within the deadline with the next source.
    func testResolveFallsThroughAPromptToTheNextSourceInTime() throws {
        let legacy = PromptingLegacyKeychain(found: "hf_keychain_token")
        defer { legacy.answer() }
        let subject = HFTokenStore(keychain: legacy.keychain(deadline: 0.2),
                                   environment: { [:] },
                                   cliTokenFileOverride: try tokenFile("hf_cli_token"))
        let started = Date()
        XCTAssertEqual(subject.resolve()?.token, "hf_cli_token")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testAnUnpromptedLegacyReadIsUnaffected() throws {
        let keychain = SystemKeychain(legacyReadDeadline: 0.2) { _, _, dataProtection in
            dataProtection ? (errSecItemNotFound, nil) : (errSecSuccess, Data("hf_legacy".utf8))
        }
        XCTAssertEqual(try keychain.read(service: "s", account: "a"), "hf_legacy")
    }

    // MARK: the opt-out switch (AB-T-0203)

    func testTheKeychainSwitchKeepsResolveOffTheKeychain() throws {
        let keychain = FakeKeychain()
        try keychain.write("hf_keychain_token", service: HFTokenStore.service,
                           account: HFTokenStore.account)
        let file = try tokenFile("hf_cli_token")

        for off in ["0", "false", "NO", " off "] {
            let resolved = store(keychain: keychain,
                                 environment: [HFTokenStore.keychainSwitchKey: off],
                                 cliTokenFile: file).resolve()
            XCTAssertEqual(resolved?.token, "hf_cli_token", "switch value \(off)")
        }
        XCTAssertEqual(keychain.reads, 0, "the switch means the Keychain is never asked")

        // Any other value, or none, leaves the chain as it was.
        XCTAssertEqual(store(keychain: keychain, environment: [HFTokenStore.keychainSwitchKey: "1"],
                             cliTokenFile: file).resolve()?.token, "hf_keychain_token")
        // The environment still outranks everything, switch or not.
        XCTAssertEqual(store(keychain: keychain,
                             environment: ["HF_TOKEN": "hf_env", HFTokenStore.keychainSwitchKey: "0"],
                             cliTokenFile: file).resolve()?.token, "hf_env")
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

    /// The AB-T-0203 reproduction on the real Keychain. `/usr/bin/security` creates a legacy item
    /// (its ACL then trusts only that binary), and this unsigned test binary reads it, which raises
    /// macOS's access prompt. Before the fix the read blocked until someone answered; now it returns
    /// within the deadline. **Raises a real dialog**: run it with someone at the Mac —
    /// `MLXENGINE_LIVE_KEYCHAIN_PROMPT=1 swift test --filter LiveLegacyPrompt` — and answer Deny, or
    /// leave it; the test cleans up its item either way.
    func testLiveLegacyPromptIsBounded() throws {
        guard ProcessInfo.processInfo.environment["MLXENGINE_LIVE_KEYCHAIN_PROMPT"] == "1" else {
            throw XCTSkip("Set MLXENGINE_LIVE_KEYCHAIN_PROMPT=1 to raise a real Keychain prompt.")
        }
        let service = "co.xocialize.mlxengine.tests.prompt"
        let account = "ab-t-0203-\(UUID().uuidString)"
        XCTAssertEqual(try security("add-generic-password", "-s", service, "-a", account,
                                    "-w", "hf_prompt_probe"), 0)
        defer { _ = try? security("delete-generic-password", "-s", service, "-a", account) }

        let started = Date()
        let value = try SystemKeychain(legacyReadDeadline: 2).read(service: service, account: account)
        let elapsed = Date().timeIntervalSince(started)
        print("[AB-T-0203 live] read returned \(value == nil ? "nil (prompt unanswered)" : "the item") "
              + String(format: "after %.2f s", elapsed))
        XCTAssertLessThan(elapsed, 4, "the read must not wait on the prompt")
    }

    private func security(_ arguments: String...) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
