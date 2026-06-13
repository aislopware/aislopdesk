# 37 — Bug-hunt + DX hardening round (2026-06-13, autonomous, continuation)

**Status: 9 items shipped to `main` (one commit each), test-first; base `077acce` → HEAD `e52b3de`.
Full suite 2122 → 2135/0.** A continuation of the autonomous loop (after docs/36). A fresh 8-reader
discovery workflow (`w5k83m7d5`) produced a ranked 15-item backlog; the highest-value, headlessly-
verifiable items were implemented one-per-commit, each adversarially verified against the real code
first; then a 5-reviewer + rejection-audit review workflow (`wb9t7om3n`) scrutinised the whole diff.

The orchestration model the user asked for: **main agent is the orchestrator** — workflows do the
parallel read-heavy phases (discovery, review); the main agent does the sequential surgery (edit →
build → test → commit, one green commit per item) and the verify-the-verifier judgement calls.

## What shipped (in commit order)

| Commit | Rank | Item | Core |
|---|---|---|---|
| `2b5f27f` | 1 (HIGH) | **Group resize can't overflow members outside the box** | `resizingGroup` floored the box to `minItemSize` then clamped each sanitized member inside it via new `Canvas.clamping(_:into:)`. Was: `sanitize` floored members LARGER than a sub-floor box → they spilled out and fed the non-overlap solver overlapping input. |
| `79b5296` | 2 (HIGH) | **One reconnect give-up cap** | `ReconnectManager.maxReconnectAttempts` (20) is the single source of truth (lower module); `ConnectionPresenter` mirrors it. Was 30 vs a displayed 20 → "attempt 25 of 20". Both loops already made exactly N attempts — **no operator flipped** (verify-the-verifier: the finding's "reversed operators" claim was overstated). |
| `c80dd47` | 3 (MED) | **Menu verbs hit the recents ring** | Group Selected Panes / Save Current Layout / Arrange align+distribute routed through `apply(_:to:)` (the one `recordRecentCommand` chokepoint) instead of direct store calls. |
| `497cf86` | 4+7 (MED) | **Import DoS caps** | `decode` bounds `bookmarks.count <= maxItems` + filters to slots 1…9; `mergeAppend` rejects when `live + imported > maxItems`. |
| `6d3eeb9` | 6+12+13 (MED/LOW) | **Settings-key hygiene** | 11 raw `@AppStorage("canvas.*")` literals → `SettingsKey` constants; deleted dead `nonOverlapEnabled`; pinned the canvas wire values + covered the privacy/layout gates. |
| `e52b3de` | 15 (LOW) | **Actionable picker empty-message** | `windowFilterEmptyMessage` — names the filter, says windows exist behind it, points at the fix. |

## Verify-the-verifier (findings REJECTED after reading the real code)

The discipline that earns its keep — 4 of the lower-ranked findings were dismissed with grounded reasons,
avoiding redundant/worse changes:

- **Rank 5 — TerminalModeTracker OSC over-cap → `.ground` (proposed `.oscDiscard`)**: a **behavioral
  no-op** for THIS tracker. The finding pattern-matched `HostOutputSniffer` (whose `.ground` rings a
  `.bell` if it eats an OSC terminator) — but `TerminalModeTracker.ground` *ignores* BEL (only reacts to
  ESC), and both `.ground` and `.oscDiscard` reclassify embedded ESCs identically (xterm semantics). No
  input produces a different event list. Implemented then reverted.
- **Rank 8 — fresh-session reset flag not epoch-tied**: the production pump only feeds via
  `ingestBatch(epoch:)`, whose epoch guard runs *before* every `ingestPass`, so a stale-epoch batch can
  never reach the wipe. `ingestOutput→ingestPass` (the only unguarded path) is tests-only. And the
  proposed epoch-tag is a logical no-op (`markReconnecting` always moves the flag and epoch together).
- **Rank 9 — oversized paste truncates silently**: `SecretPasteClassifier.assess` returns `.tooLarge`
  for `text.count > KeystrokeReplay.maxLength` (the *same* constant `encode` truncates at); the dialog
  gives no "Paste Anyway" for `.tooLarge`; every paste path routes through the guard. No silent partial
  paste exists.
- **Rank 10 — `resume()` doesn't re-validate the target**: re-establishing the *committed* `target`
  (always valid, updated only on a successful connect) is correct; adopting an uncommitted form edit on
  iOS foreground would hijack staging. Not a bug.

## Deferred

- **Rank 11 — AppConnection supervisor campaign tests**: real coverage gap, but `isConnectionAlive` is
  driven by the real `MuxNWConnection` state with no fakeable seam — testing a give-up campaign needs
  scaffolding that doesn't exist. Rank 2's fix already has a regression net (ReconnectManager give-up
  count + the presenter-constant pin). Deferred over building heavy infrastructure for a simple guard.
- **Rank 14 — zero-interval paste cancellation**: tests-only path (production paste interval is 6ms,
  which already yields each stroke); a deterministic test would be flaky. Not worth the change.

## Discipline notes

- **The bottom of a ranked backlog is where verify-the-verifier pays**: ranks 1–7 were all real and
  shipped; 4 of the lower 8 were false-positives / no-ops on close reading. Confidence should scale with
  rank — read the real code before touching anything.
- **Layering decides the single-source-of-truth site**: the reconnect cap had to live in the LOWER module
  (`AislopdeskClient`) because `ConnectionPresenter` (UI) can depend down but not up — the finding's
  "make ReconnectManager read ConnectionPresenter" was backwards.
- **A test that passes against the un-fixed code is not a regression net**: every new test here was
  written to FAIL pre-fix (e.g. the direct-store-call negative control for the recents routing).
