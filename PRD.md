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
  sl-ratchet-state.json            — SlRatchetStore (2026-10-13): highest SL
                                     ratchet rung already locked, keyed by
                                     MT5 position ticket (not base) so a
                                     recycled trade starts fresh - see §10.1.
  baseline-stop-strikes.json       — BaselineStopStrikeStore (2026-10-13):
                                     consecutive baseline-SL terminations per
                                     base (not ticket) - 2 in a row on the
                                     same direction blocks reopening until
                                     the signal flips - see §10.2.
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

- **Margin gate** (2026-10-13, per the user, confirmed to mean the exact
  same "Margin Level" figure the Dashboard's account stats block already
  shows — `equity / margin * 100`) — once this drops to **≤150%**:
  1. Every new `open` is blocked (`RiskGate.marginGateTripped`, checked in
     `gate()` right after the kill switch).
  2. Every resting (placed but not-yet-triggered) pending order this app
     itself placed gets actively **cancelled**
     (`EngineService._cancelAllRestingPendingOrders`), reverting that pair
     to plain "waiting" — because letting one of those trigger would only
     push margin level lower still, the exact thing this gate exists to
     prevent.
  3. **Already-open (triggered) positions are never touched** — this gate
     stops NEW exposure from being added, it never closes anything live.

  Margin level is refreshed every 30s (`EngineService._maybeRefreshMarginGate`,
  same self-throttled-at-every-per-symbol-boundary pattern as §10.1's own
  ratchet sweep) via a plain `get_trading_account_info` call — pure MT5,
  no TradingView/CDP involved. `null` (no margin currently in use at all)
  never trips the gate — nothing to protect against yet. The moment margin
  level climbs back above 150%, new opens resume automatically; nothing
  else needs to happen.

### 10.1 SL ratchet — tightening-only stop-loss ladder keyed off live P&L%

2026-10-13, per the user, while exploring porting tradingPionex's "Stop
Loss Lock" (SLL) concept here. **Deliberately not a port of tradingPionex's
own +100%/+200% SLL thresholds** — studied this account's own real trade
history first rather than assuming tradingPionex's numbers would transfer:
computed each of 123 real app-driven ("Expert" reason) closed trades' ACTUAL
peak floating P&L% from real MT5 H1 candle data (not just the final close
price), and found 94% never even reached +10% peak, while every single one
of the 7 that DID cross +10% went on to close at a LOSS — full swings of
20-37 percentage points (e.g. ALGOUSD.lv peaked +18.48%, closed -18.41%;
OPUSD.lv peaked +11.14%, closed -17.27%). tradingPionex's own +100% gate
would never have fired once against this account's real behavior — a
flat port would have shipped a feature that does nothing. The ladder below
uses half-size rungs (5% steps, not tradingPionex's 10%) scaled to the
range that actually matters here, confirmed with the user directly before
building.

**The ladder** (`lib/data/engine/sl_ratchet_ladder.dart`,
`highestSlRatchetThresholdCrossed`/`slRatioForThreshold` — pure functions,
no I/O):

| Floating P&L | SL locks to |
|---|---|
| 0% or below | the baseline SL set at ignition — see §10.2 |
| +5% | +2% |
| +10% | +5% |
| +15% | +10% |
| +20% | +15% |
| +25% | +20% |
| +30% and beyond | keeps going: threshold − 5 |

+5% is the one special case (locks to +2%, not 0%) — every rung from +10%
on is just threshold-5, mirroring tradingPionex's own "+10% locks to +5%,
not 0%" precedent for its first rung. **Only ever tightens, never
loosens** — once a rung is crossed and applied, it stays locked even if
P&L later retraces below it.

**Pure MT5, deliberately never touches TradingView/CDP at all** — unlike
every other per-cycle engine check, this only needs live P&L (already on
every open position from `get_trading_open_positions`) and a stop-loss
modification (`Mt5Client.modifyStopLossTakeProfit`, wrapping the real
`trade_modify_sl_tp` MCP tool — confirmed live against the actual server
schema before using it, though this feature is the first code path to ever
actually CALL it). Since it never contends for the single shared
TradingView chart connection, it doesn't need anything like
`_stopLossLockTimer`'s cooperative yield-when-busy dance tradingPionex's
own SLL needed — it's just `EngineService._applySlRatchet`, self-throttled
to 30s (`_maybeApplySlRatchet`) and called at the same per-symbol
boundaries as the mandatory health recheck (§15.3).

**Scope**: every open position whose MT5 symbol maps to a currently
auto-managed, non-retired, non-paused base — the exact same skip
conditions `_runCycle`'s own main loop already applies, so a paused pair's
running trade is left completely untouched ("paused means no action at
all" stays true here too). A manually-opened MT5 position on a symbol this
app doesn't manage is never touched.

**State**: `SlRatchetStore` (`lib/data/identity/sl_ratchet_store.dart`,
`logs/sl-ratchet-state.json`) — the highest rung already locked, keyed by
MT5 position ticket (not base/symbol), so a recycled/reopened trade on the
same pair starts the ladder fresh at zero. Pruned of any ticket no longer
open every sweep, so the file never grows unboundedly.

**Percentage basis**: identical formula to the Dashboard's P&L% column
(§16.11) — `profit / (volume * contractSize * priceOpen) * 100`, i.e.
percentage of the position's own notional value, not margin/leverage
(this app has no margin-sizing concept to divide into — see that
section's own doc comment).

### 10.2 Baseline stop-loss at ignition, and the two-strikes block

2026-10-13, per the user, filling in §10.1's own "0% or below" row (which
used to mean "unchanged" — whatever the 60/40 liquidation-avoidance model
computed, confirmed live this is typically MUCH wider than 10%, e.g. entry
1.7784/SL 2.6313 on a real SELL — a ~48% distance).

**The baseline SL** (`EngineService._baselineStopLoss`) is a flat
**-$5** stop-loss — originally the tighter of -10%/-$10 ("whichever
occurs first"), tightened the same way to -5%/-$5, then simplified
2026-10-14, per the user, to a pure dollar cap with no percent
comparison at all: "if pair is =0% or less... make it -5$ only sl" /
"so the app only triggers stop loss if P&L reaches -$5." The percent leg
was dropped because for a large position, 5% of notional could be far
more than $5 — the user confirmed the dollar cap should win for every
position size, not just small ones ("still stop at -$5 for large
positions too"). Needs the trade's own volume (a bigger position reaches
a flat $5 loss on a *smaller* price move, so this genuinely depends on
size) — computed only once the real volume for an attempt is final (the
step-down retry ladder, §12, can still shrink it), never inside
`_computeTargetLevels` itself. Replaces that function's own 60/40-model
`sl` output entirely for every fresh open and every stale-resting-order
refresh; TP is untouched.

**Applied retroactively to already-running positions too** ("apply above
also on currently running and waiting pairs"), folded into §10.1's own
sweep (same bulk position fetch, no extra MT5 calls): any open position
the ratchet has never touched (`SlRatchetStore.highestThreshold == null`)
gets tightened down to the baseline if its current SL is wider — verified
live against this account's real open positions before deploying, every
one computed a sensible tightening. Never loosens,
and never touches a position the ratchet has already locked (that SL is
already tighter by construction).

**Two-strikes block** (`BaselineStopStrikeStore`,
`lib/data/identity/baseline_stop_strike_store.dart`,
`logs/baseline-stop-strikes.json`) — per the user's own worked example:
XRP ignites SELL, hits the baseline SL, terminates; re-ignites SELL
(same signal), hits the baseline SL again, terminates — "app will not
open any further trades unless xrp becomes buy signal." Keyed by base
(tvSymbol), tracking a streak ACROSS trades, unlike `SlRatchetStore`'s
per-ticket state:

- A **qualifying "baseline stop"** is a `stop_loss`-reason close
  (`_reconcileClosedPositions`, §15.4) where the ratchet never tightened
  that ticket first (`SlRatchetStore.highestThreshold == null`) — a
  ratchet-protected close (a profit-lock hit) is a WIN, not a repeated
  failure, and never counts.
- Recorded in the SAME direction as the last one → streak increments.
  Recorded in the OPPOSITE direction → starts a fresh streak at 1 (the
  signal already flipped since the last failure).
- Any OTHER close — take-profit, a ratchet-protected SL, an opposite-
  signal close (`_closePosition`), a manual terminate — clears the streak
  outright, breaking whatever pattern was building.
- Once a direction hits **2** consecutive baseline stops,
  `EngineService._openPosition` (the single function all 5 open call
  sites funnel through) refuses to open that same direction again, log
  explaining why, until the signal genuinely flips — direction differing
  from whatever was blocked IS the flip, so there's no separate
  "clear on flip" logic needed; the block simply doesn't apply to the
  opposite direction at all.

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
(Running/Waiting-pending/Waiting), side, price, SL, TP, live P&L (value and
percentage — see below), SLL (the SL ratchet rung currently locked, if any
— see below), volume
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

**P&L column shows value and percentage** (2026-10-13, per the user, while
exploring whether tradingPionex's "Stop Loss Lock" percentage-based profit
concept could translate here: "p&l column will become 2.5 (132.78%)").
`AutoTradeRow.pnlPercent` = `profit / (volume * contractSize * priceOpen) *
100` — P&L as a percentage of the position's own **notional value**
(trade size), computed from fields this app already fetches every poll
(`WatchedSymbol.contractSize`, newly added, parses the broker's own
`contract_size` field — confirmed live 1.0 for every crypto/stock CFD on
this broker, but never hardcode that for forex, where a standard lot is
conventionally 100,000 units). Deliberately **not** a percentage of margin
or leverage — this app carries no investment/margin-sizing concept at all
(§10's own "no investment/margin sizing" principle) and neither MT5's
position data nor its account info exposes a leverage or per-position
margin field to divide into (confirmed live, checked before building
anything: grepped the whole codebase for any existing margin-per-position
usage — none — and inspected real MT5 MCP responses for both an open
position and account info — no margin/leverage field in either). Null
whenever the notional value can't be computed; shown in parentheses next
to the dollar figure, omitted entirely when null.

**SLL column** (2026-10-13, per the user: "can i have a column in auto
table to show current sll set... so user know what is current sll setup
without any guessing") — `AutoTradeRow.slRatchetThreshold`, read straight
from `SlRatchetStore`'s own file (`logs/sl-ratchet-state.json`) keyed by
this row's ticket, same cross-process plain-file-read pattern every other
identity store here already uses. Shows `+15%`-style for whatever rung is
currently locked, or `—` if the position hasn't crossed the first rung
(+5%) yet. The column header carries an (i) icon — tapping it opens a
dialog spelling out the exact ladder table (§10.1) so what each rung
actually means is never something to remember or guess at.

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

- **A single search field** (2026-10-10, reworked same day per further
  feedback: "why there are 3 search textfield??? there should be only
  one"), optionally backed by a suggestion dropdown seeded from
  `requestedInstruments` (`lib/data/models/instrument.dart`) — pick a
  suggestion or just type free text (e.g. "Gala", "EUR/USD", "NVDA",
  or either of MT5's/TradingView's own spellings for a crypto pair, see
  below) and press Search/Enter.
- **tradingMT5 checked FIRST, instantly, before any network call** — a
  local `config.json` read; a match shows a SnackBar ("Already in
  tradingMT5 — nothing to add") and stops right there, never touching
  MT5 or TradingView at all.
- **MT5** — `Mt5Client.findSymbolInFullCatalog`, called directly from the
  GUI (safe without going through the engine, since MT5's MCP protocol
  supports multiple concurrent client connections — unlike the
  TradingView check below). Tries the query as typed, and — since MT5
  quotes every crypto pair in plain USD, never USDT (`SymbolResolver`'s
  own doc comment) — ALSO tries it with a trailing "USDT" shortened to
  "USD" (2026-10-10, per the user: "if user type galausdt (crypto) then
  app need to search (galausd) in mt5 not (galausdt)"), so either
  spelling of a crypto pair finds the same real broker symbol.
- **Asset class is auto-detected from the real MT5 match**, not chosen
  up front (2026-10-10, per the user: "app should be smart enough to
  understand if this new pair is for forex or crypto or stock"): a `.lv`
  suffix means crypto, `.sd` means forex (this broker's own confirmed
  convention — see `SymbolResolver`'s doc comment), checked against the
  ACTUAL matched symbol, not the user's typed text. Only when neither
  suffix matches (ambiguous between a stock and this broker's two
  no-suffix forex exceptions, USDINR/USDKRW) does a manual Forex/Crypto/
  Stock picker — the "knob" the user asked for — appear at all.
- **TradingView** — routed through a file-based request/response store,
  `SymbolResolveStore` (`lib/data/identity/symbol_resolve_store.dart`,
  `logs/symbol-resolve.json`): the GUI writes a `'pending'` entry, and
  `EngineService._processAllPendingSymbolResolveRequests` drains it
  (re-checked before every symbol in the main loop, not just once per
  sweep — see §20's 2026-10-10 entry) by switching TradingView's chart
  (via the engine's own, sole CDP connection — see §14.7) to a candidate
  DERIVED from the real MT5 match the same way
  `WatchedSymbol.derivedTradingViewSymbol` already does in reverse (e.g.
  MT5's "GALAUSD.lv" → "GALAUSDT", per the user: "if user type galausd
  (crypto pair) then app need to search (galausdt) in trading view").
  If that guess doesn't resolve, a one-off override field appears so the
  user can correct it without starting over — the one case (stocks, whose
  MT5 catalog name is often a display name unrelated to the real ticker)
  this broker's own data can't auto-derive.
- **"Add"** (enabled only once MT5 and TradingView both pass) calls
  `Mt5Client.addMarketWatchSymbol`, **verified afterward via
  `getWatchedSymbols`** rather than trusted on its own report (2026-10-10,
  caught live TWICE with Gala: the add can succeed on MT5's own side while
  the client-side HTTP call still times out under combined engine+GUI
  polling load — up to 3 attempts, 3s apart, checking the real Market
  Watch state each time), then `EngineControlRepository.addSymbolMapping`.
  The dialog closes and the Dashboard shows a "Pair added" SnackBar.
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

### 19.2 Default install paths (confirmed 2026-10-11 against a real install)

- MT5: `C:\Program Files\MetaTrader 5\terminal64.exe`
  (`Mt5LaunchConfig.defaultForWindows`) — confirmed correct as originally
  guessed.
- TradingView: the original guess
  (`%LOCALAPPDATA%\Programs\tradingview\TradingView.exe`, a traditional
  per-user electron-builder install) is tried first, but the real machine
  this was tested on had TradingView installed via the **Microsoft Store**
  instead — a completely different MSIX/Appx mechanism
  (`C:\Program Files\WindowsApps\TradingView.Desktop_<version>_x64__<hash>\
  TradingView.exe`) no path guess could find, since that folder's
  version+hash suffix changes on every TradingView update. Resolved live
  instead via `Get-AppxPackage` (`LaunchConfig.defaultForWindows`,
  `_resolveWindowsAppxTradingViewPath` in `lib/data/tradingview/launch.dart`)
  — the same official API Windows itself uses to track installed Store
  apps, shelled out to via PowerShell. That folder's own ACL is locked down
  enough that even a plain `File.existsSync` can false-negative on a file
  the owning user genuinely has (confirmed live: `Get-ChildItem` on it
  returned nothing for a package `Get-AppxPackage` confirmed was theirs) —
  see `LaunchConfig.confirmedInstalled`'s own doc comment for why
  `isTradingViewInstalled` trusts the Appx resolution directly instead of
  re-checking the filesystem. **Still unverified**: whether a Store-
  installed TradingView actually accepts `--remote-debugging-port` at
  launch at all (MSIX apps can run inside a container that strips custom
  CLI flags) — if it doesn't, the practical fix is the non-Store direct
  download from tradingview.com/desktop instead, same installer family as
  Linux/Mac already use successfully.

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

- **2026-10-18** — Fixed the RAM light staying green after Power off,
  the last piece of the status-lights fix directly below, per the
  user, caught immediately after that fix landed: "why ram still green
  while power is off???" Root cause: `EngineStatus.ramOk` defaults
  `true` when the reading is null, by design (a transient read failure
  should never look alarming) - but that same null-safe default also
  made this ONE light stay green with no live engine behind it at all,
  inconsistent with Engine/MT5/TradingView, which all correctly gate on
  `s.running`/`s.connected`/health. Dashboard's RAM light now checks
  `s.running && s.ramOk`, so "off" looks the same everywhere on this
  card.

- **2026-10-18** — Fixed Dashboard status lights freezing green after
  Power off, per the user, checking one by one: "once power toggle is
  off, it means engine is off. but i want you to check one by one: why
  trading view still show connected??? why mt5 still showing
  connected??? why engine still showing green???" then "why ram still
  showing percentage... while those things are done by engine".
  Investigated each light individually before changing anything.
  Confirmed Power off genuinely does stop the whole engine process
  (`systemctl --user stop`/SIGTERM, per [EngineControlRepository.pause]'s
  own doc comment) - this was never "the engine secretly keeps running."
  The real bug: `logs/status.json` (the file every one of these four
  readings comes from - Engine/MT5 connected/TradingView connected/RAM)
  is only ever written WHILE the engine's loop is actually running,
  and nothing rewrites or deletes it on shutdown - the file just
  freezes at its last values (typically all green, whatever RAM % was
  last measured) and the GUI kept re-displaying that frozen snapshot
  forever, with no way to tell it apart from a live reading. Fixed in
  `EngineControlRepository.status()`: now checks `engineRunning` (the
  heartbeat file, touched every single cycle - already the engine's
  own trusted liveness signal, previously only used for its GUI-closed
  safety net) FIRST: if the process isn't actually alive, every light
  reports `EngineStatus.disconnected` (all off, RAM fields null so the
  stale percentage doesn't display either) instead of replaying
  whatever the last real reading happened to be. Second, deeper layer
  found while testing the above live: `heartbeat`/`engine.pid` were
  only ever deleted after `engine.run()` returned NATURALLY, but
  `bin/engine.dart`'s own force-exit watchdog (`exit(0)` after a 10s
  timeout) turned out to be the COMMON shutdown path in practice, not
  the rare one its own doc comment assumed - confirmed live, repeatedly,
  across this session's own deploy cycles ("Graceful shutdown did not
  finish within 10s — forcing exit" showed up almost every time). Since
  `exit(0)` terminates immediately, the cleanup code after
  `engine.run()` almost never actually ran, so the heartbeat file
  outlived the process it was supposed to represent - defeating the fix
  above. Moved the `pidFile`/`heartbeatFile` deletion into
  `onStopSignal` itself, run the instant SIGINT/SIGTERM is caught,
  before either exit path (clean or forced) - a stop is now reflected
  immediately either way. Verified live: stopped the engine via
  `systemctl --user stop`, confirmed the heartbeat file was gone and
  `is-active` showed `inactive`.

- **2026-10-18** — Favorite-pair star now also shown on a RUNNING row,
  per the user: "please make sure that fav pairs stay in fav even if
  they filled and then running. so once they are closed under any
  scenario, then will take priority" again. Verified first, before
  changing anything: `FavoritePairStore` has no `consume()` method at
  all (confirmed via grep - every `consume()` call in the engine
  belongs to `ignitedPairs`, none to `favoritePairs`) and `isFavorite`
  was already wired into all three `AutoTradeRow` construction sites in
  `app_providers.dart`, including the `running` one - so the underlying
  guarantee the user asked for was already true: filling, running, and
  closing (under ANY scenario - signal close, manual terminate, SL/TP)
  never touch the favorite flag, only an explicit unstar does, and the
  engine's per-cycle loop re-reads the persisted set fresh every cycle
  regardless of trade state, so a favorited pair resumes its priority
  the moment it's back to waiting. The one real gap was purely visual:
  the star icon only ever rendered on a waiting CARD, so once a pair
  filled and moved into the main running-trades DataTable, there was no
  on-screen confirmation the favorite survived. Added a small amber
  star next to the symbol in that table's own Symbol cell
  (`auto_trades_card.dart`) whenever `row.isFavorite` is true - same
  color/icon language as the waiting card's own star, just inline with
  the text instead of a separate tappable button (re-starring a running
  trade isn't meaningful; there's nothing left to prioritize until it
  closes).

- **2026-10-18** — Fixed Windows RAM reporting, per the user: "check why
  ram is not showing same thing in exe as linex in engine card".
  Investigated first: the Dashboard's RAM light was never showing a
  DIFFERENT number between platforms - it was reading
  `File('/proc/meminfo')`, which simply doesn't exist on Windows, so the
  read always threw, both `ramAvailableMb`/`ramTotalMb` stayed silently
  null, and the Windows build just showed the bare `'RAM'` label with no
  figures at all (confirmed this was true of every Windows install -
  the feature's own changelog entry, PRD §19, and §21's known gaps all
  independently confirm the Windows port has never been exercised on a
  real Windows machine, only compiled by CI). Fixed with a real Windows
  counterpart, `lib/data/platform/windows_memory.dart`
  (`readWindowsMemoryMb()`): calls `GlobalMemoryStatusEx` in
  `kernel32.dll` directly via `dart:ffi` (the `ffi` package, already a
  transitive dependency, promoted to a direct one) rather than shelling
  out to `wmic`/PowerShell - `_writeStatus` runs on nearly every engine
  action (18 call sites), so this needs to be as cheap as the Linux
  file read, not a subprocess spawn per call. `MEMORYSTATUSEX` is a
  stable, unchanged-since-Windows-2000 struct. `_readAvailableRamMb`/
  `_readTotalRamMb` in `engine_service.dart` now branch on
  `Platform.isWindows` - real figures on both platforms now, same null-
  on-failure contract either way (never treated as "low" per
  [EngineStatus.ramOk]'s own short-circuit). Unverified on a real
  Windows machine (same caveat as the rest of the Windows port) - CI
  compile-checks it but can't exercise the actual syscall.

- **2026-10-18** — Favorite pairs: a star icon on waiting/unfilled cards,
  per the user: "add a star icon for those waiting/unfilled cards where
  once this icon is clicked, app will give those pairs priority in
  filling once margin is okay. now: app choosing to fill pairs randomly
  ... but if there is a toll where user can make the app list favorite
  pairs to start with, it would be better." Investigated first: the
  per-cycle loop (`EngineService`'s main sweep) actually iterates
  `AutoManagedStore.loadAutoManagedBases()` in a fixed alphabetical
  order every cycle - not literally random, just arbitrary from the
  user's own perspective, with no way for them to influence it. Asked
  the user to confirm the key risk question before building: should a
  starred pair bypass the margin gate the way the existing one-shot
  Ignite feature does, or only get priority ORDERING once margin
  genuinely clears on its own - confirmed: order-only, margin gate
  behavior stays completely untouched. New `FavoritePairStore`
  (`lib/data/identity/favorite_pair_store.dart`), mirroring
  `IgnitedPairStore`'s shape but as a STANDING toggle, not one-shot -
  starring stays on until unstarred, there's no `consume()`. The
  per-cycle loop now partitions each category's bases into
  `[...favorites, ...everyone else]` (both groups keeping their own
  alphabetical order) right before iterating, so a starred pair is
  always checked - and therefore gets first crack at opening - before
  non-starred ones once `RiskGate.gate()` naturally allows a new open.
  `AutoTradeRow.isFavorite` (new, mirrors `isIgnited`) flows through
  `app_providers.dart`'s `autoTradesProvider` the same way the ignited
  set already does; the star itself sits next to the symbol title in
  `_buildWaitingCard`'s upper section (not the action-icon row below,
  since it's a standing identity preference, not a transient per-cycle
  action) - amber filled star when favorited, outline otherwise, same
  visual language as the thunder icon.

- **2026-10-18** — Backtester busy-state and stale-result fixes, per the
  user: "once user click on execute, loading indicator should be still
  loading until report viewed in app. one user click on back button,
  everything reset" and "there is an error, once user navigates to
  summary screen, there is a table visible there before entering any
  date... check why". Root cause of the stale table: `backtest-
  result.json` is a PERSISTED file (`BacktestResultStore`), so a
  previous run's report survived navigating away from and back to the
  Technique Summary screen (and even a full app restart) and would
  flash in the instant `BacktesterCard` mounted, before the user had
  touched anything - nothing ever cleared it on screen entry, only on
  editing a field. Fixed: `initState()` now clears it immediately on
  mount, and `_markSubmitted()` (called the instant Execute is pressed,
  for every resolution path) also clears it right away, so no old
  report is ever visible underneath the new run's loading state. The
  "loading indicator should still be loading" complaint was a real gap
  too: the local "waiting for engine to pick this up" flag used an 8-
  second grace timer as an unconditional cutoff - on a repeat run within
  the same session, the stream's `status` field was still showing the
  PREVIOUS run's `'done'` state (not yet overwritten) for however long
  the engine took to reach its next drain point, so if that exceeded 8s
  the busy flag dropped and the Execute button/status row would flash
  back to idle before the engine had even started. The engine's own
  `BacktestResultStore.recordDone()` writes status and result together
  in one atomic file write (confirmed: no possible gap between "not
  running anymore" and "result available"), so the real fix was just to
  stop treating 8s as a routine cutoff - the grace timer is now 3
  minutes, a last-resort safety valve only for a request that silently
  never got picked up at all, not something expected to fire in normal
  operation.

- **2026-10-18** — Backtester Pair/Volume input UX, per the user: "in
  pair .. once user enter any text, app should give suggestions list
  'if existed'. volum should match the value in mt5.. user only need to
  press on +/- .. where default value is minimum mt5 value". Pair field
  is now a `RawAutocomplete<SymbolMapping>` wrapping the same
  `TextEditingController` - as the user types, a dropdown suggests
  matching pairs already in `config.json` (contains-match, case
  insensitive); picking one resolves it instantly via the existing
  "already configured" fast path (no MT5/TradingView search) and
  immediately fetches its real volume bounds. An unlisted pair typed in
  full still runs the normal search once Execute is pressed - it just
  never appears in the dropdown, matching the user's own "if existed"
  qualifier. Volume is no longer free-typed: it's a +/- stepper
  (identical visual pattern to the live Auto Table's own stepper -
  `_VolumeStepper` in `backtester_card.dart`), reading real
  `volume_min`/`volume_step`/`volume_max` straight off the symbol's own
  MT5 Market Watch record (the SAME `get_marketwatch_symbols` fields
  `EngineService._runBacktest` already normalizes against) and
  defaulting to the real minimum - never a guessed number. For an
  unlisted pair, the bounds come from the same `findSymbolInFullCatalog`
  record the MT5-catalog search already fetches (no second round trip);
  for a listed pair, a light `getMarketWatchSymbol` call on selection.
  The stepper shows "—" and stays disabled until a pair is actually
  resolved, rather than defaulting to any value that might not be real
  for that symbol.

- **2026-10-18** — Backtester: Volume restored as its own independent
  4th input ("inputs are investment, pair, days, volum"), superseding
  the Investment-drives-Volume entry directly below from earlier the
  same day - that design (investment leveraged into a computed volume)
  produced mathematically-correct but absurdly large lot sizes (2794
  lots for a $100 investment on LTC) that didn't match what the user
  actually wanted, confirmed directly: "keep same calculations exactly
  as mt5... dont touch this" was about keeping THAT formula's own math
  honest once something WAS chosen, not a mandate to keep deriving
  volume from investment. Final design: Volume alone drives $ P&L
  (`priceDiff * contractSize * volume - $0.1 commission`), normalized to
  the symbol's real `volume_step`/`volume_min` from MT5 before use (so
  the backtest never simulates a lot size MT5 itself wouldn't actually
  let through); Investment stays purely the %-return basis, independent
  of Volume - matching the user's own description ("more volume == more
  p&l... more investment == more capital and multiplier") and real MT5
  itself, which has no "dollar investment" concept at all, only the lot
  size you choose. Also added, per the same message: `first_entry_price`
  (the window's first trade's own entry) and `last_close_price` (the
  exit of the LAST trade that's genuinely closed, explicitly excluding
  the one still-open "now" trade) as new top-level summary fields on
  `BacktestResult`, shown next to the existing per-row Entry/Exit
  columns - verified live against real LTC data.

- **2026-10-18** — Backtester redesign: Investment now DRIVES Volume,
  per the user ("there should not be a pre-set values in the fields...
  there should not be a pre-set table of calculations... user changes
  the investment value but calculations stay fixed... read calculations
  from mt5... more investment == more capital and multiplier"). Research
  first, per the user's explicit instruction: confirmed the live
  Auto-Trades table already treats "Investment" as a DERIVED notional
  value (`volume * contractSize * price`), never a free input - the
  backtester's old Investment field was inconsistent with that, used
  only to divide into a percentage, completely disconnected from the
  separate Volume field that actually drove the dollar P&L. Fixed:
  removed the standalone Volume input entirely; each trade's own real
  lot size is now computed as `investment * 2000 (this broker's real
  leverage) / (contractSize * entryPrice)`, rounded to the symbol's real
  `volume_step` and floored at its real `volume_min` - the exact same
  clamp `_openPosition` enforces for a live trade - verified live against
  real MT5 data (LTC, $100 investment -> ~2795 lots, profit_usd matching
  the formula exactly). Per the user's own explicit confirmation this
  produces very large lot sizes for a small investment, deliberately left
  as-is ("keep same calculations exactly as mt5... user need to test if
  this inputs gains or loss") - the point is testing an investment
  amount's real gain/loss, not a realistic position size. Also: every
  input field now starts genuinely blank (no pre-filled 100/30/0.01), and
  editing Investment/Days/Pair after a run immediately clears the
  displayed result so a stale table from before the edit can never sit on
  screen looking like it reflects the current field values.

- **2026-10-18** — Waiting-card fixes, per the user's two immediate
  follow-ups to the two-section redesign: (1) the fixed outer `height`
  never accounted for the `Container`'s own top+bottom padding, so the
  two inner sections didn't actually fit and the bottom row overlapped
  the card's own border - height now correctly adds the padding back in.
  (2) Action row reordered to Pause, Ignite, Last, Power (was Pause,
  Ignite, Power, Last), and the gap between the volume row and the
  action row tightened from a stretched `spaceBetween` to an explicit
  4px gap.

- **2026-10-18** — CRITICAL, backtester data-integrity bug: two
  back-to-back backtests for the exact same symbol/period returned a
  DIFFERENT `entry_price` for the exact same historical trade (69.39 vs
  71.56, ~3% apart) - impossible for fixed historical data, discovered
  while independently verifying the commission fix above by comparing
  two runs at different volumes. Root cause: `_runBacktest` reads the
  main series' historical bars (`barTimes`/`barClose`, used for every
  `entryPrice`/`exitPrice`) immediately after switching the chart to
  Heikin Ashi style - but that switch only confirms the STYLE FLAG
  changed, not that the HA-derived OHLC values across the whole loaded
  history have finished recomputing from the underlying regular candles,
  which isn't instant for a multi-week history. Same class of bug as the
  already-fixed signal-settle race (2026-10-17/18 entries below), just
  hitting the price series instead of the indicator's own plot data, and
  not previously caught because the bars read happens BEFORE the
  signal-settle retry loop, so that fix never covered it. Same mechanism
  applied here: re-read the full bar list until two consecutive reads
  agree before trusting it. Verified fixed by rerunning the exact same
  volume=1/volume=2 comparison - all 6 closed trades now show byte-
  identical entry/exit prices and correctly-scaled P&L across repeated
  runs; the one remaining difference was the still-running trade's exit
  price, which legitimately uses the live price at each run's own
  moment.

- **2026-10-18** — Waiting-card redesign, per the user's own iterative
  follow-ups while reviewing the card split above: split into two
  explicit sections - an upper section (pair title + the FULL status
  text, no more ellipsis truncation, wrapped/scrollable instead) taller
  than a fixed-size bottom section (the volume stepper, then
  Pause/Ignite/Power/Last in one row - Last added per "include last
  toggle also ... with power, pause, ignite", the table's own Switch
  scaled down to fit). Purely a layout change - every control still
  calls the exact same callback it always did.

- **2026-10-18** — Waiting-card polish, per the user's two immediate
  follow-ups to the card split above: (1) "width and height of all cards
  should be identical" - a long broker rejection reason used to push one
  card taller than its neighbors; the status label is now capped to 2
  lines with ellipsis overflow inside a fixed-height slot instead of
  growing the card, and the volume number sits in a fixed-width slot so
  it never wraps mid-number either. (2) "make a spacing between each row
  and next row in the card so user not pressing any icon by mistake ...
  make them little larger" - the three action icons (Auto/Ignite/Power)
  grew from a 28x28 compact tap target to 36x36 with real gaps between
  them, replacing `spaceAround`'s edge-to-edge packing that made an
  accidental tap on the wrong control easy.

- **2026-10-18** — Auto-Managed Trades table split into two presentations,
  per the user: "make the waiting trades (unfilled) in a card not in
  table. so auto table contains filled trades and running trades. and
  below that table wrapped cards of waiting unfilled trades sorted by
  name a-z." The main `DataTable` now holds only real running (filled)
  positions; every waiting/unfilled pair (no fill yet, pending order or
  no signal) gets its own compact card in a `Wrap` below, always sorted
  alphabetically regardless of the table's own cycling sort mode. Each
  card shows status, the next-open volume stepper, Auto play/pause,
  Ignite, and Power/terminate - the same callbacks/row data the table
  already used, just a lighter presentation for a pair with nothing else
  meaningful to show yet (no SL/TP/P&L/leverage/etc.).

- **2026-10-18** — Backtester commission fix, per the user ("broker Equiti
  is deducting $0.1 per each new trade, mock up the calculations in MT5").
  Verified directly against this broker's real trade history via
  `get_trading_history_positions` (queried over the live MT5 MCP bridge):
  the broker's own `profit` field is GROSS price-movement only
  (`(close-open) * volume * contract_size`, confirmed by recomputing it
  by hand against several real app-placed trades) - the real `-$0.1`
  commission comes back as a SEPARATE field, never folded into `profit`.
  The backtester's simulated P&L (`_runBacktest`) only ever computed the
  gross figure, so it overstated every trade's net result by exactly the
  commission - now subtracts $0.1 per trade (charged once per position
  opened, matching the real data), same as MT5 actually nets.

- **2026-10-18** — Three more real bugs from the same family, found via a
  real user report (ATOM ticket showing Update 2026-09-07, over a month
  BEFORE its own Open 2026-10-17 — impossible by definition) and confirmed
  NOT self-correcting despite the retroactive audit cache being cleared
  33 times that day alone: (1) **Monotonicity guard**: neither
  `Worm10EntrySignalStore.recordUpdate` nor the legacy
  `EntrySignalStore.recordUpdate` ever checked that an Update's time came
  after its own position's Open - now both reject (no-op) any write where
  `time < barTime`, the single choke point every call site funnels
  through. (2) **Live self-healing, not just the backtester**: the same
  "chart reports the new symbol, but the indicator script's own computed
  data hasn't caught up yet" race already fixed in `_runBacktest`
  (2026-10-17) was NOT fixed in the live real-time sweep - confirmed live,
  3 different real pairs (AAVE/ATOM/UNI) all independently backfilled an
  impossible shared Update from a stale cross-symbol read.
  `_checkOneSymbolWorm10` now runs the identical settle-and-recheck retry
  (gated on `SetChartViewResult.switched` so it only costs time on a
  cycle that actually switched symbols) before trusting any signal read.
  (3) **Crash regression from the 2026-10-17 event-kind cleanup**: removing
  `buyClose1`/`sellClose1` from `Worm10EventKind` made
  `worm10EventKindFromWire` correctly throw on those now-unknown wire
  strings - but `Worm10PendingSignalStore.get` and a Dashboard-side lookup
  in `app_providers.dart` both called it unguarded, so a LEFTOVER
  pre-cleanup pending entry (`"SELL_CLOSE1"`) crashed the technique-switch
  check for that symbol every cycle, and would have crashed the Dashboard
  the next time it rendered that row. Both call sites now catch and treat
  an unparseable/retired wire value as "nothing pending," same resilience
  pattern every other store in this app already uses for a corrupt entry.

- **2026-10-17** — Worm10 backtester/decision-engine correctness pass,
  driven by repeated real-chart cross-checks against BTC/ETH/LTC/XRP:
  (1) **Spec correction**: removed the "weak" `buyClose1`/`sellClose1`
  event kinds (HH/LL + RSI, no Supertrend check) — these were an
  unrequested addition that fired spurious closes whenever Supertrend
  hadn't actually flipped; per the user's exact spec, an HH/LL signal is
  either a fully-qualified reference (tag + Supertrend + RSI, all three)
  or it's not a signal at all, never a weaker close-only trigger.
  `Worm10EventKind` is now 4-way (`buyOpen1`/`sellOpen1`/`zigzagBuy`/
  `zigzagSell`), not 6-way. (2) **SL/TP removal**: the backtester never
  simulated SL/TP per the original spec — that was this app's own
  unrequested addition and the root cause of "doesn't match the chart"
  complaints; a simulated trade now closes exclusively on the next
  opposing/closing worm10 signal. (3) **Coalescing fix, the real
  mechanism**: the raw HH/LL/BUY/SELL plot can hold a qualifying value
  across many consecutive bars for one real swing, so naive "every
  qualifying bar = an event" reading produces spurious duplicate
  trades — confirmed and fixed twice: first by collapsing consecutive
  same-kind events, which over-merged a 38-hours-later recurrence of the
  same kind into the wrong swing (confirmed live, LTCUSDT: a real close
  at 10-13 00:00 was discarded in favor of an unrelated signal at 10-15
  02:00). The actual rule, confirmed against dense per-bar RSI/Supertrend
  data: two same-kind occurrences belong to the same swing only if the
  qualifying condition (RSI zone + Supertrend direction) holds on EVERY
  bar strictly between them, not merely "nothing else happened in
  between" — `deriveWorm10Events` (`worm10_decision.dart`) now checks
  this directly via `sameSwing`. (4) **Lookback window fix**: a trade
  already running when the requested backtest window starts (opened by a
  signal before the window's cutoff) now still gets its real pre-window
  open time once it closes inside the window — `_runBacktest` simulates
  over the full available history unfiltered and only filters the
  *output rows* by the requested window afterward, instead of filtering
  input events by cutoff before simulating (which silently discarded the
  true open and corrupted the next trade's entry price). (5)
  **Self-healing against stale indicator data**: confirmed live — running
  a backtest for one symbol immediately after another could report the
  CHART as switched (`setChartView` verified) while the worm10/spy9
  custom scripts' own computed plot data was still the previous symbol's
  (XRPUSDT backtest returning LTCUSDT-range ~$60-70 prices). `_runBacktest`
  now re-reads signals with a 2s settle delay, requiring two consecutive
  reads to agree on the latest signal before trusting the data, and
  throws rather than silently returning a wrong result if it never
  stabilizes within 6 attempts.

- **2026-10-17** — Dashboard RAM indicator: a new status light next to
  Engine/MT5/TradingView showing free system RAM and usage percentage
  (`EngineStatus.ramAvailableMb`/`ramTotalMb`/`ramUsedPercent`, read from
  `/proc/meminfo`'s `MemAvailable`/`MemTotal` every status write) — added
  after a real incident where TradingView froze mid-sweep and crashed
  while the system was down to ~955MB free with heavy swap use, which
  had been misdiagnosed as a logic bug on more than one occasion. Light
  goes red below 1500MB free (`ramLowThresholdMb`).

- **2026-10-17** — Ignite flag consume-completeness fix: the thunder icon
  (`IgnitedPairStore`) is meant to be one-shot — clear itself the moment
  its pair's next real signal actually opens. Confirmed live:
  BTCUSDT/ETHUSDT stayed ignited (icon lit) long after their triggering
  trades had filled, run, and closed. Root cause — only 4 of the engine's
  9 `_openPosition` call sites ever checked `ignitedPairs.isIgnited`/
  called `.consume()`; the other 5 (retroactive-audit reopen and
  flip-after-close, in both `_checkOneSymbol` and
  `_checkOneSymbolSupertrend`/`_checkOneSymbolWorm10`) opened positions
  with no ignite awareness at all, so if a pair's real open happened to
  go through one of those paths, the flag could never be bypassed
  *or* cleared — it just stayed lit forever. All 9 sites now
  consistently check and consume the flag.

- **2026-10-15** — Multiplier manual copy: fixed a real "+ click did
  nothing" report down to its actual root cause, which turned out to be
  TWO independent failure modes, both confirmed live at ~92-93% account
  margin: (1) MT5's own broker-side margin check can outright REJECT a
  copy's pending fallback order with `comment: "deleted [no money]"`
  (confirmed via `get_trading_history_orders` with
  `include_orders_canceled: true` on ticket 1660700117, LTCUSD.lv) - this
  app's own margin gate has no power to see this coming or bypass it, so
  [EngineService._openCopyPosition] now does the same history-order
  lookup [EngineService._openPosition] already did for this exact reason
  (2026-09-29), and surfaces a genuinely-known failure back to the
  Dashboard via a new [AddCopyResultStore]/`addCopyResultsProvider`
  poll loop, shown as a SnackBar - the ambiguous "still resting, might
  yet trigger" case deliberately shows nothing, since it isn't a failure
  yet. (2) Separately, even when MT5 DOES accept the pending fallback
  order, this app's OWN margin-gate sweep
  ([EngineService._cancelAllRestingPendingOrders]) could still cancel it
  within seconds, because a copy's pending order shared the exact same
  comment tag as any other pending order with no way to single it out -
  confirmed live, a second LTCUSD.lv attempt (ticket 1660701907) was
  cancelled this exact way. This directly contradicted the user's own
  spec for the manual path ("manual copies done by user: has nothing to
  do with margin level") - the click itself correctly bypassed the app's
  margin cap, but its own fallback order was still exposed to the same
  gate's sweep. Fixed with a new, narrowly-scoped
  [ManualCopyPendingOrderStore]: a manual copy's pending order ticket is
  marked exempt the moment it's placed and only un-marked once genuinely
  resolved (triggered or confirmed rejected by MT5) - the sweep now skips
  any ticket still marked exempt. Deliberately NOT applied to the
  automated +$5 milestone path, which is supposed to respect the margin
  gate throughout by design.

- **2026-10-15** — Multiplier column: a manual, profit-gated "add a copy
  trade" control (2026-10-15, per the user's own loud-thinking design
  session: start every pair at a small volume, only pyramid into a
  position once it's already winning, never add to a loser). Clicking
  the "+" (only enabled while the row's live P&L is positive) opens one
  additional real position on the same pair - same direction, same TP,
  same volume as what's already running, copied verbatim ("no need for
  recalculations") - with ONE deliberate exception: a tighter -$1 SL
  instead of the normal -$5 baseline, since a copy only ever opens
  already in profit and doesn't need the same room. Deliberately
  bypasses the per-symbol position cap (that exists to stop the
  AUTOMATED signal logic from accidentally duplicating positions, not to
  block this explicit manual action) while still fully respecting the
  kill switch and the margin-tiered position cap, since a copy is a
  real position consuming a real slot. The Auto-Managed Trades table now
  shows one row PER TICKET instead of collapsing a pair to one row,
  with a Multiplier count ("×N") and a shared background tint per pair
  group - the original (lowest ticket number, since MT5 assigns them
  sequentially and a copy can only open after its original exists) gets
  a visibly darker shade than its copies, so which is which is obvious
  without any separate original/copy tracking. Found and fixed a
  related pre-existing bug while building this: three separate places
  (two in engine_service.dart, one in app_providers.dart) read an open
  position's SL/TP via the wrong field names (`sl`/`tp` instead of the
  real `stop_loss`/`take_profit`, confirmed live) - History's SL/TP
  columns for an actively-closed trade, and the Market Watch screen's
  own SL/TP display, had likely been silently blank this whole time.

This section is intentionally selective — a running record of the real,
live-incident-driven decisions that shaped the app's current behavior,
newest first. Many smaller fixes are referenced inline throughout §9–§19;
this section captures the larger inflection points.

- **2026-10-15** — Margin-level-tiered risk controls, after a real
  Equiti margin stop-out (ticket 1660564764, BNBUSD.lv, -$3.07) exposed
  that [RiskConfig.maxPositions] had existed in config.json this whole
  time (set to 3) but was NEVER actually checked by [RiskGate.gate] -
  only `maxPerSymbol` was. The account had 11-13+ positions running
  simultaneously despite a configured global cap of 3. Per the user's
  own correction of the first fix attempt ("what if there is good margin
  level... why you need to setup a fixed max positions?"), the real
  design ties BOTH the position-count cap and a new trade's own size to
  the account's LIVE margin level instead of a flat number:
  margin > 300% → unrestricted; 200-300% → max 6 positions, 60% size;
  150-200% → max 3 positions, 30% size; <= 150% → already fully blocked
  by the existing gate regardless (`RiskGate.positionCapFor`/
  `marginSizeScaleFor`). Deliberately does NOT auto-close any existing
  position - per the user: "what if i dont need to close any most
  losing open positions???? ... i want the app prevent raching margin
  closing" - purely shrinks/withholds NEW exposure as real risk rises,
  which cannot guarantee immunity (existing positions' own floating
  losses are what actually drives margin down) but meaningfully reduces
  how often and how severely it happens. A full source backup was taken
  (`backups/app-2026-10-15_17-28-40/`) before this round of changes,
  per the user's own request, ahead of any further modification.

- **2026-10-15** — Reconciliation close-reason mislabeling fix: the
  passive reconciliation loop (`_reconcileClosedPositions`) only ever
  guessed the close reason from price proximity to the position's own
  SL/TP, defaulting to `'closed_by_user'` whenever that guess failed -
  silently wrong for BOTH a genuine SL hit whose fill slipped past the
  0.1% tolerance AND a genuine broker-forced margin stop-out (which
  closes at whatever the market price is, nowhere near the position's
  own SL/TP, since it's driven by the ACCOUNT's overall margin level,
  not this position's own exit level). Found live after the user said
  "i did not close any... it was all closed by mt5 itself reaching
  liquidation price" - confirmed directly against MT5's own
  `close_reason` field on two real historical tickets (one genuinely
  "Stop loss", one genuinely "Stop out"). Fixed to read MT5's own
  `close_reason` directly (`stop_reason: 'margin_stop_out'`, its own
  distinct category, deliberately not folded into `stop_loss` or
  `closed_by_user` - a forced liquidation is materially more serious
  than either), with the old price-proximity guess surviving only as a
  fallback for the rare case `close_reason` itself is missing.
  Confirmed Equiti Seychelles' real Stop-Out Level (30% of margin, per
  Equiti's own Support Center FAQ, independently verified twice) via
  live web research, after the account's own Terms & Conditions turned
  out to deliberately NOT publish a fixed number ("the percentage of
  the Margin prescribed by us from time to time").

- **2026-10-15** — Four new Dashboard/History columns, per the user
  ("all details required in history"): Leverage (flat "1:2000" display
  constant, never computed), Investment Value (`volume * contractSize *
  price`, fully computable even for history), Extra Margin
  (`AccountSnapshot.marginFree`, account-wide - MT5 has no per-position
  margin breakdown), and Liquidation Price (a real, grounded ESTIMATE:
  the price at which THIS position alone, holding every other
  position's current P&L and the account balance fixed, would drag
  account equity down to Equiti's 30% Stop-Out Level - explicitly
  labeled an estimate, not a fixed per-symbol number the way a
  crypto-exchange liquidation price is, since MT5's stop-out is a
  single account-wide trigger). Extra Margin/Liquidation Price can only
  ever be set GOING FORWARD from this deploy - both require a live
  account snapshot taken at the moment of close, which doesn't exist
  for any trade that closed before this feature shipped, and can never
  be reconstructed after the fact (confirmed live: ticket 1660564764
  closed ~18 minutes before this deploy, genuinely has no recoverable
  liquidation price).

- **2026-10-14** — Hybrid Decision critical fix: every RSI zone read
  (blue/purple/white/green/yellow) was silently wrong since this
  technique launched - the zone check read a "line" plot that always
  carries the SAME raw RSI value regardless of which zone is actually
  active (TradingView's own conditional-coloring construct: one shared
  value plot paired with a separate, untitled "colorer" plot
  immediately after it in the indicator's own plot list), so the first
  zone checked in the if/else chain (blue) matched on EVERY bar. Found
  live after the user spotted a real LL+RSI-purple+Supertrend-sell
  confluence on ATOM's chart (2026-10-14 18:00) that the app's audit
  had missed entirely, and after independently cross-checking that
  every OTHER worm_10_26 signal (Supertrend, trend-start markers, the
  bare zigzag BUY/SELL tags) read correctly via the exact same
  column-mapping approach - isolating the bug to RSI zones
  specifically. Confirmed live via `metaInfo().plots`: each zone's
  titled "line" plot (e.g. plot_8, "RSI <= 20% (Blue)") is immediately
  followed by an untitled "colorer" plot (plot_9) that's `null` when
  that zone is inactive and a small zone-index number (0 for Yellow,
  confirmed live) when active - the fix reads `lineCol + 1` instead of
  `lineCol`, and does not exclude 0 (unlike the existing `isNum` used
  for the worm10 markers, since 0 is a genuine "active" value here).
  Verified against the live chart after the fix: ATOM's latest
  `buyOpen1` landed at exactly 2026-10-14T18:00:00Z - an exact match to
  the user's own manual chart observation. Because this corrupted which
  events ever qualified as case-1 (`buyOpen1`/`sellOpen1`) and case-1-
  weak (`buyClose1`/`sellClose1`) since launch, it had been producing
  false confluence signals across the whole auto-managed portfolio,
  causing a real cascading wave of opens/closes/recycles across nearly
  every pair before the engine was powered off to stop it.

- **2026-10-14** — Hybrid Decision audit: the app now asks TradingView
  for more backward chart history itself when the retroactive audit
  can't find any case-1 (buyOpen1/sellOpen1) event anywhere in the
  currently-loaded window, instead of deferring forever on whatever
  happened to already be loaded - per the user's direct instruction
  ("again ... app not you... app pulls the data from there") after they
  challenged the earlier deferral behavior ("this scenario is not
  possible.... if app pull more date backwords .. there should be
  LL/HH singal open case 1"). Root cause confirmed live via CDP: the
  chart's loaded window was capped at exactly 300 bars (1H ≈ 12.5
  days), and `requestMoreData()` alone - or an explicit `loadRange()`
  call - silently did nothing, reloading the same 300 bars. What
  actually works mirrors TradingView's own scroll-to-load UX: the
  series' `requestMoreData` only takes effect once the chart's own
  visible viewport is first moved to the LEFT EDGE of the currently
  loaded bars (`timeScale().scrollToBarIndex(firstLoadedIndex)`) -
  after that, `requestMoreData(5000)` genuinely pulled in ~2,800 more
  bars. This was also confirmed to be temporary (something - almost
  certainly the engine's own next symbol switch - reset the window
  back to 300 bars within about 10 seconds), so the new
  `requestMoreChartHistory()` helper (chart_state.dart) and the audit's
  use of it re-read worm10 signals and retry the case-1 search
  immediately, in the same cycle, rather than relying on the wider
  window to persist.

- **2026-10-14** — Hybrid Decision audit correction: the replay's own
  Start anchor was wrong on the first attempt - it used the ticket's own
  recorded open snapshot (whatever literally triggered that specific
  MT5 position), which can genuinely be a flip triggered by a bare
  zigzag tag, not a case-1 confluence. Corrected directly per the user:
  "go backwards to the latest LL/HH case 1 open buy/sell... not go
  backwards to the signal where trade actually open" - Start is now
  ALWAYS the latest genuine buyOpen1/sellOpen1 event in the full
  history, regardless of what literally opened the current ticket. A
  direct consequence: the Dashboard's Open column for this technique
  now reflects the audit's own computed anchor, not necessarily the
  real-time event that caused MT5 to open that specific position -
  confirmed as intended with the user.

- **2026-10-14** — Hybrid Decision: added the retroactive full-chain
  audit it was missing since launch - per the user asking directly
  "please confirm that app open trades are updated according to buy/sell
  HH/LL reverse reading," which surfaced that `_checkOneSymbolWorm10`
  only ever had the real-time single-latest-event check, never a full
  replay since each running position's own Start, unlike Signal Flip's
  own block. Without it, more than one flip happening between checks
  (e.g. a long outage) could land on the wrong direction, since the
  real-time path only compares the single newest event against whatever
  is currently running. Walks every event since Start via
  [worm10DecisionFor] directly - the exact same pure function the
  real-time path uses - so the two can never disagree; verified with a
  synthetic double-flip-nets-back scenario before deploying. Same
  survive-one-extra-candle gate and re-confirm-before-acting discipline
  as Signal Flip's own audit.

- **2026-10-14** — Two more Hybrid Decision fixes, both found live within
  minutes of the user watching real running trades under it: (1) a real
  bug - `worm10EntrySignals`'s Update field got overwritten with an
  identical copy of the Open field on every single cycle, because
  [latest] is always the single most-recent event in the FULL signal
  history, not something newly observed that cycle; re-reading the same
  bar that originally opened the position (nothing newer has happened
  yet) was wrongly treated as a fresh re-confirmation. Confirmed live on
  ticket 1660457325 (`update_kind == kind`, `update_time == bar_time`) -
  fixed by requiring the event to be newer than BOTH the original open
  and whatever Update is already recorded; the one affected ticket's bad
  `update_kind`/`update_time` were cleared directly. (2) Display fix,
  per the user: the Open/Update/Close A columns now collapse the six
  internal event kinds down to the 4 labels that actually matter -
  "LL"/"HH" (which raw swing event fired) and "Buy"/"Sell" (the bare
  zigzag tag) - instead of the internal wire strings
  ("BUY_OPEN1"/"ZIGZAG_SELL" etc). Also, per the user, the Auto-Managed
  Trades table's own direction column now shows "LONG"/"SHORT" instead
  of "BUY"/"SELL" (display only).

- **2026-10-14** — Hybrid Decision follow-ups, found live immediately
  after the user switched to it on the real account: (1) renamed from
  "worm_10_26 + spy_9_26 (Heikin Ashi)" to "Hybrid Decision" (id
  unchanged); (2) each technique now carries its own accent color -
  blue/deep purple/orange - tinting the Dashboard's Decision Technique
  card and the dropdown's own items, so which one is active reads at a
  glance; (3) the Dashboard's Open/Update/Close A columns were blank for
  every REAL running trade under this technique - `app_providers.dart`
  only ever read `entry-signal.json`/`pending-signals.json` (Signal
  Flip's own stores), never this technique's own
  `worm10-entry-signal.json`/`worm10-pending.json`. Fixed to try the
  worm10 stores first, same fallback order `_recordHistory` already
  uses. The technique's own color field is a plain `0xAARRGGBB` int, not
  a `package:flutter/material.dart` `Color` - that broke `dart compile
  exe bin/engine.dart` outright on the first attempt (this model is
  shared with the pure-Dart engine binary) - confirmed live, fixed
  before it ever reached production.

- **2026-10-14** — New feature: a third decision technique, worm_10_26 +
  spy_9_26 (Heikin Ashi) - built around a custom script the user wrote
  that merges worm_9_26's own MSB/OB/HH/LL/BUY/SELL plots with Supertrend
  Plus's discrete Buy/Sell into one script ("worm_10_26"), paired with
  spy_9_26's RSI zone plots - genuinely read for entry/exit this time
  (unlike Signal Flip, where spy_9_26 is attached but never used). Open
  only on a genuine three-part confluence (Supertrend state + a fresh
  HH/LL + the matching RSI zone); that same confluence minus the
  Supertrend leg is enough on its own to close; a repeat of the full
  confluence while already running RECYCLES the same direction fresh
  instead of just confirming it; a bare opposite zigzag signal alone is
  still enough to flip. Pure decision logic lives in
  `lib/data/engine/worm10_decision.dart`, deliberately isolated from
  `EngineService` so it could be synthetic-tested (9 scenarios) and
  dry-run verified against real live TradingView data before being wired
  into any real open/close call - several earlier interpretations of the
  user's own spec were wrong and explicitly corrected across multiple
  rounds (see that file's own doc comment for the final, confirmed
  reasoning). Registered as a selectable technique (`DecisionTechnique.
  worm10`) with its own "Read more" screen - not set as the default,
  switching to it is a deliberate choice.

  Same change also extended `BotHistoryEntry`/the History screen with
  two fields applying to ALL techniques: `realizedProfitPercent` (P&L as
  a percentage of notional, same formula as the Dashboard's own live
  P&L% column, shown as "+11.02 (+33.45%)") and `sllAtTermination` (the
  exact SLL text - "+10%" or "-$5" - active on the position right before
  it closed), per the user: "include the P&L value in history card once
  bot terminated" / "include the sll setup at the trade terminal."

- **2026-10-14** — Baseline SL (§10.2) simplified from "-5% or -$5,
  whichever occurs first" to a flat **-$5 only**, no percent leg at all.
  Per the user, working through a concrete example: a small position
  where 5% of notional was only a ~$0.20 loss used to stop out there
  instead of being allowed to run to a real -$5 loss - "if xrp is -5%
  but still 0.2 ... keep it running until it reaches -5$ ... so always
  the loss not exceeding -5$." Clarified before implementing (a large
  position has the opposite problem - 5% of ITS notional could be far
  more than $5) - confirmed the dollar cap should win for every position
  size, not just small ones, then confirmed again, simpler still: "make
  it if pair is =0% or less... make it -5$ only sl." `_baselineStopLoss`
  dropped the percent comparison entirely; the SLL column and its info
  dialog now both just say `-$5`.

- **2026-10-13** — Dashboard fix: the SLL column (§16.11) showed a bare
  "—" for every position at 0% P&L or below, reading as "nothing is
  protecting this trade." Per the user: "i want sll column to reflect
  exactly sll not a blank... if p&l =<0, sll should b -10%/10$." A null
  `slRatchetThreshold` never meant "no SLL" - it means the ratchet hasn't
  crossed its first rung (+5%) yet, so the SL is still whatever baseline
  SL (§10.2) was set at ignition. The column (and the info dialog's own
  "0% or below" row, which still said "unchanged (no ratchet SL)" from
  before baseline SL existed) now both show `-10%/$10` for that case
  instead.

- **2026-10-13** — Bug fix: the SL ratchet/baseline-SL retroactive sweep
  (`_maybeApplySlRatchet`, §10.1/§10.2) was called AFTER
  `_reverseCheckOnTechniqueSwitchIfNeeded` in `_runCycle` - a single long
  `await` that walks every auto-managed base through TradingView
  sequentially on every engine start (confirmed live ~45-60s per base;
  with ~20+ bases, 15-20+ minutes to return). Found live after the user
  asked why the SLL column stayed empty and currently-running trades
  never got the new baseline SL: every redeploy this session restarted
  the engine mid-sweep, so that first slow sweep never once reached
  completion, meaning the ratchet/baseline code - fully wired and
  correctly throttled - had never actually executed in production. Fixed
  by moving the ratchet sweep and the margin gate refresh to the very top
  of `_runCycle`, ahead of the slow technique-switch sweep (both are pure
  MT5 - no CDP/TradingView involved - so they never needed to wait behind
  it). Verified live: the instant the engine reached `health: ready`
  post-fix, all 17 real open positions were retroactively tightened to
  their baseline SL in under a second.

- **2026-10-13** — New feature: baseline stop-loss at ignition (§10.2),
  filling in the SL ratchet's own "0% or below" row (which used to mean
  "unchanged" - the 60/40 model's typically ~40%+ wide SL). Per the user's
  revised spec: the tighter of -10% or a flat -$10, "whichever occurs
  first" - genuinely volume-aware (a bigger position reaches $10 on a
  smaller price move), not a fixed percent. Replaces the 60/40 model's SL
  entirely for every fresh open and stale-order refresh; applied
  retroactively to already-running positions too via the existing ratchet
  sweep (verified live against this account's real 13 open positions
  before deploying - all computed sensible tightenings). Paired with a new
  two-strikes block (`BaselineStopStrikeStore`): a pair that hits this
  baseline SL twice in a row on the same signal, with nothing breaking the
  streak in between, stops auto-reopening until the signal genuinely
  flips direction - any other close (TP, a ratchet-protected SL, a manual
  close) clears the streak.

- **2026-10-13** — New feature: margin-level risk gate (§10), per the user
  while watching live trading right after the SL ratchet shipped: "if
  margin reached <= 150%... waiting non-filled trades will stay
  non-filled... filled trades and non-triggered trades will become non
  filled." Confirmed directly this means the same "Margin Level" figure
  the Dashboard's account stats block already shows. Once margin level
  drops to ≤150%, `RiskGate` blocks every new open (same mechanism as the
  existing kill switch/daily-loss-limit gates) AND the engine actively
  cancels every resting pending order it placed, so a trigger waiting to
  happen can't push margin lower still — but never touches an
  already-open, triggered position. Resumes normal opens automatically
  the moment margin recovers above 150%. Verified live against the real
  account before deploying: margin level was 250.79% (gate correctly
  inactive) with 7 genuine resting pending orders that would be the first
  thing cancelled if it dropped.

- **2026-10-13** — Dashboard: new "SLL" column on `AutoTradesCard` (§16.11)
  showing the SL ratchet rung currently locked per position (`+15%`-style,
  `—` if none yet), per the user: "so user know what is current sll setup
  without any guessing." Read straight from `SlRatchetStore`'s own file,
  no engine change needed. Header carries an (i) icon opening a dialog
  with the full ladder table, so the exact thresholds are always visible
  rather than something to remember.

- **2026-10-13** — New feature: tightening-only SL ratchet ladder (§10.1),
  the first concrete piece of porting tradingPionex's "Stop Loss Lock"
  concept here. Explicitly refused to just copy tradingPionex's +100%/+200%
  thresholds — studied this account's own real trade history first: 123
  real app-driven closed trades, computed each one's actual PEAK floating
  P&L% from real MT5 H1 candle data (not just final close), found 94%
  never reached +10% peak and 100% of the ones that did reversed into a
  loss by close (20-37 percentage point swings). tradingPionex's +100%
  gate would never have fired once against this data. Shipped a half-size
  ladder (5% steps: +5%→+2%, +10%→+5%, +15%→+10%, ... threshold-5
  indefinitely) scaled to the range that actually matters here, confirmed
  with the user before building. Architecturally simpler than
  tradingPionex's own SLL: this never touches TradingView/CDP at all (pure
  MT5 - live P&L + `trade_modify_sl_tp`), so none of tradingPionex's
  shared-single-chart cooperative-yield machinery was needed - just one
  more self-throttled (30s) check alongside the engine's existing
  per-symbol loop. New `SlRatchetStore` (`logs/sl-ratchet-state.json`,
  keyed by position ticket) tracks the highest rung already locked per
  position so it never loosens and a recycled trade starts fresh.

- **2026-10-13** — Dashboard: P&L column now shows percentage alongside
  the dollar value (§16.11), the first concrete step while the user
  explores porting tradingPionex's "Stop Loss Lock" (SLL) concept here.
  Investigated rather than guessed at the basis for the percentage: SLL's
  own +100%/+200% thresholds were against Pionex's INVESTMENT figure, but
  this app has no equivalent — grepped the codebase (confirms an existing,
  deliberate "no investment/margin sizing" design principle) and inspected
  live MT5 responses (an open order and full account info) and found no
  margin or leverage field anywhere to divide into. Landed on percentage of
  the position's own notional value (`volume * contractSize * priceOpen`)
  instead — computable from data already fetched every poll, with a new
  `WatchedSymbol.contractSize` field (parses the broker's own
  `contract_size`, confirmed 1.0 for every crypto/stock CFD here but never
  assumed for forex, where a standard lot is conventionally 100,000 units).
  Explicitly not equivalent to a margin/leverage-based return.

- **2026-10-11** — Backup & Restore: fixed the export filename's timestamp
  going stale after the first export, per the user: "each export should
  have new time stamp... it is not updating." `_browseExportLocation` only
  generated a fresh `_defaultExportName` when the path field was EMPTY -
  harmless on a brand-new install, but once the field held any previous
  export's filename (which it always does after the very first Browse
  click or export), every subsequent Browse just re-suggested that exact
  same stale name, timestamp included, for the rest of the session. Now
  always generates a fresh one.
- **2026-10-11** — Windows: fixed TradingView detection for a Microsoft
  Store install (§19.2), the app's first real-machine report of "TradingView
  is installed but the app doesn't detect it." Live diagnosis (a PowerShell
  scan covering every standard install root, Start Menu shortcuts, and
  registry uninstall entries - all came back empty) ruled out a simple
  wrong-guessed-path fix and instead found TradingView installed via the
  Store as an MSIX/Appx package, a fundamentally different mechanism from
  the per-user electron-builder install the original Windows port assumed.
  `LaunchConfig.defaultForWindows` now resolves this live via
  `Get-AppxPackage` when the traditional path isn't found, and
  `isTradingViewInstalled` trusts that resolution directly rather than
  re-checking the filesystem (the `WindowsApps` folder's ACL can make even
  a same-user file-existence check false-negative, confirmed live).
  Whether the Store version's sandbox actually honors the
  `--remote-debugging-port` flag this app's entire TradingView automation
  depends on is still unverified pending the user's own test - if it
  doesn't, the fallback is TradingView's direct (non-Store) download.

- **2026-10-10** — Add Pair UX rework (§16.12a), per the user's direct
  feedback right after the feature shipped: "user need to choose if to add
  the pair to crypto or to forex or to stock... app should be smart enough
  to understand" + "why there are 3 search textfield??? there should be
  only one" + "app need to check if pair is already listed in tradingmt5
  before checking with mt5 and trading view." Collapsed the asset-class
  picker + 3 separate text fields into one search field: asset class is
  now auto-detected from the REAL matched MT5 symbol's own suffix (`.lv`
  crypto, `.sd` forex), with a manual picker appearing only when that's
  genuinely ambiguous; the tradingMT5 duplicate check runs first and
  instantly, via a SnackBar, before MT5/TradingView are ever contacted at
  all. Two follow-up corrections from the same conversation, both about
  bridging MT5's and TradingView's different crypto-pair spellings (MT5:
  `GALAUSD.lv`, TradingView: `GALAUSDT`) regardless of which one the user
  types: the MT5 search now also tries a typed "...USDT" shortened to
  "...USD" (so typing the TradingView spelling still finds MT5's own
  symbol), and the TradingView check always derives its candidate from the
  REAL MT5 match via the same `BASEUSD.lv ↔ BASEUSDT` convention
  `WatchedSymbol.derivedTradingViewSymbol` already uses, never from the
  raw typed text directly.
- **2026-10-10** — Add Pair: the retry-once fix below turned out
  insufficient - the SAME half-added-pair race recurred with Gala a second
  time, because MT5's MCP calls were consistently slow under the combined
  concurrent load of the engine's own ~5s polling plus every GUI provider,
  not just a one-off fluke a single retry could outrun. Replaced the
  retry-and-hope approach with a proper verify-the-real-state loop: up to 3
  attempts (3s apart) of "call `addMarketWatchSymbol`, ignore whether it
  itself reports success, then ask `getWatchedSymbols` directly whether the
  symbol is actually visible now" - the add step and its own exceptions are
  no longer trusted at all, only the independent verification read is.
  Deliberately checks `getWatchedSymbols` (what's actually selected into
  Market Watch right now), not `findSymbolInFullCatalog` (the broker's
  whole 2000+-symbol universe, which a candidate like GALAUSD.lv is already
  IN before ever being watched - checking that would have reported "done"
  without `addMarketWatchSymbol` having done anything at all). Separately,
  per the user asking "why does the app need a cycle to check if a pair is
  in TradingView... the cycle for what?": explained the CDP single-attach
  constraint (§14.7) that forces the TradingView check through the
  engine's own loop rather than a direct GUI connection, then found and
  fixed a real slowness in that loop while explaining it -
  `_processAllPendingSymbolResolveRequests` only ran once at the very top
  of each full sweep, so a request made partway through a long sweep had
  to wait out the entire rest of it (confirmed live: 55s for KASUSDT)
  before being noticed. Now re-checked before every symbol in the inner
  loop too, exactly like the terminate/unpause drains already were.
- **2026-10-10** — Add Pair: fixed a half-added-pair race, caught live right
  after the previous two fixes shipped: the user passed all three checks
  for Gala and clicked Add, got an error snackbar, but the pair "added"
  anyway. Investigation (direct MT5 query) confirmed GALAUSD.lv WAS
  genuinely selected/visible in MT5's Market Watch, yet config.json had no
  mapping for it at all - `Mt5Client.addMarketWatchSymbol` succeeded
  server-side but the client-side HTTP call still threw (almost certainly
  the 15s timeout, since MT5 subscribing a brand-new symbol's live quotes
  for the first time is slower than a routine call), aborting `_addPair`
  before it ever reached `repo.addSymbolMapping`. Fixed by retrying
  `addMarketWatchSymbol` once on any exception before giving up - safe
  because the method's own contract is already "no-op if already visible,"
  so a retry moments later returns fast either way. Manually completed the
  user's own stuck GALAUSDT -> GALAUSD.lv mapping via the same
  `EngineControlRepository.addSymbolMapping` the dialog itself calls, so
  they don't have to redo the whole check flow.
- **2026-10-10** — Add/Remove Pairs follow-up fixes, both caught live while
  the user tested adding Gala right after the feature shipped:
  (1) **`AddPairDialog` dropped typed text in the MT5/TradingView fields.**
  The search-suggestions box was a plain conditional sibling above those
  fields with no key; every keystroke that made it appear/disappear shifted
  their position in the `Column`, and Flutter's unkeyed-list reconciliation
  tore down and rebuilt their element (focus and in-flight keystrokes
  included) on every such shift. Fixed by giving every field a stable
  `ValueKey` so Flutter matches by identity instead of position.
  (2) **`Mt5Client.findSymbolInFullCatalog` was exact-match AND
  case-sensitive**, unlike MT5's own Ctrl+U search the user described by
  hand - confirmed live against the real 2312-symbol catalog: "GALAUSD.lv"
  genuinely exists, but "GALAUSD", "GALA", and "galausd.lv" all came back
  null from a single case-sensitive lookup, exactly the four spellings the
  user tried. Fixed with a bounded fallback (case-insensitive exact match,
  then a `.lv`/`.sd` suffix variant, also case-insensitive exact) - **not**
  a substring search, which was tried first and caught live rejecting
  itself: a bare "USDT" candidate spuriously "matched" the unrelated forex
  pair "USDTWD" purely because it starts with those four letters, which
  would have silently offered the wrong instrument as a hit.
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
- **GUI abnormally burns 66-71% CPU continuously** — confirmed live,
  reproducible, 2026-10-17, but NOT yet root-caused or fixed. Found while
  investigating a separate TradingView freeze/crash (ultimately
  root-caused to system RAM exhaustion, §20's 2026-10-17 RAM-indicator
  entry) - the GUI's own high, sustained CPU usage was a contributing
  factor to that RAM/resource pressure but is a distinct, still-open bug
  in its own right.

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
