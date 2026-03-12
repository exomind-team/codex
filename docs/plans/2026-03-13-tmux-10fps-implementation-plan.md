# Tmux 10 FPS TUI Budget Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan.

**Goal:** Reduce redraw/animation frequency to 10 FPS when running under tmux without changing non-tmux behavior.

**Architecture:** Detect tmux in TUI init, pass a 100ms minimum frame interval into the frame scheduler's
rate limiter. All redraw requests are globally clamped; backlog-drain behavior remains unchanged.

**Tech Stack:** Rust, codex-rs/tui, codex-core terminal detection.

---

### Task 1: Make the frame limiter configurable

**Files:**
- Modify: `codex-rs/tui/src/tui/frame_rate_limiter.rs`

**Step 1: Write the failing test**

Add a test that expects a custom min interval:

```rust
#[test]
fn clamps_to_custom_interval() {
    let t0 = Instant::now();
    let mut limiter = FrameRateLimiter::new(Duration::from_millis(100));
    limiter.mark_emitted(t0);

    let too_soon = t0 + Duration::from_millis(10);
    assert_eq!(limiter.clamp_deadline(too_soon), t0 + Duration::from_millis(100));
}
```

**Step 2: Run test to verify it fails**

Run: `cargo test -p codex-tui frame_rate_limiter::tests::clamps_to_custom_interval`
Expected: FAIL (missing constructor or wrong clamping).

**Step 3: Write minimal implementation**

Update the limiter to accept a configurable interval:

```rust
pub(super) struct FrameRateLimiter {
    last_emitted_at: Option<Instant>,
    min_interval: Duration,
}

impl FrameRateLimiter {
    pub(super) fn new(min_interval: Duration) -> Self {
        Self {
            last_emitted_at: None,
            min_interval,
        }
    }
}

impl Default for FrameRateLimiter {
    fn default() -> Self {
        Self::new(MIN_FRAME_INTERVAL)
    }
}
```

Then update `clamp_deadline` to use `self.min_interval`.

**Step 4: Run test to verify it passes**

Run: `cargo test -p codex-tui frame_rate_limiter::tests::clamps_to_custom_interval`
Expected: PASS.

**Step 5: Commit**

```bash
git add codex-rs/tui/src/tui/frame_rate_limiter.rs
git commit -m "tui: make frame limiter configurable"
```

---

### Task 2: Plumb min interval into the frame scheduler

**Files:**
- Modify: `codex-rs/tui/src/tui/frame_requester.rs`

**Step 1: Write the failing test**

Add a test that asserts a custom min interval for draw emission:

```rust
#[tokio::test(flavor = "current_thread", start_paused = true)]
async fn test_limits_draw_notifications_to_custom_interval() {
    let (draw_tx, mut draw_rx) = broadcast::channel(16);
    let requester = FrameRequester::new(draw_tx, Duration::from_millis(100));

    requester.schedule_frame();
    time::advance(Duration::from_millis(1)).await;
    let first = draw_rx.recv().timeout(Duration::from_millis(50)).await;
    assert!(first.is_ok());

    requester.schedule_frame();
    time::advance(Duration::from_millis(10)).await;
    let too_early = draw_rx.recv().timeout(Duration::from_millis(1)).await;
    assert!(too_early.is_err());

    time::advance(Duration::from_millis(100)).await;
    let second = draw_rx.recv().timeout(Duration::from_millis(50)).await;
    assert!(second.is_ok());
}
```

**Step 2: Run test to verify it fails**

Run: `cargo test -p codex-tui frame_requester::tests::test_limits_draw_notifications_to_custom_interval`
Expected: FAIL (constructor signature mismatch).

**Step 3: Write minimal implementation**

Update constructors to accept `min_interval: Duration`:

```rust
pub fn new(draw_tx: broadcast::Sender<()>, min_interval: Duration) -> Self {
    let (tx, rx) = mpsc::unbounded_channel();
    let scheduler = FrameScheduler::new(rx, draw_tx, min_interval);
    tokio::spawn(scheduler.run());
    Self { frame_schedule_tx: tx }
}
```

Update `FrameScheduler::new` to accept `min_interval`, and initialize
`FrameRateLimiter::new(min_interval)`. Update all existing tests to pass
`frame_rate_limiter::MIN_FRAME_INTERVAL` as the default interval.

**Step 4: Run test to verify it passes**

Run: `cargo test -p codex-tui frame_requester::tests::test_limits_draw_notifications_to_custom_interval`
Expected: PASS.

**Step 5: Commit**

```bash
git add codex-rs/tui/src/tui/frame_requester.rs
git commit -m "tui: plumb min frame interval into scheduler"
```

---

### Task 3: Select 10 FPS in tmux at TUI init

**Files:**
- Modify: `codex-rs/tui/src/tui.rs`

**Step 1: Write the failing test (if feasible)**

If there is an existing test harness for TUI init, add a test that asserts
tmux uses a 100ms min interval. If not feasible without heavy harnessing,
skip adding a new unit test and rely on manual verification below.

**Step 2: Implement tmux-only selection**

At the `FrameRequester::new` call site in `Tui::new`, compute:

```rust
let terminal_info = codex_core::terminal::terminal_info();
let min_frame_interval = if matches!(terminal_info.multiplexer, Some(Multiplexer::Tmux { .. })) {
    Duration::from_millis(100)
} else {
    frame_rate_limiter::MIN_FRAME_INTERVAL
};
let frame_requester = FrameRequester::new(draw_tx.clone(), min_frame_interval);
```

**Step 3: Run tests**

Run: `cargo test -p codex-tui`
Expected: PASS (no snapshot changes expected).

**Step 4: Commit**

```bash
git add codex-rs/tui/src/tui.rs
git commit -m "tui: clamp frame rate to 10fps in tmux"
```

---

### Task 4: Format and final verification

**Step 1: Run formatter**

Run: `just fmt` (in `codex-rs`).

**Step 2: Re-run targeted tests**

Run: `cargo test -p codex-tui`
Expected: PASS.

**Step 3: Optional manual validation**

- tmux history growth: `tmux list-panes -F 'hist_bytes=#{history_bytes} hist_lines=#{history_size}'`
- raw PTY output: `script -q -f /tmp/raw.log -c 'codex ...'` then `stat -c%s /tmp/raw.log`

**Step 4: Commit if fmt changed files**

```bash
git add -u
git commit -m "chore: fmt"
```
