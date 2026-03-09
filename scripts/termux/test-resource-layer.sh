#!/usr/bin/env sh
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPTS_DIR="$ROOT_DIR/scripts/termux"
SYSTEM_PATH=${PATH:-/usr/bin:/bin}
TARGET="aarch64-linux-android"

assert_eq() {
  actual=$1
  expected=$2
  label=$3
  if [ "$actual" != "$expected" ]; then
    echo "assert_eq failed for $label: expected '$expected', got '$actual'" >&2
    exit 1
  fi
}

assert_empty() {
  value=$1
  label=$2
  if [ -n "$value" ]; then
    echo "assert_empty failed for $label: got '$value'" >&2
    exit 1
  fi
}

assert_contains() {
  haystack=$1
  needle=$2
  label=$3
  case $haystack in
    *"$needle"*) ;;
    *)
      echo "assert_contains failed for $label: missing '$needle'" >&2
      exit 1
      ;;
  esac
}

parse_var() {
  payload=$1
  key=$2
  printf '%s\n' "$payload" | sed -n "s/^${key}=//p" | head -n 1
}

expected_jobs() {
  cores=$(nproc 2>/dev/null || echo 1)
  mem_kb=$(awk '/MemAvailable:/ { print $2 }' /proc/meminfo 2>/dev/null || echo 0)

  if [ "${mem_kb:-0}" -lt 3000000 ]; then
    echo 1
    return
  fi

  if [ "${mem_kb:-0}" -lt 5000000 ]; then
    echo 2
    return
  fi

  jobs=$((cores / 2))
  if [ "$jobs" -lt 2 ]; then
    jobs=2
  fi
  if [ "$jobs" -gt 4 ]; then
    jobs=4
  fi
  echo "$jobs"
}

TMP_DIR=$(mktemp -d "$ROOT_DIR/.tmp-termux-resource-layer.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM
FAKE_BIN_DIR="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN_DIR"

cat >"$FAKE_BIN_DIR/cargo" <<'EOF'
#!/usr/bin/env sh
set -eu
printf 'tool=cargo\n'
printf 'argv=%s\n' "$*"
printf 'CARGO_BUILD_JOBS=%s\n' "${CARGO_BUILD_JOBS-}"
printf 'CARGO_PROFILE_RELEASE_LTO=%s\n' "${CARGO_PROFILE_RELEASE_LTO-}"
printf 'CARGO_PROFILE_RELEASE_CODEGEN_UNITS=%s\n' "${CARGO_PROFILE_RELEASE_CODEGEN_UNITS-}"
printf 'CARGO_PROFILE_RELEASE_DEBUG=%s\n' "${CARGO_PROFILE_RELEASE_DEBUG-}"
printf 'CARGO_PROFILE_DEV_DEBUG=%s\n' "${CARGO_PROFILE_DEV_DEBUG-}"
printf 'CARGO_PROFILE_TEST_DEBUG=%s\n' "${CARGO_PROFILE_TEST_DEBUG-}"
exit "${FAKE_EXIT_CODE:-0}"
EOF

cat >"$FAKE_BIN_DIR/just" <<'EOF'
#!/usr/bin/env sh
set -eu
printf 'tool=just\n'
printf 'argv=%s\n' "$*"
printf 'CARGO_BUILD_JOBS=%s\n' "${CARGO_BUILD_JOBS-}"
printf 'CARGO_PROFILE_RELEASE_LTO=%s\n' "${CARGO_PROFILE_RELEASE_LTO-}"
printf 'CARGO_PROFILE_RELEASE_CODEGEN_UNITS=%s\n' "${CARGO_PROFILE_RELEASE_CODEGEN_UNITS-}"
printf 'CARGO_PROFILE_RELEASE_DEBUG=%s\n' "${CARGO_PROFILE_RELEASE_DEBUG-}"
printf 'CARGO_PROFILE_DEV_DEBUG=%s\n' "${CARGO_PROFILE_DEV_DEBUG-}"
printf 'CARGO_PROFILE_TEST_DEBUG=%s\n' "${CARGO_PROFILE_TEST_DEBUG-}"
exit "${FAKE_EXIT_CODE:-0}"
EOF

cat >"$FAKE_BIN_DIR/rustc" <<EOF
#!/usr/bin/env sh
set -eu
if [ "\${1:-}" = "-vV" ]; then
  printf 'host: $TARGET\n'
  exit 0
fi
printf 'fake rustc\n'
EOF

chmod +x "$FAKE_BIN_DIR/cargo" "$FAKE_BIN_DIR/just" "$FAKE_BIN_DIR/rustc"

TERMUX_PREFIX="/data/data/com.termux/files/usr"
NON_TERMUX_PREFIX="/usr/local"
EXPECTED_JOBS=$(expected_jobs)

non_termux_cargo=$(
  env -i \
    HOME="$TMP_DIR/home" \
    PATH="$FAKE_BIN_DIR:$SYSTEM_PATH" \
    PREFIX="$NON_TERMUX_PREFIX" \
    sh "$SCRIPTS_DIR/cargo-safe.sh" check -p codex-tui
)
assert_eq "$(parse_var "$non_termux_cargo" tool)" "cargo" "non-termux cargo tool"
assert_eq "$(parse_var "$non_termux_cargo" argv)" "check -p codex-tui" "non-termux cargo argv"
assert_empty "$(parse_var "$non_termux_cargo" CARGO_BUILD_JOBS)" "non-termux cargo jobs"
assert_empty "$(parse_var "$non_termux_cargo" CARGO_PROFILE_DEV_DEBUG)" "non-termux cargo dev debug"

termux_cargo=$(
  env -i \
    HOME="$TMP_DIR/home" \
    PATH="$FAKE_BIN_DIR:$SYSTEM_PATH" \
    PREFIX="$TERMUX_PREFIX" \
    TERMUX_VERSION="0.118.1" \
    sh "$SCRIPTS_DIR/cargo-safe.sh" check -p codex-tui
)
assert_eq "$(parse_var "$termux_cargo" tool)" "cargo" "termux cargo tool"
assert_eq "$(parse_var "$termux_cargo" argv)" "check -p codex-tui" "termux cargo argv"
assert_eq "$(parse_var "$termux_cargo" CARGO_BUILD_JOBS)" "$EXPECTED_JOBS" "termux cargo jobs"
assert_eq "$(parse_var "$termux_cargo" CARGO_PROFILE_RELEASE_LTO)" "off" "termux cargo release lto"
assert_eq "$(parse_var "$termux_cargo" CARGO_PROFILE_RELEASE_CODEGEN_UNITS)" "16" "termux cargo release codegen units"
assert_eq "$(parse_var "$termux_cargo" CARGO_PROFILE_RELEASE_DEBUG)" "0" "termux cargo release debug"
assert_eq "$(parse_var "$termux_cargo" CARGO_PROFILE_DEV_DEBUG)" "0" "termux cargo dev debug"
assert_eq "$(parse_var "$termux_cargo" CARGO_PROFILE_TEST_DEBUG)" "0" "termux cargo test debug"

termux_just=$(
  env -i \
    HOME="$TMP_DIR/home" \
    PATH="$FAKE_BIN_DIR:$SYSTEM_PATH" \
    PREFIX="$TERMUX_PREFIX" \
    TERMUX_VERSION="0.118.1" \
    sh "$SCRIPTS_DIR/just-safe.sh" -l
)
assert_eq "$(parse_var "$termux_just" tool)" "just" "termux just tool"
assert_eq "$(parse_var "$termux_just" argv)" "-l" "termux just argv"
assert_eq "$(parse_var "$termux_just" CARGO_BUILD_JOBS)" "$EXPECTED_JOBS" "termux just jobs"

set +e
env -i \
  FAKE_EXIT_CODE=23 \
  HOME="$TMP_DIR/home" \
  PATH="$FAKE_BIN_DIR:$SYSTEM_PATH" \
  PREFIX="$TERMUX_PREFIX" \
  TERMUX_VERSION="0.118.1" \
  sh "$SCRIPTS_DIR/cargo-safe.sh" metadata --format-version 1 >/dev/null
status=$?
set -e
assert_eq "$status" "23" "cargo-safe exit code"

build_output=$(
  env -i \
    HOME="$TMP_DIR/home" \
    PATH="$FAKE_BIN_DIR:$SYSTEM_PATH" \
    PREFIX="$TERMUX_PREFIX" \
    TERMUX_VERSION="0.118.1" \
    sh "$SCRIPTS_DIR/build-safe.sh" 2>&1
)
assert_contains "$build_output" "argv=build --release -p codex-cli -p codex-exec --target $TARGET" "build-safe cargo args"
assert_contains "$build_output" "CARGO_PROFILE_RELEASE_LTO=off" "build-safe release lto"
assert_contains "$build_output" "CARGO_PROFILE_DEV_DEBUG=0" "build-safe dev debug"

check_output=$(
  env -i \
    HOME="$TMP_DIR/home" \
    PATH="$FAKE_BIN_DIR:$SYSTEM_PATH" \
    PREFIX="$TERMUX_PREFIX" \
    TERMUX_VERSION="0.118.1" \
    sh "$SCRIPTS_DIR/check-android-target.sh" 2>&1
)
assert_contains "$check_output" "argv=check -p codex-cli --target $TARGET" "check script cli args"
assert_contains "$check_output" "argv=check -p codex-tui --target $TARGET" "check script tui args"
assert_contains "$check_output" "CARGO_PROFILE_TEST_DEBUG=0" "check script test debug"

printf 'termux resource layer script checks passed\n'
