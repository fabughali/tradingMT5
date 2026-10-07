# Gaps and open questions

Status date: 2026-09-19.

## OPEN

1. **The full live cycle has never been run end-to-end.** `flutter analyze`
   and `flutter test` are clean, and every piece (TradingView signal
   reading, MT5 client, technique math, risk gate) is individually real,
   ported/verified code — but `bin/engine.dart`'s `run()` loop, run for
   real, WOULD attempt a live trade on the connected account if a signal +
   risk-gate pass line up, since this account is LIVE (Equiti Brokerage,
   `EquitiBrokerageSC-Live`). Deliberately not run yet — that's a decision
   for the user to make explicitly, not something to trigger as a side
   effect of "testing that it compiles."
2. **`trade_send_market_order`'s success-response ticket field name is
   unconfirmed.** Never fired a real order to see the response shape
   (placing one just to find out would itself be a live trade). `_openPosition`
   in `engine_service.dart` defensively tries several plausible field names
   (`ticket`, `position_ticket`, `position`, `order`, `deal`) and logs the
   raw response at CRITICAL level with no state update if none match, rather
   than silently guessing wrong and mistracking a real position. **Confirm
   this against the first real order placed** and simplify
   `_firstIntField`'s guess-list down to the real key. Same applies to
   `OpenPositionInfo.sl`/`.tp` field names in `market_watch_snapshot.dart` —
   confirmed live that MT5 omits these fields entirely when unset, but the
   NAMES (`sl`/`tp`) follow MT5's universal convention, unconfirmed against
   a position that actually has them set.
3. **Hardening not yet ported from tradingPionex's engine_service.dart**
   (7300+ lines vs. this app's ~300): no indicator-wait retry ladder, no
   600s re-entrancy watchdog, no sleep/awake health recovery, no candle-gate
   persisted across restarts (this app's bar-time-seen gate is in-memory
   only — see the doc comment on `EngineService._lastBarTimeSeen`; not a
   safety issue since `OpenPositionStore` + `RiskGate.maxPerSymbol` are what
   actually prevent a duplicate open, just means one redundant re-check
   right after a restart). Port these incrementally as real incidents
   demand it, same discipline tradingPionex followed — don't pre-build
   hardening for failure modes that haven't happened yet.
4. ~~No GUI opt-in/opt-out flow for auto-managed symbols~~ — RESOLVED.
   The Dashboard's Auto-Managed Trades table has a per-row Auto toggle
   (and a Last toggle, and a power/terminate icon) wired straight to
   `AutoManagedStore`/`LastTagStore`/`TerminateRequestStore`. The bootstrap
   in `EngineService`'s constructor was also fixed to only seed symbols on
   a category's true first-ever run, not every startup. This app's own
   Controls screen (a separate, simpler pause/resume/check-now/stop
   screen) was deleted entirely 2026-09-30, per the user ("delete
   controls screen. not required") - not merged into the Dashboard, just
   removed, since Resume/Pause duplicated the Power toggle and Check
   now/Stop had no replacement.
5. **`TradingMT5_PRD.md` / `annex_prd_update.md`** not yet created —
   standing requirement per `../HANDOFF_BRIEFING.md` §5. Overdue now that
   there's real engine behavior worth documenting.
6. **`PairCategoryStore` ported but unused.** No GUI category-picker exists
   yet, so there's nothing to read it back for.
7. **"-50% baseline-SL reignite opposite direction" — NOT ported, needs its
   own design pass.** tradingPionex added this 2026-09-19: when a bot's real
   close reason is a raw, never-ratcheted baseline -50% stop-loss, it
   immediately reopens the same symbol+category in the OPPOSITE direction
   (bypassing the normal signal-wait gate), on the theory that hitting the
   raw baseline SL means the original direction call was wrong. This is
   broker-agnostic in principle, but (a) tradingPionex's detection relies on
   Pionex's own `reasonBy: "loss_stop"` field on a closed-grid record — MT5
   needs an equivalent way to tell "stopped out at the raw computed SL vs.
   a tightened one", and (b) this app has no ratchet/trailing-SL system at
   all yet, so "baseline vs. ratcheted" isn't even a meaningful distinction
   here yet. Don't bolt this onto an engine that's never had a single live
   cycle — design it once the core loop is proven, not before.
8. **Precision-before-safety-check ordering — checked, not applicable as
   currently built.** tradingPionex hit a real bug 2026-09-18: a broker
   precision-rounding probe ran AFTER the liquidation-shift safety decision
   instead of before, so a probe failure silently fell through to "safety
   check passed" (`stable: true`) instead of surfacing the real problem.
   This app doesn't have an equivalent probe-then-decide step — it uses the
   ORIGINAL `computeLiquidationLevels` (60/40 model), not
   `computeLiquidationShift`, and rounds SL/TP to the symbol's `digits`
   AFTER the TP/SL decision is already made, not as a gating precondition
   for it — so the same failure mode doesn't exist here. Re-check this if
   `computeLiquidationShift`-style broker-probe logic is ever added later.

## RESOLVED

- **Display strategy for the Wine-hosted terminal**: confirmed a private
  Xvfb display works for headless operation (same pattern as
  `tradingPionex`'s TradingView Desktop isolation), and that the terminal
  can also run on the visible desktop for manual inspection when needed.
- **MCP auth key** (2026-09-12): the terminal's native MCP server does NOT
  read its inbound auth key from `Config/assistant.ini`. The real key comes
  from **Tools > Options > MCP** in the terminal UI, and critically, the
  running MCP listener only reads that key at terminal startup — a key
  changed while MT5 is already running keeps failing (401) until MT5 is
  fully restarted.
- **MCP tool coverage** (2026-09-12): confirmed via `tools/list` — 42 tools,
  a complete first-party trading API including full order placement/
  management. No MQL5-EA/file bridge or WebTerminal fallback needed.
- **MCP response shape** (2026-09-17): a `tools/call` result is
  `{isError, content: [{type: "text", text: "a-json-string"}]}` — the
  actual payload is a JSON *string* inside `content[0].text`, needing a
  second decode. `Mt5Client.callTool` handles this; confirmed live against
  `get_marketwatch_symbols`, `get_trading_open_positions`, and
  `get_trading_account_info`. Some tools (`add_marketwatch_symbol`,
  `remove_marketwatch_symbol`) return plain text instead of JSON in that
  same field — `callTool` falls back to the raw string when JSON-decoding
  fails.
- **TP/SL formula, signal-direction logic, and loop scope decided**
  (2026-09-17, per the user): 60/40 range-based model
  (`computeLiquidationLevels`, ORIGINAL tradingPionex version — no
  Pionex-liquidation-price dependency); signal-flip early exit in addition
  to broker-side TP/SL; full multi-category system, same as tradingPionex.
  All implemented in `lib/data/engine/engine_service.dart`.
- **TradingView signal-reading layer + identity stores ported**
  (2026-09-17): `lib/data/tradingview/*` ported byte-identical (broker-
  agnostic, no changes needed). Identity stores ported with the Pionex
  `buOrderId` (String) concept renamed to MT5 position ticket (int) —
  `open_position_store.dart` (new), `bot_category_store.dart`,
  `widen_applied_store.dart` adapted; `auto_managed_store.dart`,
  `retired_store.dart`, `pair_category_store.dart` ported as-is (already
  keyed by symbol, not by identity). `pair_investment_store.dart`
  deliberately NOT ported (no investment/margin tracking in this app).
- **Symbol naming mismatch discovered and handled** (2026-09-17): this
  broker's MT5 symbols don't match TradingView's naming (e.g. crypto has no
  USDT at all — BTCUSDT on TradingView vs. `BTCUSD.lv` on MT5) — confirmed
  live via `get_marketwatch_symbols`. `AppConfig.symbols` is an explicit
  `SymbolMapping` list (tradingview_symbol + mt5_symbol pairs), never
  assumed to be the same name.
- **Volume**: no investment/margin sizing, per the user's explicit
  instruction — every open uses the symbol's own MT5-reported `volume_min`
  (fetched live via `get_marketwatch_symbols` at open time, never
  hardcoded).
- **Market Watch live-mirrors, symbol availability checked, New Order
  screen built** (2026-09-17): app's symbol list is never separately
  maintained — `watchedSymbolsProvider` polls MT5's actual Market Watch
  live (5s cadence) and both the Dashboard and Symbols screen render that
  directly; add/remove in MT5 shows up in-app automatically. Checkbox +
  "Remove from watch list" per symbol, disabled while that symbol has an
  open position. New Order screen: Market Execution fully wired (symbol
  picker, volume stepper using broker `volume_step`, optional SL/TP,
  BUY/SELL with confirmation dialog, MT5's real rejection reason surfaced
  verbatim on failure); the other 6 order types are placeholder-only.
- **RiskGate position-cap keying bug, caught before it ever shipped**
  (2026-09-19): ported from tradingPionex's own 2026-09-19 fix ahead of
  hitting it live here. Was keyed by bare `symbol`, which would have capped
  ANY position on a symbol to `maxPerSymbol` across ALL categories combined
  — contradicting the intended "1 open position per symbol PER CATEGORY"
  design (a position opened under 1m would have silently blocked 1H from
  ever opening on the same symbol). Now keyed `"SYMBOL|CATEGORY_WIRE"`;
  `gate()`/`openPosition()`/`closePosition()` all take an explicit
  `AutoCategory` parameter. Also added `RiskGate.resetTo()` for a one-time
  rebuild from a live broker snapshot, for the same reason tradingPionex
  needed it: a pure key-format change must never silently lose track of an
  already-open real position.
- **5m and 15m auto-categories added** (2026-09-19), matching
  tradingPionex's own expansion from 3 to 5 categories same day: 5m reads
  its signal on the literal 5-minute chart but its RANGE from the hourly
  zigzag; 15m reads its signal on the 15-minute chart but its range from
  the DAILY zigzag (neither follows the simple "one level up" pattern the
  original three categories use — this is tradingPionex's own explicit
  spec, not derived).
