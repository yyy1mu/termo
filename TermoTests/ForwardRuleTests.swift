import XCTest
@testable import Termo

/// 转发规则校验：监听端口必填合法；local/remote 还需目标主机与端口；dynamic 免目标校验。
final class ForwardRuleTests: XCTestCase {

    private func rule(kind: ForwardKind = .local, listen: Int = 8080,
                      destHost: String = "localhost", destPort: Int = 3306) -> ForwardRule {
        ForwardRule(hostId: "h1", kind: kind, listenPort: listen,
                    destHost: destHost, destPort: destPort)
    }

    func test_validLocalRule_passes() {
        XCTAssertNil(rule().validationError)
    }

    func test_listenPortZero_rejected() {
        XCTAssertNotNil(rule(listen: 0).validationError)
    }

    func test_listenPortOutOfRange_rejected() {
        XCTAssertNotNil(rule(listen: 70000).validationError)
    }

    func test_emptyDestHost_rejectedForLocal() {
        XCTAssertNotNil(rule(destHost: "  ").validationError)
    }

    func test_destPortZero_rejectedForLocal() {
        XCTAssertNotNil(rule(destPort: 0).validationError)
    }

    func test_dynamicSkipsDestValidation() {
        let r = rule(kind: .dynamic, destHost: "", destPort: 0)
        XCTAssertNil(r.validationError)
    }

    func test_remoteRule_needsDestValidation() {
        XCTAssertNotNil(rule(kind: .remote, destPort: 0).validationError)
        XCTAssertNil(rule(kind: .remote).validationError)
    }

    func test_summary_formatsByKind() {
        XCTAssertTrue(rule().summary.contains("→"))
        XCTAssertTrue(rule(kind: .remote).summary.contains("←"))
        XCTAssertTrue(rule(kind: .dynamic).summary.hasPrefix("SOCKS5"))
    }
}
