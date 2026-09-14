import Foundation
import TermoCore

/// iOS 端只保存无凭证的连接资料。SSH 凭证接入时应单独使用 Keychain。
@MainActor
final class IOSHostRepository: ObservableObject {
    @Published private(set) var hosts: [HostProfile] = []
    @Published var errorMessage: String?

    private let fileURL: URL?

    init(inMemory: Bool = false) {
        if inMemory {
            fileURL = nil
        } else {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            fileURL = root.appendingPathComponent("Termo/hosts-ios.json")
        }
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            do { hosts = try JSONDecoder().decode([HostProfile].self, from: data) } catch {
                errorMessage = String(localized: "主机资料读取失败：\(error.localizedDescription)")
            }
        }
    }

    @discardableResult
    func save(_ profile: HostProfile) -> Bool {
        var updated = hosts
        if let index = updated.firstIndex(where: { $0.id == profile.id }) {
            updated[index] = profile
        } else {
            updated.append(profile)
        }
        return persist(updated)
    }

    func remove(at offsets: IndexSet) {
        var updated = hosts
        updated.remove(atOffsets: offsets)
        _ = persist(updated)
    }

    private func persist(_ updated: [HostProfile]) -> Bool {
        do {
            if let fileURL {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
                try JSONEncoder().encode(updated).write(to: fileURL, options: .atomic)
            }
            hosts = updated
            errorMessage = nil
            return true
        } catch {
            errorMessage = String(localized: "主机资料保存失败：\(error.localizedDescription)")
            return false
        }
    }
}
