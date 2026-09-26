import SwiftUI

/// 锁屏与 WebDAV 备份加密共用主密码。
struct AppLockScreen: View {
    @ObservedObject private var lock = AppLockManager.shared
    @ObservedObject private var theme = ThemeManager.shared
    @State private var password = ""
    @State private var error = ""
    @State private var busy = false
    @FocusState private var passwordFocused: Bool

    var body: some View {
        ZStack {
            Pal.crust.ignoresSafeArea()
            VStack(spacing: 22) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 36, weight: .light)).foregroundStyle(Pal.mauve)
                    .frame(width: 80, height: 80)
                    .background(Pal.mauve.opacity(0.10), in: RoundedRectangle(cornerRadius: 22))
                VStack(spacing: 7) {
                    Text("Termo 已锁定").font(.system(size: 23, weight: .semibold)).foregroundStyle(
                        Pal.textBright)
                    Text("输入密码，继续你的工作")
                        .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                }
                VStack(alignment: .leading, spacing: 10) {
                    SecureField("解锁密码", text: $password)
                        .textFieldStyle(.plain).font(.system(size: 15))
                        .padding(13).background(Pal.card, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Pal.border, lineWidth: 1))
                        .focused($passwordFocused).onSubmit { verify() }
                        .onChange(of: password) { _, _ in error = "" }
                        .disabled(busy)
                    if !error.isEmpty { Text(error).font(.system(size: 11)).foregroundStyle(Pal.red) }
                    Button(action: verify) {
                        HStack {
                            Spacer()
                            if busy { ProgressView().controlSize(.small) }
                            Text("解锁").font(.system(size: 13, weight: .semibold))
                            Spacer()
                        }
                        .padding(12).foregroundStyle(.white)
                        .background(Pal.mauve, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain).disabled(password.isEmpty || busy).pointerCursor()
                }
                if lock.biometryAvailable {
                    Button {
                        biometricUnlock()
                    } label: {
                        Label("使用 Touch ID", systemImage: "touchid")
                            .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                    }
                    .buttonStyle(.plain).disabled(busy).pointerCursor()
                }
                Text("主密码同时用于应用解锁与 WebDAV 备份加密。")
                    .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 320).padding(32)
        }
        .onAppear {
            passwordFocused = true
        }
        .onDisappear { password = "" }
    }

    private func verify() {
        guard !busy, !password.isEmpty else { return }
        busy = true
        error = ""
        let candidate = password
        Task {
            if await lock.verifyPassword(candidate) {
                lock.unlock()
            } else {
                error = lock.credentialError ?? String(localized: "密码不正确，请重试", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)
            }
            password = ""
            busy = false
            passwordFocused = true
        }
    }

    private func biometricUnlock() {
        guard !busy else { return }
        busy = true
        error = ""
        Task {
            if await lock.unlockWithBiometrics() { lock.unlock() }
            busy = false
            passwordFocused = true
        }
    }
}

/// 所有入口共用此设置页；改密需验证当前密码，不覆盖旧备份。
struct AppLockSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lock = AppLockManager.shared
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var sync = SyncModel.shared
    @State private var currentPassword = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var error = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(lock.hasMasterPassword ? String(localized: "修改主密码", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "设置主密码", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale), systemImage: "key.horizontal")
                .font(.system(size: 19, weight: .semibold)).foregroundStyle(Pal.textBright)
            Text("一个密码，用于应用解锁和 WebDAV 备份加密。至少 8 个字符，支持文字、数字和符号。")
                .font(.system(size: 12)).foregroundStyle(Pal.subtext)
                .fixedSize(horizontal: false, vertical: true)
            if lock.hasPin {
                passwordField("当前密码", text: $currentPassword)
            }
            passwordField("新主密码", text: $password)
            passwordField("再次输入新主密码", text: $confirmation)
            if !confirmation.isEmpty && password != confirmation {
                Text("两次输入不一致").font(.system(size: 11)).foregroundStyle(Pal.red)
            }
            if !error.isEmpty { Text(error).font(.system(size: 11)).foregroundStyle(Pal.red) }
            if sync.busy {
                Text("同步进行中，请在同步结束后保存主密码。")
                    .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("所有设备使用同一个主密码。修改密码后，已有备份仍需要原密码才能读取。")
                .font(.system(size: 11)).foregroundStyle(Pal.subtext)
                .fixedSize(horizontal: false, vertical: true)
            Text("主密码无法找回。Touch ID 可解锁应用，但加解密备份仍需主密码。")
                .font(.system(size: 11)).foregroundStyle(Pal.overlay)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(busy ? String(localized: "保存中…", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale) : String(localized: "保存主密码", bundle: AppSettings.localizationBundle, locale: AppSettings.activeLocale)) { save() }
                    .buttonStyle(.borderedProminent).tint(Pal.mauve)
                    .disabled(!canSave || busy || sync.busy).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 420).background(Pal.solidBase)
        .interactiveDismissDisabled(busy)
        .onChange(of: [currentPassword, password, confirmation]) { error = "" }
        .onDisappear {
            currentPassword = ""; password = ""; confirmation = ""
        }
    }

    private var canSave: Bool {
        password.count >= 8 && !password.contains("\0") && !password.contains(where: \.isNewline)
            && password == confirmation
            && (!lock.hasPin || !currentPassword.isEmpty)
    }

    private func passwordField(_ title: LocalizedStringKey, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(Pal.subtext)
            SecureField(title, text: text).textFieldStyle(.roundedBorder).disabled(busy)
        }
    }

    private func save() {
        guard canSave, !busy, !sync.busy else { return }
        busy = true
        error = ""
        let wasConfigured = lock.hasPin
        Task {
            do {
                try await lock.setMasterPassword(password, currentPassword: currentPassword)
                if !wasConfigured { lock.setEnabled(true) }
                dismiss()
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
