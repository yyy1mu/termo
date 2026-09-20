import SwiftUI

/// 启动锁定屏：Touch ID（自动弹出 + 手动重试）或 6 位锁定码解锁。
/// 盖在 ContentView 之上（TermoApp overlay），遮挡全部交互。
struct AppLockScreen: View {
    @ObservedObject private var lock = AppLockManager.shared
    @ObservedObject private var theme = ThemeManager.shared
    @State private var pin = ""
    @State private var shakeOffset: CGFloat = 0
    @State private var biometryPrompted = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        ZStack {
            Pal.crust.ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Pal.mauve)
                Text("Termo 已锁定")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Pal.text)

                // 6 位进度点
                HStack(spacing: 10) {
                    ForEach(0..<6, id: \.self) { i in
                        Circle()
                            .fill(i < pin.count ? Pal.mauve : Color.clear)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Pal.border, lineWidth: 1))
                    }
                }
                .offset(x: shakeOffset)

                // 数字键盘
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(["1", "2", "3", "4", "5", "6", "7", "8", "9"], id: \.self) { digit in
                        keyButton(digit)
                    }
                    keyButton("⌫", action: { if !pin.isEmpty { pin.removeLast() } })
                    keyButton("0", action: { appendDigit("0") })
                    keyButton("✓", action: { verify() })
                }
                .frame(width: 220)

                if lock.biometryAvailable {
                    Button {
                        Task { if await lock.unlockWithBiometrics() { lock.unlock() } }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "touchid").font(.system(size: 12))
                            Text("使用 Touch ID 解锁").font(.system(size: 12))
                        }
                        .foregroundStyle(Pal.subtext)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Pal.border, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).pointerCursor()
                }

                Text("输入 6 位锁定码，或使用 Touch ID")
                    .font(.system(size: 10))
                    .foregroundStyle(Pal.overlay)
            }
        }
        .onAppear(perform: promptBiometryOnce)
    }

    private func keyButton(_ label: String, action: (() -> Void)? = nil) -> some View {
        Button {
            if let action {
                action()
            } else if let digit = Int(label) {
                appendDigit(String(digit))
            }
        } label: {
            Text(label)
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(Pal.text)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Pal.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerCursor()
    }

    private func appendDigit(_ d: String) {
        guard pin.count < 6 else { return }
        pin += d
        if pin.count == 6 { verify() }   // 满 6 位自动校验
    }

    private func verify() {
        if lock.verifyPin(pin) {
            lock.unlock()
            pin = ""
        } else {
            pin = ""
            // 错误抖动提示
            withAnimation(.easeInOut(duration: 0.06).repeatCount(3, autoreverses: true)) {
                shakeOffset = -8
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                withAnimation(.easeOut(duration: 0.08)) { shakeOffset = 0 }
            }
        }
    }

    /// 锁定屏出现时自动弹一次 Touch ID（失败/取消后由按钮手动重试，不骚扰）。
    private func promptBiometryOnce() {
        guard !biometryPrompted, lock.biometryAvailable else { return }
        biometryPrompted = true
        Task { if await lock.unlockWithBiometrics() { lock.unlock() } }
    }
}

/// 锁定码设置弹窗（设置 → 安全 →「锁定码」）：两次输入一致的 6 位数字。
struct AppLockSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var theme = ThemeManager.shared
    @State private var pin1 = ""
    @State private var pin2 = ""
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("设置锁定码").font(.system(size: 15, weight: .semibold)).foregroundStyle(Pal.text)

            pinField("输入 6 位数字", text: $pin1)
            pinField("再次输入确认", text: $pin2)

            if !error.isEmpty {
                Text(error).font(.system(size: 11)).foregroundStyle(Pal.red)
            }

            HStack(spacing: 10) {
                Button { dismiss() } label: {
                    Text("取消").font(.system(size: 12, weight: .medium)).foregroundStyle(Pal.text)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Pal.fill(0.06), in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor()

                Button(action: saveAction) {
                    Text("保存并启用").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(canSave ? Pal.mauve : Pal.fill(0.08), in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerCursor().disabled(!canSave)
            }

            Text("忘记锁定码无法找回（Touch ID 仍可解锁）；可在 设置 → 安全 关闭启动锁。")
                .font(.system(size: 10)).foregroundStyle(Pal.overlay)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 320)
    }

    private var canSave: Bool { pin1.count == 6 && pin1 == pin2 }

    private func pinField(_ hint: String, text: Binding<String>) -> some View {
        TextField(hint, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 14, design: .monospaced))
            .foregroundStyle(Pal.text)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Pal.fill(0.05), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Pal.border, lineWidth: 1))
            .onChange(of: text.wrappedValue) { v in
                // 只留数字、最多 6 位
                text.wrappedValue = String(v.filter(\.isNumber).prefix(6))
            }
    }

    private func saveAction() {
        guard pin1.count == 6, pin1 == pin2 else {
            error = pin1 != pin2 ? "两次输入不一致" : "请输入完整的 6 位数字"
            return
        }
        AppLockManager.shared.setPin(pin1)
        AppLockManager.shared.setEnabled(true)
        dismiss()
    }
}
