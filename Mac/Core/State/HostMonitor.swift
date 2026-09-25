import SwiftUI

/// 每台主机一份运行状态，由终端设置控制；采集使用共享 SSH 传输上的独立 exec 通道。
/// 离开面板不停止，用户停止或删除主机时只释放监控通道，不影响终端和文件。
@MainActor
final class HostMonitor: ObservableObject {
    enum Phase: Equatable { case stopped, connecting, live, unsupported, error }

    @Published private(set) var metrics: HostMetrics?
    @Published private(set) var phase: Phase = .stopped
    @Published private(set) var errorMessage: String?
    @Published private(set) var trustBlocked = false
    @Published private(set) var verifiedFingerprint: String?
    @Published private(set) var netHistory: [NetSample] = []   // 最近若干帧网速，供波动折线图
    @Published private(set) var netHistoryByInterface: [String: [NetSample]] = [:]
    @Published private(set) var netTick = 0                    // 每追加一帧自增，驱动折线整条左滑一格
    private static let netHistoryCap = 42                       // 与折线窗口（visible+2）一致，填满后无需补齐

    /// 每解析出一帧调用一次，供上层做阈值告警；监控本身只产数据、不判定告警。
    var onSample: ((HostMetrics) -> Void)?

    private var ssh: SSHConnection
    private var session: SSHSession?     // 本监控独占操作句柄，底层传输共享
    private var launchGen = 0            // 每次 launch 自增；旧连接的回调据此失效（替代 Process 的 terminationHandler=nil）
    private var buffer = Data()
    @Published private(set) var isEnabled = false
    @Published private(set) var monitoringAllowed: Bool
    private var restartWork: DispatchWorkItem?

    // 上一帧原始计数器，用于算差值
    private var prevCpu: [String: (idle: Double, total: Double)] = [:]   // 键为 cpu / cpu0 / cpu1…
    private var prevNet: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var prevProcesses: [String: UInt64] = [:]
    private var prevUptime: Double?

    // 采样间隔，需与远端 sleep 一致；作为网速 Δt 的兜底（实际优先用 uptime 差更准）
    private static let interval = 2

    /// 一帧采样的间隔秒数；供折线图把左滑动画时长对齐采样节奏，保证连续不顿挫。
    var sampleInterval: Double { Double(Self.interval) }

    /// 远端内联采样脚本：无 /proc 立即报 NOPROC 退出；否则每 interval 秒输出一帧，以 === 分隔。
    /// CPU 输出整机与每核；网络逐网卡输出原始 UInt64 字节计数，排除 lo；磁盘只列真实块设备。
    /// NVIDIA 由 nvidia-smi 采样，AMD/Intel 由 DRM sysfs 识别；没有可靠指标时输出空字段。
    /// 内存单位 kB、磁盘 1K 块、显存 MiB。
    private static let script = """
    [ -r /proc/stat ] || { echo NOPROC; echo ===; exit 0; }
    export LC_ALL=C
    CLOCK_TICKS=$(getconf CLK_TCK 2>/dev/null)
    PAGE_BYTES=$(getconf PAGESIZE 2>/dev/null)
    NVIDIA_SMI=$(command -v nvidia-smi 2>/dev/null)
    if [ -z "$NVIDIA_SMI" ]; then
      for candidate in /usr/bin/nvidia-smi /usr/local/bin/nvidia-smi /usr/local/nvidia/bin/nvidia-smi /opt/nvidia/bin/nvidia-smi; do
        [ -x "$candidate" ] && { NVIDIA_SMI=$candidate; break; }
      done
    fi
    NVIDIA_DEVICE=0
    for gpu in /proc/driver/nvidia/gpus/*/information; do
      [ -r "$gpu" ] && NVIDIA_DEVICE=1
    done
    PCI_GPU=0
    if command -v lspci >/dev/null 2>&1; then
      pci_vendors=$(lspci -Dn 2>/dev/null | awk '$2 ~ /^03/ {split($3, id, ":"); if (id[1] ~ /^(10de|1002|8086)$/) print id[1]}')
      [ -n "$pci_vendors" ] && PCI_GPU=1
      case "$pci_vendors" in *10de*) NVIDIA_DEVICE=1;; esac
    fi
    while :; do
      awk '/^cpu[0-9]* /{print "CPU "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9}' /proc/stat
      awk '/^(MemTotal|MemAvailable|SwapTotal|SwapFree):/{gsub(/:/,"",$1); print "MEM "$1" "$2}' /proc/meminfo
      awk 'NR>2 {name=$0; sub(/:[^:]*$/, "", name); gsub(/^[[:space:]]+|[[:space:]]+$/, "", name); data=$0; sub(/^.*:/, "", data); sub(/^[[:space:]]+/, "", data); n=split(data, v, /[[:space:]]+/); if(name!="lo" && n>=9 && v[1] ~ /^[0-9]+$/ && v[9] ~ /^[0-9]+$/) print "NET "name" "v[1]" "v[9]}' /proc/net/dev
      echo "UP $(cut -d" " -f1 /proc/uptime)"
      echo "LOAD $(cut -d" " -f1-3 /proc/loadavg)"
      df -kP 2>/dev/null | awk 'NR>1 && index($1,"/dev/")==1{mount=$6; for(i=7;i<=NF;i++) mount=mount" "$i; print "VOLUME "$1"|"mount"|"$3"|"$2}'
      case "$CLOCK_TICKS:$PAGE_BYTES" in
        *[!0-9:]*|:*|*:) ;;
        *)
          echo "PROC_CLOCK $CLOCK_TICKS"
          for stat in /proc/[0-9]*/stat; do
            IFS= read -r row 2>/dev/null < "$stat" && printf '%s\\n' "$row"
          done | awk -v page="$PAGE_BYTES" '{pid=$1; name=$0; sub(/^[^(]*\\(/,"",name); sub(/\\) [^)]*$/,"",name); rest=$0; sub(/^.*\\) /,"",rest); n=split(rest,v," "); if(n>=22) print "PROC "pid" "v[20]" "sprintf("%.0f",v[12]+v[13])" "sprintf("%.0f",v[22]*page/1024)" "name}'
          echo 'PROC_STATUS OK'
          ;;
      esac
      if command -v ss >/dev/null 2>&1; then
        if sockets=$(ss -H -tunap 2>/dev/null); then
          printf '%s\\n' "$sockets" | awk 'NF {print "NETCONN "$0}'
          echo 'NETPROC_STATUS OK'
        fi
      fi
      # name 放查询列最后：对含逗号的型号名重组剩余字段。
      nvidia_rows=
      nvidia_failed=0
      if [ -n "$NVIDIA_SMI" ]; then
        nvidia_raw=$("$NVIDIA_SMI" --query-gpu=index,utilization.gpu,memory.used,memory.total,temperature.gpu,uuid,name --format=csv,noheader,nounits 2>/dev/null) || nvidia_failed=1
        nvidia_rows=$(printf '%s\\n' "$nvidia_raw" | awk -F", *" 'NF>=7 && $1 ~ /^[0-9]+$/ {name=$7; for(i=8;i<=NF;i++) name=name", "$i; gsub(/"/,"",name); print "GPU NVIDIA|"$1"|"name"|"$2"|"$3"|"$4"|"$5"|nvidia-smi|"$6}')
      fi
      [ -n "$nvidia_rows" ] && printf '%s\\n' "$nvidia_rows"
      if [ -n "$nvidia_rows" ]; then
        if gpu_apps=$("$NVIDIA_SMI" --query-compute-apps=gpu_uuid,pid,used_gpu_memory,process_name --format=csv,noheader,nounits 2>/dev/null); then
          printf '%s\\n' "$gpu_apps" | awk -F", *" 'NF>=4 && $2 ~ /^[0-9]+$/ {name=$4; for(i=5;i<=NF;i++) name=name", "$i; print "GPUPROC "$1"|"$2"|"$3"|"name}'
          echo 'GPUPROC_STATUS OK'
        fi
      fi
      drm_found=0
      for card in /sys/class/drm/card[0-9]*; do
        [ -r "$card/device/vendor" ] || continue
        vendor=$(cat "$card/device/vendor" 2>/dev/null)
        case "$vendor" in
          0x10de) NVIDIA_DEVICE=1; [ -n "$nvidia_rows" ] && continue; vendor=NVIDIA; fallback=GPU ;;
          0x1002) vendor=AMD; fallback=Radeon ;;
          0x8086) vendor=Intel; fallback=Graphics ;;
          *) continue ;;
        esac
        drm_found=1
        index=${card##*/}; index=${index#card}
        name=$(cat "$card/device/product_name" 2>/dev/null)
        [ -n "$name" ] || name="$fallback card$index"
        name=$(printf '%s' "$name" | tr '|' ' ')
        util=$(cat "$card/device/gpu_busy_percent" 2>/dev/null)
        used=$(cat "$card/device/mem_info_vram_used" 2>/dev/null)
        total=$(cat "$card/device/mem_info_vram_total" 2>/dev/null)
        case "$used" in ''|*[!0-9]*) used=;; *) used=$((used / 1048576));; esac
        case "$total" in ''|*[!0-9]*) total=;; *) total=$((total / 1048576));; esac
        temp=
        for sensor in "$card"/device/hwmon/hwmon*/temp1_input; do
          [ -r "$sensor" ] || continue
          milli=$(cat "$sensor" 2>/dev/null)
          case "$milli" in ''|*[!0-9]*) ;; *) temp=$((milli / 1000));; esac
          break
        done
        printf 'GPU %s|%s|%s|%s|%s|%s|%s|DRM sysfs\\n' "$vendor" "$index" "$name" "$util" "$used" "$total" "$temp"
      done
      if [ "$NVIDIA_DEVICE" = 1 ] && [ -z "$nvidia_rows" ]; then
        [ -z "$NVIDIA_SMI" ] && echo 'GPU_STATUS TOOL_MISSING' || echo 'GPU_STATUS QUERY_FAILED'
      elif [ -n "$nvidia_rows" ] || [ "$drm_found" = 1 ]; then
        echo 'GPU_STATUS OK'
      elif [ "$nvidia_failed" = 1 ]; then
        echo 'GPU_STATUS QUERY_FAILED'
      elif [ "$PCI_GPU" = 1 ] || [ ! -d /sys/class/drm ]; then
        echo 'GPU_STATUS DEVICE_UNAVAILABLE'
      else
        echo 'GPU_STATUS NONE'
      fi
      echo "==="
      sleep __INTERVAL__
    done
    """

    init(ssh: SSHConnection) {
        self.ssh = ssh
        self.monitoringAllowed = ssh.monitoringEnabled ?? true
    }

    /// 兜底回收：正常流程靠 stop() 清理。万一对象未 stop 即被释放（如所有者将来漏调 stop），
    /// 远端采样脚本是 `while :; sleep` 永不自行结束 —— 这里必须打断流（cancel 线程安全），
    /// 否则后台阻塞线程 + TCP 连接 + 远端进程会永久泄漏。
    deinit {
        session?.cancel()
        restartWork?.cancel()
    }

    /// 用最新连接信息刷新（如「每次询问」先输错密码、缓存的监控仍持旧密码，改对后需更新）。
    /// 关键字段变化时若正在运行则立即用新信息重连，避免缓存的监控一直用旧/错密码连接失败。
    func updateConnection(_ s: SSHConnection) {
        let targetChanged = s.host != ssh.host || s.port != ssh.port
        let changed = s.password != ssh.password || s.host != ssh.host
            || s.port != ssh.port || s.user != ssh.user || s.keyId != ssh.keyId || s.keyPath != ssh.keyPath
            || s.authMethod != ssh.authMethod
        ssh = s
        monitoringAllowed = s.monitoringEnabled ?? true
        if targetChanged {
            metrics = nil; netHistory = []; netHistoryByInterface = [:]; verifiedFingerprint = nil
            trustBlocked = false; errorMessage = nil
        }
        guard monitoringAllowed else { stop(); return }
        guard changed, isEnabled else { return }
        restartWork?.cancel(); restartWork = nil
        teardownProcess()
        phase = .connecting
        launch()
    }

    func start(allowTrustRetry: Bool = false) {
        guard monitoringAllowed, !isEnabled else { return }
        guard !trustBlocked || allowTrustRetry else { phase = .error; return }
        guard !ssh.host.isEmpty else { phase = .unsupported; return }
        isEnabled = true
        phase = .connecting
        launch()
    }

    func stop() {
        isEnabled = false
        restartWork?.cancel(); restartWork = nil
        teardownProcess()
        buffer.removeAll()
        phase = .stopped
        if !trustBlocked { errorMessage = nil }
    }

    /// 网络切换时调用：立刻丢弃当前连接重连，不等 keepalive 超时。
    /// launch 内部已对离线自守，离线则置 error 等下次网络恢复再连。
    func handleNetworkChange() {
        guard isEnabled else { return }
        restartWork?.cancel(); restartWork = nil
        teardownProcess()
        phase = .connecting
        launch()
    }

    private func teardownProcess() {
        launchGen &+= 1        // 使旧 stream 的回调（ingest/结束重连）失效
        session?.cancel()      // 打断流；其后台线程会自行 close 收尾
        session = nil
    }

    private func launch() {
        // 离线时不发起连接，等网络恢复由 handleNetworkChange 触发重连，避免离线期间空转重试。
        guard NetworkMonitor.shared.isOnline else { phase = .error; return }
        let cmd = Self.script.replacingOccurrences(of: "__INTERVAL__", with: String(Self.interval))
        errorMessage = nil
        trustBlocked = false
        // 统一入口会在首次认证前验证指纹；复用时继承已验证连接。
        let connection = ssh

        prevCpu.removeAll(); prevNet.removeAll(); prevProcesses.removeAll(); prevUptime = nil
        buffer.removeAll()
        launchGen &+= 1
        let gen = launchGen
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let session: SSHSession
            do {
                session = try SSHSessionPool.shared.acquireOperation(for: connection)
            } catch {
                Task { @MainActor in self?.connectionFailed(error, gen: gen) }
                return
            }
            Task { @MainActor in
                guard let self else { session.cancel(); return }
                self.adoptSession(session, gen: gen)
            }
            session.execStream(cmd) { data in                        // 同步阻塞直到 cancel/EOF
                Task { @MainActor in guard gen == self?.launchGen else { return }; self?.ingest(data) }
            }
            session.close()                                          // 只归还监控操作，不断开其他通道
            Task { @MainActor in self?.streamEnded(gen: gen) }
        }
    }

    /// 后台线程连上后回主线程认领会话；若此次 launch 已被取代/停止则就地取消。
    private func adoptSession(_ s: SSHSession, gen: Int) {
        if gen == launchGen {
            session = s
            verifiedFingerprint = s.fingerprintSHA256
        } else { s.cancel() }
    }

    private func connectionFailed(_ error: Error, gen: Int) {
        guard gen == launchGen, isEnabled else { return }
        phase = .error
        errorMessage = error.localizedDescription
        trustBlocked = (error as? SSHSession.SSHError)?.isHostKeyFailure == true
        if trustBlocked {
            // 未知/变更指纹需要明确确认；网络恢复不能自动绕过或反复重试。
            isEnabled = false
            restartWork?.cancel(); restartWork = nil
        } else { scheduleRestart() }
    }

    /// 流结束（EOF/错误/连接失败）。仅当前代际有效；我方未停止则延迟重连。
    private func streamEnded(gen: Int) {
        guard gen == launchGen else { return }   // 已被新 launch 取代 → 忽略
        session = nil
        guard isEnabled else { return }            // 我方主动停止，不重连
        phase = .error
        scheduleRestart()
    }

    /// 连接意外断开后延迟重连；用户停止后不再重试。
    private func scheduleRestart() {
        guard isEnabled, restartWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartWork = nil
            if self.isEnabled { self.phase = .connecting; self.launch() }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        // 以 "===\n" 为帧界逐帧解析；不完整的尾部留在 buffer 等下次。
        let delim = Data("===\n".utf8)
        while let r = buffer.range(of: delim) {
            let frame = buffer.subdata(in: buffer.startIndex..<r.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<r.upperBound)
            if let text = String(data: frame, encoding: .utf8) { parse(text) }
        }
    }

    func parse(_ frame: String) {
        if frame.split(separator: "\n").contains("NOPROC") {
            phase = .unsupported
            isEnabled = false            // 远端无 /proc，已 exit，不再重连
            return
        }

        var m = HostMetrics()
        var memAvail: Int64 = 0
        var swapFree: Int64 = 0
        var curCpu: [String: (idle: Double, total: Double)] = [:]
        var cores: [(idx: Int, pct: Double)] = []
        var curNet: [String: (rx: UInt64, tx: UInt64)] = [:]
        var processRows: [(pid: Int, start: UInt64, ticks: UInt64, memory: Int64, name: String)] = []
        var clockTicks: Double?
        var connectionCounts: [Int: Int] = [:]

        for raw in frame.split(separator: "\n") {
            let p = raw.split(separator: " ").map(String.init)
            guard let key = p.first else { continue }
            switch key {
            case "CPU":
                // CPU <名> user nice system idle iowait irq softirq steal；名为 cpu（整机）或 cpuN（单核）
                guard p.count >= 6 else { break }
                let name = p[1]
                let v = p.dropFirst(2).compactMap { Double($0) }
                guard v.count >= 4 else { break }
                let total = v.reduce(0, +)
                let idle = v[3] + (v.count > 4 ? v[4] : 0)        // idle + iowait
                curCpu[name] = (idle, total)
                if let prev = prevCpu[name], total > prev.total {
                    let pct = max(0, min(100, (1 - (idle - prev.idle) / (total - prev.total)) * 100))
                    if name == "cpu" { m.cpuPercent = pct }
                    else if let n = Int(name.dropFirst(3)) { cores.append((n, pct)) }
                }
            case "MEM":
                if p.count >= 3, let kb = Int64(p[2]) {
                    switch p[1] {
                    case "MemTotal": m.memTotalKB = kb
                    case "MemAvailable": memAvail = kb
                    case "SwapTotal": m.swapTotalKB = kb
                    case "SwapFree": swapFree = kb
                    default: break
                    }
                }
            case "NET":
                if p.count >= 4, let rx = UInt64(p[2]), let tx = UInt64(p[3]) {
                    curNet[p[1]] = (rx, tx)
                }
            case "UP":
                if p.count >= 2, let up = Double(p[1]) { m.uptimeSecs = up }
            case "LOAD":
                if p.count >= 4 {
                    m.load1 = Double(p[1]) ?? 0
                    m.load5 = Double(p[2]) ?? 0
                    m.load15 = Double(p[3]) ?? 0
                }
            case "PROC_CLOCK":
                clockTicks = p.count > 1 ? Double(p[1]).flatMap { $0 > 0 && $0.isFinite ? $0 : nil } : nil
            case "PROC_STATUS":
                m.processesAvailable = p.dropFirst().first == "OK"
            case "PROC":
                if p.count >= 6, let pid = Int(p[1]), pid > 0,
                   let start = UInt64(p[2]), let ticks = UInt64(p[3]), let memory = Int64(p[4]), memory >= 0 {
                    processRows.append((pid, start, ticks, memory, p[5...].joined(separator: " ")))
                }
            case "GPUPROC_STATUS":
                m.gpuProcessesAvailable = p.dropFirst().first == "OK"
            case "GPUPROC":
                let fields = raw.dropFirst(8).split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
                if fields.count == 4, let pid = Int(fields[1]), pid > 0 {
                    m.gpuProcesses.append(GPUProcessUsage(
                        gpuUUID: fields[0], pid: pid, name: fields[3],
                        memoryMB: Int64(fields[2]).flatMap { $0 >= 0 ? $0 : nil }))
                }
            case "NETPROC_STATUS":
                m.networkProcessesAvailable = p.dropFirst().first == "OK"
            case "NETCONN":
                let pids = Set(raw.components(separatedBy: "pid=").dropFirst().compactMap {
                    Int($0.prefix(while: { $0.isNumber }))
                })
                for pid in pids { connectionCounts[pid, default: 0] += 1 }
            case "VOLUME":
                let fields = raw.dropFirst(7).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                if fields.count == 4, let used = Int64(fields[2]), used >= 0,
                   let total = Int64(fields[3]), total > 0 {
                    m.disks.append(DiskUsage(mount: fields[1], usedKB: used, totalKB: total, device: fields[0]))
                }
            case "DISK":
                // DISK <挂载点> <已用KB> <总KB>；挂载点可能含空格，按「末两列为数字」反向取。
                if p.count >= 4, let u = Int64(p[p.count - 2]), let t = Int64(p[p.count - 1]), t > 0 {
                    let mount = p[1..<(p.count - 2)].joined(separator: " ")
                    m.disks.append(DiskUsage(mount: mount, usedKB: u, totalKB: t))
                }
            case "GPU":
                // GPU vendor|index|name|util|memUsedMB|memTotalMB|temp。
                // 缺失或不支持的指标保留 nil，不能显示成 0。
                let f = p.dropFirst().joined(separator: " ")
                    .split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if f.count >= 7, ["NVIDIA", "AMD", "Intel"].contains(f[0]), let idx = Int(f[1]) {
                    m.gpus.append(GPUInfo(
                        index: idx, vendor: f[0], name: f[2],
                        utilPercent: Double(f[3]).flatMap { (0...100).contains($0) ? $0 : nil },
                        memUsedMB: Int64(f[4]),
                        memTotalMB: Int64(f[5]),
                        tempC: Int(f[6]),
                        source: f.count > 7 ? f[7] : "", uuid: f.count > 8 ? f[8] : ""))
                }
            case "GPU_STATUS":
                if p.count >= 2, let status = GPUCollectionStatus(rawValue: p[1]) {
                    m.gpuStatus = status
                }
            default:
                break
            }
        }

        m.memUsedKB = max(0, m.memTotalKB - memAvail)
        m.swapUsedKB = max(0, m.swapTotalKB - swapFree)
        m.perCore = cores.sorted { $0.idx < $1.idx }.map { $0.pct }
        m.gpus.sort { $0.vendor == $1.vendor ? $0.index < $1.index : $0.vendor < $1.vendor }
        prevCpu = curCpu

        // 每张网卡分别做差，新增、消失或计数器回退不影响其余网卡。
        // UInt64 先做差再转 Double，避免累计字节数超过 2^53 后丢失小增量。
        if let prevUptime, m.uptimeSecs < prevUptime { prevNet.removeAll() }
        let dt = (prevUptime.map { m.uptimeSecs - $0 }).flatMap { $0 > 0 ? $0 : nil } ?? Double(Self.interval)
        var totalRx = 0.0, totalTx = 0.0
        var sawRx = false, sawTx = false
        var nextHistories: [String: [NetSample]] = [:]
        for name in curNet.keys.sorted() {
            guard let counters = curNet[name] else { continue }
            let previous = prevNet[name]
            let rx = previous.flatMap { counters.rx >= $0.rx ? Double(counters.rx - $0.rx) / dt : nil }
            let tx = previous.flatMap { counters.tx >= $0.tx ? Double(counters.tx - $0.tx) / dt : nil }
            m.interfaces.append(NetworkInterfaceUsage(name: name, rxBytesPerSec: rx, txBytesPerSec: tx))
            if let rx { totalRx += rx; sawRx = true }
            if let tx { totalTx += tx; sawTx = true }
            var samples = netHistoryByInterface[name] ?? []
            if let rx, let tx {
                samples.append(NetSample(rx: rx, tx: tx))
                if samples.count > Self.netHistoryCap { samples.removeFirst(samples.count - Self.netHistoryCap) }
            }
            nextHistories[name] = samples
        }
        m.netRxBytesPerSec = sawRx ? totalRx : nil
        m.netTxBytesPerSec = sawTx ? totalTx : nil
        // PID 可复用，必须连同启动时刻匹配；重启/计数器回退/首帧不伪造 0%。
        let processInterval = prevUptime.map { m.uptimeSecs - $0 }
        var nextProcesses: [String: UInt64] = [:]
        for row in processRows {
            let identity = "\(row.pid):\(row.start)"
            var cpu: Double?
            if let ticks = clockTicks, let elapsed = processInterval, elapsed > 0,
               let previous = prevProcesses[identity], row.ticks >= previous {
                cpu = Double(row.ticks - previous) / ticks / elapsed * 100
            }
            nextProcesses[identity] = row.ticks
            m.processes.append(MonitorProcess(pid: row.pid, startTicks: row.start, name: row.name,
                                              cpuPercent: cpu, memoryKB: row.memory))
        }
        prevProcesses = nextProcesses
        let processNames = Dictionary(m.processes.map { ($0.pid, $0.name) }, uniquingKeysWith: { first, _ in first })
        m.networkProcesses = connectionCounts.map { pid, count in
            NetworkProcessUsage(pid: pid, name: processNames[pid] ?? "PID \(pid)",
                                connections: count)
        }.sorted { $0.connections == $1.connections ? $0.pid < $1.pid : $0.connections > $1.connections }
        // 每个挂载点/设备进程保持稳定且唯一的视图标识。
        var mounts = Set<String>()
        m.disks = m.disks.filter { mounts.insert($0.id).inserted }
        var gpuProcessIDs = Set<String>()
        m.gpuProcesses = m.gpuProcesses.filter { gpuProcessIDs.insert($0.id).inserted }
        prevNet = curNet
        netHistoryByInterface = nextHistories
        prevUptime = m.uptimeSecs

        if let rx = m.netRxBytesPerSec, let tx = m.netTxBytesPerSec {
            netHistory.append(NetSample(rx: rx, tx: tx))
            if netHistory.count > Self.netHistoryCap { netHistory.removeFirst(netHistory.count - Self.netHistoryCap) }
            netTick &+= 1
        }

        metrics = m
        phase = .live
        onSample?(m)
    }

}
