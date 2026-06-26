# E6 carry-overs (required acceptance criteria)

These fold into E6's acceptance criteria. The design + implementation MUST honor them.

## Scope reduction (BINDING — user directive, do NOT build)

**Horizontal tab bar is DROPPED from this clone.** aislopdesk is **vertical-tabs-only** by deliberate product decision (already encoded in E7 Settings → Appearance → Tabs, and in the `e7-close` commit `f3ea994`).

For E6 specifically:

- Render the tab rows (`OttyTabRow`: status dot, `#N` number badge, cwd subtitle, shell/process trailing label) in the **VERTICAL left sidebar ONLY**. Do **not** add a horizontal/top tab strip, a tab-bar layout selector, or any "Tabs Top / Tabs Bottom" variant of these rows.
- The **grouping/sort hamburger** (None/By-Project/By-Date grouping; Created/Updated/Manual sort) lives in the **vertical sidebar header** and must mutate the **store order** (not a local `@State`), so it is the single source of truth for row order.
- The **tab search/filter** field also lives in the vertical sidebar (reuse `RailRowsBuilder.filtered`).
- Do not treat the absent horizontal-tab-bar option as a gap to fill — it is an intentional exclusion. (The otty screenshots that show a horizontal bar are out of scope for this epic; match only the vertical-sidebar presentation.)

## No earlier-epic fidelity mediums route to E6

E1's and E3's carry-over mediums were consumed by E7 (`e3a0594c` … `f3ea994`); E4's 4 mediums route to **E9** (`E9-carryovers.md`). E5's residual mediums are find/search-surface only (whole-word toggle deferred as an engine gap) and do not touch the sidebar. So E6 carries only the scope-reduction guardrail above.
