# tradingMT5 — persistent agent context

Read this file first, every session, on any machine. This is the durable handoff —
Claude's own chat memory does NOT transfer between machines or sessions; this file does
(it's committed to git). Keep it updated as facts change.

## What this app is

Real-money algorithmic trading app. Equiti Brokerage Seychelles, MT5 login `1013734072`.
Flutter desktop app (GUI) + a separate trading engine process that talks to MT5 and
TradingView Desktop (via CDP) to make trading decisions. This is NOT a toy project —
every change here can place real trades with real money. Verify, don't assume.

- Repo: `https://github.com/fabughali/tradingMT5.git`
- GUI entry point: `lib/main.dart`
- Engine: `lib/data/engine/engine_service.dart` (the core decision/trading loop)
- PRD / full feature + decision history: [PRD.md](PRD.md) — read this too, it has the
  dated changelog of every release and the reasoning behind it.

## Platforms — Linux and Windows, never both live at once

The user runs this on both a Linux machine and a Windows machine, same MT5 account
(1013734072). **Only one of them may ever be the live, trading instance at a time.**
Two engines racing against the same account is a real-money risk (duplicate orders,
conflicting risk-gate decisions) — never start the engine on one platform without first
confirming it's stopped on the other.

- Linux: engine runs as a systemd user service (`tradingmt5-engine.service`), GUI bundle
  at `/home/fabughali/.local/share/tradingmt5/bundle/`. Standard checks:
  `systemctl --user status tradingmt5-engine.service`, engine log at
  `/home/fabughali/.local/share/tradingmt5/engine.log`.
- Windows: see "Windows machine — operations" below (verified live 2026-10-20).
- Linux reachability from Windows: SSH to `hypernode` (Tailscale `100.80.150.53`) is
  **refused on port 22** as of 2026-10-20 — a Windows session can NOT check the Linux
  engine itself. Ask the user to run `systemctl --user is-active tradingmt5-engine.service`
  there and report back before starting the engine on Windows.
- Windows build: GitHub Actions CI already builds and releases
  `TradingMT5-Setup-X.Y.Z.exe` / `TradingMT5-Windows-X.Y.Z.zip` automatically on every
  push to `main` — confirm the Actions run went green and the GitHub release has both
  assets before considering a Windows release "shipped."

## Windows machine — operations (verified live 2026-10-20, host `hypervortex`)

Everything below was checked against the running v1.6.23 install and the code
(`lib/data/control/engine_control_repository.dart`, `lib/main.dart`, `bin/engine.dart`),
not assumed. Re-verify if the code in those files changes.

**Install / paths**
- App: `C:\Users\DELL\AppData\Local\Programs\TradingMT5\` (per-user Inno Setup install
  from the CI `TradingMT5-Setup-X.Y.Z.exe`). `trading_mt5.exe` (GUI) and
  `tradingmt5_engine.exe` (engine) sit side by side.
- Data dir: `%USERPROFILE%\.tradingmt5\` (`C:\Users\DELL\.tradingmt5\`; override with
  `TRADING_MT5_HOME`). Engine log: `C:\Users\DELL\.tradingmt5\logs\engine.log`.
  Also in `logs\`: `status.json`, `engine.pid`, `heartbeat`, `gui-heartbeat`.
- Repo checkout: `D:\tradingMT5\app` (remote `origin` = GitHub, branch `main`).
- MT5: `C:\Program Files\MetaTrader 5\terminal64.exe`. TradingView is the **Microsoft
  Store** build (`C:\Program Files\WindowsApps\TradingView.Desktop_*\TradingView.exe`),
  launched by the engine with `--remote-debugging-port=9222`.
- Installed version check:
  `(Get-Item "$env:LOCALAPPDATA\Programs\TradingMT5\trading_mt5.exe").VersionInfo.FileVersion`
  and `Select-String -Path "$env:LOCALAPPDATA\Programs\TradingMT5\data\flutter_assets\pubspec.yaml" -Pattern '^version'`.

**How the engine starts/stops — there is NO service, scheduled task, Run key or
Startup-folder entry** (all checked). The GUI owns the engine process entirely:
- Launch the GUI (Start Menu "TradingMT5"). Every GUI launch forces Power **OFF**
  (`main.dart`, `unawaited(_controlRepo.pause())`), so opening the GUI never starts
  trading by itself.
- Power ON (Dashboard toggle) → deletes `~\.tradingmt5\PAUSE` and spawns
  `tradingmt5_engine.exe` **detached**, as a child of `trading_mt5.exe`. The engine then
  launches `terminal64.exe` and TradingView itself (their parent PID is the engine's).
- Power OFF → writes `PAUSE`, waits 2s, `taskkill /F /PID <engine.pid>`. Closing the GUI
  window does the same (`AppLifecycleListener.onExitRequested` → `pause()`).
- Safety nets: the engine idles/stops itself if `gui-heartbeat` (touched by the GUI every
  5s) goes stale; the GUI's 15s watchdog restarts the engine if Power is on but the
  `heartbeat` file is missing (logged as `ENGINE WATCHDOG`). The engine refuses to start
  if `engine.pid` points at a live `tradingmt5_engine.exe` (single-instance lock).
- **Windows stop cleanup bug — confirmed 2026-10-20, fixed in v1.6.24** (PRD §20):
  ≤ v1.6.23 used a bare `taskkill /F`, which runs no handlers, so `engine.pid` +
  `heartbeat` survived every Windows stop. From v1.6.24 Power-off writes
  `~\.tradingmt5\SHUTDOWN_REQUEST`, the engine exits by itself within ~1s
  (`SHUTDOWN_REQUEST received — shutting down.`), `taskkill /F` only after 10s, and the
  GUI logs `Engine stop (Windows): graceful|forceKilled|notRunning|stillAlive`.
  "Engine running" = `engine.pid` names a live `tradingmt5_engine.exe`. Not yet
  verified with a real Power-off on Windows — do that before trusting it. On a
  v1.6.23 install, a present `heartbeat` file still does NOT mean the engine runs.

**Is it running? (PowerShell, read-only)**
```powershell
tasklist /FI "IMAGENAME eq tradingmt5_engine.exe"            # the process
Get-Content "$env:USERPROFILE\.tradingmt5\logs\engine.pid"   # should match the PID above
Get-Content "$env:USERPROFILE\.tradingmt5\logs\status.json"  # running/connected/last_cycle_at
Test-Path   "$env:USERPROFILE\.tradingmt5\PAUSE"             # True = Power OFF intent
Get-Content "$env:USERPROFILE\.tradingmt5\logs\engine.log" -Tail 50   # add -Wait to follow
```
Do not judge liveness from the `heartbeat` file's timestamp: it's touched once per main
loop iteration, and one full auto sweep (~28 pairs × ~45s) makes it 10+ minutes old
while the engine is perfectly healthy. Use the PID + `status.json` `last_cycle_at` +
log tail instead. To stop the engine, use the Power toggle (or close the GUI) rather than
a raw `taskkill`, so the `PAUSE` intent is recorded too.

**Inspecting the GUI**
- **NEVER call computer-use `open_application("TradingMT5")` to focus the window** — on
  2026-10-20 it launched a SECOND GUI, which forced Power OFF and stopped the live engine
  with 2 positions open (fixed in v1.6.25 by a single-instance lock, but don't rely on
  it). Focus the existing one instead:
  `(New-Object -ComObject WScript.Shell).AppActivate((Get-Process trading_mt5).Id)`.
- Claude Desktop's computer-use tools: `request_access(["TradingMT5"])`, then
  `screenshot`. Toggling Power via a click is blocked by the auto-mode safety
  classifier — ask the user to do it. Other windows (MT5, TradingView, browsers) are masked unless also
  granted. Window title is `trading_mt5`. View-only unless the user asks for clicks —
  the Dashboard has live Power/Auto/trade controls.
- The GUI's own Logs tab shows the same `engine.log`.

**Dev toolchain on this machine (installed 2026-10-20, winget defaults unless noted)**
- Git 2.55 (`C:\Program Files\Git`), GitHub CLI 2.102 (needs `gh auth login` by the
  user — not authenticated yet), Node 24 LTS, Bun 1.4, VS 2022 Build Tools (C++ workload).
- Flutter has no official winget package — cloned `stable` to
  `%USERPROFILE%\develop\flutter` (3.47.7 / Dart 3.13.5), `bin` added to user PATH.
  `flutter doctor`: Windows toolchain OK. `flutter test` → 47/47 pass.
- Newer Flutter here rewrites `pubspec.lock` and `analysis_options.yaml` on `pub get` —
  `git restore` them unless the change is intentional, so Linux and Windows don't
  fight over the lockfile.
- `claude` isn't on PATH; the Claude Desktop-bundled CLI is at
  `%APPDATA%\Claude\claude-code\<version>\<hash>\claude.exe`.
- New shells started before an install don't see the new PATH; refresh with
  `$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')`.

## Release discipline (non-negotiable, learned the hard way)

1. Bump the version in `pubspec.yaml` **before** building — never build then bump.
   Verify the built bundle actually has the intended version
   (`grep "^version:" build/linux/x64/release/bundle/data/flutter_assets/pubspec.yaml`
   or the Windows equivalent) before deploying.
2. Deploy, verify the running binary matches (md5sum against the fresh build), leave the
   engine's on/off state exactly as the user had it before (never force-start or
   force-stop as a side effect of deploying).
3. Commit with `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`, push to
   `origin main`.
4. Wait for Windows CI to go green (`gh run list` / `gh run view`), confirm the release
   has both the `.exe` and `.zip`.
5. Add a dated entry to PRD.md §20 changelog explaining the *why*, in the user's own
   words where possible.
6. Run `flutter test` clean before every deploy — there is a real unit test suite now
   (`test/*.dart`, 46+ tests covering the pure decision/risk-gate logic). Never skip this.

## Backup discipline

Single backup location only: `/media/fabughali/PARTITION11/tradingMT5/backups/` on the
Linux machine. After every release: wipe it and re-populate via
`git archive HEAD | tar -x -C <dest>` into a fresh `app-v<version>-<timestamp>` folder
with a `.backup-info.txt` (commit hash, version, timestamp). Do not let backups
accumulate in multiple places — this was explicitly cleaned up once already (7 stale
snapshots + scattered exports deleted) and should stay that way. Git itself (GitHub) is
the actual cross-machine source of truth — the backups folder is a local-only extra.

## Key architecture decisions already made (do not re-litigate without reason)

- **SLL = dollar ladder, profit-only (v1.6.32 / v1.6.38):** NO action at P&L <= 0 (the
  -$5 baseline and the copies' -$1 SL were removed by the user's choice on 2026-10-25);
  +$5 locks +$2, +$10 -> +$5, +$15 -> +$10 ... Sweep is sequential with the main loop on purpose (it closes positions);
  verify cadence from the `SLL heartbeat` log line, don't assume it.
- **No spread limit (v1.6.39, user's explicit choice):** the v1.6.32 spread guard and the
  copy -$1-survivability check were removed. Pending-order triggers sit at the broker
  minimum (5 price steps); +1 step is rejected by Equiti (retcode 10015).
- **Chart DATA check before every read (v1.6.41, after ~20 trades were closed on
  2026-10-25):** a TradingView label can switch while the series stays stuck
  mid-load on the previous pair's bars. `setChartView` must verify `isLoading()`
  false + `symbolInfo()` names the pair + bar spacing = resolution; never weaken this
  back to a label-only check. 3 failures in a row -> chart page reload.
- **NEVER test a second GUI instance or click Power on the live machine** — a stray GUI
  launch cost a real-money flip on 2026-10-20.
- **Ignite (thunder icon), v1.6.28, user's spec:** one-shot margin-level bypass that
  fills a WAITING pair right away on its CURRENT signal direction (even a bare zigzag)
  at the FULL card volume (no margin size scaling, v1.6.46),
  respecting the closed-candle rule; consumed the moment it fills (incl. late stop-order
  fills); clicking a yellow icon on a waiting pair cancels it; disabled on running rows.
  Entry for non-ignited pairs stays strictly OPEN1-only — the user explicitly wants that.
- **Immediate checks act only on closed candles** (2026-10-20, user's choice, v1.6.27):
  the Power-on / technique-switch reverse-check sweep and the un-pause check skip the
  "survive one extra candle" wait ONLY for a signal whose own candle has closed. Any
  restart of the engine runs this sweep over every open position — before v1.6.27 it
  flipped BTC on a 2-minute-old candle. Treat every restart as a trading event.

- **Worm10 consolidation**: "Supertrend Plus" and "Signal Flip" decision techniques both
  now read off the `worm_10_26` TradingView indicator (via `readWorm10Signals`), not
  their own old indicators (`supertrend`, `worm_9_26`/zigzag). The old reader functions
  (`readSupertrendSignals`, `readSwingOscillatorSignals`, `enforceSupertrendPlus`,
  `enforceCustomScripts`) are deliberately left in place, unused, as a rollback path.
  **The Hybrid Decision (Worm10) technique's own code must never be touched** by work
  on the other two — it's the thing the other two were consolidated onto, not the other
  way around.
- **Retroactive audit cache** (`_auditedTickets` in `engine_service.dart`): a ticket only
  gets the full forward-replay audit once per "occurrence." Four independent triggers
  clear the cache (GUI reopen, hourly pre-candle re-arm, internet-recovery, and a
  per-pair forced clear on manual unpause) — all routed through a shared
  `_clearAuditCache(reason)` helper with a 2-minute debounce, so overlapping triggers
  coalesce into a single audit instead of stacking. This was a deliberate fix for a real
  gap (WiFi/internet recovery wasn't forcing a re-check) — don't remove the debounce
  thinking it's redundant; it's there on purpose.

## How the user works — read this before doing anything

- Extremely demanding, terse, frequent typos — answer the actual question, don't pad.
- Wants **real, verified** claims only — never say something is done without actually
  checking (md5sum the binary, grep the version, confirm the CI run, re-read the file).
  "I think it should work" is not an acceptable standard here.
- Every fix ships as a proper versioned release — not left as an uncommitted local
  change. Both Linux local deploy AND Windows CI build, every time.
- Get explicit confirmation before destructive actions (deleting backups, force-pushing,
  etc.) — but routine commits/pushes/deploys following the pattern above don't need
  re-confirmation each time once the pattern is established.
- If something looks like a bug during testing, investigate it for real (read logs,
  trace timestamps) before concluding — but also don't cry wolf. One past case (engine
  auto-restarting during manual `systemctl` testing) was root-caused to the user's own
  rapid manual test sequence colliding with MT5/TradingView's launch timing, not a real
  code bug — concluded honestly rather than either dismissed or over-fixed.

## Current state (keep this updated)

- Version: repo `1.6.53+101` (2026-10-26). Releases since 1.6.25 are summarised in PRD
  §20 (closed-candle rule, ignite, Market Watch auto-add, dollar SLL, spread guard,
  recycle pre-check, pending-cancel <200%, SLL profit-only, no spread limit, resting-order volume sync, chart DATA check before any read). Windows install status: check
  `VersionInfo.FileVersion` (never assume). Linux not redeployed from Windows (no SSH) —
  still 1.6.23 there; update it before ever running it.
- Windows 2026-10-27 16:0xZ: ENGINE ONLY hot-swapped to v1.6.53 (user: "install it") -
  GUI is still 1.6.51 (`FileVersion` shows 1.6.51). The old engine is kept as
  `tradingmt5_engine.v1.6.51.bak.exe` next to it (rollback = rename back). The new
  engine runs from the next engine start (watchdog restart or Power-on); md5 of the
  installed file = 2970e9c3bb4e924ebfeae20887442fb9 (= CI zip). Next full install
  of a later version replaces both.
- Linux engine: currently **stopped** (`inactive (dead)`) — Windows is the live
  instance as of now (MT5 balance ≈ 34.76 on 1013734072 there).
- Unit tests: `test/sl_ratchet_ladder_test.dart`, `zigzag_range_test.dart`,
  `worm10_decision_test.dart`, `risk_gate_static_test.dart`, `volume_step_test.dart`,
  `windows_engine_stop_test.dart`, plus `widget_test.dart` — 59/59 green (2026-10-20,
  Windows, Flutter 3.47.7). `RiskGate.gate()` itself (the stateful, I/O-backed core) still has no
  coverage — only its pure static helpers do. This is a known, accepted gap.
- 2026-10-20 (Windows, verified): engine running (PID 24092, started 17:28 local via
  Power ON), MT5 + TradingView connected, balance 34.76. Linux reported `inactive` by
  the user. Investigated same day:
  - **Windows MT5 has never accepted a single MCP trade request** (open/close/modify/
    delete) since install — MT5's own journal logs `trading is not permitted, ... order
    request failed` for every one (5,134 engine-side failures 2026-10-11..20). MT5's
    toolbar **Algo Trading** button was OFF (red) on 2026-10-20. Account login itself is
    a full trading login (`trading has been enabled - hedging mode`). "deal ... done"
    lines in the Windows MT5 journal are fills of orders placed by OTHER terminals.
  - **Root cause found + fixed by the user 2026-10-20 19:30:** MT5 → Tools → Options →
    **AI Assistant → Trading** was `Manual confirmation`; set to `Enabled` + MT5 restart →
    MCP trade calls accepted. First-ever Windows fill: BTCUSD.lv SELL 0.003 @ 82617.02
    (deal #1658888893, via the Invalid-fill → sell-stop fallback). If "trading is not
    permitted" ever returns, check this setting first. MCP key rotated 19:35 (MT5 restart
    required; engine re-reads `.env` and reconnected within ~5s, a few 401s meanwhile).
  - Other IPs authorize on 1013734072 between Windows sessions (212.34.x, 188.123.x,
    57.129.12.220 — Windows itself is 176.29.x); not attributed to a device yet.
  - Null cast: `_computeTargetLevels` hard-cast `info['bid'] as num`; MT5 returns no
    bid for SOLUSD.lv/TRXUSD.lv/XRPUSD.lv/GALAUSD.lv. Fixed in v1.6.24 (returns null +
    logs) - those 4 still can't open until MT5 quotes them. Not the audit path.
  - Dashboard 10014/10016/"no money" reasons are stale Linux data from the 2026-10-17
    Backup import (`logs/waiting-reasons.json`), cleared only on a successful open.
    Suspected 10014 cause (unconfirmed, needs Linux log): margin-scaled and stepped-down
    volumes weren't on the `volume_step` grid - snapped before the first send from
    v1.6.24 (`snapVolumeToStep`).
- Known longstanding gaps, not yet addressed: GUI sustained CPU usage (~66-71%); the
  Windows build has only ever been CI-compiled, this is its first real live run.
