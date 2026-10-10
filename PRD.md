# TradingMT5 — Product & Technical Requirements Document

**Updated:** 2026-10-08
**Status date:** 2026-10-08
**Document type:** Living document — every future bug fix, feature, or design
decision made on this project should be reflected here, in place, as part of
that change. This is the one place project history and current truth live.
**Scope:** Single-user, single-machine (with a Windows port, untested against
a real Windows machine as of this date), real-money MT5-broker signal trading
system. Everything in this document describes the Flutter/Dart application at
`app/` in this repository, as it exists on the date above. It is written to
be fully self-contained — no external files need to be opened to understand
any claim made here.

---

## Table of contents

1. Executive summary
2. Origin and relationship to tradingPionex
3. Goals, non-goals, and operating philosophy
4. System architecture
5. Technology stack
6. Data directory layout — complete file reference
7. Configuration reference
8. Core domain models
9. The trading techniques — full algorithmic specification
10. Risk management (`RiskGate`)
11. The Auto category system
12. Trade sizing (volume) and the step-down retry ladder
13. MT5 API integration
14. TradingView integration (CDP)
15. Engine runtime behavior (`bin/engine.dart` / `engine_service.dart`)
16. GUI reference — every screen and widget
17. Design system / tokens
18. Safety invariants — do not regress these
19. Windows support
20. Development history and changelog
21. Known gaps and deliberately deferred work
22. Testing and verification approach
23. Operational procedures

---

## 1. Executive summary

TradingMT5 is a real-money, single-user automated trading application that
reads entry/exit signals off a TradingView Desktop chart (via Chrome DevTools
Protocol automation of the user's own Pine Script indicators) and executes
trades on a MetaTrader 5 account through MT5's native MCP server. It is
deliberately **not** a grid-trading system — every "trade" is a single market
(or, on fallback, pending) order with a broker-side Stop Loss and Take Profit,
sized at the symbol's own broker-reported minimum volume (or a user-chosen
override), closed either by hitting SL/TP, by an opposite confirmed signal,
or by the user.

The app consists of two long-running Dart processes sharing one local data
directory:

- **The engine** (`bin/engine.dart` → `EngineService`) — the brain. Connects
  to TradingView (via CDP) and MT5 (via its native MCP server), reads
  signals/ranges, applies risk checks, and places/closes real orders.
- **The GUI** (`lib/main.dart`, Flutter) — the dashboard. Never talks to MT5
  or TradingView to make a trading decision; it only displays the engine's
  own on-disk status/log/history files and writes plain control files
  (Power on/off, per-pair Auto/Last toggles, terminate requests, volume
  overrides) that the engine picks up on its next cycle.

The account currently connected is Equiti Brokerage (Seychelles) Limited,
login 1013734072, `EquitiBrokerageSC-Live` — a **live, real-money account**.
Every trading decision described in this document can place or close a real
position.

Two interchangeable **decision techniques** exist, selectable from the GUI
without a restart:

- **Signal Flip (HH/LL + BUY/SELL)** — reacts to a Pine Script called
  `worm_9_26`'s own HH/LL/BUY/SELL tag plots.
- **Supertrend Plus (Heikin Ashi)** — reacts to a separate Pine Script's
  strictly-alternating Buy/Sell plots, on Heikin Ashi candles.

The app runs natively on Linux today and has a Windows port (built and
packaged entirely through GitHub Actions CI) that compiles clean but has
never been exercised against a real Windows machine.

## 2. Origin and relationship to tradingPionex

TradingMT5 is a **fully separate, independent codebase** — its own engine,
its own runtime state, its own memory — built by the same user and developer
as a sister project, `tradingPionex` (a Pionex-broker, grid-trading system,
also live and trading real money). TradingMT5 deliberately does not share
code, a repository, or a data directory with `tradingPionex`.

`tradingPionex` is consulted **read-only**, as a reference for its proven
architecture pattern (two processes sharing one data directory, file-backed
control signals, identity stores, an app-brain-first signal-reading
approach) and its hard-won bug lessons (flicker-prone chart reads needing
multi-read confirmation, position-cap keying bugs, reconciliation gaps,
etc.) — never edited from here, and tradingMT5's own decisions are never
assumed to match tradingPionex's just because the pattern was borrowed.

The two apps diverge sharply on trading model: tradingPionex opens grids
(multiple orders per position, investment/leverage/liquidation-price sizing,
a liquidation-price-shift TP/SL model); tradingMT5 opens a single market
order per position with no investment sizing at all (MT5's account equity is
shared across positions, not dedicated per-trade like a Pionex grid) and uses
the **original**, simpler 60/40 range-based TP/SL model tradingPionex itself
used before its liquidation-price-shift variant existed. Several pieces —
the TradingView CDP transport, the zigzag-range detector, the risk gate, the
structured logger — are broker-agnostic and were ported from tradingPionex
near-verbatim, since nothing about reading a chart or capping daily loss
depends on which broker executes the trade.

## 3. Goals, non-goals, and operating philosophy

**Goals:**
- Read a single, authoritative signal source per decision technique directly
  off the user's own TradingView Pine Script indicators — never guess, never
  fall back to a second source.
- Execute real MT5 orders deterministically from that signal, with a
  broker-side Stop Loss and Take Profit on every position.
- Require extreme confidence before acting: every signal and every price
  range must agree across three independent reads, ten seconds apart, before
  the engine trusts it (see §9's "1,000,000 sure" rule) — and then survive
  one additional full candle unchanged before being acted on.
- Self-heal from the failure modes that have actually happened live: a stuck
  TradingView process, a dead MT5 connection, a stale PID, a vanished
  position never reconciled, a resting pending order the engine forgot about.
- Keep exactly one source of truth for every durable fact (a position's
  tracked status, its category, its auto-managed/retired state) in a single
  JSON file read fresh by both processes — never a value cached once and
  trusted forever.

**Non-goals:**
- No investment, margin, or leverage sizing. No grid of multiple orders per
  position. No liquidation-price-dependent TP/SL model.
- No multi-user, multi-account, or multi-machine support — this is a
  single-user, single-broker-account, single-data-directory app.
- No "paper trading" or simulation mode — every build talks to the real,
  configured MT5 account.

**Operating philosophy:** this codebase is built and corrected almost
entirely from live, real-money incidents, not speculative hardening. A
feature or safety check exists because something the user watched happen
live demanded it — the development history in §20 is the actual design
process, not an afterthought log. Don't pre-build hardening for failure
modes that haven't happened yet; do add it the moment one has.

## 4. System architecture

### 4.1 Two processes, one shared data directory

```
bin/engine.dart (EngineService)   — the brain. Long-running. Connects to
                                     TradingView (CDP) + MT5 (native MCP),
                                     reads signals/ranges per auto category/
                                     symbol, opens/closes real orders.
                                     Writes logs/status.json, logs/heartbeat,
                                     logs/engine.log, logs/bot-history.jsonl.
                                     Single-instance-locked via
                                     logs/engine.pid. Honors the PAUSE/STOP/
                                     CHECKNOW/AUTO_PAUSED* control files.

Flutter GUI (lib/main.dart)       — the dashboard. Reads status/logs/history,
                                     writes control files and identity-store
                                     entries, NEVER decides a trading
                                     parameter or calls a trading MT5 tool
                                     itself for signal/decision purposes (it
                                     DOES poll MT5 directly, read-only, for
                                     live display data — see §16).
```

Data directory: `$TRADING_MT5_HOME`, default `~/.tradingmt5`
(`CoreStorage._resolveRootDir`). Both processes resolve every path through
the same `CoreStorage` singleton, so they always agree on where every file
lives.

### 4.2 Process lifecycle (Power toggle, rewritten 2026-10-05)

Power is now the engine **process's own** on/off switch, not an internal
pause flag an always-running process polls:

- Power ON (`EngineControlRepository.resume`) → `systemctl --user start
  tradingmt5-engine.service` on Linux, or a direct `Process.start` of
  `tradingmt5_engine.exe` on Windows. The engine process runs the full
  internet → MT5 → TradingView → indicators sequence from scratch on its
  very first loop iteration.
- Power OFF (`EngineControlRepository.pause`) → `systemctl --user stop` (a
  SIGTERM) on Linux, or `taskkill`/graceful-fallback on Windows. The engine's
  own 10-second force-exit watchdog (`bin/engine.dart`) guarantees the
  process is gone within that window regardless of what it was mid-doing.
- Closing the GUI window, or the GUI crashing/losing its process, also stops
  the engine (see §4.3).
- Power always starts OFF on every fresh GUI launch (`main.dart`'s startup
  hook unconditionally calls `_controlRepo.pause()`) — the app never silently
  resumes trading just because the GUI was reopened.

### 4.3 GUI-heartbeat gate (2026-10-05)

`main.dart` touches `logs/gui-heartbeat` every 5 seconds while the GUI is
running. The engine's main loop (`EngineService.run`) checks this file's
freshness (`_guiStaleThreshold` = 20s) on every iteration: while fresh, the
engine runs normally; the instant it goes stale (GUI closed gracefully, GUI
crashed, or the machine restarted without a clean shutdown), the engine stops
itself outright rather than idling — "TradingView/MT5 should not launch
unless the user has the GUI open," per the user's explicit rule. The GUI's
own graceful-close handler (`AppLifecycleListener.onExitRequested` plus
SIGINT/SIGTERM watchers) is the fast path (asks `systemctl` to stop the
engine immediately); the heartbeat-staleness check is the safety-net fallback
for every ungraceful loss.

### 4.4 Cross-process store staleness rule

Every identity store (`lib/data/identity/*`) and every control file is read
fresh from disk on each access — never cached across a poll/cycle boundary
and trusted stale. `CoreStorage.writeString` writes atomically (temp file +
rename) so a concurrent reader from the other process never sees a
torn/partial write.

### 4.5 Single-instance engine lock

`bin/engine.dart` writes its own PID to `logs/engine.pid` and refuses to
start if a PID already recorded there belongs to a still-alive process
*confirmed to be this binary* — not just any process reusing that PID number
(see `_isProcessAlive`'s own doc comment in §15.1 for the real incident this
guards against: a crashed engine's stale PID file getting reused by an
unrelated OS process after a reboot, which made every restart attempt
falsely believe an engine was already running).

## 5. Technology stack

- **Flutter/Dart** (SDK `^3.12.2`) for both the GUI and the headless engine
  binary — one language, one toolchain, two entry points (`lib/main.dart`,
  `bin/engine.dart`).
- **flutter_riverpod** (`^3.4.2`) for GUI state — file-backed
  `StreamProvider`s polling every few seconds (never a push/socket
  architecture between GUI and engine).
- **go_router** (`^17.5.0`) for the GUI's shell navigation (splash →
  Dashboard/History/Logs/Settings persistent tabs).
- **MetaTrader 5's native MCP server** (build 6140+, JSON-RPC 2.0 over HTTP,
  `Mcp-Session-Id` session protocol) as the sole execution path — no MQL5
  Expert Advisor, no file bridge, no WebTerminal UI automation.
- **Chrome DevTools Protocol** (raw WebSocket JSON-RPC, no browser-automation
  framework) against TradingView Desktop's own Electron/Chromium process,
  for reading Pine Script indicator plot data directly out of the chart's
  internal data model and, where needed, for dispatching real synthetic
  mouse events to drive indicator-management UI.
- **`cryptography`** (AES-256-GCM, PBKDF2-HMAC-SHA256) + **`archive`** (zip)
  for the encrypted Backup & Restore feature.
- **`path`**, **`http`**, **`intl`**, **`flutter_localizations`** — standard
  supporting packages. No `package_info_plus` (see §19's FAT32 note) — the
  app's own version string is read from `pubspec.yaml`, bundled as a plain
  Flutter asset, at runtime instead.
- **Wine** (Linux only) hosts the MT5 terminal; **Xvfb** (Linux only, remote
  sessions only) isolates TradingView Desktop on a private, invisible X
  display.
- **systemd --user** (Linux) manages the engine process's lifecycle; Windows
  has no equivalent and uses direct process spawn/kill instead (§19).
- **GitHub Actions** (`windows-latest` runner) builds and publishes
  versioned Windows releases on every push to `main`.

## 6. Data directory layout — complete file reference

Root: `$TRADING_MT5_HOME` (default `~/.tradingmt5`). All paths below are
relative to this root unless noted. Every path is defined once, in
`lib/core/core_storage.dart`, and both processes share that single source.

```
config.json                       — AppConfig (see §7.1). Seeded on first
                                     run from AppConfig.defaultConfig if
                                     missing.
.env                               — MT5_MCP_API_KEY only (see §7.2). Never
                                     committed; local secret.
backups/                           — Settings → Backup & Restore export
                                     destination (encrypted .tmt5 files).
                                     Explicitly excluded from its own
                                     backups.
PAUSE                              — Power-off INTENT marker. Toggled by the
                                     Dashboard Power switch; no longer read
                                     by the engine itself (2026-10-05) — the
                                     engine process only exists because Power
                                     was turned on; this file is purely a
                                     fast, synchronous read for the toggle's
                                     own display.
STOP                               — Kill switch. RiskGate blocks every
                                     "open" action while this file exists;
                                     "close" is always allowed. The main
                                     loop also breaks out entirely on seeing
                                     it.
CHECKNOW                           — Deleted every loop iteration; currently
                                     has no other behavioral effect (Checkup
                                     already runs continuously).
AUTO_PAUSED                        — Global Auto off. Engine still runs/
                                     connects/heartbeats; skips the whole
                                     auto-category checkup loop.
AUTO_PAUSED_ONE_HOUR               — Per-category Auto off (only ONE_HOUR
                                     exists today — see §11).
gui-prefs.json                     — GUI-only theme mode preference. Never
                                     read by the engine.
pnl-since.json                     — GUI-only "reset" marker for the
                                     Dashboard's P&L-since-timestamp tracker.
                                     Never read by the engine.

logs/
  engine.log                       — Structured log, 20MB rotation into
                                     timestamped archives, 60-day auto-purge.
                                     Every manual GUI action is also written
                                     here, prefixed "[USER]", via the same
                                     AppLogger the engine itself uses — one
                                     unified timeline.
  engine.<timestamp>.log           — Rotated archive.
  heartbeat                        — Touched by the engine every loop
                                     iteration. `EngineControlRepository.
                                     engineRunning` is this file's mere
                                     existence.
  gui-heartbeat                    — Touched by the GUI every 5s (see §4.3).
  engine.pid                       — The running engine process's own PID
                                     (single-instance lock, see §4.5).
  status.json                      — EngineStatus (running/connected/health/
                                     message/last-cycle-time). GUI-read-only.
  state.json                       — RiskState (daily P&L%, per-symbol|
                                     category open-position counts, cooldown
                                     deadline). Resets at UTC midnight.
  open-positions.json              — OpenPositionStore: every MT5 position
                                     ticket the app itself opened.
  bot-categories.json              — BotCategoryStore: ticket -> AutoCategory
                                     wire value.
  auto-managed-bases.json          — AutoManagedStore (ONE_HOUR category):
                                     uppercase tvSymbol bases the engine
                                     actively auto-manages.
  last-tagged-pairs.json           — LastTagStore: bases flagged "finish the
                                     current trade, then stop auto-managing."
  paused-pairs.json                — PausedPairStore (2026-10-09): bases
                                     still fully auto-managed but the engine
                                     takes no action on right now - stays
                                     listed, unlike retired-pairs.json.
  unpause-check-requests.json      — UnpauseCheckRequestStore (2026-10-09):
                                     a one-shot queue, same shape as
                                     terminate-requests.json - a base just
                                     un-paused, awaiting its immediate
                                     reverse-checkup/catch-up re-evaluation.
  retired-pairs.json               — RetiredStore: bases the engine will
                                     never auto-recreate (an explicit
                                     "unretire" — re-adding via Auto — is the
                                     only way back in).
  symbol-resolve.json              — SymbolResolveStore (2026-10-10): Add
                                     Pair dialog's GUI<->engine request/
                                     response scratch pad for "does
                                     TradingView genuinely have a chart for
                                     this candidate symbol" - same one-shot
                                     request shape as terminate-requests.json,
                                     but carries a status (pending/found/
                                     not_found) + the resolved symbol back to
                                     the GUI instead of just being cleared.
  waiting-reasons.json             — WaitingReasonStore: the broker's own
                                     exact rejection text for the last failed
                                     open attempt, per tvSymbol.
  last-checked.json                — LastCheckedStore: when each running base
                                     was last genuinely re-evaluated (past
                                     cooldown, a real chart read attempted).
  pending-signals.json             — PendingSignalStore: Signal Flip's own
                                     "survive one extra candle" candidate per
                                     category|tvSymbol — {tag, bar_time}.
  supertrend-pending.json          — SupertrendPendingStore: Supertrend
                                     Plus's own, SEPARATE survive-one-candle
                                     candidate store. Never shared with
                                     pending-signals.json; the Dashboard's
                                     Close A/Update columns always read only
                                     the Signal Flip file and stay blank for
                                     Supertrend-driven pairs.
  first-open.json                  — FirstOpenStore: category|tvSymbol keys
                                     that have EVER achieved a real first
                                     open. Permanent once set.
  new-pair-wait.json               — NewPairWaitStore: for a pair that has
                                     never opened, the direction being
                                     waited OUT before its first-ever entry.
  terminate-requests.json          — TerminateRequestStore: a one-shot queue
                                     the GUI appends to (Dashboard power
                                     icon), the engine drains every cycle.
  trade-volume.json                — TradeVolumeStore: per category|tvSymbol
                                     desired/attempt/last-applied volume
                                     (see §12).
  pair-categories.json             — PairCategoryStore: ported, currently
                                     unused (no GUI category-picker exists —
                                     only one category, 1H, exists today).
  bot-history.jsonl                — Every terminated position's full
                                     record, append-only, one JSON object per
                                     line (BotHistoryEntry, see §8).
  entry-signal.json                — EntrySignalStore: the open-side signal
                                     snapshot (tag + bar time + later update
                                     tag/time) per currently-open ticket;
                                     consumed once at close time to fill
                                     BotHistoryEntry's open_signal_* fields.
  widen-applied-bots.json          — WidenAppliedStore: tickets whose 60/40
                                     range-widen adjustment was applied at
                                     open time.
  decision-technique.json          — The GUI-selected DecisionTechnique.id
                                     (see §9). GUI-owned; engine reads it
                                     fresh every cycle, never writes it.
  last-seen-technique.json         — The DecisionTechnique.id the engine
                                     last fully acted on. Engine-owned, used
                                     purely to detect a genuine switch for
                                     logging and for gating the one-time
                                     reverse-check sweep (see §9.5).
```

## 7. Configuration reference

### 7.1 `config.json` (mirrors `AppConfig`)

```json
{
  "poll_interval_sec": 5,
  "remote_session": true,
  "mt5": { "mcp_host": "127.0.0.1", "mcp_port": 22346 },
  "cdp": { "host": "127.0.0.1", "port": 9222 },
  "technique": { "range_swing_count": 20 },
  "risk": {
    "daily_loss_limit_pct": 5,
    "max_positions": 3,
    "max_per_symbol": 1,
    "max_trade_size_pct": 2,
    "cooldown_sec": 900
  },
  "symbols": [
    { "tradingview_symbol": "BTCUSDT", "mt5_symbol": "BTCUSD.lv" }
  ],
  "heartbeat": { "alert_every_min": 15 }
}
```

- `poll_interval_sec` — delay between main-loop iterations (default 5s).
- `remote_session` — whether TradingView launches isolated on a private,
  invisible Xvfb display (`true`, the safe default for a remote-desktop
  session) or visibly on the real display (`false`, for a genuinely local
  session). Linux only; meaningless on Windows (§19).
- `mt5.mcp_host`/`mcp_port` — MT5's native MCP server address. **No
  fallback/default values** (removed 2026-10-07, per the user, since this
  repo is public — every user has their own setup) — missing fields throw a
  `FormatException` pointing at `config.example.json`. Read once at engine
  startup only; a changed value needs an engine restart.
- `cdp.host`/`port` — TradingView Desktop's CDP debug port, same
  no-fallback rule. Read once at engine startup only.
- `technique.range_swing_count` — how many recent zigzag pivots the Daily
  MSB/OB range detector keeps (default 20, see §9.2).
- `risk.*` — see §10.
- `symbols` — the explicit `{tradingview_symbol, mt5_symbol}` mapping list.
  Re-read fresh from disk every engine cycle (`_loadSymbolsFresh`), so a
  symbol added live (e.g. via the Dashboard's "Start Auto Trade") takes
  effect on the very next cycle, no restart needed.
- `heartbeat.alert_every_min` — reserved; not currently wired to any alert
  mechanism.

### 7.2 `.env`

```
MT5_MCP_API_KEY=
```

The per-client key MT5's native MCP server expects as `Authorization: Bearer
<key>`. Sourced from **Tools → Options → MCP** in the MT5 terminal UI — *not*
`Config/assistant.ini` (confirmed unrelated). **Gotcha, confirmed live**: the
running MCP listener only reads this key at terminal startup; changing it in
Options does not hot-reload — MT5 must be fully restarted before a new key
authenticates. Read fresh only when the engine rebuilds its MT5 client (a
failed connect, or an engine restart) — a key changed via the Settings screen
also needs an engine restart to take effect.

### 7.3 Settings-screen-editable config

Host/port for both MT5 and TradingView CDP, plus the MT5 API key, are
editable directly from the Settings screen's "Connections" card
(`EngineControlRepository.updateMt5Config`/`updateCdpConfig`/
`updateMt5ApiKey`) — each writes straight back to `config.json`/`.env`,
preserving every other key, with an explicit "needs an engine restart" caveat
since none of these three hot-reload mid-session.

## 8. Core domain models

- **`TradeDirection`** (`long`/`short`) — the MT5 equivalent of
  tradingPionex's `GridDirection`, renamed since there's no grid here.
- **`SignalTag`** (`hh`/`ll`/`buy`/`sell`) and **`Signal`** — one confirmed
  tag on one bar, with `time` (epoch seconds, the bar's open time) and a
  derived `side` (HH/SELL → sell; LL/BUY → buy).
- **`BuySellCheck`** — the result of one signal read: a symbol, its list of
  `Signal`s, and `latestBarTime` (the newest candle's open time, the anchor
  used to detect a freshly-created bar). `latest` resolves ties (two tags on
  the same bar) deterministically via a fixed HH/LL/BUY/SELL push order.
- **`RangeResult`** (`top`/`bottom`/`pivotCount`) — the Daily MSB/OB zigzag-
  derived price range. `ZigzagPoint`/`ZigzagSegment` are the raw polyline
  primitives it's reconstructed from.
- **`LiquidationLevels`** — the 60/40 TP/SL model's output: `takeProfitPrice`,
  `stopLossPrice`, `stable` (was no widening needed), `widenApplied` (was the
  SL-side edge pushed out so entry sits at exactly 60% of the span), and the
  final `gridTop`/`gridBottom` actually used.
- **`RiskState`** — persisted risk-manager state: UTC-midnight day boundary,
  day P&L%, per-`symbol|category` open-position counts, cooldown deadline.
- **`BotHistoryEntry`** — one closed position's permanent record (see
  `bot-history.jsonl` in §6). Carries: id, timestamp, MT5 + TradingView
  symbol, category, ticket, direction, entry/exit price, volume, SL/TP at
  open, realized P&L, start/end time, the open/update/close signal tag+time
  triad, `stopReason` (`opposite_signal`/`take_profit`/`stop_loss`/
  `closed_by_user`/`closed_by_app`), and a free-text `detail`.
- **`AutoTradeRow`** — the Dashboard table's one-row-per-symbol live view:
  status (`running`/`waitingPending`/`waitingNoSignal`), direction, price,
  SL/TP, live floating P&L, ticket, open time, start/update tag+time,
  Auto/Last toggle state, the broker's exact waiting reason, last-checked
  time, Close A/B (the live "about to flip" preview), and desired/current
  trade volume with broker-reported min/step/max.
- **`EngineStatus`** — running/connected/`lastCycleAt`/message/
  `PowerHealthState`.
- **`PowerHealthState`** — `off` / `checking` / `ready` /
  `internetProblem` / `mt5Problem` / `tradingViewProblem` /
  `mt5NotInstalled` / `tradingViewNotInstalled`.
- **`Instrument`**/`AssetClass`/`SymbolResolver` — the curated "requested
  instruments" seed list (30 forex, 30 stocks, 40 crypto) and the
  broker-specific name-derivation rules used to suggest an MT5 symbol
  candidate for one.
- **`WatchedSymbol`** — one live MT5 Market Watch entry: symbol, bid/ask,
  digits, and broker-reported volume min/step/max. `isCrypto`/`isForex`/
  `isStock` are derived from this broker's own naming convention (`.lv`
  suffix = crypto, `.sd` suffix or two known exceptions = forex, neither =
  stock). `derivedTradingViewSymbol` is the reverse mapping used to suggest
  a TradingView symbol for a newly-added MT5 pair.
- **`MarketWatchSnapshot`**/`OpenPositionInfo` — one poll's worth of live
  Market Watch + open-position-side data, fetched together.
- **`AccountSnapshot`** — live balance/equity/margin/free-margin/currency,
  with a derived `marginLevel` (the standard `equity / margin * 100`).
- **`OrderType`** — the 7 order types MT5's MCP server supports; only
  `marketExecution` is wired up in the New Order screen today.
- **`ControlToggleState`** — Power/Auto/per-category on-off, as read by the
  GUI's polling providers.
- **`DecisionTechnique`** — see §9.1.

## 9. The trading techniques — full algorithmic specification

### 9.1 Dual decision-technique architecture

Two independent, interchangeable techniques exist, selectable from a picker
on the Dashboard (`DecisionTechnique.all`), persisted to
`logs/decision-technique.json` by the GUI, read fresh every engine cycle via
`EngineService._activeTechnique()` (default: Signal Flip, if the file is
missing/unreadable — the only technique that ever existed before this picker
did). The two techniques are implemented as **deliberately separate** methods
(`_checkOneSymbol` for Signal Flip, `_checkOneSymbolSupertrend` for
Supertrend Plus) rather than threaded through one generic function with
branches — kept apart on purpose for regression-safety, since Signal Flip's
logic is hard-won, carefully-tuned, live-verified code that must never be put
at risk by a change meant for the other technique. The two methods share only
the two blocks that are byte-identical between them: `_readConfirmedRange`
(the triple-read range confirmation) and `_reconcileStaleRestingOrderIfAny`
(stale pending-order reconciliation for a not-yet-filled pair).

```
DecisionTechnique.signalFlip:
  id: 'signal_flip_hh_ll_buy_sell'
  name: 'Signal Flip (HH/LL + BUY/SELL)'
  "Reacts immediately to the newest HH/LL/BUY/SELL tag: opens, ignores,
   or closes-and-reopens opposite."

DecisionTechnique.supertrendPlus:
  id: 'supertrend_plus_heikin_ashi'
  name: 'Supertrend Plus (Heikin Ashi)'
  "A Buy signal opens long and is the close for any running short; a Sell
   signal does the reverse. No separate confirmation signal."
```

### 9.2 Signal Flip — signal source

A Pine Script the user maintains, saved under the short name `worm_9_26`
(`scriptIdPart = USER;ac8febb9427a44578fd4052af6c17d65`), is the **sole**
signal source. It plots four tags on a bar: `New Higher High` (HH),
`New Lower Low` (LL), and its own dedicated `BUY`/`SELL` plotshape pair.
`readSwingOscillatorSignals` (`lib/data/tradingview/signals_reader.dart`)
reads all four, resolving each plot's column by its exact title (never by
Pine's internal plot-numbering order, which doesn't match source order).

A second script, `spy_9_26` (`scriptIdPart =
USER;f40c0a529f954b648be8f2b530d43d3f`), must also be attached to the chart
for the app to run at all (enforced the same way as worm_9_26 — see §14.3)
but **its data is never read for signal purposes** — this is a deliberate,
user-directed simplification: an earlier two-indicator HH/LL + RSI-zone
confirmation model was fully replaced (not layered) on 2026-09-29.

A tag's own implied direction: **HH and SELL both mean short/sell; LL and
BUY both mean long/buy.**

### 9.3 Supertrend Plus — signal source

A separate Pine Script saved as `Supertrend Plus`
(`scriptIdPart = USER;de83e70197704202ae530fd979d38aae`) supplies this
technique's own `Buy`/`Sell` plots (title-matched exactly, mixed case — never
the all-caps `BUY`/`SELL` worm_9_26 uses, and never that same script's
*other* `SuperTrend Buy`/`SuperTrend Sell` plots, which are continuous
true-every-bar trend flags, not discrete entry signals). Confirmed live that
these two plots fire as sparse, strictly alternating events — never two of
the same side in a row — so there is no HH/LL trend-anchor concept and no
cross-tag "Update" confirmation for this technique.

`worm_9_26` is also kept attached under this technique — not for its
HH/LL/BUY/SELL signals, but purely because its own zigzag/MSB-OB range data
still drives the 60/40 TP/SL model ("keep using old method," per the user).
`spy_9_26` is *not* required here; nothing in this technique reads it.

The chart is forced onto **Heikin Ashi candles** (`ChartStyle.heikinAshi =
8`, set directly via the chart's own property setter, not UI clicking) while
this technique is active, and reverted to regular candles
(`ChartStyle.candles = 1`) the moment the technique switches back to Signal
Flip.

### 9.4 Range — the Daily zigzag (both techniques)

Both techniques derive their TP/SL price range from the same source: the
Daily MSB/OB script's zigzag polyline (`dwg-lines`), via
`detectZigzagRange` (`lib/data/technique/zigzag_range.dart`). The algorithm:
collapse the raw line segments into distinct points, sort by x, reconstruct
proper ZigZag pivots (collapsing same-direction runs into their most extreme
point), take the last `range_swing_count` (config, default 20) of them,
range top = max pivot y, bottom = min pivot y. **No label/box fallback** — if
this returns null, the caller skips the whole cycle for that symbol rather
than trading on a different, less-trusted range source.

For the `ONE_HOUR` auto category, the signal is read on the 60-minute chart
(`signalResolution = '60'`) and the range is read on the Daily chart
(`rangeResolution = 'D'`).

### 9.5 The "1,000,000 sure" confirmation pipeline

Both the signal read and the range read go through the identical confirmation
ladder before anything is trusted enough to act on:

1. **Initial read.** If nothing is found yet ("no range yet" / "no signal
   yet"), skip this cycle entirely — except during an `immediate` sweep (see
   below), which gets up to 2 extra retries, 5 seconds apart, before giving
   up, so a pair that happens to have a transient miss on the one sweep that
   matters isn't silently demoted to the slow normal cadence.
2. **Triple-read confirmation.** Two further reads, 10 seconds apart (20s
   total), must agree EXACTLY with the first read — the raw tag (not just its
   side) for signals, the exact top/bottom for range. Any disagreement at any
   point ("FLICKER") aborts the whole cycle with a warning log; the bar is
   never marked as seen, so a genuinely fresh signal gets a clean re-check
   next cycle rather than being treated as acted-on.
3. **Survive one full extra candle** (Signal Flip always; Supertrend Plus
   only for a pair with **no currently-running position** — see the
   technique-specific carve-out below). A triple-confirmed signal is not
   acted on immediately — it's recorded as a *pending candidate*
   (`PendingSignalStore`/`pending-signals.json` for Signal Flip,
   `SupertrendPendingStore`/`supertrend-pending.json` for Supertrend Plus,
   deliberately separate stores — see §6). The symbol is skipped entirely
   (no chart access at all) until wall-clock reaches the end of the candle
   immediately *after* the candidate's own bar. At that point, if the
   freshly re-read latest tag/bar still matches the pending candidate exactly
   (nothing newer has appeared anywhere on the chart), the candle after it is
   provably empty and the decision engine acts on it immediately, using that
   cycle's own fresh range/signal reads. If something newer has appeared
   instead, the new tag/bar replaces the pending candidate and the wait
   restarts for it — recursively, so a signal only ever fires once it is the
   first one to survive a full candle completely unchallenged.

   **Supertrend Plus carve-out (2026-10-08, per the user):** for a pair that
   currently has a real running position, this step is skipped entirely —
   once the opposite signal clears step 2's triple-read confirmation, the
   engine closes and reopens immediately, with no extra-candle wait layered
   on top. "For currently running trades, I don't want the app to wait for
   Close A and Close B to confirm signal flipping — once the opposite signal
   appears, the app needs to take the action." This applies only to
   Supertrend Plus, and only to an already-open, running position — a
   brand-new first-ever entry (no position, no resting order yet) and an
   already-resting-but-not-yet-filled pending order both still go through
   the full extra-candle wait exactly as before. Signal Flip is completely
   unaffected by this carve-out. See §9.6a and §18 (invariant 8).

The pending-candidate flag is **only cleared on a genuine success** (a real
open, a real close+reopen, or a legitimate "ignore, already correct
direction"). A retriable snag below it — a duplicate order already resting,
a risk-gate block, a failed order placement — leaves it in place, so the
very next cycle retries the *same* already-confirmed signal immediately
instead of waiting out an entire fresh candle all over again.

### 9.6 Decision state machine

Once a signal is triple-confirmed and has survived the extra-candle wait (or
`immediate` bypasses both gates — see §9.8):

**Signal Flip** (`EngineService._checkOneSymbol`):
- No position running → open in the tag's own direction.
- Position running, tag agrees with its direction → ignore (but see §9.7 for
  the "Update" cross-tag confirmation recorded in this branch).
- Position running, tag disagrees → close AND immediately reopen in the
  tag's (opposite) direction, regardless of which specific tag type fired.
  Every tag type is treated identically once confirmed — an earlier
  "HH/LL close-only, wait for a genuinely new tag" exception was deliberately
  removed (2026-09-29): "signal appears > 1 million reading > action...no
  waiting for new signal."

**Supertrend Plus** (`EngineService._checkOneSymbolSupertrend`): identical
agree/disagree shape, but since Buy/Sell strictly alternate there is no
meaningful "Update" concept — the Dashboard's Update/Close A columns are
*always* blank for a Supertrend-driven pair, by design (the method simply
never writes them), not by suppression logic.

Neither technique has a `DecisionTechnique`-level concept of "wait for
cooldown after acting" — the triple-read-plus-survive-candle pipeline above
**is** the only gate (modulo the running-trade carve-out below); once a
signal clears it, the action is immediate.

### 9.6a Supertrend Plus — immediate flip for a running trade (no extra-candle wait)

(2026-10-08, per the user.) For Supertrend Plus **only**, and **only** when
`_findAppPosition` finds a real, currently-open position for the pair
(`existing != null` — i.e. a genuinely running trade, not a resting-but-
unfilled pending order and not a brand-new never-opened pair), step 3 of
§9.5's confirmation pipeline ("survive one full extra candle") is skipped
entirely — `skipExtraCandleWait = existing != null` short-circuits both the
early "still mid-wait, skip this cycle" gate and the later "newly confirmed,
must defer" gate. Step 2 (the triple-read confirmation, 1,000,000 sure) is
**never** skipped — only the additional candle-survival wait on top of it.
The instant an opposite Buy/Sell tag triple-confirms, the running position
closes and reopens in the new direction on that same cycle.

A fresh first-ever entry (no position, no resting order) and an
already-resting pending order that hasn't triggered yet both still go
through the full, unmodified extra-candle wait — this carve-out is
specifically about an already-open position reversing direction ("signal
flipping"), per the user's own wording, not about how quickly a new entry
is taken. Signal Flip's own survive-one-candle gate (`PendingSignalStore`)
is completely unaffected — this change touches only
`EngineService._checkOneSymbolSupertrend`'s own, separate
`SupertrendPendingStore` gate.

### 9.7 Signal Flip's retroactive audit (full forward replay)

Because Signal Flip's running direction can, in principle, drift from what a
full replay of the signal history since open would conclude (an HH/LL +
BUY/SELL chain the Dashboard never automatically re-walks on its own), every
currently-running Signal Flip ticket is periodically audited from its own
recorded Start signal forward, walking every tag strictly after it in
chronological order and applying the exact same agree-or-flip rule the
real-time flow uses at each one — so a position that has flipped direction
*twice* since opening correctly lands on the second flip, not the first. The
audit's own verdict must itself survive one full extra candle (the same
Close A/Close B rule) before being trusted. If the replay's final direction
disagrees with the position's real running direction, the position is closed
and immediately reopened in the replay's direction — re-confirmed against a
fresh chart read first, in case the historical data has shifted.

This audit runs once per ticket per gate-clearing event (`_auditedTickets`,
in-memory only — no persistence needed, since losing it on a restart just
means one extra re-audit, not a safety issue), re-armed on:
- Every GUI reopen (stale→fresh heartbeat transition).
- Once per UTC hour, 15 minutes before the next 1H candle closes (so the
  audit — and any recycle it decides on — finishes well before the new
  candle begins).

Supertrend Plus has **no equivalent audit block** — every single cycle
already re-reads the latest triple-confirmed Buy/Sell tag and compares it
directly against the running direction, which already *is* the reverse
check; there is nothing historical left to replay for this technique.

### 9.8 Reverse-check-on-technique-switch (and on every Power-on)

`_reverseCheckOnTechniqueSwitchIfNeeded` runs an immediate sweep (bypassing
the normal cooldown and the extra-candle wait, but keeping the full
triple-read confirmation) over **every** auto-managed pair — running,
waiting, or not-filled alike — on two occasions:
1. **Unconditionally, on the very first cycle after every Power-on** —
   "if I power on... app needs to check technique, not require re-choosing
   the dropdown." Power-on itself is the moment to trust the active
   technique fully.
2. Afterward, only when the active technique genuinely differs from what the
   engine last acted on (`logs/last-seen-technique.json`).

Each pair's check is passed `immediate: true`, which:
- Skips the per-symbol retry cooldown entirely.
- Skips the "survive one extra candle" wait entirely.
- Still requires the full triple-read confirmation (never relaxed).
- Gets up to 2 extra retries (5s apart) on an initial "no signal/range yet"
  miss, so a transient read failure on this one critical sweep doesn't
  silently demote that pair to the slow normal cadence (confirmed live: a
  pair that failed its first attempt in an earlier version of this sweep
  then sat un-retried until its next normal, much-later cycle).

### 9.9 First-ever-entry gate (Signal Flip only)

A pair that has never achieved a real open (`FirstOpenStore`) does not trust
whatever direction happens to be showing the very first time it's checked —
that signal could already be close to its own reversal. It instead waits for
a genuinely *opposite*, triple-confirmed direction to appear
(`NewPairWaitStore`) before its first-ever entry, going through the exact
same confirmation machinery every other signal already passes. Once a pair
has ever opened (even once), this gate is permanently skipped for all future
cycles. Supertrend Plus deliberately has **no equivalent gate** — a
brand-new pair under this technique takes whatever's currently confirmed
immediately ("if the app has a waiting trade... if it is currently buy, then
app needs to start buy").

### 9.10 Stop-loss / take-profit — the 60/40 range model

`computeLiquidationLevels` (`lib/data/technique/liquidation.dart`) — the
**original**, simpler model (not the later liquidation-price-shift variant,
which depends on a margin/leverage-dependent probe that doesn't exist in
this app's no-investment-sizing design):

- **LONG**: if entry is already past the top of the range, the top (TP side)
  widens further up so entry lands at exactly 60% of the (now-wider) span
  above the bottom (SL side), which stays fixed. Otherwise TP = top (fixed);
  if entry sits at less than 60% of the span above bottom, the bottom widens
  further down so entry sits at exactly 60% up from the new bottom, TP still
  fixed.
- **SHORT**: the mirror image (TP = bottom, SL = top, unless entry is past
  the bottom entirely, in which case the top widens).
- If the solved edge would land on the wrong side of entry, or at/below
  zero, the range is left unmodified (`stable: false, widenApplied: false`)
  rather than producing a nonsensical price.

A final sanity guard (`_computeTargetLevels`) refuses to compute levels at
all if the range is a *wildly* different order of magnitude than current
price (`rangeTop < entry * 0.01 || rangeBottom > entry * 100`) — this
specifically catches a corrupted/stale range read (confirmed live: a BTC
range of `0.99–1.70` against a real price near $84,500), not a legitimate
widen, which never produces a scale mismatch anywhere close to this large.

### 9.11 Closing a position — opposite-signal exit plus broker SL/TP

Every position closes one of three ways: (1) the engine's own
opposite-signal flip (`_closePosition`, `stopReason: 'opposite_signal'`);
(2) MT5 itself closing it by hitting the order's own SL or TP price,
detected via reconciliation (§15.4); (3) a human closing it directly in MT5,
also detected via reconciliation, as `closed_by_user` when neither SL nor TP
was hit; or (4) the Dashboard's per-pair terminate (power) icon
(`_processTerminateRequest`, `closed_by_user`, "via the Dashboard power
icon"). `closed_by_app` is reserved for a future app-initiated close reason
other than an opposite signal — no current call site produces it.

### 9.12 Quote-precision rounding

TP/SL prices are rounded to the symbol's own broker-reported `digits` via
`_roundToDigits`, applied *after* the 60/40 decision is made (not as a
gating precondition for it — confirmed not to reproduce a precision-ordering
bug tradingPionex once hit, since that bug required a probe-then-decide
structure this app's simpler model doesn't have).

## 10. Risk management (`RiskGate`)

`lib/data/risk/risk_gate.dart`, ported near-verbatim from tradingPionex:
`close` is always allowed; `open` is the only gated action.

- **Kill switch** — the `STOP` file's mere existence blocks every open.
- **Daily loss limit** (`risk.daily_loss_limit_pct`, default 5%) — once the
  day's cumulative P&L% hits this threshold, every open is blocked and a
  cooldown (`risk.cooldown_sec`, default 900s) begins.
- **Per-symbol-per-category position cap** (`risk.max_per_symbol`, default
  1) — keyed `"SYMBOL|CATEGORY_WIRE"`, **never** bare symbol (a bare-symbol
  key would let one category's open position silently block every other
  category on the same symbol — a real bug tradingPionex hit and fixed
  2026-09-19; ported here already-fixed, never regress back).
- **Day boundary** — UTC midnight, deterministic regardless of machine
  timezone.
- **`resetTo()`** — a full rebuild of the open-position-count map from a live
  MT5 snapshot, called every cycle from `_reconcileClosedPositions` (§15.4).
  Self-corrects *any* drift between the counter and reality within one
  cycle, regardless of cause (a manual MT5 close, a reconciliation gap, a
  future code path nobody anticipated) — confirmed live: before this call
  existed, a counter could get silently stuck too high forever with no way
  to self-correct, permanently blocking a symbol from ever opening again.

`maxPositions` and `maxTradeSizePct` exist in `RiskConfig` but are not
currently enforced anywhere in the engine (reserved config surface).

## 11. The Auto category system

`AutoCategory` is an enum with a single current member, `oneHour` — reduced
from an original five (3m/5m/15m/1H/1D) on 2026-09-22, per the user: "i dont
want app to check 3m, 5m, 15m, 1D... i want only 1H chart checkup." Kept as
an enum (rather than removed as a type entirely) since every call site
already generically loops over `allAutoCategories`/switches on
`AutoCategory` — shrinking the enum to one value cleanly removed the other
four everywhere without touching those call sites.

```
AutoCategory.oneHour:
  label: '1H'
  wireValue: 'ONE_HOUR'
  signalResolution: '60'   (minutes — the 60-minute chart)
  rangeResolution: 'D'     (the Daily chart — one level above signal)
  candlePeriod: 1 hour
```

Each category has its own `AutoManagedStore` (file:
`autoManagedBasesFileFor`), independent per-category pause file
(`AUTO_PAUSED_<WIRE>`), and participates in the global `AUTO_PAUSED` toggle.
Bootstrap: every symbol in `config.json` is auto-managed by default **only
on that category's true first-ever run** (its auto-managed-bases file not
existing yet) — fixed 2026-09-28 so removing a symbol from auto-management
doesn't silently revert on the next routine restart.

### 11.1 Per-pair Play/Pause (replaces the old per-row Auto toggle)

(2026-10-09, per the user.) The Dashboard's per-row Auto Switch — which
used to add/remove a base from `AutoManagedStore` entirely, unlisting the
row the moment it was turned off — is now a **Play/Pause button**
(`EngineControlRepository.setPaused` / `PausedPairStore`/
`logs/paused-pairs.json`), chosen specifically so the control "shows
exactly the action it is doing" rather than an ambiguous on/off switch.

**Pausing never removes a base from `AutoManagedStore` and never touches
whatever it's currently doing.** A paused pair is, in the user's own words,
"still an auto pair, but the engine will not take any action on it unless
it is unpaused" — a running trade stays running (no close, no flip, no
reconciliation beyond the global `_reconcileClosedPositions` sweep, which
still runs for every tracked ticket regardless of pause state, since that's
accounting for broker-side reality, not a trading decision); a waiting pair
stays waiting, exactly as-is. `EngineService._runCycle`'s main loop skips
any paused base with a plain `continue`, the identical mechanism already
used for a retired base — the **only** difference is that a paused base
stays listed and stays in `auto-managed-bases.json`, where a retired one is
filtered out of the table entirely (§16.11). The technique-switch/Power-on
reverse-check sweep (§9.8) also skips a paused base — pausing is an
absolute "no automatic action of any kind" rule, not just an exemption from
the normal per-cycle check.

**Un-pausing queues an immediate re-evaluation.** The instant the Play
button is pressed, `EngineControlRepository.setPaused` both clears the
paused flag and appends the base to a one-shot queue
(`UnpauseCheckRequestStore`/`logs/unpause-check-requests.json`), drained by
`EngineService._processAllPendingUnpauseChecks` — at the top of every
`_runCycle` (before the main per-symbol loop, so a later pass over the same
symbol in that same cycle is a cooldown-gated no-op rather than a
duplicate action) and again inside the loop for the same "don't wait out
the whole sweep" responsiveness `_processAllPendingTerminateRequests`
already has. This runs the pair through its own normal check method
(`_checkOneSymbol`/`_checkOneSymbolSupertrend`) with `immediate: true` —
the exact same bypass-the-extra-candle-wait machinery the technique-switch
sweep already uses (§9.8), still fully triple-read confirmed. Per the
user's own two-case spec, this single mechanism covers both without any
extra branching:
- **A paused pair that was running, un-paused**: "a reverse checkup will
  occur on this pair instantly and then action according to this
  checkup" — the normal running-position branch re-reads the latest signal
  and flips immediately if it disagrees with the running direction, or
  backfills/ignores if it agrees.
- **A paused pair that was waiting, un-paused**: "an instant checkup will
  be applied to match current filled calculations" — the normal
  no-position branch evaluates against the current chart right away
  instead of waiting out the usual 3-minute retry cooldown.

A base that gets re-paused before its queued request is ever processed is
left alone (the request is discarded, not acted on) — the user's later
action always wins.

**Unlisting a base from the table remains exclusively tied to retirement**
(Last tag + close), unchanged by this feature — per the user's own
clarification: "any auto pair will be unlisted only if it is tagged Last
and then either the signal flips and the app terminates it while Last is
on, or the user presses the power button for this pair while Last is on."
Pausing is orthogonal to Last/retirement entirely.

## 12. Trade sizing (volume) and the step-down retry ladder

No investment or margin sizing exists anywhere in this app (an explicit,
repeated user instruction) — every open uses the symbol's own MT5-reported
`volume_min` by default, or a user-chosen override via the Dashboard's
per-row +/- volume stepper (`TradeVolumeStore`/`trade-volume.json`):

- **`desired`** — the user's target for the *next* open of this pair. A
  currently-running trade's own size is never touched; this only takes
  effect once the pair closes and reopens (fresh or recycled).
- **`attempt`** — the volume actually being tried right now, when the
  broker rejected `desired` for a volume/margin-related reason (MT5
  retcode `10019` NO_MONEY or `10014` INVALID_VOLUME) and the engine had
  to step down. Null means "no step-down in progress."
- **`last_applied`** — the volume actually used by the most recently
  successfully-opened trade for this pair/category — the step-down floor.
  The engine never steps below this: "if old volume was 20 and 20 can't go,
  app will keep trying on 20, not applying any more decrease."

On a volume-related rejection, the engine steps down by one broker
`volume_step` (clamped to `[floor, desired]`) and retries on the next cycle.
Re-adding a previously-retired pair via "Start Auto Trade" resets this state
entirely (`EngineControlRepository.resetDesiredVolume`) so it starts clean
at the broker minimum, exactly like a never-traded pair.

## 13. MT5 API integration

`lib/data/mt5/mt5_client.dart` — a thin client for MT5's **native MCP
server** (build 6140+), confirmed live as a complete first-party trading
API (42 tools via `tools/list`, including full order placement/management —
no MQL5 Expert Advisor, file bridge, or WebTerminal automation needed).

### 13.1 Session protocol

`connect()` must be called once before any other method: runs `initialize`
(JSON-RPC `2.0`, `protocolVersion: '2025-06-18'`), captures the
`Mcp-Session-Id` response header, then sends the required
`notifications/initialized` follow-up. Every subsequent request carries that
session id as an `Mcp-Session-Id` header; skipping any step of this gets
`"MCP session is not initialized"` (JSON-RPC error -32600). Auth:
`Authorization: Bearer <key>` (from `.env`'s `MT5_MCP_API_KEY`). Every HTTP
call has a 15-second timeout (added 2026-10-05, since none existed before
and a hung MCP response could block the engine indefinitely).

### 13.2 Response handling

A `tools/call` result is `{isError, content: [{type: "text", text:
"a-json-string"}]}` — the real payload is a JSON *string* inside
`content[0].text`, needing a **second** `jsonDecode`. `callTool` does this
unwrapping and throws `Mt5ClientException` on `isError: true`. A permission
failure (e.g. trading tools disabled in MCP options) comes back as **plain
text**, not JSON — `callTool` falls back to surfacing that raw text rather
than crashing on a `FormatException`.

### 13.3 Public methods (all through `callTool`)

Read-only: `getOpenPositions`, `getHistoryPositions`, `getHistoryOrders`,
`getMarketWatchSymbol`, `getWatchedSymbols` (current Market Watch),
`getAllSymbols` (full tradable universe, ~2247 symbols on this broker,
`include_hidden: true`), `getAccountInfo`.

Trading (real actions): `sendMarketOrder` (`trade_send_market_order`),
`sendPendingOrder` (`trade_send_pending_order` — exposes `fillingType`,
needed for symbols whose spec requires IOC fills, where the market-order
tool has no filling-mode parameter at all and rejects with retcode `10030`
"Invalid fill"), `deleteOrder`, `modifyStopLossTakeProfit`, `closePosition`.

Visibility only (never places/modifies/cancels a trade):
`removeMarketWatchSymbol`.

### 13.4 Symbol naming (`SymbolResolver`)

TradingView and this broker's MT5 use different symbol names for the same
instrument, confirmed live against the full 2247-symbol catalog:
- **Crypto**: no USDT at all on MT5 — `BASE + 'USD.lv'` (e.g. TradingView
  `BTCUSDT` → MT5 `BTCUSD.lv`).
- **Forex**: `BASEQUOTE + '.sd'` (e.g. `EURUSD.sd`), with named exceptions
  (`USD/NZD` → `NZDUSD.sd`; `USD/INR`/`USD/KRW` → no suffix at all).
- **Stocks**: the broker's own *display name*, not the real ticker (e.g.
  `NVDA` → `"NVIDIA"`, `QCOM` → `"Qualcom"` — sic, one 'm') — too ambiguous
  to derive automatically, so this is an explicit, hand-verified map
  (`_stockNames`), not a fuzzy match.

`AppConfig.symbols` is always an explicit `{tradingview_symbol, mt5_symbol}`
pair list — never assumed to be the same name.

## 14. TradingView integration (CDP)

### 14.1 `CdpClient` (`lib/data/tradingview/cdp_client.dart`)

A raw Chrome DevTools Protocol client over a plain WebSocket — not a
browser-automation framework. `evaluate()` runs a JavaScript expression
string inside TradingView Desktop's own renderer and returns its value.
Every request has an 8-second timeout (`CoreConstants.cdpRequestTimeout`,
lowered from 60s on 2026-10-05 after a confirmed live 5-minute stall caused
by a single stuck request retried 5 times at the old timeout).
`connectToChart` retries with exponential backoff (max 3 attempts). A `dead`
flag is set once the socket is known unusable, so pending callers reject
immediately with a clear error instead of hanging forever on a broken
connection.

### 14.2 Chart state (`lib/data/tradingview/chart_state.dart`)

`setChartView` switches the chart's symbol/resolution via the widget API and
polls until the chart actually reports back the requested values — comparing
*base tickers* (stripped of exchange prefix/quote suffix), not exact
strings, since a bare request (`"ETHUSDT"`) resolves to a fully-qualified
report (`"BINANCE:ETHUSDT"`) that would otherwise never match and spuriously
time out after 45 seconds.

### 14.3 Enforcement (`lib/data/tradingview/enforce.dart`)

Keeps exactly the right two scripts attached and dialogs dismissed — the
hard-won result of real live debugging. Key gotchas documented directly in
the code:

- The legend row's clickable bounding box spans almost the full chart pane
  (mostly blank canvas) — a naive hover-and-click on it never arms anything.
  The fix: dispatch a *real* mouse event (`Input.dispatchMouseEvent`, not a
  synthetic `.click()` call — confirmed live that TradingView silently
  stopped responding to synthetic clicks on some controls entirely, with no
  error, while identical real dispatched events worked immediately) onto
  the indicator's NAME text specifically, wait for React to arm the trash
  button, re-query it, gate on computed `opacity > 0` and
  `pointer-events !== 'none'`, confirm via `elementFromPoint` that nothing
  covers it, then click for real.
- The trash button is **always present in the DOM** (TradingView fades it
  via opacity/pointer-events, never `display:none`) — `offsetParent` alone
  is a false positive for "interactable."
- **Never call `s.destroy()`** on a study dataSource — it corrupts
  `metaInfo` until a full TradingView restart.
- Indicators are matched by both exact `scriptIdPart` AND exact short
  save-name (never a generic keyword like "MSB" or "RSI") — a looser
  keyword match once let a completely different, unrelated indicator pair
  restored after an outage falsely "pass" presence verification for 5+
  minutes.

`enforceCustomScripts` (Signal Flip: worm_9_26 + spy_9_26) and
`enforceSupertrendPlus` (Supertrend Plus + worm_9_26, parallel set, never
merged with the first — same regression-safety reasoning as the two check
methods in §9) both: close everything, re-add the required scripts via "My
Scripts," wait for loading stubs to resolve (dismissing any promo/upgrade
dialog that can interrupt mid-add), then clean up any leftover legend stub
(free-account 2-indicator limit).

`areIndicatorsPresent`/`isSupertrendPresent` are cheap read-only presence
checks run every health-check cycle; the full close-and-re-add cycle only
runs when something is actually missing.

### 14.4 Signal reading — see §9 for the algorithm

`readSwingOscillatorSignals` (Signal Flip), `readSupertrendSignals`
(Supertrend Plus), `readBuySellSignals` (an earlier, now-superseded variant
still present but unused by the current decision flow), all in
`lib/data/tradingview/signals_reader.dart` — every reader evaluates a JS
expression that walks TradingView's internal chart model
(`dataSources()` → `_graphics._primitivesCollection` for line/box/label/
table readers; `_data._items` for plot-value readers) directly.

### 14.5 Launch (`lib/data/tradingview/launch.dart`)

`virtualDisplay = ':77'` — TradingView Desktop always launches on this
private, isolated Xvfb display on Linux when `remote_session: true`, never
the real session's display. Confirmed live 2026-09-03: opening TradingView
on the same display serving a remote-desktop session crashed Mutter/GNOME
Shell with SIGSEGV within seconds, 6/6 times, tearing down the **entire**
remote session (RDP, every open app). The engine only ever talks to
TradingView via the CDP port (`127.0.0.1:9222`), so nothing about
automation depends on which display it actually renders to.

`launchTradingView` kills any stale instance first (`pkill -9 -f
<binaryPath>`), launches with `--remote-debugging-port=<port>
--ozone-platform=x11 [--disable-gpu if isolated]`, and polls until the CDP
port responds. `isTradingViewInstalled` is checked **before** any launch
attempt (2026-10-07) — a missing install fails fast with a clear
`PowerHealthState.tradingViewNotInstalled` message instead of a confusing
process-spawn error or an endless retry loop.

### 14.6 Self-healing watchdog

`_forceRelaunchTradingViewIfStuck` (in `engine_service.dart`): after 3
consecutive stuck attempts (CDP port reachable but TradingView never
cooperates — either `waitForChartApiReady` failing, or indicator
enforcement failing with everything otherwise looking fine), force-kills
TradingView so the next connect starts it fresh. Covers both the "chart
never becomes ready" failure mode and (fixed 2026-10-07) a raw CDP
connection exception from `connectToChart` itself, which previously skipped
the watchdog's counter entirely and let a hung-but-port-open TradingView
retry forever against the same frozen process.

### 14.7 Single-flight guard on `_ensureCdpUp`

`_ensureCdpUpInFlight` (fixed 2026-10-06): the outer 30-second deadline
wrapping `_ensureCdpUp()` in the health check doesn't cancel the underlying
future when it fires — Dart's `.timeout()` only abandons the *wait*. Without
this guard, a slow-but-legitimately-still-working enforcement pass (e.g.
Supertrend Plus needing to search/add two scripts from a cold chart) could
get raced by the very next health-check tick starting a second, fully
independent `_ensureCdpUp()` call — both calling `removeAllSources` and
re-adding scripts on the *same* chart, each wiping out the other's work
(confirmed live as the user-observed flicker: "it loads supertrend first,
closing it then load worm/spy"). Every caller now awaits the same in-flight
future instead of starting an overlapping one.

## 15. Engine runtime behavior (`bin/engine.dart` / `engine_service.dart`)

### 15.1 Process lifecycle

`bin/engine.dart`'s `main()`: loads config, constructs `EngineService`,
checks the single-instance PID lock (verifying not just that *a* process
holds that PID, but that `/proc/<pid>/cmdline` — or, on Windows,
`tasklist`'s reported image name — actually names `tradingmt5_engine`, since
the OS recycling a stale PID number to an unrelated process has, confirmed
live, otherwise produced a permanent false-positive "already running"
refusal after an unclean shutdown), writes its own PID, registers
SIGINT (and SIGTERM, Linux only — unsupported on Windows) handlers that call
`engine.stop()` and arm a 10-second force-exit watchdog as a guaranteed
shutdown ceiling, then awaits `engine.run()`.

### 15.2 Main loop (`EngineService.run`)

Each iteration: check the `STOP` file (break if present); touch the
heartbeat; check the GUI heartbeat's freshness (stop outright if stale —
§4.3); on the stale→fresh transition, clear the retroactive-audit cache; on
the hourly pre-candle window (15 min before the next 1H candle, once per
UTC hour), also clear it; run the layered health check; if healthy
(`PowerHealthState.ready`), run a full cycle; delete the `CHECKNOW` file;
sleep `poll_interval_sec` (default 5s).

### 15.3 Layered health check (`_runHealthCheck`)

Runs every cycle for as long as the engine is alive (not just once at
startup), in strict dependency order — nothing past a failed step can
meaningfully work:

1. **Internet** — DNS lookup against `cloudflare.com`/`google.com`/`1.1.1.1`
   (any one succeeding counts; never a single point of failure).
2. **MT5** — check the MCP port; if down, check `isMt5Installed` first
   (fails fast with `mt5NotInstalled` if not, rather than attempting a
   doomed launch); otherwise auto-launch under Wine (Linux) or natively
   (Windows) and poll until the port responds; then run the full `connect()`
   session handshake.
3. **TradingView + indicators** — `_ensureCdpUp()`, wrapped in a hard 30-
   second outer deadline (`_tradingViewCheckDeadline`) as a guaranteed
   ceiling regardless of how the internals behave, guarded by the
   single-flight lock (§14.7).

A status log line is written only on an actual state **transition** (never
on every 5-second re-check, which would flood the log uselessly) — internet
lost/restored, MT5 down/up, TradingView down/up, or reaching/leaving fully
`ready`.

A mid-cycle recheck (`_maybeRunHealthCheck`, every 5s, at the natural
per-symbol boundary) closes the gap between the outer loop's once-per-sweep
health check and a multi-minute sweep taking far longer than 5 seconds to
complete — "the Power toggle must mandatorily re-verify connection every 5
seconds," per the user's explicit spec.

### 15.4 Reconciliation (`_reconcileClosedPositions`)

Runs once per cycle, across every tracked ticket, **before** the normal
per-category loop, gated for 90 seconds after engine startup
(`_reconcileGracePeriod` — confirmed live that MT5's own
`get_trading_open_positions` response was unreliable for longer than a
3-second re-read right after a restart, on two separate real occasions,
falsely declaring every tracked position "vanished"). Catches a position
that closed **without** the engine's own `_closePosition` ever running it
(MT5 hitting its own SL/TP, or a human closing it directly) — a confirmation
re-read (3 seconds later) must agree before anything is declared vanished.
Classifies the close reason by comparing the close price to the recorded
SL/TP within 0.1% tolerance (`take_profit`/`stop_loss`), falling back to
`closed_by_user` otherwise. Also rebuilds `RiskGate`'s entire open-position
count map from live reality every single cycle (`risk.resetTo`), so drift
from *any* cause self-corrects within one cycle rather than accumulating
forever.

### 15.5 Per-cycle sweep (`_runCycle`)

Skipped entirely while `AUTO_PAUSED` exists, or during the post-restart
grace period. Order: reconcile closed positions → drain all pending
terminate requests → read the active decision technique once (shared for
the whole sweep) → run the reverse-check-on-switch sweep if needed →
for each auto category (only `ONE_HOUR` exists), for each auto-managed,
non-retired base: drain terminate requests again (so a request doesn't wait
out the whole sweep), run the opportunistic mid-sweep health recheck, resolve
the symbol's live `config.json` mapping fresh (catching an unmapped symbol
as a per-symbol error rather than crashing the whole cycle), then dispatch
to `_checkOneSymbolSupertrend` or `_checkOneSymbol` depending on the active
technique.

### 15.6 `_openPosition` — the actual order placement

Computes target SL/TP/entry via `_computeTargetLevels` (§9.10), resolves the
volume via the step-down ladder (§12), sends a market order; on retcode
`10030` ("Invalid fill"), falls back to a pending stop order placed just past
current price (within the symbol's own minimum stop distance plus a small
safety margin) with an explicit `fillingType: 'ioc'`, which triggers
essentially immediately where the market-order tool categorically cannot for
that symbol class. On any other rejection, surfaces the broker's own exact
retcode/reason via `WaitingReasonStore`, and steps the volume down on a
volume-related retcode. On success, extracts the ticket defensively from
several possible response field names (unconfirmed exactly which MT5 uses —
see §21), registers it into `OpenPositionStore`/`BotCategoryStore`, bumps the
risk gate, and snapshots the triggering signal into `EntrySignalStore`. A
pending-fallback order is polled for up to 20 seconds to catch its real
resulting position ticket (distinct from the order ticket) before giving up
and leaving it for the next cycle's self-healing lookup (§15.7) to pick up.

### 15.7 Self-healing position discovery (`_findAppPosition`)

Any open position on the symbol carrying this app's own comment tag
(`'trading_mt5 ONE_HOUR'`) but not yet in `OpenPositionStore` is registered
right here, rather than depending solely on `_openPosition`'s own one-shot
post-placement poll ever having succeeded (confirmed live: a pending order
that finally triggered *after* that 20-second window gave up sat as a real
position forever invisible to tracking, letting the next cycle open a third,
conflicting position on top of it). A manually-opened position (no matching
comment, or a different category's tag) is left strictly untouched.

### 15.8 Stale resting-order reconciliation

`_reconcileStaleRestingOrderIfAny` (shared by both decision techniques):
for a "no position running" branch, compares what a *fresh* open would use
right now (direction + SL/TP from the live chart) against an already-resting
pending order from a prior attempt. If nothing has changed, logs and does
nothing (no duplicate placed). If direction or SL/TP has genuinely drifted,
cancels the stale order and lets the caller place a fresh one — "for waiting
pairs, if anything updated, app needs to update this pair whether it is
filled or not filled."

## 16. GUI reference — every screen and widget

### 16.1 App shell

`TradingMt5App` (`lib/main.dart`) wraps a `MaterialApp.router` with light/dark
Material 3 themes (`CoreTheme`), app-wide localizations, and `CoreRouter`'s
`GoRouter` config.

### 16.2 Routing (`lib/core/core_router.dart`)

`/splash` → a persistent `StatefulShellRoute.indexedStack` nav shell
(`ReuseNavShell`) with four independently-stateful tabs: `/dashboard`,
`/history`, `/logs`, `/settings`. The former Controls tab (bare Resume/
Pause/Check-now/Stop buttons) was deleted entirely 2026-09-30 — Resume/Pause
duplicated the Dashboard's own Power toggle, and Check-now/Stop had no
replacement.

### 16.3 Splash (`lib/screens/app/splash_screen.dart`)

Minimal loading screen shown only during initial route resolution.

### 16.4 Dashboard (`lib/screens/app/dashboard_screen.dart`)

The primary screen: engine status indicators (Engine/MT5 connected/
TradingView connected dots, last-cycle time, readiness message), the
`PowerToggle` + `ControlTogglesBar` (Power/Auto switches plus the 1H chip
with its live countdown to the next candle and current check-cycle mark),
the Decision Technique picker (bordered card, dropdown, "How it works"
button opening `TechniqueDetailsScreen`), `_AccountStatsColumn`
(Balance/Equity/Margin/Free Margin/Margin Level + floating P&L, with a color
rule on Balance: red when balance > equity, yellow when equal, green when
balance < equity), the `AutoTradesCard` table, and `WatchedSymbolsList`.

### 16.5 History (`lib/screens/app/history_screen.dart`)

Every closed position's full permanent record — id, direction, entry/exit
price, volume, SL/TP at open, realized P&L, open/update/close signal detail,
and exactly how it ended. A `_ReasonSummaryBar` groups every entry by
`stopReason` with its count and total P&L. A `_PnlDividerLine` marks the
user's own chosen "reset" timestamp (the Dashboard's P&L-since tracker),
splitting the list into "since reset" and "before."

### 16.6 Logs (`lib/screens/app/logs_screen.dart`)

Live, polled view of `engine.log` — the same unified timeline both the
engine's own automatic actions and every `[USER]`-prefixed manual Dashboard
action write to.

### 16.7 Settings (`lib/screens/app/settings_screen.dart`)

A plain single-column stack of four cards (`lib/widgets/settings_cards.dart`):
- **`AppearanceCard`** — System/Light/Dark theme toggle.
- **`ConnectionsCard`** — editable TradingView host/port, MT5 host/port + API
  key (masked, with a show/hide toggle), each with its own Test + Save.
- **`BackupRestoreCard`** — Export (password-encrypted `.tmt5` file to a
  chosen path) / Import (overwrite this machine's entire data directory from
  a backup, same password). Neither field has a default path any more
  (2026-10-10, per the user: "there should be no default path. so user
  need to choose the path (navigate) before file is created") — both start
  empty and their action button stays disabled until a path exists, via
  either typing one or the native "Browse" dialog next to each field
  (`lib/data/backup/file_dialog.dart` — `zenity` on Linux, PowerShell's
  `System.Windows.Forms` dialogs on Windows; deliberately not a Flutter
  file-picker plugin, which would hit the same FAT32-symlink wall as
  `package_info_plus`, §19.5). **No credentials, API keys, or connection
  settings are ever included in a backup** (2026-10-10, per the user:
  "credentials are not included in exported imported files. only user
  data... api, ports, credentials are not included") — `.env` is excluded
  entirely and `config.json`'s `mt5`/`cdp` blocks are stripped before
  export; import merges the backup's config.json over the local one,
  preserving this machine's own connection settings rather than deleting
  them (`BackupService._sanitizeConfigForExport`/`_mergeImportedConfig`).
  Every export also embeds a small `_meta.json` manifest (export timestamp
  + app version) inside the archive, independent of the filename (which is
  *also* stamped `tradingmt5-backup-<timestamp>-v<version>.tmt5` — per the
  user: "exported file should have time stamp and app version") — surviving
  a rename, and shown back to the user on the next successful import.
- **`AboutCard`** — app name + live version, read from `pubspec.yaml`
  (bundled as a Flutter asset, parsed at runtime — see §19's note on why).

### 16.8 Technique details (`lib/screens/app/technique_details_screen.dart`)

The "Read more" screen reached from the Dashboard's technique picker — a
hero header (icon badge + name + one-line description), an icon-led section
per topic (direction, range, confirmation timing, Power on/off behavior,
Auto on/off behavior, waiting/filled/not-filled states), one highlighted
callout box around the single rule that actually decides open/close, and a
`_StatusGrid` summarizing Waiting/Not-filled/Filled-Running as a real table.
Written in plain, non-technical language — "for a human deciding whether to
trust the app, not a code comment."

### 16.9 `PowerToggle` (`lib/widgets/power_toggle.dart`)

Red = off. Green (blinking only for the very first check right after
switch-on, steady once a result lands) = healthy. Yellow = no internet.
Blue = MT5 unreachable. Orange = TradingView/indicators unreachable. Red
(darker shade) = MT5 or TradingView genuinely not installed, which also
triggers a one-time `AlertDialog` naming the problem and telling the user to
install the missing app. Always starts off on every GUI (re)launch.

### 16.10 `ControlTogglesBar` (`lib/widgets/control_toggles_bar.dart`)

Power / Auto (global) / per-category toggles, plus the 1H chip's live
countdown (`_HourlyCandleLabel`, ticking every second off pure wall-clock
math, no coordination file needed since TradingView's own 1H bars always
align to exact UTC hour boundaries) and the Decision Technique picker
(redesigned 2026-10-07 into a bordered, filled card with a real "How it
works" button rather than an easy-to-miss bare dropdown).

### 16.11 `AutoTradesCard` (`lib/widgets/auto_trades_card.dart`)

One row per auto-managed symbol: symbol, trade id, status chip
(Running/Waiting-pending/Waiting), side, price, SL, TP, live P&L, volume
(with +/- stepper, showing a struck-through old value in yellow when a
desired-but-not-yet-applied override exists), open time, start/update
signal, Close A/Close B preview, Check mark (this candle cycle), a per-row
Play/Pause button, a Last toggle checkbox, and a terminate (power) icon. A
header strip shows running/pending/waiting counts, net P&L, a
"since <timestamp>" marker with a reset icon, and a cycling sort button
(symbol A-Z → Z-A → P&L positive → P&L negative → duration, wrapping).

**The Play/Pause button** (2026-10-09, per the user — replaces the former
Auto on/off `Switch`) shows a Pause icon while the pair is actively managed
(pressing it pauses in place, touching nothing about its current state) and
a Play icon while paused (pressing it resumes AND queues an instant
re-check). Chosen specifically because a toggle's on/off state didn't
convey which action pressing it would actually take — see §11.1 for the
full pause/resume semantics.

**Update/Close A/Close B columns are hidden entirely while Supertrend Plus
is the active technique** (`hideUpdateCloseColumns`, 2026-10-08, per the
user: "hide close a, close b columns in the auto table once supertrend
technique choosen" / "update column too not required ... once supertrend
choosen"). `DashboardScreen` passes this straight from
`decisionTechniqueProvider`; the widget itself has no technique awareness —
all three columns are Signal Flip-only concepts (cross-tag "Update"
confirmation, and the "survive one extra candle" Close A/B preview) that
were already always blank for a Supertrend-driven row even before this flag
existed (§9.3, §9.6), and are now doubly meaningless for a running
Supertrend trade specifically since that wait no longer applies to one at
all (§9.6a). Rather than show three columns that can never hold anything
under this technique, they're omitted from both the header and every row
together, keeping column count and cell order in exact lockstep.

### 16.12 `WatchedSymbolsList` (`lib/widgets/watched_symbols_list.dart`)

Grouped Forex/Crypto/Stocks rendering of MT5's **live** Market Watch —
deliberately the app's one and only pair-universe list (no separately
maintained config), per the user: add a symbol in MT5 and it appears here
within one poll; remove it and it disappears. Each pair is a tappable
selection card with a checkbox (disabled while that symbol has an open
position), a BUY/SELL tag + volume/SL/TP when running. Checking symbols
enables "Remove from watch list" (MT5 visibility only, blocked for a symbol
with an open position) and "Start Auto Trade," which opens
`StartAutoTradeDialog` for any checked symbol not yet in `config.json`
(crypto/forex get a safe auto-derived TradingView symbol suggestion to
confirm; stocks need a hand-typed ticker, since this broker's stock
`symbol` values are display names, not real tickers).

### 16.12a Add/Remove Pairs (`lib/widgets/add_pair_dialog.dart`)

2026-10-10, per the user: "user should have capability to add/remove pairs
in forex/crypto/stock. but be careful, adding a pair should be confirmed
from three apps (mt5: if this pair is listed, trading view: if this pair
matching the name or need mapping, tradingMT5: if this pair existed in the
list or not)." Unlike `StartAutoTradeDialog` (§16.12, which only ever
covers symbols already visible in MT5's own Market Watch), `AddPairDialog`
can add a pair MT5 doesn't even know about yet, from a header button next
to "Market Watch."

- **Asset-class picker** (Forex/Crypto/Stock) + a search box seeded from
  `requestedInstruments` (`lib/data/models/instrument.dart`), with a free-text
  fallback for anything not in that curated list. Picking a suggestion
  pre-fills a candidate MT5 symbol (`SymbolResolver.candidateFor`) and a
  candidate TradingView symbol (the same crypto `BASEUSD.lv ↔ BASEUSDT`
  convention `WatchedSymbol.derivedTradingViewSymbol` already uses in
  reverse) — both fields stay hand-editable before checking.
- **Three independent, all-must-pass checks**, run in parallel:
  1. **tradingMT5** — an instant local read of `config.json`'s own
     `symbols` mapping; fails if either candidate symbol is already mapped.
  2. **MT5** — `Mt5Client.findSymbolInFullCatalog` (`include_hidden: true`),
     called directly from the GUI. Safe to do without going through the
     engine, since MT5's MCP protocol supports multiple concurrent client
     connections (already proven by every other direct-from-GUI MT5 read in
     `app_providers.dart`) — unlike the TradingView check below.
  3. **TradingView** — routed through a new file-based request/response
     store, `SymbolResolveStore` (`lib/data/identity/symbol_resolve_store.dart`,
     `logs/symbol-resolve.json`): the GUI writes a `'pending'` entry, and
     `EngineService._processAllPendingSymbolResolveRequests` drains it each
     cycle by switching TradingView's chart (via the engine's own, sole CDP
     connection — see §14.7) to the candidate and recording what it finds.
     The dialog polls the store every 1.5s (30s timeout) since a second
     direct CDP connection from the GUI is exactly the single-attach
     violation §14.7 exists to prevent.
- **"Add"** (enabled only once all three checks pass) calls
  `Mt5Client.addMarketWatchSymbol` (visibility only — a no-op if already
  shown) then `EngineControlRepository.addSymbolMapping`, same as the
  existing Start Auto Trade path.
- **"Remove pair"** — a small trash icon on any already-mapped card in
  `WatchedSymbolsList` (§16.12), confirmed via a dialog, refused outright by
  `EngineControlRepository.removeSymbolMapping` if the symbol has an open
  position. Strips the mapping from `config.json`'s `symbols` array and
  every per-base identity store (`AutoManagedStore`, `PausedPairStore`,
  `RetiredStore`, `LastTagStore`, the per-category pending-signal stores) —
  the same cleanup a natural Last-tagged retirement already does, so a
  removed pair leaves nothing stale behind for a later re-add. Never touches
  MT5's own Market Watch visibility or Red-list membership (neither has any
  bearing on trading decisions — see the Red-list note in §16.12).

### 16.13 `ReuseNavShell`/`ReuseStatusLight`

Shared chrome: the persistent sidebar nav (Dashboard/History/Logs/Settings)
and a small colored status-dot widget reused across several live-indicator
spots.

### 16.14 Providers (`lib/data/providers/app_providers.dart`)

Every live GUI data source is a Riverpod `StreamProvider` polling a local
file or a direct (read-only, display-purpose) MT5 call every 2–5 seconds,
with a "keep last known-good on a transient disconnect" pattern rather than
flashing empty: `botHistoryProvider`, `autoManagedTvBasesProvider`,
`configProvider`, `decisionTechniqueProvider` (also logs every selection
unconditionally, at the moment of the click, into the unified engine.log —
closing a gap where the engine itself only logs a switch it happens to
observe on its next cycle, missing a fast round-trip), `engineStatusProvider`,
`watchedSymbolsProvider`, `autoTradesProvider` (the single richest
provider — one bulk MT5 round trip covering every symbol's position/order/
Market Watch state per poll), `accountInfoProvider`,
`controlToggleStateProvider`, `pnlSinceProvider`/`historyPnlSinceProvider`,
`themeModeProvider`.

### 16.15 `EngineControlRepository` (`lib/data/control/engine_control_repository.dart`)

The GUI's only write surface into shared state — never talks to MT5/
TradingView directly for a trading decision. Every mutating method logs a
`[USER]`-prefixed line into the same `engine.log` the engine itself writes
to, so manual and automatic actions share one timeline. See §4.2 for the
Power lifecycle it drives, and §9/§11/§12 for the per-pair Auto/Last/
terminate/volume/config methods it exposes.

## 17. Design system / tokens

- **Seed color**: `0xFF0E7490` (`CoreColors.seed`) — deliberately different
  from tradingPionex's own seed, a separate visual identity for a separate
  app. Full Material 3 `ColorScheme` derived via `ColorScheme.fromSeed`.
- **Trading-specific semantic colors** (`TradingColors`, a `ThemeExtension`,
  accessed via `context.tradingColors`): profit/loss/warning pairs (each
  with a container variant), plus one distinct accent hue per Market Watch
  asset class (forex blue, crypto amber, stock purple) — both light and dark
  variants defined explicitly.
- **Input fields**: filled, rounded (`8px` radius) boxes, never the bare
  Material underline default — applied app-wide via `InputDecorationTheme`.
- **Typography/spacing**: standard Material 3 defaults; no custom type scale
  defined yet.

## 18. Safety invariants — do not regress these

1. **No investment/margin/leverage sizing, anywhere.** Every open uses the
   broker's own reported minimum volume or an explicit user override —
   never a calculated position size.
2. **The app never touches a position it didn't open.** `OpenPositionStore`
   is the sole source of truth for "this is ours"; a manually-opened
   position on the same symbol is always left alone, and never blocks a new
   app position either.
3. **`close` is always allowed through `RiskGate`; only `open` is gated.**
   The kill switch, daily loss limit, and per-symbol-per-category cap all
   apply to opening only.
4. **Position-cap keying is always `"SYMBOL|CATEGORY"`, never bare symbol.**
5. **Every `RiskGate.openPosition` call has a matching `closePosition` call**
   on every actual close path, or the counters only ever grow.
   `RiskGate.resetTo()` additionally self-corrects any drift every cycle,
   regardless of cause.
6. **No range source other than the Daily MSB/OB zigzag; no label/box
   fallback.** If the zigzag yields nothing, skip the cycle — never
   substitute a different, less-trusted range source.
7. **Every signal AND every range must agree across three independent
   reads, 10 seconds apart, before being trusted** — "1,000,000 sure."
   Never act on a single read.
8. **A triple-confirmed signal must additionally survive one full extra
   candle unchanged before being acted on** (both techniques, separate
   pending stores), with one narrow, explicit exception: Supertrend Plus
   skips this extra-candle wait for a pair with a currently-running
   position (§9.6a) — the triple-read confirmation itself is never
   shortcut, only the additional wait on top of it, and only for that one
   technique's running-trade flip. The `immediate` reverse-check sweep
   (§9.8) is the only other place this wait is bypassed, also without ever
   relaxing the triple-read requirement.
9. **`STOP` file present → no new opens, under any technique, under any
   category, ever.**
10. **Never call `s.destroy()` on a TradingView study dataSource** — it
    corrupts `metaInfo` until a full TradingView restart.
11. **TradingView is always isolated on its own private Xvfb display on a
    remote/Linux session** (`remote_session: true` default) — never the
    real session's display, which has confirmed-live crashed the entire
    remote desktop session, not just the app.
12. **The engine process only exists, and only does real work, while the
    GUI's heartbeat is fresh.** No trading activity without the GUI open.
13. **Power always starts OFF on every fresh GUI launch** — never silently
    resumes trading on reopen.
14. **The two decision techniques' pending-signal stores
    (`pending-signals.json` / `supertrend-pending.json`) are always kept
    separate and always cleared of the OTHER technique's leftover entry**
    whenever either method touches a pair, both reactively (within the
    check methods) and proactively (the instant Auto is turned on for a
    pair in `EngineControlRepository.setAutoManaged`).
15. **Linux and Windows app versions are always kept in sync** — every fix
    gets `pubspec.yaml`'s version bumped, committed, and pushed (triggering
    the Windows CI build) *before* being considered fully deployed; never
    deploy to Linux alone and call a fix finished.

## 19. Windows support

Added 2026-10-07. The app ran only on Linux until this date; the Windows
port is built and packaged **entirely through GitHub Actions CI**
(`.github/workflows/windows-build.yml`, `windows-latest` runner) — it has
**never been exercised against a real Windows machine** as of this writing.
Treat every default path below as a starting point to verify, not a
guarantee.

### 19.1 What's genuinely different

- **Power toggle / process management**: Linux uses `systemctl --user
  start/stop` against a long-lived service unit; Windows has no systemd, so
  `EngineControlRepository` directly spawns `tradingmt5_engine.exe`
  (resolved as a sibling of `Platform.resolvedExecutable` — the CI build
  packages both binaries into the same release folder) via `Process.start`
  and stops it via `taskkill /F /PID`.
- **TradingView launch**: Linux isolates TradingView on the private Xvfb
  `virtualDisplay` to survive the GNOME-Shell-specific Mutter crash (§14.5)
  — a Linux-compositor-specific bug with no Windows equivalent reported, so
  Windows just launches TradingView visibly and directly, no isolation, no
  `--disable-gpu`, no `--ozone-platform=x11` (a Linux-only Chromium flag).
- **MT5 launch**: Linux runs MT5 under Wine (`WINEPREFIX`); Windows runs the
  native `terminal64.exe` directly, no wrapper.
- **`sigterm` is unsupported on Windows** — only `sigint` (Ctrl+C/Break) is
  watched there; the engine's hard force-exit watchdog is the real shutdown
  backstop on that platform.
- **PID-liveness check**: `tasklist /FI "PID eq <pid>" /FO CSV /NH` (image
  name match) replaces `/proc/<pid>/cmdline` reads.
- **Icon-matching env-var hacks** (`GIO_LAUNCHED_DESKTOP_FILE`, `.desktop`
  file preference) are Linux/GNOME-Shell-specific and simply don't exist on
  Windows — Windows resolves the taskbar icon from the exe's own identity
  automatically.

### 19.2 Default install paths (verify against a real install)

- MT5: `C:\Program Files\MetaTrader 5\terminal64.exe`
  (`Mt5LaunchConfig.defaultForWindows`).
- TradingView: `%LOCALAPPDATA%\Programs\tradingview\TradingView.exe`
  (`LaunchConfig.defaultForWindows`).

### 19.3 Build/release pipeline

Every push to `main` (and manual `workflow_dispatch`) on the GitHub Actions
`windows-latest` runner: `flutter create --platforms=windows .` generates
the `windows/` platform scaffold (this step **cannot** run on the Linux
dev machine — Flutter's own capability gate for writing those files is
keyed to the host platform), `flutter pub get`, `flutter build windows
--release` (GUI) + `dart compile exe bin\engine.dart` (engine) into the
same Release folder, then **two** packaging steps run side by side:

1. **`TradingMT5-Windows-<version>.zip`** — the raw Release folder,
   `Compress-Archive`'d as-is. Extract-and-run, no install step, no
   shortcuts, no uninstaller — for anyone who specifically wants a
   portable copy.
2. **`TradingMT5-Setup-<version>.exe`** — a real installer (2026-10-09, per
   the user: "i am not looking for exe direct run file. i want a setup
   exe file where it setup all and everything on windows"), compiled from
   `windows_installer/tradingmt5.iss` via Inno Setup (`ISCC.exe`,
   installed on the runner with `choco install innosetup` rather than
   assumed pre-installed, since that varies by runner image generation).
   `/DMyAppVersion=<version>` is passed on the ISCC command line — the
   `.iss` file itself never hardcodes a version, same "pubspec.yaml is the
   one source of truth" discipline as everywhere else in this pipeline
   (§18, invariant 15). The installer copies the whole Release folder
   (GUI bundle + the sibling engine exe — preserving the sibling
   relationship `EngineControlRepository._enginePath` depends on) to
   `%LOCALAPPDATA%\Programs\TradingMT5` (per-user, no admin/UAC prompt —
   same convention already used for MT5/TradingView's own Windows default
   paths, §19.2), creates Start Menu and optional Desktop shortcuts, and
   registers a normal "Apps & features" uninstaller entry.

Both artifacts are published as a **versioned GitHub Release** (tagged
`v<major.minor.patch>` from `pubspec.yaml`'s own version,
`softprops/action-gh-release@v2`, `make_latest: true`) — a permanent,
clearly-versioned download link, not a 30-day Actions artifact that doesn't
say which fixes it includes. The installer is the primary, recommended
download (WINDOWS.md); the zip is secondary.

**Bundled VC++ Redistributable** (2026-10-09, fixed after the app's actual
first real-machine install failed with "the code execution cannot proceed
because MSVCP140.dll/VCRUNTIME140_1.dll was not found"): Flutter's Windows
release build links against the Microsoft Visual C++ runtime but does not
bundle its DLLs — present on the GitHub Actions build machine (so the build
itself always succeeds and CI never catches this), but not guaranteed on an
end user's real Windows install at all. The CI workflow now downloads
Microsoft's official redistributable installer fresh every run
(`https://aka.ms/vs/17/release/vc_redist.x64.exe`, never committed to the
repo) into `windows_installer/` before compiling the `.iss` script, which
stages it to `{tmp}` and runs it silently (`/install /quiet /norestart`) as
the installer's first `[Run]` step — but only when a Pascal Script check
(`VCRedistNeedsInstall`, reading the same registry key Microsoft's own
installers use:
`HKLM64\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64\Installed`)
finds it's not already present, so a machine that already has it (common —
many apps ship it) isn't slowed down re-installing it. The redistributable
installer carries its own UAC manifest and will show exactly one elevation
prompt for that one step regardless of this installer's own
`PrivilegesRequired=lowest` — the rest of the install (copying TradingMT5
itself) stays fully per-user/unelevated either way.

**Real app icon, not Flutter's generic placeholder** (2026-10-10, per the
user: "app icon in exe should have app fave icon/logo"). `flutter create`
(the scaffold-generation step) writes a generic placeholder icon into
`windows/runner/resources/app_icon.ico` on every single run, since
`windows/` is regenerated fresh each time rather than committed. A new
workflow step, "Apply app icon," overwrites it with the real one — a
6-resolution `.ico` (16/32/48/64/128/256px) built once from
`assets/icons/icon_512.png` (the same source Linux's own
`linux/runner/my_application.cc` already uses for its window icon, via
`gtk_window_set_icon_from_file`) and committed at
`windows_installer/app_icon.ico` — *before* `flutter build windows
--release` runs, so `Runner.rc` compiles the real icon directly into
`trading_mt5.exe`. The installer's own `.exe` additionally sets
`SetupIconFile=app_icon.ico` in `tradingmt5.iss` for its own identity while
running; the Start Menu/Desktop shortcuts and the "Apps & features" entry
all resolve their icon from the target `trading_mt5.exe` automatically
once that exe itself carries the real icon, with no separate setting
needed for any of them.

### 19.4 Moving data Linux → Windows

Entirely via the existing, unmodified Backup & Restore feature (§16.7, §22):
export an encrypted `.tmt5` file on Linux, copy it to the Windows machine by
any means, import with the same password on Windows. Carries config,
connections, auto-managed pairs, trade history, and every identity store.

### 19.5 FAT32 constraint (this machine's dev environment, not Windows itself)

This project's working directory (`/media/fabughali/PARTITION11`) is
formatted `vfat` (FAT32), which does not support symlinks. Flutter's native-
plugin build step symlinks plugin source into
`linux/flutter/ephemeral/.plugin_symlinks/` for *any* package with real
native platform code — this breaks on this specific machine for such a
package (first hit by `package_info_plus`), with no such constraint on a
normal filesystem or on the Windows CI runner. Resolved by avoiding native
plugins entirely where a pure-Dart alternative exists (e.g. reading the app
version from `pubspec.yaml` bundled as a plain asset, rather than via
`package_info_plus`) — a decision specific to this dev machine's storage,
not a Windows limitation.

## 20. Development history and changelog

This section is intentionally selective — a running record of the real,
live-incident-driven decisions that shaped the app's current behavior,
newest first. Many smaller fixes are referenced inline throughout §9–§19;
this section captures the larger inflection points.

- **2026-10-10** — Add/Remove Pairs (§16.12a), per the user: "user should
  have capability to add/remove pairs in forex/crypto/stock. but be
  careful, adding a pair should be confirmed from three apps (mt5 ...
  trading view ... tradingMT5 ...)." New `AddPairDialog` runs all three
  checks (a local `config.json` read, a direct GUI-side
  `Mt5Client.findSymbolInFullCatalog` call, and a TradingView existence
  check routed through a brand-new file-based request/response store,
  `SymbolResolveStore` — the GUI can't check TradingView directly since the
  engine already owns the one real CDP connection, §14.7) before enabling
  "Add." A matching "Remove pair" trash icon on `WatchedSymbolsList`
  (blocked while a position is running) strips the mapping from
  `config.json` and every per-base identity store via a new
  `EngineControlRepository.removeSymbolMapping`. Followed the user's own
  reminder mid-request: "crypto is mapped btcusd in mt5 = btcusdt in
  trading view" — reused the existing `SymbolResolver`/
  `derivedTradingViewSymbol` naming conventions rather than inventing new
  ones.
- **2026-10-10** — Backup & Restore reworked on three fronts, all per the
  user in one request: (1) native "Browse" file-picker dialogs for both
  Export and Import, shelled out to `zenity`/PowerShell rather than a
  Flutter plugin (§16.7); (2) no default path for either field any more —
  the user must explicitly choose one before the action button enables;
  (3) backups now stamp a timestamp + app version into both the filename
  and an internal manifest, and never include credentials/ports at all
  (`.env` excluded entirely, `config.json`'s `mt5`/`cdp` stripped at
  export and never overwritten at import). Also: a real app icon
  (`windows_installer/app_icon.ico`) now gets compiled directly into
  `trading_mt5.exe` by CI, replacing Flutter's generic placeholder — Linux
  already had its own icon wired up from an earlier session, this closed
  the same gap for Windows (§19.3). **A genuine regression caught before
  shipping**: the first attempt put the new version-reading helper in
  `core_constants.dart`, which is shared by `cdp_client.dart` —
  engine-reachable code the plain `dart compile exe` build can't carry any
  `package:flutter/...` import through at all. Broke the engine's AOT
  build outright; fixed by splitting it into its own GUI-only file,
  `lib/core/app_version.dart` (see that file's own doc comment).
- **2026-10-09** — CRITICAL, Windows: the installer's actual first
  real-machine run (its first-ever test off the CI/GitHub environment)
  failed outright at launch with "the code execution cannot proceed
  because MSVCP140.dll/VCRUNTIME140_1.dll was not found" - the Microsoft
  Visual C++ runtime Flutter's Windows build links against but doesn't
  bundle, present on the build machine (so CI never caught it) but not
  guaranteed on a real end-user machine. Fixed by downloading Microsoft's
  own `vc_redist.x64.exe` fresh every CI run and having the installer
  silently run it first (skipped if already present, via a registry
  check) before the app ever tries to launch (§19.3).
- **2026-10-09** — Windows gets a real installer: `TradingMT5-Setup-
  <version>.exe` (Inno Setup, `windows_installer/tradingmt5.iss`, compiled
  by CI), published alongside the existing portable zip. Per-user install
  (no admin prompt), Start Menu + optional Desktop shortcuts, a normal
  uninstaller — replacing the old "download a zip, extract it yourself,
  run the bare exe in place" flow, per the user: "i am not looking for exe
  direct run file. i want a setup exe file where it setup all and
  everything on windows" (§19.3).
- **2026-10-09** — The Dashboard's per-row Auto `Switch` replaced with a
  Play/Pause button backed by a genuinely new state (`PausedPairStore`),
  not a repurposed old one: pausing a pair no longer removes it from
  `AutoManagedStore`/unlists it from the table — it stays fully listed,
  stays genuinely auto-managed, and the engine simply takes no action on it
  at all (no close, no open, no flip) until it's resumed, leaving a running
  trade running and a waiting pair waiting exactly as they were. Resuming
  queues a one-shot immediate re-evaluation (`UnpauseCheckRequestStore`)
  that doubles as both "a reverse checkup, act accordingly" for a running
  trade and "an instant checkup against current calculations" for a
  waiting one, reusing the exact same `immediate: true` machinery the
  technique-switch sweep already has. Unlisting a base remains exclusively
  tied to retirement (Last tag + close), unchanged (§11.1).
- **2026-10-08** — Supertrend Plus's "survive one full extra candle" wait
  removed for a currently-running trade's signal flip: once the opposite
  Buy/Sell tag triple-confirms, the position now closes and reopens on that
  same cycle instead of waiting for Close A/Close B to resolve on the
  following candle. Scoped narrowly, per the user's own wording ("this only
  applies on supertrend technique" / "for currently running trades"): the
  triple-read confirmation itself is untouched, Signal Flip is untouched,
  and a brand-new first-ever entry or a not-yet-filled resting order under
  Supertrend Plus still goes through the full wait exactly as before (see
  §9.6a). Dashboard follow-up, same day: the Auto-Managed Trades table's
  Update/Close A/Close B columns — always blank under Supertrend Plus even
  before this change, now doubly meaningless for a running trade — are
  hidden entirely (header and every row) while Supertrend Plus is the
  active technique (§16.11).
- **2026-10-08** — Fixed the Settings screen's version display being
  permanently stuck at `1.0.0+1` since the app's very first release: a
  hand-typed `AboutCard.appVersion` constant was meant to be kept in sync
  with `pubspec.yaml` manually on every bump, but was updated exactly once
  and silently drifted across every release since (1.1.0 through 1.2.2).
  Fixed by reading the real version from `pubspec.yaml` itself, bundled as a
  plain Flutter asset and parsed at runtime — no second copy left to drift.
  Also: the instant-fix for a pair re-added to Auto still briefly showing a
  stale HH/LL candidate was made proactive (cleared the moment Auto is
  turned on, in `EngineControlRepository`) rather than only reactive (on
  that pair's own next engine cycle, which could be minutes away).
- **2026-10-07** — Full Windows port: process management, TradingView/MT5
  launch paths, PID-liveness checks, and a GitHub Actions CI build/release
  pipeline, all `Platform.isWindows`-branched without touching any existing
  Linux behavior (see §19). Also: MT5-not-installed/TradingView-not-
  installed detection added as distinct `PowerHealthState`s with a one-time
  explanatory dialog, ahead of attempting any doomed launch. Hardcoded
  MT5/TradingView host+port *defaults* removed from `AppConfig` (the repo
  went public — no default should assume any specific user's setup);
  `config.json`'s real local file had to be proactively patched with its
  missing `cdp` section to avoid a crash from the new strict validation.
- **2026-10-06** — Second decision technique, Supertrend Plus (Heikin Ashi),
  added as a fully separate, parallel implementation rather than branches in
  the existing Signal Flip code (regression-safety). Includes its own
  enforcement pair, its own survive-one-candle pending store, Heikin Ashi
  candle-style forcing, and the Power-on / technique-switch immediate
  reverse-check sweep (§9.8). A centralization pass afterward extracted
  only the two byte-identical duplicated blocks between the two check
  methods (`_readConfirmedRange`, `_reconcileStaleRestingOrderIfAny`),
  verified via diff before extraction and via live log-output comparison
  after deploy — deliberately leaving the actual decision logic in each
  method completely untouched.
- **2026-10-05** — Rewrote the Power toggle's entire lifecycle model: Power
  now directly starts/stops the engine **process** (via systemd) rather than
  an internal pause flag an always-running process polls; the GUI's own
  heartbeat file gates whether the engine does any real work at all, so
  TradingView/MT5 never launch unless the GUI is open. Also: CDP/MT5 request
  timeouts dropped sharply (60s → 8s for CDP, unlimited → 15s for MT5) after
  confirming live stalls up to 5 minutes long from a single stuck request
  retried at the old timeouts.
- **2026-10-03** — Settings screen redesigned into per-section cards;
  AES-256-GCM encrypted Backup & Restore feature built; per-pair manual
  trade-volume override + step-down retry ladder added; the Dashboard's
  Market Watch list unified into one single live-mirrored list (forex/
  crypto/stock sections) rather than a separately-maintained config-only
  list.
- **2026-09-30** — "Survive one full extra candle" confirmation gate added
  on top of the existing triple-read rule (the Close A/Close B Dashboard
  columns), per-pair terminate (power) icon and Last toggle added to the
  Dashboard table, the standalone Controls screen deleted (superseded by
  the Dashboard's own Power toggle).
- **2026-09-29** — CRITICAL, real-money: full decision-system rewrite —
  `worm_9_26`'s own HH/LL/BUY/SELL tags became the **only** signal source
  for any trading decision; the prior two-indicator HH/LL + RSI-zone
  confirmation model was removed entirely, not layered. The "close only,
  wait for a new tag" exception for HH/LL was also removed — every
  confirmed tag type now acts identically.
- **2026-09-27** — CRITICAL, real-money: triple-read confirmation (two
  reads, 10s apart, from the original single/double read) adopted for both
  signal and range reads — "1,000,000 sure" — after a real, confirmed-live
  near-miss: a corrupted single range read of `0.99–1.70` on BTC at
  ~$84,500 would have produced a stop-loss with essentially no real
  protection.
- **2026-09-20** — The layered Power health check (internet → MT5 →
  TradingView/indicators, continuously re-run every cycle, not just once at
  switch-on) introduced, along with `PowerHealthState`'s full state space.
- **2026-09-19** — RiskGate's position-cap keying fixed to
  `"SYMBOL|CATEGORY"` (ported ahead of hitting the equivalent live bug
  tradingPionex had already found and fixed the same day).
- **2026-09-17** — The core trading model decided: no investment/margin
  sizing at all (every open at the broker's own minimum volume); the
  original (not liquidation-price-shift) 60/40 TP/SL model; symbol-naming
  mismatch between TradingView and this MT5 broker discovered and handled
  via an explicit mapping list.
- **2026-09-12** — MT5 integration path resolved: the terminal's native MCP
  server (build 6140+) confirmed as a complete first-party trading API (42
  tools) — no MQL5 Expert Advisor, file bridge, or WebTerminal automation
  needed. Session protocol, auth-key source, and the double-JSON response
  unwrapping all confirmed live.

## 21. Known gaps and deliberately deferred work

- **`trade_send_market_order`'s exact success-response ticket field name is
  still read defensively** (`_firstIntField` tries `ticket`,
  `position_ticket`, `position`, `order`, `deal` in order) rather than a
  single confirmed key — no call site has ever hit a genuine market-order
  success without the pending-order fallback path to confirm against.
  Simplify once confirmed against a real, directly-successful market order.
- **No "-50% baseline-SL reignites the opposite direction" feature** (a
  tradingPionex concept) — this app has no ratchet/trailing-SL system at
  all, so the "baseline vs. tightened SL" distinction that feature depends
  on isn't even meaningful here yet.
- **`PairCategoryStore` is ported but unused** — no GUI category-picker
  exists, since only one category (`ONE_HOUR`) currently exists at all.
- **`RiskConfig.maxPositions`/`maxTradeSizePct`** are parsed from config but
  not currently enforced anywhere in the engine.
- **The Windows port is untested against a real Windows machine** — every
  platform-specific path compiles and passes CI, but none has been run for
  real outside the GitHub Actions build environment (see §19).
- **No multi-account / multi-broker support** — one `config.json`, one MT5
  account, one data directory, by design.

## 22. Testing and verification approach

There is no automated trading-logic test suite (`flutter test` covers only
default template smoke tests) — every feature and fix in this app is
verified against **live, real-money behavior**, not simulated data, per the
project's own operating philosophy (§3). The standing verification
discipline, applied consistently throughout development:

- **`flutter analyze`** run clean (zero new issues beyond a small, stable
  set of pre-existing info-level lints) before every deploy.
- **Compile verification** (`dart compile exe` for the engine, `flutter
  build linux/windows --release` for the GUI) before every deploy.
- **Binary-sync verification** — checking actual deployed binary
  timestamps/checksums against source, not just assuming a build succeeded
  and was picked up.
- **Live log-output comparison** before/after a refactor, to prove
  behavioral equivalence when no visible output is expected to change (used
  explicitly for the duplication-extraction refactor in §20's 2026-10-06
  entry).
- **Independent live audits** — e.g. manually re-deriving the Supertrend/
  Signal Flip signal for every auto-managed pair and comparing against the
  engine's own live readings, to catch a real decision-logic bug rather
  than trusting the code's own self-report.
- **Screenshot-verified GUI changes** — every visual change is checked
  against the actual running app via X11 screenshot tooling before being
  considered done, not just assumed correct from reading the widget code.
- **Version/release discipline** (§18, invariant 15) — every fix bumps
  `pubspec.yaml`, is committed and pushed (triggering the Windows CI build),
  and that build is confirmed green, before the fix is deployed locally and
  considered finished.

## 23. Operational procedures

### 23.1 Standard deploy (Linux)

```
systemctl --user stop tradingmt5-engine.service
dart compile exe bin/engine.dart -o <engine binary path>
chmod +x <engine binary path>

flutter build linux --release
rsync -a --delete build/linux/x64/release/bundle/ <gui install dir>/
chmod +x <gui install dir>/trading_mt5
# kill the old GUI PID, relaunch under the real DISPLAY/XAUTHORITY
# verify exactly one GUI instance is running

systemctl --user start tradingmt5-engine.service
```

Always bump `pubspec.yaml`'s version, commit, and push **before** this local
deploy, so the pushed commit's Windows CI build and the locally-running
Linux binary are built from the exact same source (§18, invariant 15).

### 23.2 Backup & Restore

Settings → Backup & Restore → Export, choosing a strong password, writes an
AES-256-GCM encrypted `.tmt5` file (format: `MAGIC(4) | VERSION(1) |
SALT(16) | NONCE(12) | CIPHERTEXT(N) | MAC(16)`, PBKDF2-HMAC-SHA256 at
310,000 iterations) containing everything under the data directory except
process-specific/diagnostic files (heartbeat, PID, log files themselves,
and the backups folder itself, to avoid unbounded growth across repeated
exports). Import, same password, **overwrites every file this machine
currently has** with the backup's contents.

### 23.3 Recovering from a stuck TradingView/MT5

Normally self-healing (§14.6, §13 MT5 reconnect-on-failure) — no manual
intervention needed in the common case. If a genuine stuck state persists
past the watchdog's own escalation, the manual fallback is the same
mechanism the watchdog itself uses: force-kill the process
(`pkill -9 -f <binaryPath>` on Linux, `taskkill /F /IM <exe>` on Windows)
and let the next health-check cycle relaunch it fresh.

### 23.4 Rotating the MT5 MCP API key

Generate/change the key in MT5's **Tools → Options → MCP** page, then
**fully restart MT5** (the running MCP listener only reads the key at
terminal startup — a changed key does not hot-reload) before updating it in
the app's Settings screen or `.env` file.
