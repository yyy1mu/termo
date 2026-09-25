import AppKit
import SwiftUI
import XCTest
@testable import Termo

@MainActor
final class AIMarkdownRenderingTests: XCTestCase {
    func testModeTitleAndMarkdownNeverGrantCommandApproval() {
        XCTAssertEqual(AIMode.general.title, "Chat")
        XCTAssertFalse(AIMessageMarkdown.isApprovalCode("uptime", language: "bash", command: nil))
        XCTAssertFalse(AIMessageMarkdown.isApprovalCode("reboot", language: "bash", command: "uptime"))
        XCTAssertFalse(AIMessageMarkdown.isApprovalCode("uptime", language: "text", command: "uptime"))
        XCTAssertTrue(AIMessageMarkdown.isApprovalCode("uptime\n", language: "bash", command: "uptime"))
    }

    func testMarkdownLinksCannotLaunchLocalFilesOrCommands() throws {
        for value in ["https://example.com/docs", "http://localhost:8080", "mailto:help@example.com"] {
            XCTAssertTrue(AIMessageMarkdown.canOpenLink(try XCTUnwrap(URL(string: value))))
        }
        for value in ["file:///etc/passwd", "ssh://root@example.com", "javascript:alert(1)", "termo://execute", "/relative"] {
            XCTAssertFalse(AIMessageMarkdown.canOpenLink(try XCTUnwrap(URL(string: value))))
        }
    }

    func testNarrowAndWideMarkdownLayoutsIncludingUnclosedStreamingFence() async throws {
        for width in [320.0, 560.0] {
            let root = AIMessageMarkdown(text: Self.sample)
                .padding(12).frame(width: width, alignment: .leading).background(Pal.base)
            let host = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 1400),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            defer { window.contentView = nil }
            host.frame = NSRect(x: 0, y: 0, width: width, height: 1400)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.width, width, accuracy: 1)
            XCTAssertGreaterThan(host.fittingSize.height, 300)
            XCTAssertLessThan(host.fittingSize.height, 1400)
            let bounds = host.bounds
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: bounds))
            host.cacheDisplay(in: bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: "/tmp/termo-markdown-\(Int(width)).png"))
        }
    }

    private static let sample = """
    ## 主机诊断结果

    **CPU 正常**，内存需要关注。使用 `free -h` 查看内存，~~无需重复连接~~。

    ### 建议步骤
    1. 核对资源占用
       - 查看内存与缓存
       - 保留当前 SSH 会话
    2. 确认后再处理

    > 输出只作为诊断资料。
    > **执行命令前仍需你确认。**

    - [x] 已检查网络
    - [ ] 待核对内存

    | 设备 | 使用情况 | 说明 |
    | :--- | ---: | :--- |
    | CPU | 12% | 正常 |
    | 内存 | 78% | 查看占用较高的进程 |
    | /mnt/data | 41% | 空间充足 |

    ### 配置示例
    ```json
    {"host": "server.example.com", "path": "/var/log/very/long/application/path/server.log", "enabled": true}
    ```

    [查看文档](https://example.com/docs)

    ---

    后续代码正在生成：
    ```bash
    printf '%s\\n' "collecting host information"
    """
}
