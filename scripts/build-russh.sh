#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TARGET="aarch64-apple-darwin"
OUT_DIR="$ROOT/build/russh/$TARGET"
mkdir -p "$OUT_DIR"

# 锁定 rustup 工具链：stable 1.97.1 在 macOS 上会生成无法加载的 proc-macro dylib（E0463），
# 1.95.0 已验证可用；调用方可显式覆盖。必须把 rustup 的 bin 前置，否则误用 Homebrew 的 rustc。
if [ -x "$HOME/.cargo/bin/cargo" ]; then
    CARGO="$HOME/.cargo/bin/cargo"
    export PATH="$HOME/.cargo/bin:$PATH"
    export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-1.95.0}"
else
    CARGO="$(command -v cargo)"
fi

# 必须剥掉 Xcode 导出的 MACOSX_DEPLOYMENT_TARGET（与版本值无关）：实测 14.0 和 27.0 都会让
# Xcode 27 链接器产出损坏的 proc-macro dylib（dlopen: mis-aligned LINKEDIT string pool），
# cargo 报 E0463 can't find crate for *_macro。此 workaround 不可删除。
unset MACOSX_DEPLOYMENT_TARGET

# 仅 Apple Silicon（macOS 27 起系统本身不再支持 Intel，无需 x86_64 切片）。
"$CARGO" build --manifest-path "$ROOT/TermoSSH/Cargo.toml" \
    --target "$TARGET" \
    --release \
    --target-dir "$ROOT/build/russh/target"

cp "$ROOT/build/russh/target/$TARGET/release/libtermo_ssh.a" "$OUT_DIR/libtermo_ssh.a"
nm -gU "$OUT_DIR/libtermo_ssh.a" | grep -q "_termo_russh_backend_version"
printf '%s\n' "Built Rust SSH static library: $OUT_DIR/libtermo_ssh.a"
