#!/bin/sh
# 构建 iOS 用 Rust SSH 引擎 XCFramework（device arm64 + 模拟器 arm64）。
# 由 Termo-iOS target 的 preBuildScript 调用；cargo 增量构建，日常开销极小。
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT_DIR="$ROOT/build/russh/ios"
mkdir -p "$OUT_DIR"

# 与 build-russh.sh 同一把锁：rustup 1.95.0（stable 1.97.1 的 proc-macro dylib 损坏，E0463）。
if [ -x "$HOME/.cargo/bin/cargo" ]; then
    CARGO="$HOME/.cargo/bin/cargo"
    export PATH="$HOME/.cargo/bin:$PATH"
    export RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-1.95.0}"
else
    CARGO="$(command -v cargo)"
fi

# Xcode Run Script 会导出 MACOSX_DEPLOYMENT_TARGET，导致 proc-macro dylib 损坏（E0463），必须剥掉。
# IPHONEOS_DEPLOYMENT_TARGET 则显式钉在 App 的最低版本：不设置时 cc/ring 的对象按 SDK 版本（27.0）标记，
# 链接进 iOS 16 target 会产生大量「built for newer version」警告。
unset MACOSX_DEPLOYMENT_TARGET
export IPHONEOS_DEPLOYMENT_TARGET=16.0

for TARGET in aarch64-apple-ios aarch64-apple-ios-sim; do
    "$CARGO" build --manifest-path "$ROOT/TermoSSH/Cargo.toml" \
        --target "$TARGET" \
        --release \
        --target-dir "$ROOT/build/russh/target"
done

rm -rf "$OUT_DIR/TermoSSH.xcframework"
xcodebuild -create-xcframework \
    -library "$ROOT/build/russh/target/aarch64-apple-ios/release/libtermo_ssh.a" \
    -library "$ROOT/build/russh/target/aarch64-apple-ios-sim/release/libtermo_ssh.a" \
    -output "$OUT_DIR/TermoSSH.xcframework"

nm -gU "$ROOT/build/russh/target/aarch64-apple-ios/release/libtermo_ssh.a" | grep -q "_termo_russh_backend_version"
printf '%s\n' "Built Rust SSH XCFramework: $OUT_DIR/TermoSSH.xcframework"
