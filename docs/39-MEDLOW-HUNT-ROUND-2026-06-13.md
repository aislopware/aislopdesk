# 39 — MED/LOW adversarial hunt + fixes (2026-06-13, autonomous, continuation)

**Status: shipped to `main`. Base `c600da6` → HEAD `68fffaf` (11 commits). Full suite 2153 → 2166/0.**
A continuation of the autonomous loop. After the HIGH-only hunt converged (0 findings, docs not written —
see memory), the user asked to "check MED + LOW too." A 9-finder adversarial hunt + a 3-lens
(reachable / real / worth-fixing, default-refuted) verifier returned **19 candidates → 15 confirmed**
(each 3/3 votes) and 4 correctly rejected (reach 0–1 or worth 1). All 15 were fixed test-first, each test
verified to FAIL when its fix is reverted; one fix (#1) repaired a bug in *this session's own* nav feature.

Orchestration: the Workflow does discovery + verification (66 agents, ~3.8M tokens); the main agent does
the sequential edit→build→test→commit surgery + verify-the-verifier judgment.

## The 15 fixes (one commit each, grouped where coherent)

| Commit | Sev | Fix |
|---|---|---|
| `2a89f37` | MED | **nav** — quick-switch (⌥⌘;) was DEAD: every creation/raise path (addPane, duplicate, reopen, raise, move, moveSelection) set `focusedPane` directly, bypassing the `focusHistory` MRU ring, so the ring stayed empty until a click. Route them through a `focusOnPlacement` helper that records the visit (ephemeral system-dialog path excluded). |
| `561b529` | MED | **import** — `mergeAppend` capped only the canvas; an over-cap groups/snippets/presets merge produced a workspace that `load()` rejects → **next launch silently discards the ENTIRE workspace** to default. Reject symmetrically on all three side collections. |
| `8534257` | LOW | **import** — a merged bookmark with no surviving anchor kept a foreign-frame `cameraOrigin` → recall (⌘n) panned into the void. Adopt only bookmarks whose anchor survives the id remap (mirrors `switchToLayoutPreset`). |
| `f725fc2` | MED | **terminal** — a deliberate reconnect (⇧⌘R / Retry) of an exited pane left the dead session's framebuffer on the always-mounted surface (`reset()` disarmed the fresh-session wipe). Arm `pendingFreshSessionReset` like `markReconnecting()`. |
| `2892639` | LOW×2 | **focus** — `FocusResolver` resolved against a `[PaneID:CGRect]` whose iteration order is hash-seed-randomized; the `.next/.previous` cycle (minX-only tie-break) and the directional pick (first-iterated wins exact ties) were both nondeterministic for coincident panes. Total tie-break on the id (mirrors `Canvas.allIDs()`). |
| `25afa99` | LOW×3 | **palette recents** — surfaced focus-requiring verbs (Close/Rename/…) at the top of the palette on an empty canvas where the catalog hides them (added the same focused-pane filter to an extracted, testable `buildRecentEntries`); and ⌘N (`.newPaneDefault`, no catalog entry) was recorded verbatim → silently dropped + wasted a ring slot (record the resolved `.newPane(defaultKind)`). |
| `dc4513f` | MED | **menu** — File ▸ New Terminal Pane (table-derived ⌘T) and Pane ▸ New Pane (hardcoded ⌘T) both advertised ⌘T → AppKit arbitrates, one glyph a decoy. Stale comment claimed File used ⌘N (now `.newPaneDefault`). Drop the redundant explicit chord. |
| `806f0f5` | LOW | **video** — `DecodeGate` downgraded needKeyframe→brokenChain on any stale keyframe, then admitted an acked-LTR refresh against a session whose DPB was wiped by the teardown → another -12909/teardown/IDR round. Downgrade only from brokenChain (session alive); stay needKeyframe when torn down (stricter than the finding's `reset()`, which would reopen to undecodable deltas). |
| `41909e9` | LOW×2 | **inspector** — a Task* payload with no todos/tasks array blanked the whole todo panel (distinguish "no array" from "explicit empty"); a tool_result object block without a `text` key flattened via `values.first` (Dictionary-random) → render the whole object (sorted keys). |
| `099b9b7` | MED | **hid** — `VirtualHIDKeyboardClient.releaseAll()` sent the zero report but never cleared the folded `HIDKeyboardState.pressed`, so the next keystroke re-asserted previously-held keys as phantom presses into the next secure field. Added a mutating `HIDKeyboardState.releaseAll()` that clears + returns the report. |
| `68fffaf` | MED | **video** — DIALOG-EXPAND: `onGeometry` re-origined the injector/cursor to the PLAIN window frame on every window move while the capture region was expanded to the union → clicks/cursor in the dialog area mapped to the wrong point. Gate the re-origin on a pure `CaptureRegionMath.shouldReoriginToWindowOnGeometry` (skip while a region override is active). |

## The 4 rejected (correctly filtered by the verifier)
- `SettingsKey.defaultPaneKind → .systemDialog` (reach 0 — the settings UI can't select it).
- `ReconnectManager` 64-attempt cap divergence (reach 0 — that path is unreachable from the unified cap).
- Late-tailed subagent line flips stopped→running (reach 1).
- Tool-card re-emit duplicate after eviction (worth 1).

## Discipline notes
- **Verify-the-verifier preferred precise fixes over the finding's suggestion twice:** the DecodeGate fix
  stays `needKeyframe` (the finding's `reset()` would reopen the gate to undecodable post-loss deltas), and
  the inspector todos fix distinguishes "no array" from "empty array" (the finding's framing).
- **Testable seams for "untestable" surfaces:** the two host-session bugs (DIALOG-EXPAND mapping, virtual-HID
  state) were made unit-testable by extracting the decision/state into the pure `CaptureRegionMath` /
  `HIDKeyboardState` helpers — the session itself needs live ScreenCaptureKit / a root UDP bridge.
- **One perl-`-0pi` revert hit the wrong occurrence** (clobbered `markReconnecting` instead of `reset`); a
  passing revert-check exposed it. Lesson reinforced: revert via a targeted `Edit`, not a loose regex.
- Every fix is backed by a test verified to FAIL when the fix is reverted (revert-to-confirm-fail), incl.
  the determinism fixes (8 coincident panes / format-change make them reliably discriminating).
