import XCTest

/// A1 运行时冒烟：真实 App + 真实模拟器 + 容器 SSH（localhost:2222，tester / Termo123456）。
/// 覆盖：添加主机 → 保存 → 列表出现 → 详情 → 连接终端 → 指纹信任 → 终端页稳定无错误覆盖层。
/// 终端文本经 Metal 渲染、不进无障碍树，只断言页面状态与关键元素存在性。
final class TermoIOSUITests: XCTestCase {
    private var app: XCUIApplication!

    /// 冒烟主机参数（容器见 docker termo-ssh-test）。名称固定以便重跑时辨认。
    private let hostName = "A1 冒烟"
    private let hostAddress = "127.0.0.1"
    private let hostPort = "2222"
    private let hostUser = "tester"
    private let hostPassword = "Termo123456"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    /// 清空并输入：XCUITest 的长按全选在表单里不稳定，按当前值逐字符删除更可靠。
    private func replaceText(in field: XCUIElement, with text: String) {
        field.tap()
        let current = field.value as? String ?? ""
        if !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(text)
    }

    func testAddHostAndConnectTerminal() throws {
        // ── 添加主机 ────────────────────────────────────────────────
        let addButton = app.buttons["addHostButton"].firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 10), "主机页应出现「添加主机」按钮")
        addButton.tap()

        let nameField = app.textFields["hostEditor.name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), "编辑器应弹出")
        replaceText(in: nameField, with: hostName)

        replaceText(in: app.textFields["hostEditor.hostname"], with: hostAddress)
        // 默认 root / 22，需清空后替换为容器账号与端口
        replaceText(in: app.textFields["hostEditor.username"], with: hostUser)
        replaceText(in: app.textFields["hostEditor.port"], with: hostPort)

        // 认证方式默认即「密码」
        let passwordField = app.secureTextFields["hostEditor.password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 3), "密码认证应显示密码输入框")
        passwordField.tap(); passwordField.typeText(hostPassword)

        let saveButton = app.buttons["hostEditor.save"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 3))
        XCTAssertTrue(saveButton.isEnabled, "表单填写完整后保存应可用")
        saveButton.tap()

        // iOS AutoFill「保存密码？」弹窗（远程视图控制器，挂在 App 树的 Sheet 元素上）。
        // 远程视图的元素 hit-point 同样算不出，须按其 frame 中心坐标点按。
        let savePromptLater = app.sheets["保存密码？"].buttons["以后"].firstMatch
        if savePromptLater.waitForExistence(timeout: 8) {
            savePromptLater.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }

        // 保存后编辑器应收起；若 5 秒后仍在，抓取现场（错误弹窗/无障碍树）便于定位。
        if nameField.waitForExistence(timeout: 5) {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.lifetime = .keepAlways
            add(shot)
            let tree = XCTAttachment(data: Data(app.debugDescription.utf8), uniformTypeIdentifier: "public.plain-text")
            tree.lifetime = .keepAlways
            add(tree)
            XCTFail("保存后编辑器未收起（错误信息：\(app.alerts.firstMatch.exists ? "有弹窗" : "无弹窗")）")
        }

        // ── 列表出现新主机 ──────────────────────────────────────────
        // 用坐标点按行中心：XCUITest 对 SwiftUI List 行的 hit-point 计算在本环境
        // 会得到 {-1,-1}（合成事件落空），坐标点按跳过命中测试。
        let hostRow = app.buttons.containing(.staticText, identifier: hostName).firstMatch
        XCTAssertTrue(hostRow.waitForExistence(timeout: 5), "保存后列表应出现新主机")
        hostRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        // ── 详情 → 连接终端 ─────────────────────────────────────────
        let connectButton = app.buttons["connectTerminalButton"].firstMatch
        if !connectButton.waitForExistence(timeout: 5) {
            // 失败现场留证：截图 + 无障碍树（xcresult 附件）
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.lifetime = .keepAlways
            add(shot)
            let tree = XCTAttachment(data: Data(app.debugDescription.utf8), uniformTypeIdentifier: "public.plain-text")
            tree.lifetime = .keepAlways
            add(tree)
        }
        XCTAssertTrue(connectButton.exists, "详情页应出现「连接终端」")
        connectButton.tap()

        // ── 指纹确认（首次/变更才弹；已信任则跳过）────────────────────
        let trustButton = app.alerts.buttons["信任并连接"]
        if trustButton.waitForExistence(timeout: 8) {
            trustButton.tap()
        }

        // ── 终端页稳定：终端视图存在，且无失败/掉线覆盖层 ─────────────
        let terminalView = app.descendants(matching: .any)["terminalView"]
        XCTAssertTrue(terminalView.waitForExistence(timeout: 10), "终端页应出现终端视图")

        let failedOverlay = app.descendants(matching: .any)["terminalFailedOverlay"]
        let droppedOverlay = app.descendants(matching: .any)["terminalDroppedOverlay"]
        // 连接容器很快；给足余量后两覆盖层都不应出现，且再稳定观察几秒不复发。
        XCTAssertFalse(failedOverlay.waitForExistence(timeout: 5), "不应出现失败覆盖层")
        XCTAssertFalse(droppedOverlay.waitForExistence(timeout: 2), "不应出现掉线重连覆盖层")
        sleep(3)
        XCTAssertFalse(failedOverlay.exists, "终端页应保持稳定（无失败覆盖层）")
        XCTAssertFalse(droppedOverlay.exists, "终端页应保持稳定（无掉线覆盖层）")
    }
}
