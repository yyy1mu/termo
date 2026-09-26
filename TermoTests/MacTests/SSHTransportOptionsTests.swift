import XCTest
import Security

@testable import Termo
import TermoEngine
import TermoCore

final class SSHTransportOptionsTests: XCTestCase {
    func testParsesDirectAndProxyConnections() throws {
        var direct = SSHConnection(timeoutMs: 12_000, heartbeatMs: 0)
        var options = try SSHTransportOptions(direct)
        XCTAssertEqual(options.timeoutMs, 12_000)
        XCTAssertEqual(options.heartbeatMs, 0)
        XCTAssertNil(options.proxy)

        direct.proxyURL = "socks5://127.0.0.1:1080"
        options = try SSHTransportOptions(direct)
        XCTAssertEqual(options.proxy?.kind, .socks5)
        XCTAssertEqual(options.proxy?.host, "127.0.0.1")
        XCTAssertEqual(options.proxy?.port, 1080)

        direct.disableProxy = true
        XCTAssertNil(try SSHTransportOptions(direct).proxy)
    }

    func testRejectsAmbiguousOrSecretBearingProxyURLs() {
        for value in [
            "https://proxy.example:443",
            "http://proxy.example",
            "http://name:secret@proxy.example:8080",
            "socks5://proxy.example:1080/path",
        ] {
            var connection = SSHConnection(proxyURL: value)
            connection.disableProxy = false
            XCTAssertThrowsError(try SSHTransportOptions(connection), value)
        }
    }

    func testTransportSettingsParticipateInReuseIdentity() {
        let base = SSHConnection(host: "example.test", password: "secret")
        var changed = base
        changed.heartbeatMs = 20_000
        XCTAssertNotEqual(SSHConnectionReuseKey(base), SSHConnectionReuseKey(changed))
        changed = base
        changed.ciphers = "aes256-ctr"
        XCTAssertNotEqual(SSHConnectionReuseKey(base), SSHConnectionReuseKey(changed))
        changed = base
        changed.proxyURL = "http://127.0.0.1:8080"
        XCTAssertNotEqual(SSHConnectionReuseKey(base), SSHConnectionReuseKey(changed))
    }

    @MainActor
    func testDraftValidatesRangesAndProxyBeforeSaving() {
        let draft = HostDraft()
        draft.name = "server"
        draft.address = "example.test"
        draft.timeout = "999"
        XCTAssertNotNil(draft.connectionValidationMessage)
        draft.timeout = "10000"
        draft.heartbeat = "1"
        XCTAssertNotNil(draft.connectionValidationMessage)
        draft.heartbeat = "0"
        draft.proxyEnabled = true
        draft.proxyURL = ""
        XCTAssertNotNil(draft.connectionValidationMessage)
        draft.proxyURL = "http://127.0.0.1:8080"
        XCTAssertNil(draft.connectionValidationMessage)
        XCTAssertFalse(draft.buildConnection().disableProxy)
    }

    @MainActor
    func testDraftKeepsUngroupedHostsLanguageIndependent() {
        let draft = HostDraft()
        draft.group = "   "
        XCTAssertEqual(draft.resolvedGroup, "")

        draft.group = "Production"
        XCTAssertEqual(draft.resolvedGroup, "Production")
    }

    func testLegacyLocalizedUngroupedValueIsNormalizedOnLoad() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("termo-hosts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let legacyHost = Host(
            id: "legacy", name: "Legacy", addr: "legacy.invalid", group: "未分组",
            status: .unknown, os: "Linux")
        try JSONEncoder().encode([legacyHost]).write(to: url)
        let noCredentials = HostKeychain.Storage(
            read: { _, _ in (errSecItemNotFound, nil) },
            update: { _, _, _ in errSecSuccess },
            add: { _, _, _ in errSecSuccess },
            remove: { _, _ in errSecSuccess })

        XCTAssertEqual(HostStore.loadHosts(at: url, credentials: noCredentials).first?.group, "")
    }
}
