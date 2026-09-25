import Foundation

enum HostSystemProbe {
    static let cacheTTL: TimeInterval = 30 * 60

    /// 远端一次性探测脚本。内存与磁盘输出原始字节，显存按每张卡输出 MiB。
    static let script = """
        [ -r /etc/os-release ] && . /etc/os-release
        echo "OS=${PRETTY_NAME:-$(uname -sr)}"
        echo "CORES=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null)"
        mem=$(awk '/MemTotal/{printf "%.0f", $2*1024; exit}' /proc/meminfo 2>/dev/null)
        [ -z "$mem" ] && mem=$(sysctl -n hw.memsize 2>/dev/null)
        echo "MEM=$mem"
        echo "DISK=$(df -k / 2>/dev/null | awk 'NR==2{printf "%.0f %.0f", $3*1024, $2*1024}')"
        NVIDIA_SMI=$(command -v nvidia-smi 2>/dev/null)
        if [ -z "$NVIDIA_SMI" ]; then
          for candidate in /usr/bin/nvidia-smi /usr/local/bin/nvidia-smi /usr/local/nvidia/bin/nvidia-smi /opt/nvidia/bin/nvidia-smi; do
            [ -x "$candidate" ] && { NVIDIA_SMI=$candidate; break; }
          done
        fi
        if [ -n "$NVIDIA_SMI" ]; then
          "$NVIDIA_SMI" --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | awk '$1 ~ /^[0-9]+$/{print "VRAM="$1}'
        fi
        nvidia_names=$([ -n "$NVIDIA_SMI" ] && "$NVIDIA_SMI" --query-gpu=name --format=csv,noheader 2>/dev/null)
        [ -n "$nvidia_names" ] && printf '%s\\n' "$nvidia_names" | awk '{gsub(/"/,""); print "GPU="$0}'
        for card in /sys/class/drm/card[0-9]*; do
          [ -r "$card/device/vendor" ] || continue
          vendor=$(cat "$card/device/vendor" 2>/dev/null)
          case "$vendor" in
            0x10de) [ -n "$nvidia_names" ] && continue; vendor=NVIDIA; fallback=GPU ;;
            0x1002) vendor=AMD; fallback=Radeon ;;
            0x8086) vendor=Intel; fallback=Graphics ;;
            *) continue ;;
          esac
          index=${card##*/}; index=${index#card}
          name=$(cat "$card/device/product_name" 2>/dev/null)
          [ -n "$name" ] || name="$fallback card$index"
          printf 'GPU=%s %s\\n' "$vendor" "$name"
          bytes=$(cat "$card/device/mem_info_vram_total" 2>/dev/null)
          case "$bytes" in ''|*[!0-9]*) ;; *) [ "$bytes" -gt 0 ] && printf 'VRAM=%s\\n' "$((bytes / 1048576))";; esac
        done
        """

    static func parse(_ output: String, now: Date = Date()) -> HostSpecs? {
        var specs = HostSpecs()
        var vramMiB: [Int64] = []
        var gpuNames: [String] = []

        for line in output.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "OS":
                specs.os = value
            case "CORES":
                specs.cores = value
            case "MEM":
                if let bytes = Int64(value) { specs.memory = formatBytes(bytes) }
            case "DISK":
                let parts = value.split(separator: " ")
                if parts.count == 2, let used = Int64(parts[0]), let total = Int64(parts[1]) {
                    specs.disk = "\(formatBytes(used)) / \(formatBytes(total))"
                }
            case "VRAM":
                if let mib = Int64(value), mib > 0 { vramMiB.append(mib) }
            case "GPU":
                if !value.isEmpty { gpuNames.append(value) }
            default:
                break
            }
        }

        if !vramMiB.isEmpty { specs.vram = formatVRAM(vramMiB) }
        if !gpuNames.isEmpty {
            specs.gpu =
                gpuNames.count > 1
                ? (Set(gpuNames).count == 1
                    ? "\(gpuNames[0]) ×\(gpuNames.count)" : "\(gpuNames[0]) 等 \(gpuNames.count) 张")
                : gpuNames[0]
        }
        guard !specs.isEmpty else { return nil }
        specs.probedAt = now
        return specs
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .decimal
        return formatter.string(fromByteCount: bytes)
    }

    private static func formatVRAM(_ perCardMiB: [Int64]) -> String {
        let gib: (Int64) -> String = { String(format: "%.1f", Double($0) / 1024) }
        if perCardMiB.count > 1, Set(perCardMiB).count == 1 {
            return "\(gib(perCardMiB[0])) GiB ×\(perCardMiB.count)"
        }
        return "\(gib(perCardMiB.reduce(0, +))) GiB"
    }
}
