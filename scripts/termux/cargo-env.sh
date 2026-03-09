#!/usr/bin/env sh
set -eu

if [ "${TERMUX_CARGO_ENV_LOADED:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

TERMUX_CARGO_ENV_LOADED=1
TERMUX_CARGO_ENV_ACTIVE=0
TERMUX_CARGO_ENV_CORES=""
TERMUX_CARGO_ENV_MEM_KB=""
TERMUX_CARGO_ENV_DATA_USE_PCT=""
TERMUX_CARGO_ENV_JOBS=""
export TERMUX_CARGO_ENV_LOADED

is_termux=0
if [ -n "${TERMUX_VERSION:-}" ]; then
  is_termux=1
else
  case "${PREFIX:-}" in
    /data/data/com.termux/* | /data/user/*/com.termux/*)
      is_termux=1
      ;;
  esac
fi

if [ "$is_termux" -ne 1 ]; then
  return 0 2>/dev/null || exit 0
fi

TERMUX_CARGO_ENV_ACTIVE=1
TERMUX_CARGO_ENV_CORES=$(nproc 2>/dev/null || echo 1)
TERMUX_CARGO_ENV_MEM_KB=$(awk '/MemAvailable:/ { print $2 }' /proc/meminfo 2>/dev/null || echo 0)

if [ "${TERMUX_CARGO_ENV_MEM_KB:-0}" -lt 3000000 ]; then
  TERMUX_CARGO_ENV_JOBS=1
elif [ "${TERMUX_CARGO_ENV_MEM_KB:-0}" -lt 5000000 ]; then
  TERMUX_CARGO_ENV_JOBS=2
else
  TERMUX_CARGO_ENV_JOBS=$((TERMUX_CARGO_ENV_CORES / 2))
  if [ "$TERMUX_CARGO_ENV_JOBS" -lt 2 ]; then
    TERMUX_CARGO_ENV_JOBS=2
  fi
  if [ "$TERMUX_CARGO_ENV_JOBS" -gt 4 ]; then
    TERMUX_CARGO_ENV_JOBS=4
  fi
fi

TERMUX_CARGO_ENV_DATA_USE_PCT=$(df -P /data 2>/dev/null | awk 'NR==2 { gsub(/%/, "", $5); print $5 }')

CARGO_BUILD_JOBS=$TERMUX_CARGO_ENV_JOBS
CARGO_PROFILE_RELEASE_LTO=off
CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16
CARGO_PROFILE_RELEASE_DEBUG=0
CARGO_PROFILE_DEV_DEBUG=0
CARGO_PROFILE_TEST_DEBUG=0

export TERMUX_CARGO_ENV_ACTIVE
export TERMUX_CARGO_ENV_CORES
export TERMUX_CARGO_ENV_MEM_KB
export TERMUX_CARGO_ENV_DATA_USE_PCT
export TERMUX_CARGO_ENV_JOBS
export CARGO_BUILD_JOBS
export CARGO_PROFILE_RELEASE_LTO
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS
export CARGO_PROFILE_RELEASE_DEBUG
export CARGO_PROFILE_DEV_DEBUG
export CARGO_PROFILE_TEST_DEBUG

if [ -n "${TERMUX_CARGO_ENV_DATA_USE_PCT:-}" ] && [ "${TERMUX_CARGO_ENV_DATA_USE_PCT:-0}" -ge 92 ] && [ "${TERMUX_CARGO_ENV_WARNED:-0}" != "1" ]; then
  echo "[termux-cargo-env] warning: /data usage is ${TERMUX_CARGO_ENV_DATA_USE_PCT}% (low free space may cause instability)." >&2
  TERMUX_CARGO_ENV_WARNED=1
  export TERMUX_CARGO_ENV_WARNED
fi
