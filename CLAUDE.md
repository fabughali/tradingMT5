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
- Windows: engine/GUI launch mechanism is NOT YET DOCUMENTED here — whichever Claude
  session sets this up on Windows should write the actual mechanism (scheduled task vs.
  manual exe, log file path, how to check running/stopped state) into this section.
- Windows build: GitHub Actions CI already builds and releases
  `TradingMT5-Setup-X.Y.Z.exe` / `TradingMT5-Windows-X.Y.Z.zip` automatically on every
  push to `main` — confirm the Actions run went green and the GitHub release has both
  assets before considering a Windows release "shipped."

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
- Known longstanding gaps, not yet addressed: GUI sustained CPU usage (~66-71%); the
  Windows build has only ever been CI-compiled, this is its first real live run.
