import CryptoKit
import XCTest

@testable import Termo

@MainActor
final class AppPasswordTests: XCTestCase {
    private let password = "我的 Termo 密码!2026"

    private func legacyRecord(_ pin: String) -> String {
        let salt = "test-legacy-salt"
        return salt + ":"
            + SHA256.hash(data: Data((salt + pin).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func withManager(_ body: (AppLockManager, () -> String?) async throws -> Void) async throws {
        let domain = "termo-password-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        var record: String?
        let manager = AppLockManager(
            defaults: defaults,
            credentials: .init(
                read: { record }, write: { record = $0 }))
        try await body(manager, { record })
    }

    func testUnicodePasswordAndWrongPassword() throws {
        let record = try AppPasswordRecord.make(password)
        XCTAssertTrue(AppPasswordRecord.verify(password, record: record))
        XCTAssertFalse(AppPasswordRecord.verify(password + "!", record: record))
        XCTAssertFalse(record.contains(password))
        XCTAssertNotEqual(record, try AppPasswordRecord.make(password))
    }

    func testLegacyPinAndMalformedRecords() {
        let record = legacyRecord("123456")
        XCTAssertTrue(AppPasswordRecord.isLegacy(record))
        XCTAssertTrue(AppPasswordRecord.verify("123456", record: record))
        XCTAssertFalse(AppPasswordRecord.verify("000000", record: record))
        XCTAssertFalse(AppPasswordRecord.verify(password, record: "master-v1:not-base64"))
        XCTAssertFalse(AppPasswordRecord.verify(password, record: "broken"))
    }

    func testNewPasswordRejectsShortAndNullInputs() {
        XCTAssertThrowsError(try AppPasswordRecord.make("123456"))
        XCTAssertThrowsError(try AppPasswordRecord.make("12345678\0suffix"))
        XCTAssertThrowsError(try AppPasswordRecord.make("12345678\nline"))
    }

    func testLockClearsSharedPasswordAndBiometricStyleUnlockDoesNotRestoreIt() async throws {
        try await withManager { manager, _ in
            try await manager.setMasterPassword(self.password, currentPassword: "")
            manager.setEnabled(true)
            XCTAssertEqual(manager.masterPassword, self.password)
            manager.lock()
            XCTAssertTrue(manager.isLocked)
            XCTAssertNil(manager.masterPassword)
            manager.unlock()
            XCTAssertNil(manager.masterPassword)
            let valid = await manager.verifyPassword(self.password)
            XCTAssertTrue(valid)
            XCTAssertEqual(manager.masterPassword, self.password)
        }
    }

    func testChangingPasswordRequiresCurrentPassword() async throws {
        try await withManager { manager, read in
            try await manager.setMasterPassword(self.password, currentPassword: "")
            let original = read()
            do {
                try await manager.setMasterPassword("replacement123!", currentPassword: "wrong")
                XCTFail("Must not replace existing password")
            } catch {}
            XCTAssertEqual(read(), original)
            try await manager.setMasterPassword("replacement123!", currentPassword: self.password)
            XCTAssertEqual(manager.masterPassword, "replacement123!")
            XCTAssertFalse(AppPasswordRecord.verify(self.password, record: read()!))
        }
    }

    func testLegacyUpgradeRequiresPinAndPreservesFailedWrites() async throws {
        let original = legacyRecord("123456")
        let domain = "termo-password-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let manager = AppLockManager(
            defaults: defaults,
            credentials: .init(
                read: { original }, write: { _ in throw AppPasswordError.keychain(-1) }))
        let valid = await manager.verifyPassword("123456")
        XCTAssertTrue(valid)
        XCTAssertNil(manager.masterPassword)
        do {
            try await manager.setMasterPassword(password, currentPassword: "123456")
            XCTFail("Must report storage failure")
        } catch {}
        XCTAssertTrue(manager.usesLegacyPin)
        XCTAssertNil(manager.masterPassword)
    }

    func testLegacyPinUpgradeAndLockedPasswordChange() async throws {
        var record = legacyRecord("123456")
        let domain = "termo-password-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let manager = AppLockManager(
            defaults: defaults,
            credentials: .init(
                read: { record }, write: { record = $0 }))
        try await manager.setMasterPassword(password, currentPassword: "123456")
        XCTAssertFalse(manager.usesLegacyPin)
        XCTAssertTrue(manager.hasMasterPassword)
        XCTAssertTrue(AppPasswordRecord.verify(password, record: record))
        XCTAssertFalse(AppPasswordRecord.verify("123456", record: record))
        manager.setEnabled(true)
        let generation = manager.sessionGeneration
        manager.lock()
        XCTAssertGreaterThan(manager.sessionGeneration, generation)
        XCTAssertNil(manager.masterPassword)
        do {
            try await manager.setMasterPassword("replacement123!", currentPassword: password)
            XCTFail("Cannot change password while locked")
        } catch {}
    }

    func testBackupAndUnlockUseSameMasterPassword() throws {
        let plain = Data("sample backup".utf8)
        let record = try AppPasswordRecord.make(password)
        let encrypted = try SyncCrypto.encrypt(plain, password: password)
        XCTAssertTrue(AppPasswordRecord.verify(password, record: record))
        XCTAssertEqual(try SyncCrypto.decrypt(encrypted, password: password), plain)
        XCTAssertFalse(AppPasswordRecord.verify("different-password", record: record))
        XCTAssertThrowsError(try SyncCrypto.decrypt(encrypted, password: "different-password"))
    }

    func testRepeatedUIReadsDoNotReopenKeychain() async throws {
        let domain = "termo-password-cache-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        var reads = 0
        var record = try AppPasswordRecord.make(password)
        let manager = AppLockManager(defaults: defaults, credentials: .init(
            read: { reads += 1; return record }, write: { record = $0 }))
        for _ in 0..<50 {
            XCTAssertTrue(manager.hasPin)
            XCTAssertTrue(manager.hasMasterPassword)
            XCTAssertFalse(manager.usesLegacyPin)
        }
        let valid = await manager.verifyPassword(password)
        XCTAssertTrue(valid)
        XCTAssertEqual(reads, 1)
        try await manager.setMasterPassword("updated-password!", currentPassword: password)
        let updated = await manager.verifyPassword("updated-password!")
        XCTAssertTrue(updated)
        XCTAssertEqual(reads, 1)
    }

    func testDeniedKeychainReadKeepsLockedAndOnlyRetriesExplicitVerification() async throws {
        let domain = "termo-password-denied-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "applock.enabled")
        var reads = 0
        var denied = true
        let record = try AppPasswordRecord.make(password)
        let manager = AppLockManager(defaults: defaults, credentials: .init(
            read: {
                reads += 1
                if denied { throw AppPasswordError.readKeychain(-25293) }
                return record
            }, write: { _ in XCTFail("Must not replace unreadable password") }))
        XCTAssertTrue(manager.isLocked)
        XCTAssertNotNil(manager.credentialError)
        for _ in 0..<20 { XCTAssertTrue(manager.hasPin); XCTAssertTrue(manager.hasMasterPassword) }
        XCTAssertEqual(reads, 1)
        let rejected = await manager.verifyPassword(password)
        XCTAssertFalse(rejected)
        XCTAssertTrue(manager.isLocked)
        XCTAssertEqual(reads, 2)
        denied = false
        let valid = await manager.verifyPassword(password)
        XCTAssertTrue(valid)
        XCTAssertNil(manager.credentialError)
        XCTAssertEqual(reads, 3)
    }

    func testUnknownCredentialErrorsAreNotShownVerbatimOnLockScreen() {
        let domain = "termo-password-unknown-error-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "applock.enabled")
        let internalError = NSError(domain: "LocalAuthentication", code: 404, userInfo: [
            NSLocalizedDescriptionKey: "loca not found",
        ])

        let manager = AppLockManager(defaults: defaults, credentials: .init(
            read: { throw internalError }, write: { _ in }))

        XCTAssertEqual(
            manager.credentialError,
            String(
                localized: "无法访问主密码，请检查系统钥匙串后重试",
                bundle: AppSettings.localizationBundle,
                locale: AppSettings.activeLocale))
        XCTAssertFalse(manager.credentialError?.contains("loca not found") ?? true)
    }
}

final class AppLanguageTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let domain = "AppLanguageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        return (defaults, domain)
    }

    func testStoredEnglishResolvesToEnglishLocale() {
        let (defaults, domain) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(AppLanguage.en.rawValue, forKey: "appLanguage")

        XCTAssertEqual(AppSettings.storedLanguage(defaults: defaults), .en)
        XCTAssertEqual(AppLanguage.en.locale.identifier, "en")
        XCTAssertNil(defaults.persistentDomain(forName: domain)?["AppleLanguages"])
    }

    func testMissingLanguageDefaultsToSystem() {
        let (defaults, domain) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }

        XCTAssertEqual(AppSettings.storedLanguage(defaults: defaults), .system)
    }

    func testLegacyAppleLanguagesOverrideMigratesOnceToSystem() {
        let (defaults, domain) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(AppLanguage.en.rawValue, forKey: "appLanguage")
        defaults.set(["en"], forKey: "AppleLanguages")

        XCTAssertTrue(AppSettings.migrateLegacyLanguageOverride(defaults: defaults, appDomain: domain))
        XCTAssertEqual(AppSettings.storedLanguage(defaults: defaults), .system)
        XCTAssertNil(defaults.persistentDomain(forName: domain)?["AppleLanguages"])

        defaults.set(AppLanguage.en.rawValue, forKey: "appLanguage")
        XCTAssertFalse(AppSettings.migrateLegacyLanguageOverride(defaults: defaults, appDomain: domain))
        XCTAssertEqual(AppSettings.storedLanguage(defaults: defaults), .en)
    }

    func testSystemLanguageUsesAutoUpdatingLocaleWithoutMutatingAppleLanguages() {
        let (defaults, domain) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(AppLanguage.system.rawValue, forKey: "appLanguage")
        XCTAssertEqual(AppSettings.storedLanguage(defaults: defaults), .system)
        XCTAssertEqual(AppLanguage.system.locale, .autoupdatingCurrent)
        XCTAssertNil(defaults.persistentDomain(forName: domain)?["AppleLanguages"])
    }

    func testLocaleSelectionUsesTheNewLanguageValueDirectly() {
        XCTAssertEqual(
            AppSettings.locale(for: .system, preferredLanguages: ["zh-Hans-CN", "en"]).identifier,
            "zh-Hans-CN")
        XCTAssertEqual(AppSettings.locale(for: .en).identifier, "en")
        XCTAssertEqual(AppSettings.locale(for: .zh).identifier, "zh-Hans")
    }

    func testSystemBundleUsesMacOSPreferredLanguageOrder() {
        let chinese = AppSettings.localizationBundle(
            for: .system, preferredLanguages: ["zh-Hans-CN", "en"])
        XCTAssertEqual(
            String(localized: "启动行为", bundle: chinese, locale: Locale(identifier: "zh-Hans-CN")),
            "启动行为")

        let english = AppSettings.localizationBundle(
            for: .system, preferredLanguages: ["en-US", "zh-Hans"])
        XCTAssertEqual(
            String(localized: "启动行为", bundle: english, locale: Locale(identifier: "en-US")),
            "Startup Behavior")
    }

    func testCriticalSettingsStringsHaveEnglishTranslations() {
        let english = Locale(identifier: "en")
        let bundle = AppSettings.localizationBundle(for: .en)
        XCTAssertEqual(String(localized: "安全", bundle: bundle, locale: english), "Security")
        XCTAssertEqual(String(localized: "启动行为", bundle: bundle, locale: english), "Startup Behavior")
        XCTAssertEqual(String(localized: "上下文容量", bundle: bundle, locale: english), "Context Window")
        XCTAssertEqual(String(localized: "同步内容", bundle: bundle, locale: english), "Synced Content")
        XCTAssertEqual(String(localized: "主机与密码", bundle: bundle, locale: english), "Hosts and Passwords")
        XCTAssertEqual(
            String(localized: "界面语言，选择后立即应用", bundle: bundle, locale: english),
            "Interface language; changes apply immediately.")
    }

    func testSSHKeySheetsHaveEnglishTranslations() {
        let english = Locale(identifier: "en")
        let bundle = AppSettings.localizationBundle(for: .en)
        let keychainStatus = String(Int32(-25293))
        XCTAssertEqual(
            String(localized: "生成 SSH 密钥", bundle: bundle, locale: english),
            "Generate SSH Key")
        XCTAssertEqual(
            String(localized: "创建一对用于服务器登录的公钥和私钥", bundle: bundle, locale: english),
            "Create a public/private key pair for server login")
        XCTAssertEqual(
            String(localized: "密钥名称", bundle: bundle, locale: english),
            "Key Name")
        XCTAssertEqual(
            String(localized: "生成密钥", bundle: bundle, locale: english),
            "Generate Key")
        XCTAssertEqual(
            String(localized: "部署公钥", bundle: bundle, locale: english),
            "Deploy Public Key")
        XCTAssertEqual(
            String(
                localized: "无法将私钥保存到系统钥匙串（错误 \(keychainStatus)）。请确认已允许 Termo 访问钥匙串后重试。",
                bundle: bundle,
                locale: english),
            "Couldn't save the private key to the system Keychain (error -25293). Make sure Termo is allowed to access the Keychain, then try again.")
    }

    func testCriticalSettingsStringsRemainChineseWhenAppSelectsChinese() {
        let chinese = Locale(identifier: "zh-Hans")
        let bundle = AppSettings.localizationBundle(for: .zh)
        XCTAssertEqual(String(localized: "启动行为", bundle: bundle, locale: chinese), "启动行为")
        XCTAssertEqual(String(localized: "新增主机", bundle: bundle, locale: chinese), "新增主机")
        XCTAssertEqual(String(localized: "同步内容", bundle: bundle, locale: chinese), "同步内容")
        XCTAssertEqual(String(localized: "安全", bundle: bundle, locale: chinese), "安全")
    }
}
