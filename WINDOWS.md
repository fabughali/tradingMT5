# Running on Windows

Added 2026-10-07. The app has only ever run on Linux until now — this is
the first Windows port, built and packaged entirely through GitHub Actions
CI (`.github/workflows/windows-build.yml`). Its first real-machine install
(2026-10-09) failed outright on a missing Visual C++ runtime — now fixed
(see below) — a reminder that "compiles clean on CI" and "runs on a real
Windows machine" are genuinely different claims here. Treat the defaults
below as a starting point to verify, not a guarantee.

## Getting the build

Every push to `main` (and manual runs) builds automatically and publishes
a **versioned GitHub Release**. To install:

1. Go to the repo's **Releases** page (or the **Actions** tab → the latest
   **Windows build** run, which lists the same files).
2. Download **`TradingMT5-Setup-<version>.exe`** — a real installer
   (2026-10-09), not a bare exe to run in place. Run it: it installs to a
   per-user folder (no admin/UAC prompt), adds Start Menu and (optional)
   Desktop shortcuts, registers a normal uninstaller in "Apps & features",
   and silently installs the Microsoft Visual C++ Runtime first if this
   machine doesn't already have it (you may see one separate UAC prompt
   just for that one step — that's Microsoft's own installer, not this
   app, asking) — no Flutter, no Visual Studio, nothing else to install,
   those only ran on GitHub's build machine.
3. Launch TradingMT5 from the Start Menu or desktop shortcut the installer
   created.

A portable `TradingMT5-Windows-<version>.zip` (extract-and-run, no
installer, no shortcuts, no uninstaller) is also published alongside it on
the same Release, for anyone who specifically wants that instead.

## Before Power works

The app needs to find MetaTrader 5 and TradingView Desktop on this
machine. Their default install paths (in `lib/data/mt5/mt5_launcher.dart`'s
`defaultForWindows()` and `lib/data/tradingview/launch.dart`'s
`defaultForWindows()`) are:

- MT5: `C:\Program Files\MetaTrader 5\terminal64.exe`
- TradingView: `%LOCALAPPDATA%\Programs\tradingview\TradingView.exe`

If either is installed somewhere else, update those two defaults and
rebuild (or ask me to make them configurable from Settings if that keeps
happening).

## Moving your data over from Linux

This has nothing to do with GitHub or the build — it's the existing
**Backup & Restore** feature (Settings screen), already built with
AES-256-GCM password-protected encryption:

1. On the Linux machine: Settings → Backup & Restore → Export. Pick a
   strong password.
2. Copy the resulting encrypted file to the Windows machine (flash drive,
   anything).
3. On Windows: Settings → Backup & Restore → Import, same password.

That carries over config, auto-managed pairs, trade history, every
identity store — everything Linux knows, now on Windows.

## What's genuinely new/different on Windows vs. Linux

- **Power toggle**: Linux uses a systemd service to start/stop the engine
  process; Windows has no systemd, so Power directly spawns
  `tradingmt5_engine.exe` (expected right next to `trading_mt5.exe` — the
  CI build already places it there) and stops it via `taskkill`.
- **TradingView launch**: Linux isolates TradingView on a private virtual
  display to survive a GNOME-Shell-specific crash bug that doesn't apply
  on Windows — Windows just launches it visibly, directly, no isolation
  needed.
- **MT5 launch**: Linux runs MT5 under Wine; Windows runs it natively, no
  wrapper needed.
- **Installer**: Linux has no installer at all (a systemd service file +
  a manually-placed bundle); Windows gets a real one
  (`windows_installer/tradingmt5.iss`, Inno Setup, compiled by CI).

All of the above are implemented and compile clean, but **none have been
exercised against a real Windows session yet** — the first real run is
the actual test. Report anything that doesn't work and it'll get fixed the
same way every other bug in this app has been: investigated against real
evidence, not guessed at.
