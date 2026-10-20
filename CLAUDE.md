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
- **Unverified, suspected Windows-only gap:** `taskkill /F` is a hard kill and the engine
  doesn't watch SIGTERM on Windows, so the cleanup in `bin/engine.dart`'s
  `onStopSignal` (deleting `engine.pid` + `heartbeat`) never runs on a Windows stop —
  no `received — shutting down` line follows any Windows Power-off in engine.log. If
  confirmed, the 2026-10-18 "Dashboard lights stay green after Power off" fix doesn't
  hold on Windows. Check `logs\heartbeat` right after a Power-off before relying on it.

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
- Claude Desktop's computer-use tools: `request_access(["TradingMT5"])`, then
  `screenshot`. Other windows (MT5, TradingView, browsers) are masked unless also
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

- Version: `1.6.23+71`, both platforms.
- Linux engine: currently **stopped** (`inactive (dead)`) — Windows is the live
  instance as of now (MT5 balance ≈ 34.76 on 1013734072 there).
- Unit tests: `test/sl_ratchet_ladder_test.dart`, `zigzag_range_test.dart`,
  `worm10_decision_test.dart`, `risk_gate_static_test.dart`, plus `widget_test.dart` —
  all green. `RiskGate.gate()` itself (the stateful, I/O-backed core) still has no
  coverage — only its pure static helpers do. This is a known, accepted gap.
- 2026-10-20 (Windows, verified): engine running (PID 24092, started 17:28 local via
  Power ON), MT5 + TradingView connected, balance 34.76. Linux reported `inactive` by
  the user. Live issues seen in engine.log / Dashboard, not yet investigated:
  `trade_send_market_order ... trading is not permitted` (MT5-side refusal), a
  `type 'Null' is not a subtype of type 'num'` in the technique-switch reverse check,
  and many cards showing retcode 10014 (invalid volume) / 10016 (invalid stops) /
  "no money".
- Known longstanding gaps, not yet addressed: GUI sustained CPU usage (~66-71%); the
  Windows build has only ever been CI-compiled, this is its first real live run.
