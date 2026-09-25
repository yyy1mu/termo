#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT_DIR="$ROOT/build/russh/universal"
mkdir -p "$OUT_DIR"

# 锁定 rustup 工具链：交叉 target（x86_64-apple-darwin 等）由 rustup 管理。
# 注意：cargo 解析 rustc 靠 PATH——必须把 rustup 的 bin 前置，否则会误用
# Homebrew 的独立 rustc（不含交叉 target，报 E0463 can't find crate for core）。
if [ -x "$HOME/.cargo/bin/cargo" ]; then
    CARGO="$HOME/.cargo/bin/cargo"
    export PATH="$HOME/.cargo/bin:$PATH"
    # 1.95.0 已验证能从空缓存构建双架构库；当前 stable 1.97.1 在 macOS 上
    # 生成无法加载的 proc-macro dylib（E0463）。调用方仍可显式覆盖工具链。
    export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-1.95.0}"
else
    CARGO="$(command -v cargo)"
fi

# 双架构编译（Intel + Apple Silicon），产出一个通用静态库。
for TARGET in aarch64-apple-darwin x86_64-apple-darwin; do
    "$CARGO" build --manifest-path "$ROOT/TermoSSH/Cargo.toml" \
        --target "$TARGET" \
        --release \
        --target-dir "$ROOT/build/russh/target"
done

lipo -create \
    "$ROOT/build/russh/target/aarch64-apple-darwin/release/libtermo_ssh.a" \
    "$ROOT/build/russh/target/x86_64-apple-darwin/release/libtermo_ssh.a" \
    -output "$OUT_DIR/libtermo_ssh.a"

nm -gU "$OUT_DIR/libtermo_ssh.a" | grep -q "_termo_russh_backend_version"
printf '%s\n' "Built Rust SSH static library (universal): $OUT_DIR/libtermo_ssh.a"
