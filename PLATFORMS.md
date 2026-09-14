# 多端开发入口

当前 macOS 是完整产品；iOS 和 Apple Watch 已有独立的 App 入口、导航、共享模型与基础数据流，但尚未接入 SSH 连接。不要直接把 `Termo/` 的 AppKit 视图或 macOS `AppModel` 加进移动端 target。

| 目录 | 职责 |
| --- | --- |
| `Termo/` | macOS App、Rust SSH 桥接、终端、SFTP 与现有同步实现 |
| `TermoCore/Sources/TermoCore/` | 纯 Foundation 的跨平台数据契约，不依赖 AppKit、UIKit 或 WatchConnectivity |
| `iOS/Termo-iOS/App/` | iPhone/iPad 生命周期和根导航 |
| `iOS/Termo-iOS/Features/` | iOS 页面；当前有主机资料编辑和设置说明 |
| `iOS/Termo-iOS/Services/` | iOS 本地存储与发给 Watch 的资料投影 |
| `Watch/Termo-Watch/App/` | watchOS 生命周期 |
| `Watch/Termo-Watch/Features/` | Watch 页面；当前显示 iPhone 送来的主机名称 |
| `Watch/Termo-Watch/Services/` | WatchConnectivity 接收与最后一次快照缓存 |

`HostProfile` 只包含名称、地址、端口和用户名。iOS 本地资料写入 Application Support；密码与私钥尚未实现，未来必须放在该设备的 Keychain。传往 Watch 的 `WatchSnapshot` 进一步只保留主机 ID 和名称。Watch 当前**不显示在线状态、不执行命令**；没有收到 iPhone 快照时展示明确的空状态。iOS 主机资料也尚未与 macOS/WebDAV 合并。

## 构建和运行

修改 `project.yml` 或增删 Swift 文件后，在仓库根目录运行 `xcodegen generate`。Xcode 选择 `Termo-iOS` Scheme 开发 iPhone/iPad；它会通过 `Embed Watch Content` 自动带上 `Termo-Watch`。单独调试手表页面时选择 `Termo-Watch` Scheme，并使用配对的 iPhone/Watch 模拟器或真机。

```bash
swift test --package-path TermoCore
xcodebuild -project Termo.xcodeproj -scheme Termo-iOS -configuration Debug \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Termo.xcodeproj -scheme Termo-Watch -configuration Debug \
  -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

当前开发机有 iOS/watchOS SDK，但未安装可供 Xcode 选择的模拟器设备/运行环境，因此上述两个 `xcodebuild` 目标在选择 destination 时会停止。新增代码已分别用 iOS 16 和 watchOS 9 模拟器 SDK 通过 Swift 类型检查；安装对应模拟器运行环境或连接设备后，还需要执行完整构建与配对收发验证。真机安装前需在 Xcode 给 iOS 和 Watch target 选择有效的开发团队。

## 后续接入顺序

1. 将 macOS `Host` 的跨平台字段显式映射到 `HostProfile`，保持现有 ID；不要迁移运行时状态和 Keychain 密文。
2. iOS 独立接入 SSH 会话与钥匙串凭证，再实现连接、终端和文件页面；本地终端和 macOS 窗口逻辑不要迁移。
3. 为 iOS 与 macOS 设计明确的同步协议及迁移版本，再让 Watch 消费经过筛选的状态快照。WatchConnectivity 的 `applicationContext` 只交付最新快照，不适合作为命令执行队列。
