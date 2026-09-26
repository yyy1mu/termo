import XCTest
@testable import Termo
import TermoEngine
import TermoCore

final class SSHConnectionBoundaryTests: XCTestCase {
    /// 测试环境：路径/密钥落盘不参与断言（连接从未真正发起）。
    private let testEnvironment = SSHConnectionEnvironment(
        realKnownHosts: "/unused/known_hosts", sessionKnownHosts: "/unused/session_known_hosts",
        materializeKey: { _ in nil })

    func testPasswordAuthenticationDoesNotResolveStaleKeyFields() throws {
        var connection = SSHConnection(host: "fixture.invalid")
        connection.password = "fixture-password"
        connection.keyId = "unused-key"
        connection.keyPath = "/unused/path"
        let authentication = try SSHAuthentication(connection) { _ in
            XCTFail("Password authentication must not access private keys")
            return nil
        }
        XCTAssertEqual(authentication, .password("fixture-password"))
        connection.password = ""
        XCTAssertEqual(try SSHAuthentication(connection, materializeKey: { _ in nil }), .password(nil))
    }

    func testManagedKeyTakesPrecedenceAndUsesSecretOnlyAsPassphrase() throws {
        var connection = SSHConnection(host: "fixture.invalid")
        connection.authMethod = .key
        connection.keyId = "managed-key"
        connection.keyPath = "/fallback/key"
        connection.password = "fixture-passphrase"
        let authentication = try SSHAuthentication(connection) { id in
            XCTAssertEqual(id, "managed-key")
            return "/materialized/key"
        }
        XCTAssertEqual(authentication, .privateKey(path: "/materialized/key", passphrase: "fixture-passphrase"))
        XCTAssertEqual(try SSHAuthentication(connection, materializeKey: { _ in nil }),
                       .privateKey(path: "/fallback/key", passphrase: "fixture-passphrase"))
    }

    func testMissingKeyIsRejectedBeforeAttemptingConnection() {
        var connection = SSHConnection(host: "fixture.invalid")
        connection.authMethod = .key
        connection.keyId = "missing-key"
        XCTAssertThrowsError(try SSHAuthentication(connection, materializeKey: { _ in nil }))
        connection.keyId = ""
        connection.keyPath = "/explicit/key"
        XCTAssertEqual(try SSHAuthentication(connection, materializeKey: { _ in nil }), .privateKey(path: "/explicit/key", passphrase: nil))
    }

    func testStatusQueriesAndIdleCleanupDoNotCreateConnectionEntries() {
        var creations = 0
        let pool = SSHSessionPool(makeHub: { creations += 1; return SSHConnectionHub(environment: self.testEnvironment) })
        let connection = SSHConnection(host: "fixture.invalid")
        for _ in 0..<10 {
            XCTAssertFalse(pool.hasLiveSession(connection))
            pool.closeIdleConnection(for: connection)
        }
        XCTAssertEqual(creations, 0)
        _ = pool.connectionHub(for: connection)
        XCTAssertEqual(creations, 1)
        XCTAssertFalse(pool.hasLiveSession(connection))
        XCTAssertEqual(creations, 1)
    }

    func testRegistrySharesOnlyMatchingAuthenticationIdentity() {
        let pool = SSHSessionPool(makeHub: { SSHConnectionHub(environment: self.testEnvironment) })
        var connection = SSHConnection(host: "fixture.invalid")
        connection.password = "first"
        let original = pool.connectionHub(for: connection)
        XCTAssertTrue(original === pool.connectionHub(for: connection))
        connection.password = "second"
        XCTAssertFalse(original === pool.connectionHub(for: connection))
        connection.password = "first"
        connection.user = "another-user"
        XCTAssertFalse(original === pool.connectionHub(for: connection))
    }

    func testNetworkResetRetiresOldEntryBeforeItCanReconnect() {
        let pool = SSHSessionPool(makeHub: { SSHConnectionHub(environment: self.testEnvironment) })
        let connection = SSHConnection(host: "fixture.invalid")
        let original = pool.connectionHub(for: connection)
        pool.closeAll()
        XCTAssertFalse(pool.hasLiveSession(connection))
        XCTAssertThrowsError(try original.acquire(connection)) // retired guard, no network request
        XCTAssertFalse(original === pool.connectionHub(for: connection))
    }
}
