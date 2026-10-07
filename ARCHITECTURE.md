# Architecture

Status date: 2026-09-12. This is the **single** authoritative design doc for
this app, mirroring the "one doc, not four" discipline `tradingPionex`
settled on after its own doc sprawl (`HANDOFF.md`, `MASTER_HANDOFF.md`,
`CURRENT_STATE.md`, `brain/technique.md` all drifting out of sync).

## Why this exists

Same overall idea as `tradingPionex` (an app-brain-first grid/signal trading
bot driven by TradingView chart data), but the execution broker is
**MetaTrader 5** instead of Pionex. Kept as a fully separate, independent
codebase — own engine, own runtime state, own memory — because MT5's
integration shape is different enough from Pionex's single REST call
(`createFuturesGrid`) to not belong bolted onto `tradingPionex`'s already
Pionex-specific `engine_service.dart`, and because `tradingPionex` is live,
trading real money, right now. See `../HANDOFF_BRIEFING.md` for the full
reasoning and `tradingPionex`'s PRD/annex (read-only reference only, never
edited from here) for the hard-won bug lessons this app should not repeat.

## Two processes, one shared data directory

Exactly like `tradingPionex`:

```
bin/engine.dart          — the app brain (once there is one). Long-running.
                            Writes logs/status.json, logs/heartbeat,
                            logs/engine.log, honors PAUSE/STOP/CHECKNOW.
                            Single-instance-locked via logs/engine.pid.

Flutter GUI (lib/main.dart) — the dashboard. Reads status/logs, toggles
                            control files, never decides a trading
                            parameter itself.
```

Data directory: `$TRADING_MT5_HOME`, default `~/.tradingmt5` (see
`lib/core/core_storage.dart`).

## RESOLVED: how the engine talks to MT5

**Native MCP is the execution path.** Confirmed end-to-end 2026-09-12:

- MT5 is installed under Wine (`WINEPREFIX=~/.mt5`, build 6140) and
  authenticates successfully to a live account (Equiti Brokerage). Confirmed
  it can run headlessly on a private Xvfb display (the same "isolated,
  invisible display" pattern `tradingPionex` uses for TradingView Desktop
  after a full-session-crashing bug — see that PRD's §14.5) — and can also
  run on the visible desktop for manual inspection.
- Build 6140 ships a **native MCP server** on `127.0.0.1:22346`, requiring
  `Authorization: Bearer <key>`. This is MetaQuotes' own first-party
  automation surface.
- **The real client key comes from Tools > Options > MCP** in the terminal
  UI — NOT from `Config/assistant.ini` (that file's keys are unrelated,
  confirmed by direct comparison; probably back the MetaEditor AI-assistant
  panel's own outbound connection). **Gotcha, confirmed live**: the running
  MCP listener reads that key only at terminal startup. Saving a new/changed
  key in Options does not hot-reload it — the server keeps rejecting it
  (401) until MT5 is fully restarted (`pkill terminal64.exe` + relaunch).
  Same key, before restart: 401. After restart: 200. If a future key ever
  stops authenticating, restart MT5 before assuming the key itself is wrong.
- **`tools/list` confirmed 42 tools**, spanning full trading execution
  (`trade_send_market_order`, `trade_send_pending_order`,
  `trade_modify_sl_tp`, `trade_delete_order`, `trade_close_single_position`,
  `trade_close_by_position`), complete read-side data (account info, open
  positions/orders, trade history, market watch, chart/tick history),
  MQL5 workspace file tools (read/write/search — shared with the MetaEditor
  AI-assistant feature), chart control, and strategy-tester control. No
  MQL5-EA/file-bridge fallback or WebTerminal UI-automation is needed — the
  native MCP server is a complete first-party trading API.
- Session protocol notes for `mt5_client.dart`: `initialize` returns an
  `Mcp-Session-Id` response header that must be echoed back as a request
  header on every subsequent call, and the client must send a
  `notifications/initialized` message before any `tools/call`/`tools/list` —
  skipping it gets `"MCP session is not initialized"` (JSON-RPC error
  -32600).

`lib/data/mt5/mt5_client.dart` implements the confirmed wire format, session
protocol, AND the double-JSON response unwrapping (see GAPS.md — confirmed
live 2026-09-17 that a tool result's payload is a JSON *string* inside
`content[0].text`, not structured JSON directly).

## The trading model (decided 2026-09-17, per the user)

No investment/margin sizing at all — MT5's equity is shared across
positions, not dedicated per-trade like Pionex's grid. Every open is just
**buy/sell + TP price + SL price + volume**, where volume is always the
symbol's own MT5-reported minimum (`volume_min` from
`get_marketwatch_symbols`, fetched live, never hardcoded).

- **Signal/direction** (rewritten 2026-09-29, per the user — the prior
  worm_9_26 HH/LL + spy_9_26 RSI-zone confirmation model is fully replaced,
  not layered): worm_9_26 ALONE drives every decision now, off its own four
  tag plots on a single bar — `New Higher High` (HH), `New Lower Low` (LL),
  and its own separate `BUY`/`SELL` plotshape pair. spy_9_26 still has to be
  attached (checked before any pair is scanned, same as before) but its
  data is no longer read for signals. `lib/data/tradingview/signals_reader.dart`
  (`readSwingOscillatorSignals`) reads worm_9_26's tags; the decision state
  machine itself lives in `EngineService._checkOneSymbol`:
  - A tag's own direction: HH and SELL mean short/sell; LL and BUY mean
    long/buy.
  - No position running: open in the new tag's direction.
  - Position running, new tag agrees with its direction: ignore.
  - Position running, new tag disagrees: close AND immediately reopen in
    the opposite direction, regardless of tag type (simplified 2026-09-29,
    per the user — an earlier HH/LL "close only, wait for a new tag"
    exception was removed: "no waitng for new signal ... signal appears >
    1 million reading > action").
  - **"Survive one extra candle" confirmation** (added 2026-09-30, per the
    user, sitting between the triple-read confirmation and the decision
    above — `PendingSignalStore`/`pending-signals.json`, keyed by
    `category|tvSymbol`): a triple-confirmed signal is NOT acted on
    immediately. It's recorded as a pending candidate, and the symbol is
    skipped entirely (no chart access at all) until wall-clock reaches the
    end of the candle immediately following the candidate's own bar —
    checked once at that point, not every cycle. If the freshly re-read
    `latest` tag/bar still matches the pending candidate exactly (nothing
    newer has appeared anywhere on the chart), the candle after it is
    provably empty, the candidate is cleared, and the decision engine above
    acts on it immediately using THIS cycle's fresh range/signal reads (per
    the user: "just act as if signal occures now. instant action"). If
    `latest` has moved on instead, the new tag/bar replaces the pending
    candidate and the wait restarts for it — recursively, so a signal only
    ever fires once it's the first one to survive a full candle unchallenged.
- **Range**: unchanged — Daily MSB/OB zigzag polyline,
  `lib/data/technique/zigzag_range.dart`, ported verbatim.
- **TP/SL**: the 60/40 range-based model, `lib/data/technique/liquidation.dart`
  (`computeLiquidationLevels`) — but the **ORIGINAL** tradingPionex version,
  not the 2026-09-14 `computeLiquidationShift` variant (which depends on
  Pionex's real liquidation price from a margin/leverage-dependent probe —
  an input that doesn't exist here, per the user's explicit "no
  investment/margin calc" instruction).
- **Exit**: signal-flip closes the position early (mirrors tradingPionex's
  opposite-signal exit) IN ADDITION to the SL/TP already set directly on
  the MT5 order, which the broker enforces on its own regardless.
- **Scheduling**: the full multi-category system, same as tradingPionex —
  `lib/data/models/auto_category.dart`, per-category
  `AutoManagedStore`/`BotCategoryStore` state, ported/adapted from
  tradingPionex's identity layer. Started as 3 categories (1m/1H/1D),
  expanded to 5 on 2026-09-19 (added 5m/15m) mirroring tradingPionex's own
  same-day expansion — see GAPS.md for the non-obvious range-resolution
  rule those two use.
- **Symbol naming**: TradingView and this MT5 broker use different symbol
  names for the same instrument — crypto has no USDT at all on MT5
  (BTCUSDT on TradingView vs. `BTCUSD.lv` on MT5, confirmed live via
  `get_marketwatch_symbols`). `AppConfig.symbols` is an explicit list of
  `{tradingview_symbol, mt5_symbol}` pairs, never assumed to be the same
  name.
- **Risk gate keying**: position-cap state is keyed `"SYMBOL|CATEGORY"`,
  not bare symbol — ported ahead of time from a real bug tradingPionex hit
  and fixed 2026-09-19 (bare-symbol keying let one category's open position
  silently block every other category on the same symbol). See GAPS.md.

**The full cycle has never been run live** — see GAPS.md item 1. Every
piece is real, compiling, individually-verified code, but running
`bin/engine.dart` for real, right now, could place an actual trade on the
connected LIVE account (Equiti Brokerage) if a signal lines up. That's a
decision for the user, not something to trigger while "just testing it
compiles."

## Component map: what's real vs. placeholder right now

| File | Status |
|---|---|
| `lib/core/*` | Real — generic Flutter/Material3 infra, no MT5-specific decisions baked in. |
| `lib/core/core_storage.dart` | Real — file layout + control-file conventions ported from tradingPionex. |
| `lib/data/logging/app_logger.dart` | Real — ported near-verbatim from tradingPionex, genuinely broker-agnostic. |
| `lib/data/risk/risk_gate.dart` + `models/risk_state.dart` | Real — ported near-verbatim. Kill switch (STOP file), daily loss %, per-symbol position cap, cooldown, UTC day boundary. |
| `lib/data/mt5/mt5_client.dart` | Real, fully wired: session handshake, double-JSON unwrapping, and typed wrappers for every trading tool used (`sendMarketOrder`, `modifyStopLossTakeProfit`, `closePosition`, `getOpenPositions`, `getMarketWatchSymbol`, `getAccountInfo`). |
| `lib/data/tradingview/*` | Real — ported byte-identical from tradingPionex (broker-agnostic, no changes needed). |
| `lib/data/technique/{zigzag_range,liquidation}.dart` | Real — ported verbatim / adapted (60/40 model only, see above). |
| `lib/data/identity/*` | Real — ported/adapted from tradingPionex, Pionex `buOrderId` (String) renamed to MT5 position ticket (int) throughout. `pair_investment_store.dart` deliberately not ported. |
| `lib/data/engine/engine_service.dart` | Real cycle logic — connects TradingView + MT5, reads signal/range per category/symbol, computes TP/SL, checks the risk gate, opens/closes via MT5. NOT yet live-tested end-to-end (see above) and missing tradingPionex's deeper hardening (retry ladders, watchdogs — see GAPS.md). |
| `lib/screens/app/*`, `lib/widgets/*` | Real but minimal — enough to run, navigate, and watch status/logs/controls. No auto-managed-symbol toggle UI yet (see GAPS.md item 4). |

## Standing process requirements

- Maintain **`TradingMT5_PRD.md`** and **`annex_prd_update.md`** in
  `tradingMT5/` (repo root, not `app/`) — not yet created as of this
  scaffold. Mirror `tradingPionex`'s discipline: update after every
  fix/feature, root cause + user quotes + fix + verification evidence, newest
  entries first in the annex.
- Always consult `tradingPionex`'s PRD + annex (read-only) before
  re-deriving a design answer it already found the hard way.
