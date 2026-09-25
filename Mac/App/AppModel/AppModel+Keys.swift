import AppKit
import SwiftUI

extension AppModel {
    // ---------- 密钥库（SSH Keys）----------
    /// 私钥与元数据都成功保存后才发布，供表单可靠决定是否关闭。
    @discardableResult
    func generateKey(name: String, type: SSHKeyType, comment: String, passphrase: String) async -> Bool {
        keyOpError = nil
        do {
            // RSA 4096 的生成和口令加密可能持续数秒；不要在主线程阻塞整个工作台。
            let generation = Task.detached(priority: .userInitiated) {
                try KeyTools.generate(type: type, comment: comment, passphrase: passphrase)
            }
            let g = try await withTaskCancellationHandler {
                try await generation.value
            } onCancel: {
                generation.cancel()
            }
            guard !Task.isCancelled else { return false }
            let key = SSHKey(
                name: name.isEmpty ? String(localized: "未命名密钥") : name, type: type,
                publicKey: g.publicKey, fingerprint: g.fingerprint,
                comment: comment, hasPassphrase: !passphrase.isEmpty)
            let saved = sshKeys + [key]
            try KeyStore.save(saved, updatingPrivateKeys: { $0[key.id] = g.privateKey })
            sshKeys = saved
            return true
        } catch {
            guard !Task.isCancelled else { return false }
            keyOpError = (error as? KeyError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    /// 原生选择器支持查看完整路径；导入结果在密钥库显示，失败由设置页提示。
    func presentImportKey() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "导入私钥")
        panel.message = String(localized: "选择一份私钥；加密私钥可按住 ⌘ 同时选中同名 .pub 文件。")
        panel.prompt = String(localized: "导入私钥")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK else { return }
        do {
            let files = try KeyTools.selectedImportFiles(panel.urls)
            _ = importKey(from: files.privateKey, publicKeyURL: files.publicKey)
        } catch {
            keyOpError = error.localizedDescription
        }
    }

    /// 从用户选择的文件导入；保存失败不发布临时条目或改变主机选择。
    @discardableResult
    func importKey(from url: URL, publicKeyURL: URL? = nil) -> SSHKey? {
        keyOpError = nil
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let accessedPublic = publicKeyURL?.startAccessingSecurityScopedResource() ?? false
        defer { if accessedPublic { publicKeyURL?.stopAccessingSecurityScopedResource() } }
        do {
            let pem = try String(contentsOf: url, encoding: .utf8)
            let info = try KeyTools.importInfo(privatePath: url.path, publicKeyURL: publicKeyURL)
            let key = SSHKey(
                name: url.deletingPathExtension().lastPathComponent,
                type: info.type, publicKey: info.publicKey,
                fingerprint: info.fingerprint, comment: info.comment,
                hasPassphrase: info.hasPassphrase)
            let saved = sshKeys + [key]
            try KeyStore.save(saved, updatingPrivateKeys: { $0[key.id] = pem })
            sshKeys = saved
            return key
        } catch {
            keyOpError = (error as? KeyError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func deleteKey(_ key: SSHKey) -> Bool {
        keyOpError = nil
        do {
            let saved = sshKeys.filter { $0.id != key.id }
            try KeyStore.save(
                saved, updatingPrivateKeys: { $0.removeValue(forKey: key.id) },
                beforePrivateKeysChange: { ids in
                    for id in ids { try KeyMaterializer.invalidate(id) }
                })
            sshKeys = saved
            if detailKey?.id == key.id { detailKey = nil }
            return true
        } catch {
            keyOpError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func renameKey(_ id: String, to name: String) -> Bool {
        keyOpError = nil
        guard let i = sshKeys.firstIndex(where: { $0.id == id }) else { return false }
        var saved = sshKeys
        saved[i].name = name.isEmpty ? saved[i].name : name
        do {
            try KeyStore.save(saved)
            sshKeys = saved
            return true
        } catch {
            keyOpError = error.localizedDescription
            return false
        }
    }

    /// 切换到受管密钥认证。旧服务器密码不能被误当成新私钥的解密口令。
    @discardableResult
    func associateKey(_ keyId: String, hostId: String) -> Bool {
        keyOpError = nil
        guard sshKeys.contains(where: { $0.id == keyId }),
            let idx = hosts.firstIndex(where: { $0.id == hostId }), let connection = hosts[idx].ssh
        else {
            keyOpError = String(localized: "目标主机或密钥已不存在，请重新选择。")
            return false
        }
        var saved = hosts
        let credentialsChanged = connection.authMethod != .key || connection.keyId != keyId
        saved[idx].ssh?.authMethod = .key
        saved[idx].ssh?.keyId = keyId
        saved[idx].ssh?.keyPath = ""
        if credentialsChanged { saved[idx].ssh?.password = "" }
        let temporary =
            credentialsChanged ? sessionOnlyHostPasswords.subtracting([hostId]) : sessionOnlyHostPasswords
        guard
            persistHosts(
                saved, clearingPasswordsFor: credentialsChanged ? [hostId] : [], temporary: temporary)
        else {
            keyOpError = hostSaveError ?? String(localized: "主机的登录密钥未能保存，请重试。")
            return false
        }
        hosts = saved
        reconcileConnectionRequests()
        sessionOnlyHostPasswords = temporary
        return true
    }

    func copyPublicKey(_ key: SSHKey) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key.publicKey, forType: .string)
    }

}
