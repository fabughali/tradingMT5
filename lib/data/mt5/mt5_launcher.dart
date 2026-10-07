import 'dart:io';

/// Launches/verifies the MT5 terminal (under Wine) is up — the MT5
/// equivalent of `tradingview/launch.dart`'s `launchTradingView`/`isCdpUp`.
/// Per the user (2026-09-19): MT5 has repeatedly gone down independently of
/// this app during the same session (closed manually, or the environment
/// restarted) with no automatic recovery — "once tradingMT5 on, mt5 should
/// be running" means the app itself should ensure that, not require a
/// human to notice the Market Watch list went empty and relaunch MT5 by
/// hand every time.
class Mt5LaunchConfig {
  const Mt5LaunchConfig({
    this.winePrefix,
    required this.terminalPath,
    this.display,
    this.xauthority,
    this.desktopFile,
  });

  /// Null on Windows (2026-10-07, Windows port) - MT5 is a native Windows
  /// app there, nothing to wrap in Wine. Required (non-null) on Linux,
  /// where every instance always goes through [defaultForHome]/explicit
  /// construction with a real prefix.
  final String? winePrefix;
  final String terminalPath;

  /// Which X display to show the terminal on. Per the user, they've
  /// consistently wanted to actually SEE MT5 on the real desktop this
  /// session (not the isolated/invisible-display pattern TradingView uses)
  /// — default to the caller's own current DISPLAY unless overridden.
  final String? display;
  final String? xauthority;

  /// The Wine-generated `.desktop` launcher for MT5 (created automatically
  /// by `winemenubuilder` the first time the terminal is installed/run) —
  /// preferred over launching `terminal64.exe` directly. Confirmed live
  /// 2026-09-20, per the user: launching the raw exe as a plain child
  /// process carries no desktop startup-notification/app-id, so the
  /// window manager can't tell it's the same app as the user's pinned
  /// MetaTrader 5 taskbar icon — it shows up as a separate, generic-icon
  /// window instead of merging into the pinned one. Going through this
  /// `.desktop` file (the same one the pinned icon itself launches)
  /// fixes that. Falls back to the raw exe launch if this file doesn't
  /// exist (e.g. a WINEPREFIX where MT5's Start Menu entry never got
  /// generated).
  final String? desktopFile;

  static Mt5LaunchConfig defaultForHome(String home) => Mt5LaunchConfig(
    winePrefix: '$home/.mt5',
    terminalPath: '$home/.mt5/drive_c/Program Files/MetaTrader 5/terminal64.exe',
    desktopFile:
        '$home/.local/share/applications/wine/Programs/MetaTrader 5/MetaTrader 5.desktop',
  );

  /// Windows port (2026-10-07, UNTESTED against a real Windows machine -
  /// verify this default install path once an actual build runs there).
  /// MT5's Windows installer defaults to Program Files, but per-user
  /// installs (no admin rights) land under the user's own AppData instead -
  /// [ensureMt5Running] already only uses this as a fallback the user can
  /// override via their own [Mt5LaunchConfig], same as Linux.
  static Mt5LaunchConfig defaultForWindows() => const Mt5LaunchConfig(
    terminalPath: r'C:\Program Files\MetaTrader 5\terminal64.exe',
  );
}

/// Checked BEFORE ever attempting a launch (2026-10-07, per the user: "app
/// need to be smart... need to detect if both are installed in linux. wine
/// (mt5) and trading view too") - a missing install should fail fast with a
/// clear, actionable message ([PowerHealthState.mt5NotInstalled]) instead
/// of a confusing process-spawn error, or silently retrying a launch that
/// can never succeed. On Linux this ALSO requires `wine` itself to be on
/// PATH - the terminal exe existing inside a WINEPREFIX means nothing if
/// there's no Wine installed to run it.
Future<bool> isMt5Installed(Mt5LaunchConfig config) async {
  if (!File(config.terminalPath).existsSync()) return false;
  if (Platform.isWindows) return true;
  try {
    final result = await Process.run('wine', ['--version']);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// Cheap "is the MCP server listening" probe — same idea as
/// `tradingview/launch.dart`'s `isCdpUp`, just a raw TCP connect since MT5's
/// MCP endpoint returns 401 without auth (still meaningfully "up") rather
/// than a clean 200 to check for.
Future<bool> isMt5Up(String host, int port) async {
  try {
    final socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 3),
    );
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// Checks [isMt5Up] first; if not, launches the terminal under Wine and
/// polls until the MCP port responds or [timeout] elapses. Does NOT kill an
/// existing instance first (unlike `launchTradingView`) — MT5 is a live
/// trading terminal with a real broker session; blindly killing it on every
/// app start is a materially different risk than restarting a chart viewer.
Future<bool> ensureMt5Running(
  String host,
  int port,
  Mt5LaunchConfig config, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  if (await isMt5Up(host, port)) return true;

  try {
    if (Platform.isWindows) {
      // Windows port (2026-10-07, UNTESTED against a real Windows machine):
      // MT5 is a native Windows app here - no Wine, no WINEPREFIX, no
      // DISPLAY/XAUTHORITY, no GIO_LAUNCHED_DESKTOP_FILE icon-matching
      // hack (that was GNOME Shell-specific) - Windows resolves the
      // taskbar icon from the exe's own identity automatically. Just
      // launch the real terminal directly.
      await Process.start(
        config.terminalPath,
        const [],
        mode: ProcessStartMode.detached,
      );
    } else {
      final home = Platform.environment['HOME'] ?? '';
      final env = {
        ...Platform.environment,
        'WINEPREFIX': config.winePrefix!,
        if (config.display != null) 'DISPLAY': config.display!,
        if (config.xauthority != null) 'XAUTHORITY': config.xauthority!,
        'HOME': home,
      };
      // Strip startup-notification vars inherited from THIS process's own
      // launch context before spawning MT5's — confirmed live 2026-09-20,
      // per the user: `Platform.environment` carries
      // `GIO_LAUNCHED_DESKTOP_FILE` pointing at Claude Desktop's own
      // .desktop file (since the whole session was opened from Claude's
      // icon), and blindly copying that onto the MT5 child process told
      // GNOME Shell the new window belonged to Claude, not MT5 — it
      // matched neither app and fell back to a generic icon in the dock
      // instead of resolving to MT5's real one. `gio launch` sets its own
      // correct value for these once the stale one is gone.
      env.remove('GIO_LAUNCHED_DESKTOP_FILE');
      env.remove('DESKTOP_STARTUP_ID');
      env.remove('XDG_ACTIVATION_TOKEN');

      // Prefer the Wine-generated `.desktop` launcher — see the doc
      // comment on [Mt5LaunchConfig.desktopFile] for why: it's what keeps
      // the launched window merged into the user's pinned taskbar icon
      // instead of showing up as a separate, generic-icon window.
      final desktopFile = config.desktopFile;
      if (desktopFile != null && File(desktopFile).existsSync()) {
        await Process.start(
          'gio',
          ['launch', desktopFile],
          environment: env,
          mode: ProcessStartMode.detached,
        );
      } else {
        await Process.start(
          'wine',
          [config.terminalPath],
          environment: env,
          mode: ProcessStartMode.detached,
        );
      }
    }
  } catch (_) {
    return false;
  }

  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await isMt5Up(host, port)) return true;
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  return false;
}
