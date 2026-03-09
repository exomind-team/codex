# Termux Scripts

Scripts in this folder are for validating and developing Termux support in the `exomind-codex` local project branch.

## `cargo-env.sh`

Shared Termux resource layer for Cargo-based commands.

- detects Termux/Android via `TERMUX_VERSION` or the Termux `PREFIX`
- computes a conservative `CARGO_BUILD_JOBS` from current `MemAvailable`
- exports low-risk debug/profile overrides:
  - `CARGO_PROFILE_RELEASE_LTO=off`
  - `CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16`
  - `CARGO_PROFILE_RELEASE_DEBUG=0`
  - `CARGO_PROFILE_DEV_DEBUG=0`
  - `CARGO_PROFILE_TEST_DEBUG=0`
- warns when `/data` usage is high
- is a no-op passthrough outside Termux

This script is meant to be sourced by other scripts in this folder.

## `cargo-safe.sh`

Runs `cargo` through the shared Termux resource layer.

Usage:

```sh
scripts/termux/cargo-safe.sh test -p codex-tui
scripts/termux/cargo-safe.sh check -p codex-cli --target aarch64-linux-android
```

## `just-safe.sh`

Runs `just` through the shared Termux resource layer.

Usage:

```sh
scripts/termux/just-safe.sh fmt
scripts/termux/just-safe.sh fix -p codex-tui
```

## `build-safe.sh`

Builds `codex-cli` and `codex-exec` for Android/Termux using the shared resource layer.

This script prints the computed Termux settings, then delegates to `cargo-safe.sh`.

Usage:

```sh
scripts/termux/build-safe.sh
```

## `check-android-target.sh`

Runs Android ARM64 preflight checks and cargo compile checks for key crates.

This script keeps the existing target validation flow, then delegates actual `cargo check`
invocations to `cargo-safe.sh`.

## `test-resource-layer.sh`

Script-level regression checks for the resource wrapper layer.

It validates:

- non-Termux passthrough behavior
- Termux-only environment injection
- wrapper exit-code passthrough
- `build-safe.sh` and `check-android-target.sh` integration with the shared layer

Usage:

```sh
scripts/termux/test-resource-layer.sh
```
