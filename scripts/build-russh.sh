#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TARGET="aarch64-apple-darwin"
OUT_DIR="$ROOT/Build/russh/$TARGET"

mkdir -p "$OUT_DIR"
cargo build --manifest-path "$ROOT/Rust/TermoSSH/Cargo.toml" \
    --target "$TARGET" \
    --release \
    --target-dir "$ROOT/Build/russh/target"

cp "$ROOT/Build/russh/target/$TARGET/release/libtermo_ssh.a" "$OUT_DIR/libtermo_ssh.a"
nm -gU "$OUT_DIR/libtermo_ssh.a" | grep -q "_termo_russh_backend_version"
printf '%s\n' "Built Rust SSH static library: $OUT_DIR/libtermo_ssh.a"
