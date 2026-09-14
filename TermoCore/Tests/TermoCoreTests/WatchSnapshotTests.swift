import XCTest

@testable import TermoCore

final class WatchSnapshotTests: XCTestCase {
    func testWatchProjectionExcludesConnectionDetails() throws {
        let profile = HostProfile(
            id: "host-1", name: "Development", hostname: "server.example",
            username: "alice")
        let data = try JSONEncoder().encode(WatchSnapshot.from([profile]))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("server.example"))
        XCTAssertFalse(json.contains("alice"))
        XCTAssertEqual(
            try JSONDecoder().decode(WatchSnapshot.self, from: data).hosts,
            [WatchHostSummary(id: "host-1", name: "Development")])
    }
}
