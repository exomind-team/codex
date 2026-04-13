# Durable Kernel Replay Plan

## Summary

This document defines the implementation plan for replacing the current
TUI-side "resubmit the user message" retry behavior with core-owned durable
replay for `codex-rs`.

The v1 target is intentionally narrow:

- cover `Regular` turns and thread-spawn `SubAgent` turns
- keep replay inside the same logical turn
- keep automatic replay on the same prompt snapshot
- persist replay state durably so `codex resume` can continue it
- move replay ownership to core and later delete the TUI resubmission path

The design principle is local override with no hard retry-attempt cap:

- no outer replay attempt limit
- no inner transport retry limit that can end the turn
- capped retry interval per error category
- explicit human interruption is the only normal stop condition

## Problem Statement

Today, errors such as `exceeded retry limit, last status: 429 Too Many Requests`
can escape the core turn loop and are then handled in the TUI by resubmitting
the in-flight user message as a new `Op::UserTurn`.

That behavior is wrong for this fork's requirements because it:

- creates a new turn instead of continuing the existing logical turn
- re-injects turn context and user message content
- consumes extra context budget
- changes model-visible history
- makes recovery a UI policy instead of a kernel policy

At the same time, core already has a narrower recovery mechanism:

- same-turn transport reconnect / stream retry for transient stream failures
- HTTP/WebSocket recovery inside a single sampling attempt

That existing inner retry is useful, but it is not sufficient because it:

- is not durable
- does not own terminal turn failure recovery
- does not snapshot the exact model-visible prompt baseline
- cannot resume across process restart

## V1 Scope

### In scope

- `Regular` turns
- thread-spawn `SubAgent` turns
- durable replay state in core / rollout persistence
- structured replay status events for UI consumption
- replay-aware resume behavior
- TUI status-area replay display
- post-core cleanup of TUI retry-by-resubmission logic

### Out of scope for v1

- `Review` task replay
- `Compact` task replay
- realtime conversation replay
- cross-process global rate limiter
- client-side token bucket / queue smoothing
- best-effort deduplication of side effects from in-flight incomplete tools
- user-configurable replay policy in `config.toml`

## Core Behavioral Decisions

### Logical turn identity

- Durable replay stays within the same logical turn.
- UI- and protocol-visible `turn_id` remains stable across automatic replay.
- Core may use internal attempt/checkpoint identifiers, but they are not new
  user-visible turns.

### Automatic replay versus manual continuation

- Automatic replay always reuses the same durable prompt snapshot.
- Automatic replay must not append a new user message or replay-only context
  diff items.
- If the user explicitly interrupts replay, the turn enters `paused_manual`.
- If the user resumes with an empty composer and submits, replay continues from
  the last durable snapshot unchanged.
- If the user resumes with a non-empty composer and submits, that new message is
  treated as a manual steer for the same logical turn, producing a new durable
  snapshot before replay continues.

### New user input while replay is pending

- If a turn is auto-retrying or waiting for its next replay, new user input is
  queued by default.
- The queued input does not cancel the replay automatically.
- To stop the replay, the user must explicitly interrupt it first.

### Partial assistant output

- Partial assistant output from failed incomplete attempts is discarded.
- It must not become part of durable baseline state.
- It must not become part of reconstructed prompt state.

## Replay Architecture

### Two-layer recovery model

- Keep the existing inner same-turn transport recovery loop in core.
- Add an outer durable replay supervisor around the turn execution path.
- The inner layer handles fast reconnect / transport-local recovery.
- The outer layer owns all terminal turn failure recovery for in-scope tasks.

### Existing capped retry knobs

- Existing inner capped retry knobs such as `stream_max_retries` no longer get
  to terminate a `Regular` or thread-spawn `SubAgent` turn.
- For the new architecture, those old capped-retry semantics are treated as
  obsolete.
- Inner recovery exhausting its local strategy hands control to outer durable
  replay instead of failing the turn.

### Replay source of truth

- Core owns replay policy and replay state.
- Rollout persistence is the durable source of truth.
- TUI replay/filter logic is display-only and must not remain the source of
  recovery semantics.

## Durable Snapshot Model

### Snapshot form

- Persist a normalized model-visible prompt snapshot, not a provider-specific
  raw request body.
- Reconstruct provider requests from the normalized snapshot at replay time.
- The normalized snapshot must be exact enough that replay does not depend on
  best-effort history reconstruction.

### Snapshot contents

Each durable replay checkpoint must capture at least:

- logical `turn_id`
- normalized prompt snapshot
- resolved turn settings snapshot
- completed tool outputs that are now part of the model-visible baseline
- replay state:
  - `running`
  - `scheduled`
  - `paused_manual`
  - `paused_gate`
- current replay category / attempt / next retry time
- latest failure summary suitable for UI/status use
- pending interactive gates:
  - exec approval
  - patch approval
  - elicitation
  - `request_user_input`

### Snapshot lifecycle

- Materialize the snapshot only after the turn's model-visible input for that
  stage is fully assembled.
- Refresh the durable snapshot every time completed tool output becomes part of
  the model-visible baseline.
- Treat each newly materialized baseline as a new durable stage for backoff
  accounting.

## Tool and Side-Effect Semantics

### Completed tools

- Only completed tool outputs are trusted durable checkpoints.
- Once a completed tool output is incorporated into durable baseline state, it
  must not be re-run by replay.
- Replay resumes from after those completed outputs.

### In-flight incomplete tools

- If failure occurs while a side-effectful tool has started but has not produced
  a completed output checkpoint, v1 does not attempt best-effort deduplication.
- Only completed outputs are durable truth.
- Replay after such a failure may cause the model to re-issue the tool.

## Interactive Gates

### Durability

- Pending approvals, elicitations, and `request_user_input` prompts must be
  durably tracked in core replay state.
- Resume behavior must restore unresolved interactive gates from durable state.

### Replay behavior

- Automatic replay stops at an unresolved interactive gate.
- A turn blocked on a gate is `paused_gate`, not terminally failed.
- Replay resumes only after the corresponding user response is received.

### TUI interaction

- TUI may still maintain local helper state for rendering, but unresolved gate
  truth must come from core-owned durable state.
- TUI must stop depending on local inference to recover unresolved prompts after
  resume.

## Resume Semantics

### Automatic resume

- `codex resume` automatically continues pending replay for turns that were not
  manually paused.
- Resuming a scheduled replay restores its countdown and replay loop without
  requiring extra confirmation.

### Manual pause behavior

- `paused_manual` replay does not auto-continue on resume.
- It waits for explicit user action:
  - empty submit resumes the existing snapshot
  - submit with a new message updates the snapshot and continues the same
    logical turn

## Backoff Policy

### Policy shape

- No retry-attempt cap at the outer replay layer.
- No retry-attempt cap that can terminate the inner transport layer for in-scope
  tasks.
- Each error category has its own backoff streak and interval cap.
- Error-category state is independent per category.
- When the durable baseline advances to a new snapshot stage, that stage resets
  the relevant outer replay streak.

### Default parameters

- base delay: `1s`
- exponential factor: `2`
- jitter range: `0.5x .. 1.5x`

### Category interval caps

- transport-like failures: `30s`
- rate-limit / overloaded / 5xx-like failures: `300s`
- auth / deterministic / bad-request / context-window / sandbox-like failures:
  `900s`

### Service hints

- If the provider gives `Retry-After`, prefer it.
- If `Retry-After` is absent but durable error state exposes a usable reset time
  such as `resets_at`, prefer that.
- Service-provided wait time is still clamped by the local category `D_max`.
- Service-provided wait time is not additionally jittered.
- Locally computed exponential waits use jitter.

### No client-side proactive smoother in v1

- v1 only changes replay delay scheduling.
- It does not add a token bucket, leaky bucket, or session-global queue
  smoothing layer.

## Error Coverage

### Direction

- Outer durable replay is not limited to `429`.
- All in-scope turn failures route through replay classification and replay
  scheduling.

### Expected categories

At minimum, classify:

- transport disconnect / reconnect failures
- HTTP connection failures
- provider overload / 5xx-style failures
- generic `429` replayable failures
- usage-limit style failures with reset hints
- auth failures
- deterministic request failures
- sandbox/tool policy failures
- context window exhaustion

The implementation may merge or split categories internally, but the above
groups must map to bounded interval policies and structured status output.

## Protocol and UI

### Structured replay protocol

- Add dedicated replay status events rather than reusing `StreamInfoEvent` or
  encoding replay state in free-form error strings.
- Replay status payload must include at least:
  - `turn_id`
  - replay state
  - error category
  - attempt count
  - `next_retry_at`
  - paused reason
  - whether the turn belongs to main session or subagent

### TUI display rules

- Automatic replay status appears only in the status area.
- Replay must not add transcript noise.
- Status area must show at least:
  - replay attempt count
  - countdown until next replay

### SubAgent visibility

- Thread-spawn `SubAgent` turns use the same replay machinery.
- Parent session status should surface aggregated subagent replay waiting state.
- Parent transcript should not receive extra history messages just because a
  subagent is replaying.

## TUI Cleanup Strategy

### Sequence

- First, land core replay ownership and make it effective.
- After that, remove the TUI-side failed-turn resubmission path.

### Cleanup target

- Delete logic that turns a failed in-flight user message into a new
  `Op::UserTurn` retry.
- Delete tests that assert a second `Op::UserTurn` is synthesized after retry
  limit failure.
- Keep only queue/status behavior that still makes sense when replay ownership
  lives fully in core.

## Implementation Work Breakdown

### Phase 1: protocol and persistence scaffolding

- add replay state types to protocol
- add durable replay checkpoint/state records to rollout persistence
- make resume load replay state from rollout as durable truth
- add tests for serialization/deserialization and resume restoration

### Phase 2: core replay supervisor

- wrap in-scope turn execution with an outer replay supervisor
- classify errors into replay categories
- compute scheduled retry times from policy + service hints
- keep logical turn identity stable across automatic replay
- update durable replay state before sleeping / pausing / resuming

### Phase 3: durable snapshot checkpoints

- capture normalized prompt snapshot at the correct assembly boundary
- refresh checkpoints when completed tool outputs advance the baseline
- ensure failed partial assistant output is excluded
- reset replay stage streak when baseline advances

### Phase 4: interactive gates

- persist unresolved approvals / elicitations / `request_user_input`
- restore them through core on resume
- pause replay cleanly at unresolved gates
- resume replay after user response without creating a new logical turn

### Phase 5: TUI integration

- consume dedicated replay status events
- render replay state in the status area only
- show aggregated subagent replay waiting status in parent session
- stop relying on status-string heuristics for replay

### Phase 6: TUI retry cleanup

- remove `retry_current_user_message` style resubmission logic
- remove obsolete queue-gap tests
- preserve only still-valid ordering / display logic

## Testing Plan

### Core behavior tests

- `429` failure enters outer durable replay instead of ending the turn
- automatic replay does not emit a second `Op::UserTurn`
- logical `turn_id` remains stable across automatic replay
- same-snapshot replay does not duplicate context or user message items
- inner transport retry exhaustion hands off to outer replay rather than failing
- manual interrupt produces `paused_manual`
- empty-submit resume continues the same snapshot
- non-empty-submit resume updates the snapshot for the same logical turn

### Tool tests

- completed tool outputs enter durable baseline and are not re-run
- failure after completed tools resumes from after those completed outputs
- failure during incomplete side-effectful tool does not produce a fake durable
  checkpoint

### Interactive gate tests

- unresolved exec approval survives resume and remains pending
- unresolved patch approval survives resume and remains pending
- unresolved elicitation survives resume and remains pending
- unresolved `request_user_input` survives resume and remains pending
- answering a restored gate resumes replay without creating a new turn

### Resume tests

- scheduled replay auto-continues after `codex resume`
- `paused_manual` replay does not auto-continue after `codex resume`
- restored replay uses the durable normalized snapshot rather than fresh context
  injection

### SubAgent tests

- thread-spawn `SubAgent` uses the same replay loop
- parent status reflects subagent replay wait state
- parent transcript remains free of replay noise

### TUI tests

- status area shows replay attempt + countdown
- replay state is restored correctly after thread snapshot / resume
- obsolete resubmission tests are removed or inverted to assert no new
  `Op::UserTurn` is sent
- update TUI snapshots for any intentional UI/status changes

## Upstream and Fork Context

### Upstream issue references

- `openai/codex#2612`: `exceeded retry limit, last status: 429 Too Many Requests`
- `openai/codex#2903`: rate-limit / backoff handling pain

No upstream implementation has been identified that already provides:

- same logical turn replay
- durable prompt snapshot replay
- replay-aware resume
- full removal of TUI retry-by-resubmission

### Fork-specific cleanup targets

The fork currently carries TUI retry/queue patches concentrated in:

- `codex-rs/tui/src/chatwidget.rs`
- `codex-rs/tui/src/chatwidget/tests.rs`

Notable commits already identified as cleanup context:

- `a2aaf27f7` - `Retry transient turn failures before queue advance`
- `b2ddfd457` - `Block queue advance during retry submission gap`
- `2e0e9fdc1` - `fix(tui): hold queued drafts on incomplete turn failures`

## Final Acceptance Criteria

The implementation is complete when all of the following are true:

- core, not TUI, owns failed-turn recovery for `Regular` and thread-spawn
  `SubAgent` turns
- `429` and other in-scope failures replay without creating a new user-visible
  turn
- automatic replay reuses the same durable prompt snapshot
- completed tool outputs are checkpointed and not re-run
- unresolved interactive gates are durably restorable
- `codex resume` auto-continues pending replay except `paused_manual`
- TUI shows replay status only in the status area
- TUI no longer synthesizes retry `Op::UserTurn` submissions
