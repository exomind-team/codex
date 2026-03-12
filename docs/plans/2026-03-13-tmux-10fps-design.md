# Tmux 10 FPS TUI Budget Design

Date: 2026-03-13

## Problem Statement
Long-running Codex sessions inside tmux show UI lag even after backlog-drain fixes
(exomind-team/codex#27). Evidence from upstream (openai/codex#11877, #11857)
indicates that redraw/animation output churn can accumulate terminal history and
add multiplexer overhead. We need a tmux-only mitigation that reduces redraw
frequency without changing core agent scheduling or adding new config knobs.

## Goals
- Reduce redraw/animation pressure to 10 FPS when running under tmux.
- Keep non-tmux behavior unchanged.
- Avoid new config surface area.
- Keep changes TUI-local and minimal.

## Non-Goals
- No slow-terminal detection outside tmux.
- No changes to core agent scheduling, queue semantics, or network behavior.
- No UI redesign; only refresh rate control.

## Evidence and References
- openai/codex#11877: terminal animations cause excessive output and tmux history growth.
- openai/codex#11857: idle output churn can bloat tmux history over time.
- OpenCode issues show tmux rendering problems too (anomalyco/opencode#16967, #16566, #16547).
- Claude Code has tmux rendering/flicker issues (anthropics/claude-code#29937, #28282, #32744).

## Proposed Approach
1. Detect tmux via `codex_core::terminal::terminal_info().multiplexer`.
2. If tmux is detected, set a minimum frame interval of 100ms (10 FPS).
3. Apply this interval at the frame scheduler level so all redraws and animations
   are clamped uniformly. Widgets continue calling `schedule_frame_in`, but
   the scheduler clamps to the tmux min interval.
4. Preserve existing backlog-drain behavior from exomind-team/codex#27.

## Architecture / Data Flow
- TUI initialization computes `min_frame_interval`:
  - tmux => 100ms
  - non-tmux => current 8.33ms (120 FPS cap)
- `FrameRequester` / `FrameScheduler` uses a `FrameRateLimiter` configured with
  that `min_frame_interval`.
- Redraw notifications emitted on the broadcast channel are thus globally
  clamped without per-widget logic.

## Files to Touch (Implementation)
- `codex-rs/tui/src/tui/frame_rate_limiter.rs`
- `codex-rs/tui/src/tui/frame_requester.rs`
- `codex-rs/tui/src/tui.rs`

## Verification Plan
- Unit tests for the configurable frame limiter (clamp behavior at 100ms).
- Manual tmux validation:
  - Measure `history_bytes` growth via `tmux list-panes -F 'hist_bytes=...'`.
  - Measure raw PTY output growth via `script -q -f`.
  - Confirm input responsiveness and non-tmux unchanged behavior.

## Risks
- Reduced animation cadence might feel less lively in tmux. This is acceptable
  for performance stability and is tmux-only.
- If tmux detection fails (unusual env), fallback is current behavior.

## Rollout Notes
No config changes. Behavior is automatic and tmux-scoped.
