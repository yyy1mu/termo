import XCTest
@testable import Termo

/// 同步合并语义：主机按稳定 id/自然键/回退键三级匹配，冲突默认保留本机，
/// 远端转发规则的 hostId 经主机映射表归一。
@MainActor
final class SyncEngineTests: XCTestCase {

    private func host(_ id: String, name: String = "srv", addr: String = "root@1.2.3.4",
                      sshHost: String = "1.2.3.4") -> Termo.Host {
        var conn = SSHConnection()
        conn.host = sshHost
        conn.user = "root"
        conn.port = 22
        return Termo.Host(id: id, name: name, addr: addr, group: "", status: .unknown,
                    os: "", port: 22, ssh: conn, notes: "")
    }

    private func payload(hosts: [Termo.Host], passwords: [String: String] = [:],
                         snippets: [Snippet] = [], forwards: [ForwardRule] = [],
                         settings: SyncedSettings = SyncedSettings()) -> SyncPayload {
        SyncPayload(exportedAt: Date(), deviceName: "test", hosts: hosts,
                    hostPasswords: passwords, keys: [], privateKeys: [:],
                    snippets: snippets, forwards: forwards, settings: settings)
    }

    func test_localOnlyHost_keptAndCounted() {
        let r = SyncEngine.merge(local: payload(hosts: [host("L1")]), remote: payload(hosts: []))
        XCTAssertEqual(r.merged.hosts.map(\.id), ["L1"])
        XCTAssertEqual(r.localOnlyCount, 1)
        XCTAssertEqual(r.remoteOnlyCount, 0)
        XCTAssertTrue(r.conflicts.isEmpty)
    }

    func test_remoteOnlyHost_adoptedWithPassword() {
        let r = SyncEngine.merge(local: payload(hosts: []),
                                 remote: payload(hosts: [host("R1")], passwords: ["R1": "pw"]))
        XCTAssertEqual(r.merged.hosts.map(\.id), ["R1"])
        XCTAssertEqual(r.merged.hostPasswords["R1"], "pw")
        XCTAssertEqual(r.remoteOnlyCount, 1)
    }

    func test_sameHostSamePassword_noConflict() {
        let l = payload(hosts: [host("A")], passwords: ["A": "pw"])
        let r = payload(hosts: [host("A")], passwords: ["A": "pw"])
        let m = SyncEngine.merge(local: l, remote: r)
        XCTAssertTrue(m.conflicts.isEmpty)
        XCTAssertEqual(m.merged.hosts.count, 1)
    }

    func test_sameHostDifferentPassword_conflictKeepsLocal() {
        let l = payload(hosts: [host("A")], passwords: ["A": "local-pw"])
        let r = payload(hosts: [host("A")], passwords: ["A": "remote-pw"])
        let m = SyncEngine.merge(local: l, remote: r)
        XCTAssertEqual(m.conflicts.count, 1)
        XCTAssertEqual(m.merged.hosts.map(\.id), ["A"])          // 默认保留本机
        XCTAssertEqual(m.merged.hostPasswords["A"], "local-pw")
    }

    func test_remoteForwardRule_hostIdRemappedToLocal() {
        // 远端主机 id 不同但自然键相同 → 匹配后其转发规则的 hostId 应归一到本机 id
        let l = payload(hosts: [host("L1")])
        let rf = ForwardRule(hostId: "R9", listenPort: 8080, destHost: "localhost", destPort: 3306)
        let r = payload(hosts: [host("R9")], forwards: [rf])
        let m = SyncEngine.merge(local: l, remote: r)
        XCTAssertTrue(m.merged.forwards.contains { $0.id == rf.id && $0.hostId == "L1" })
    }

    func test_differentSettings_producesSettingsConflict() {
        var s = SyncedSettings()
        s.termFontSize = 99
        let m = SyncEngine.merge(local: payload(hosts: []), remote: payload(hosts: [], settings: s))
        XCTAssertEqual(m.conflicts.count, 1)
    }

    func test_remoteOnlySnippet_adopted() {
        let sn = Snippet(id: "s1", name: "n", content: "ls")
        let m = SyncEngine.merge(local: payload(hosts: []), remote: payload(hosts: [], snippets: [sn]))
        XCTAssertEqual(m.merged.snippets.map(\.id), ["s1"])
        XCTAssertEqual(m.remoteOnlyCount, 1)
    }

    func test_multilineSnippetConflict_showsFullContentBeforeChoosing() {
        let local = Snippet(id: "s1", name: "部署", content: "echo prepare\necho local")
        let remote = Snippet(id: "s1", name: "部署", content: "echo prepare\necho remote")
        let result = SyncEngine.merge(
            local: payload(hosts: [], snippets: [local]),
            remote: payload(hosts: [], snippets: [remote]))
        XCTAssertEqual(result.conflicts.count, 1)
        let field = result.conflicts[0].fields.first { $0.label == "内容" }
        XCTAssertEqual(field?.local, local.content)
        XCTAssertEqual(field?.remote, remote.content)
        XCTAssertEqual(field?.isDifferent, true)
    }
}
