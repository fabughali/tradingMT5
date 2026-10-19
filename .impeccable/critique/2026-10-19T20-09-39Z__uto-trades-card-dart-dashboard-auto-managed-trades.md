---
target: Dashboard + Auto-Managed Trades screens
total_score: 23
max_score: 40
na_heuristics: 
p0_count: 1
p1_count: 3
timestamp: 2026-10-19T20-09-39Z
slug: uto-trades-card-dart-dashboard-auto-managed-trades
---
Method: dual-agent (A: a4fc362fc0ac6a6fe · B: a84e376b5b6ff9f07)

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 3 | Good live lights/cycle age; "Launching TradingView" cycling text doesn't distinguish heartbeat from stall |
| 2 | Match System / Real World | 3 | Good Long/Short relabeling; raw `retcode=10014` strings break the pattern |
| 3 | User Control and Freedom | 2 | Pause is reversible; live-trade Terminate has no undo and no confirm |
| 4 | Consistency and Standards | 3 | Status logic centralized in one function; but orange/amber/yellow each carry multiple unrelated meanings (confirmed: 8 distinct semantic colors cataloged, several hues reused) |
| 5 | Error Prevention | 2 | Volume clamped to real MT5 min/max; no pre-warning before a doomed order, no confirm before terminating a live position |
| 6 | Recognition Rather Than Recall | 2 | SLL info dialog is excellent; no persistent legend for waiting-card icons or table abbreviations (Auto/Last/Check/SLL) |
| 7 | Flexibility and Efficiency | 2 | Cycling sort needs up to 4 taps to reach a target mode; no bulk actions, no keyboard shortcuts anywhere reviewed |
| 8 | Aesthetic and Minimalist Design | 2 | Waiting-card layout has real polish; header alone surfaces ~18 simultaneous data points (8+ band) |
| 9 | Error Recovery | 2 | `waitingReason` shows the real broker reason (good); no recovery guidance ("what do I do about Invalid volume?") |
| 10 | Help and Documentation | 2 | "How it works" + SLL dialog exist; no equivalent for the waiting-card action row |
| **Total** | | **23/40** | **Acceptable** |

## Design Specificity Verdict

**LLM assessment**: Split verdict. The information architecture is genuinely bespoke — the SLL ratchet dialog spells out an exact tightening ladder, `waitingReason` surfaces the literal MT5 broker retcode instead of guessing, the liquidation-price tooltip ties to Equiti's real 30% stop-out level, and copy-trade grouping solves a problem unique to this engine. But the visual language carries none of that specificity: stock Flutter Material dark theme, hardcoded `Colors.red/green/amber/orange` scattered directly in widget code, default `DataTable`/`Switch`/`IconButton` throughout. Nothing in the chrome signals "this controls real money" versus "internal engineering console" — the seriousness lives entirely in the domain logic, not in how the screen presents itself.

**Deterministic scan**: `detect.mjs` was run against both the single file and the `lib/widgets` directory. Directory scan matched 0 of 10 files (its `SCANNABLE_EXTENSIONS` list is HTML/CSS/JS/TS/Vue/Svelte only — `.dart` isn't in it). The single-file scan has no extension gate and did execute its regex rules against the real file text, but returned zero matches because its rules target CSS/web idioms (`font-family:`, `box-shadow:`, hex colors in CSS syntax) that don't occur in Dart. Confirmed by direct detector-source tracing, not assumed. **The scanner does not support this file type/platform — its empty-array result carries zero evidentiary weight**, positive or negative.

**Visual overlays**: Not applicable. This is a compiled native GTK/Flutter-Linux window, not a browser-rendered page — no DOM, no live-server URL, no script-injection surface exists for the skill's standard overlay step. Substituted with direct screenshot inspection plus exact source-line citations for every mechanical claim below.

## Overall Impression

The domain logic is unusually well thought through for a solo-built trading tool — real broker behavior drives real UI decisions (retcodes, liquidation estimates, SLL history-backed thresholds). But the screen presenting all of that is a stock dark-Material admin console with no visual seriousness of its own, a header that front-loads ~18 simultaneous data points, and — the single biggest risk — a "terminate this live trade" button with the exact same one-tap, no-confirm interaction cost as "pause." The biggest opportunity is closing that gap: let the interface's own visual weight match the real financial stakes of each action, not just its domain copy.

## What's Working

1. **`waitingReason` surfaces the literal broker rejection** instead of a flattened "no signal" — a deliberate decision (per the code's own dev comment) that trusts the operator with real detail instead of hiding it.
2. **Copy-trade group color-tinting** — one hashed color per symbol, darker for the original and lighter for its copies — solves "which trades belong together" with a single visual device, no extra chrome.
3. **Waiting-card layout craft** — fixed equal width/height, deliberate top/bottom padding symmetry, confirmed by direct line citation (`cardPadding = 10.0`, line 433) and several dated comments chasing pixel-level rhythm across a 28-card grid.

## Priority Issues

**[P0] No confirmation before terminating a live trade** — The waiting-card and table-row power icon calls `widget.onTerminate(row.tvSymbol)` straight from `onPressed` — its own tooltip says *"Terminate this pair's trade"* for a running row, yet it carries the exact same one-tap cost as Pause, in an action row measured at 28–36px tap targets (none reach the 44×44dp guideline; confirmed via explicit `BoxConstraints` at lines 484/529/566/594/604/625/1158/1183/1235). **Why it matters**: a single misclick among four adjacent, differently-risky icons closes a real position with real money, with no undo anywhere in the reviewed code. **Fix**: require the same confirm-dialog pattern already used for the far lower-stakes "Reset P&L tracking" action, gated on `row.status == running`. **Suggested command**: `/impeccable harden`

**[P1] Raw broker internals surfaced as primary copy** — `"order rejected: retcode=10014 Invalid volume"` gives the operator a code, not an action; `"Waiting · trading_mt5 ONE_HOUR"` (visible in both screenshots) reads like a leaked/unformatted internal string rather than intended copy. **Why it matters**: operators are left to guess what to actually do, and a likely real bug ships as if it were a status message. **Fix**: map known retcodes to a short human explanation + suggested next step; audit the `ONE_HOUR` string's source as a probable bug. **Suggested command**: `/impeccable clarify`

**[P1] Near-liquidation risk is visually under-weighted** — the single most financially dangerous state this screen shows only recolors two numeric cells to `Colors.yellow.shade800` (lines 981, 1047) with no row highlight, banner, or header-level count — one of only 3 places in the whole review where meaning is carried by color alone with no text/icon backup. **Why it matters**: the highest-stakes state on the page is the easiest to miss while scrolling past a dense table. **Fix**: elevate to row-level highlighting and/or a persistent "N positions near liquidation" indicator near the header. **Suggested command**: `/impeccable colorize`

**[P1] Waiting grid has no severity sort, only alphabetical** — card order is alphabetical only, independent of the running table's own cycling sort; both screenshots show 4 of 6 visible cards in alarm-red simultaneously with no aggregate framing ("account has no funds — N pairs can't open"), forcing the operator to read every card individually to spot one systemic cause. **Why it matters**: with 28 pairs, errors can sit buried mid-alphabet indefinitely. **Fix**: add an "errors first" waiting-card sort mode, or a count banner above the grid. **Suggested command**: `/impeccable layout`

**[P2] Color palette overload** — 8 distinct semantic colors cataloged, with orange/amber/yellow specifically each reused for unrelated meanings (pending status, cancel-button color, Close-A/B tags, near-liquidation, pending-volume indicator). **Why it matters**: a color's meaning isn't stable across the screen, raising the cost of learning the system. **Fix**: reserve each hue for one meaning-class; use a non-color channel (icon/border) for the rest. **Suggested command**: `/impeccable colorize`

## Persona Red Flags

**Alex (impatient power user, managing 28+ pairs)**: No bulk actions anywhere (pause-all, ignite-all-favorites, filter-to-errors don't exist). The sort control cycles through 5 modes one tap at a time rather than direct-select — up to 4 extra taps to reach "P&L low to high." No keyboard shortcuts anywhere in the reviewed widgets, despite this being a native desktop app. Waiting cards are alphabetical-only, so Alex can't jump straight to the rejected pairs that both screenshots show are a frequent, real need.

**Sam (keyboard/screen-reader dependent)**: `ReuseStatusLight` has no `Semantics` wrapping and no state-dependent text — color is the *only* signal (`color = on ? Colors.green : Colors.grey`, confirmed at line 12), confirmed as one of 3 real color-alone risks found in the whole review. Icon-only controls (Ignite, Favorite, Pause) rely on hover/long-press `Tooltip`s as their primary meaning-carrier — a real barrier for non-pointer navigation. The bottom action row packs 4 controls into a ~160px strip with confirmed 28–36px tap targets (none meet 44×44dp); the team's own comment already acknowledges this was a mis-tap risk for mouse users, and "Ignite" (bypasses margin safety) sits directly next to "Terminate" (closes a live trade).

## Minor Observations

- The "1H ✓✓✓ 58:50" chip has no legend in the reviewed source — likely a cycle/candle countdown, opaque in isolation.
- The RAM status light sits at the same visual tier as Engine/MT5/TradingView connectivity — an internal memory diagnostic promoted to peer status with business-critical connection state.
- Spacing is mostly disciplined (`dashboard_screen.dart` uses one `SizedBox(height: 8)` value 5/5 times); a few off-4dp-grid values (6, 10, 14) exist in `auto_trades_card.dart` but each is tied to a distinct, commented layout purpose — not unreviewed drift.
- The icon-size difference between the waiting card's volume stepper (22px) and the table's (16px) is explicitly justified in an inline comment as a deliberate accessibility fix, not an inconsistency.

## Questions to Consider

1. If the account is genuinely at $0.00 balance (as both screenshots show), should the Auto-Managed Trades grid render its normal 28-card layout at all — or should a zero-funds account interrupt with one clear reason, instead of making the operator discover it card-by-card across a dozen identical-looking rejections?
2. The least financially significant action in this codebase (resetting a P&L counter) earned a confirmation dialog; the most financially significant one (terminating a live trade) didn't. What decided that split?
3. Everything distinctive about this product lives in its domain logic (SLL ladders, liquidation estimates, retcode handling) — none of it lives in how the screen looks. Does an interface meant to be trusted with real capital need its own visual signature of seriousness, or is correctness alone assumed sufficient?
