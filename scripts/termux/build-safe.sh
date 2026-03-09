#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TARGET="aarch64-linux-android"

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing command: $1" >&2
    exit 1
  fi
}

need_cmd cargo
need_cmd rustc

. "$SCRIPT_DIR/cargo-env.sh"

echo "[termux-build-safe] target: $TARGET"
echo "[termux-build-safe] cores: ${TERMUX_CARGO_ENV_CORES:-unknown}"
echo "[termux-build-safe] MemAvailable: ${TERMUX_CARGO_ENV_MEM_KB:-unknown} kB"
echo "[termux-build-safe] CARGO_BUILD_JOBS=${CARGO_BUILD_JOBS:-unset}"
echo "[termux-build-safe] release overrides: LTO=${CARGO_PROFILE_RELEASE_LTO:-unset}, codegen-units=${CARGO_PROFILE_RELEASE_CODEGEN_UNITS:-unset}, debug=${CARGO_PROFILE_RELEASE_DEBUG:-unset}"
echo "[termux-build-safe] dev/test debug overrides: dev=${CARGO_PROFILE_DEV_DEBUG:-unset}, test=${CARGO_PROFILE_TEST_DEBUG:-unset}"

cd "$ROOT_DIR/codex-rs"
sh "$SCRIPT_DIR/cargo-safe.sh" build --release -p codex-cli -p codex-exec --target "$TARGET"

echo "[termux-build-safe] done"
echo "[termux-build-safe] binaries:"
echo "  $ROOT_DIR/codex-rs/target/$TARGET/release/codex"
echo "  $ROOT_DIR/codex-rs/target/$TARGET/release/codex-exec"
