import Foundation
import TermoCore

/// 隐藏诊断入口：`xcrun simctl launch --console booted com.cloudza.termo.ios -sshSelfTest <host> <port> <user> <password>`
/// 直接在控制台打印指纹扫描与分阶段诊断结果，用于排查连接链路（不进入 UI）。
enum IOSSSHSelfTest {
    static func runIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-sshSelfTest"), args.count > i + 4 else { return }
        let host = args[i + 1], port = Int(args[i + 2]) ?? 22
        let conn = SSHConnection(user: args[i + 3], host: host, port: port, password: args[i + 4])
        print("[SELFTEST] begin \(host):\(port) user=\(conn.user)")
        let sem = DispatchSemaphore(value: 0)
        Task {
            let result = await IOSHostKeyVerifier.preflight(connection: conn)
            print("[SELFTEST] preflight=\(result)")
            if case .scanFailed = result {
                let message = await Task.detached { IOSHostKeyVerifier.diagnose(connection: conn) }.value
                print("[SELFTEST] diagnose=\(message ?? "nil")")
            }
            print("[SELFTEST] end")
            sem.signal()
        }
        sem.wait()
        exit(0)
    }
}
