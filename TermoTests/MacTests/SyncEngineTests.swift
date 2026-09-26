import XCTest
@testable import Termo
import TermoCore

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
                         settings: SyncedSettings = SyncedSettings(),
                         ai: SyncedAI? = nil, knownHosts: [String] = []) -> SyncPayload {
        SyncPayload(exportedAt: Date(), deviceName: "test", hosts: hosts,
                    hostPasswords: passwords, keys: [], privateKeys: [:],
                    snippets: snippets, forwards: forwards, settings: settings,
                    ai: ai, knownHosts: knownHosts)
    }

    func testHostMonitoringLegacyDefaultsAndDraftRoundTrip() throws {
        let encoded = try JSONEncoder().encode(host("A"))
        let choices: [Bool?] = [nil, true, false]
        for choice in choices {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            var ssh = try XCTUnwrap(json["ssh"] as? [String: Any])
            if let choice { ssh["monitoringEnabled"] = choice }
            else { ssh.removeValue(forKey: "monitoringEnabled") }
            json["ssh"] = ssh
            let data = try JSONSerialization.data(withJSONObject: json)
            let restored = try JSONDecoder().decode(Termo.Host.self, from: data)
            XCTAssertEqual(restored.ssh?.monitoringEnabled ?? true, choice ?? true)
            let draft = HostDraft()
            draft.load(from: restored)
            XCTAssertEqual(draft.monitoringEnabled, choice ?? true)
            let saved = draft.buildConnection()
            XCTAssertEqual(saved.monitoringEnabled ?? true, choice ?? true)
            let synced = try JSONDecoder().decode(SSHConnection.self, from: JSONEncoder().encode(saved))
            XCTAssertEqual(synced.monitoringEnabled ?? true, choice ?? true)
        }
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var ssh = try XCTUnwrap(json["ssh"] as? [String: Any])
        ssh["monitoringEnabled"] = NSNull()
        json["ssh"] = ssh
        let legacy = try JSONDecoder().decode(Termo.Host.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(legacy.ssh?.monitoringEnabled ?? true)
    }

    func testMonitoringConflictBelongsToOneHostAndDoesNotChangeAnother() throws {
        let a = host("A")
        let b = host("B", name: "second", sshHost: "fixture.invalid")
        var remoteA = a
        remoteA.ssh?.monitoringEnabled = false
        let merged = SyncEngine.merge(local: payload(hosts: [a, b]), remote: payload(hosts: [remoteA, b]))
        XCTAssertEqual(merged.conflicts.count, 1)
        let conflict = try XCTUnwrap(merged.conflicts.first)
        guard case .host(let local, _, _, _) = conflict.item else {
            return XCTFail("Monitoring must be a host conflict, not an application setting")
        }
        XCTAssertEqual(local.id, "A")
        XCTAssertEqual(conflict.fields.filter(\.isDifferent).count, 1)
        let resolved = SyncEngine.resolve(result: merged, choices: [conflict.id: false])
        let restored = try JSONDecoder().decode(SyncPayload.self, from: JSONEncoder().encode(resolved))
        XCTAssertEqual(restored.hosts.first { $0.id == "A" }?.ssh?.monitoringEnabled, false)
        XCTAssertTrue(restored.hosts.first { $0.id == "B" }?.ssh?.monitoringEnabled ?? true)
    }

    func testMissingAndExplicitlyEnabledHostMonitoringDoNotConflict() {
        let local = host("A")
        var remote = local
        remote.ssh?.monitoringEnabled = true
        let merged = SyncEngine.merge(local: payload(hosts: [local]), remote: payload(hosts: [remote]))
        XCTAssertTrue(merged.conflicts.isEmpty)
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
        let field = result.conflicts[0].fields.first {
            $0.label == String(
                localized: "内容",
                bundle: AppSettings.localizationBundle,
                locale: AppSettings.activeLocale)
        }
        XCTAssertEqual(field?.local, local.content)
        XCTAssertEqual(field?.remote, remote.content)
        XCTAssertEqual(field?.isDifferent, true)
    }

    // MARK: - 全量同步扩展（AI 配置 / 新设置字段 / known_hosts）

    func test_newFields_payloadRoundTrip() throws {
        var settings = SyncedSettings()
        settings.closeToTray = true
        settings.monitorNoticeHidden = true
        settings.downloadDir = "/tmp/downloads"
        settings.downloadAskEachTime = true
        settings.maxConcurrentTransfers = 5
        settings.pausedReleasesSlot = false
        settings.showDownloadDialog = false
        var ai = SyncedAI()
        ai.baseURL = "https://api.moonshot.cn"
        ai.model = "kimi-k2"
        ai.temperature = 0.7
        ai.contextWindow = 128_000
        ai.systemPrompt = "自定义提示"
        ai.apiKey = "sk-secret"
        let p = payload(hosts: [host("A")], settings: settings, ai: ai,
                        knownHosts: ["1.2.3.4 ssh-ed25519 AAAA", "[h]:22 ssh-rsa BBBB"])
        let restored = try JSONDecoder().decode(SyncPayload.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(restored.settings, settings)
        XCTAssertEqual(restored.ai, ai)
        XCTAssertEqual(restored.knownHosts, p.knownHosts)
    }

    func test_legacyPayload_withoutNewKeys_decodes() throws {
        let encoded = try JSONEncoder().encode(payload(hosts: [host("A")]))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "ai")
        json.removeValue(forKey: "knownHosts")
        var settings = try XCTUnwrap(json["settings"] as? [String: Any])
        for key in ["closeToTray", "monitorNoticeHidden", "downloadDir", "downloadAskEachTime",
                    "maxConcurrentTransfers", "pausedReleasesSlot", "showDownloadDialog"] {
            settings.removeValue(forKey: key)
        }
        json["settings"] = settings
        let legacy = try JSONDecoder().decode(SyncPayload.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.ai)
        XCTAssertEqual(legacy.knownHosts, [])
        XCTAssertEqual(legacy.hosts.map(\.id), ["A"])
        XCTAssertFalse(legacy.settings.closeToTray)
        XCTAssertFalse(legacy.settings.monitorNoticeHidden)
        XCTAssertEqual(legacy.settings.downloadDir, "")
        XCTAssertFalse(legacy.settings.downloadAskEachTime)
        XCTAssertEqual(legacy.settings.maxConcurrentTransfers, 2)
        XCTAssertTrue(legacy.settings.pausedReleasesSlot)
        XCTAssertTrue(legacy.settings.showDownloadDialog)
    }

    func test_knownHosts_unionMerge_noConflict() {
        let l = payload(hosts: [], knownHosts: ["a ssh-ed25519 A", "b ssh-rsa B"])
        let r = payload(hosts: [], knownHosts: ["b ssh-rsa B", "c ssh-ed25519 C"])
        let m = SyncEngine.merge(local: l, remote: r)
        XCTAssertEqual(m.merged.knownHosts, ["a ssh-ed25519 A", "b ssh-rsa B", "c ssh-ed25519 C"])
        XCTAssertTrue(m.conflicts.isEmpty)
    }

    func test_knownHosts_remoteOnly_adopted() {
        let m = SyncEngine.merge(local: payload(hosts: []),
                                 remote: payload(hosts: [], knownHosts: ["r ssh-ed25519 R"]))
        XCTAssertEqual(m.merged.knownHosts, ["r ssh-ed25519 R"])
    }

    func test_aiDifference_producesConflict_apiKeyMasked() {
        var la = SyncedAI()
        la.model = "local-model"
        var ra = la
        ra.model = "remote-model"
        ra.apiKey = "sk-remote-secret"
        let m = SyncEngine.merge(local: payload(hosts: [], ai: la),
                                 remote: payload(hosts: [], ai: ra))
        let conflict = m.conflicts.first { $0.id == "ai" }
        guard let conflict, case .ai = conflict.item else {
            return XCTFail("AI 配置不同应产生 .ai 冲突")
        }
        let keyField = conflict.fields.first { $0.label == "API Key" }
        XCTAssertEqual(keyField?.isDifferent, true)
        XCTAssertFalse(conflict.fields.contains { $0.local.contains("sk-remote-secret") || $0.remote.contains("sk-remote-secret") })
        XCTAssertEqual(m.merged.ai, la)  // 默认保留本机
    }

    func test_aiConflict_resolveRemote() {
        var la = SyncedAI()
        la.model = "local-model"
        var ra = la
        ra.model = "remote-model"
        ra.apiKey = "sk-remote-secret"
        let m = SyncEngine.merge(local: payload(hosts: [], ai: la),
                                 remote: payload(hosts: [], ai: ra))
        let resolved = SyncEngine.resolve(result: m, choices: ["ai": false])
        XCTAssertEqual(resolved.ai, ra)
        let kept = SyncEngine.resolve(result: m, choices: ["ai": true])
        XCTAssertEqual(kept.ai, la)
    }

    func test_ai_remoteOnly_adopted() {
        var ra = SyncedAI()
        ra.model = "remote-model"
        let m = SyncEngine.merge(local: payload(hosts: []), remote: payload(hosts: [], ai: ra))
        XCTAssertEqual(m.merged.ai, ra)
        XCTAssertTrue(m.conflicts.isEmpty)
    }

    func test_appendKnownHosts_appendsMissingOnly() throws {
        let path = NSTemporaryDirectory() + "termo-test-\(UUID().uuidString)/session_known_hosts"
        SyncEngine.appendKnownHosts(["a ssh-ed25519 A"], path: path)
        SyncEngine.appendKnownHosts(["a ssh-ed25519 A", "b ssh-rsa B"], path: path)
        XCTAssertEqual(SyncEngine.readKnownHosts(path: path), ["a ssh-ed25519 A", "b ssh-rsa B"])
    }

    func test_newSettingsFields_produceSettingsConflict() {
        var s = SyncedSettings()
        s.maxConcurrentTransfers = 5
        s.closeToTray = true
        let m = SyncEngine.merge(local: payload(hosts: []), remote: payload(hosts: [], settings: s))
        XCTAssertEqual(m.conflicts.count, 1)
        let labels = m.conflicts[0].fields.map(\.label)
        XCTAssertTrue(labels.contains(String(
            localized: "并发传输数",
            bundle: AppSettings.localizationBundle,
            locale: AppSettings.activeLocale)))
        XCTAssertTrue(labels.contains(String(
            localized: "关闭时隐藏到菜单栏",
            bundle: AppSettings.localizationBundle,
            locale: AppSettings.activeLocale)))
        let resolved = SyncEngine.resolve(result: m, choices: ["settings": false])
        XCTAssertEqual(resolved.settings.maxConcurrentTransfers, 5)
        XCTAssertTrue(resolved.settings.closeToTray)
    }
}
