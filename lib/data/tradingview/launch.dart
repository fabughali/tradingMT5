import 'dart:io';

/// The private, isolated X display TradingView Desktop always runs on -
/// never the real session's display. Confirmed live on 2026-09-03: with
/// TradingView opening a window on the same Wayland/XWayland session that
/// serves the user's remote desktop, every single TradingView launch (6/6)
/// crashed Mutter/GNOME Shell with SIGSEGV within seconds, tearing down the
/// ENTIRE remote session (RDP, every open app, including Claude's own
/// desktop client) - confirmed via journalctl showing every crash landing
/// right after a TradingView spawn, and the crash's own teardown cascade
/// disconnecting unrelated clients like claude-desktop. Disabling GPU
/// compositing alone (`--disable-gpu`) reduced but did not eliminate this.
/// Running TradingView on its own Xvfb display instead means a crash there
/// can only ever take down that private display, never the user's actual
/// session - the engine only ever talks to TradingView via the CDP port
/// (127.0.0.1:9222) so nothing about automation depends on which display it
/// renders to.
const String virtualDisplay = ':77';

/// Starts the private Xvfb display TradingView renders to, if it isn't
/// already up. No-op if it's already running (checked via its socket file,
/// not a PID we'd have to track across engine restarts).
Future<void> ensureVirtualDisplayUp({
  Duration timeout = const Duration(seconds: 10),
}) async {
  final socketFile = File(
    '/tmp/.X11-unix/X${virtualDisplay.replaceFirst(':', '')}',
  );
  if (socketFile.existsSync()) return;

  await Process.start('Xvfb', [
    virtualDisplay,
    '-screen',
    '0',
    '1920x1080x24',
    '-nolisten',
    'tcp',
  ], mode: ProcessStartMode.detached);

  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (socketFile.existsSync()) return;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

/// Auto-launches TradingView Desktop if CDP is down — ported 1:1 from
/// lib/launch.js. display/xauthority/etc. are deliberately null by default
/// (see [launchTradingView]) rather than hardcoded: a fixed Xauthority path
/// (e.g. GDM's) breaks the moment the session type changes - confirmed live
/// when this machine switched from a local GDM session to remote access,
/// which uses a different, randomly-named Xwayland auth file each time. The
/// engine process's own environment already has the right values for
/// whatever session it's actually running in; only set these explicitly if
/// a specific override is genuinely needed. NOTE: none of this applies to
/// DISPLAY any more - TradingView is always forced onto [virtualDisplay],
/// see that constant's doc comment for why.
class LaunchConfig {
  const LaunchConfig({
    required this.binaryPath,
    this.display,
    this.xauthority,
    this.dbusSessionBusAddress,
    this.xdgRuntimeDir,
    this.desktopFile,
  });

  final String binaryPath;
  final String? display;
  final String? xauthority;
  final String? dbusSessionBusAddress;
  final String? xdgRuntimeDir;

  /// The installed `.desktop` file for TradingView (same role as
  /// `Mt5LaunchConfig.desktopFile`) - used only to tell GNOME Shell which
  /// real icon this window belongs to; never launched via `gio launch`
  /// itself, since its fixed `Exec=` line can't carry the
  /// `--remote-debugging-port`/`--ozone-platform` flags CDP automation
  /// requires. See the comment where it's used in [launchTradingView].
  final String? desktopFile;

  static LaunchConfig defaultForHome(String home) => LaunchConfig(
    binaryPath: '$home/Applications/tradingview/opt/TradingView/tradingview',
    desktopFile: '$home/.local/share/applications/tradingview.desktop',
  );

  /// Windows port (2026-10-07, UNTESTED against a real Windows machine -
  /// verify this default install path once an actual build runs there).
  /// Electron apps built with electron-builder (which TradingView Desktop
  /// is) default to a per-user install under `%LOCALAPPDATA%\Programs`,
  /// no admin rights required - [launchTradingView]'s own Windows branch
  /// only uses this as a fallback the user can override.
  static LaunchConfig defaultForWindows() {
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    return LaunchConfig(binaryPath: '$localAppData\\Programs\\tradingview\\TradingView.exe');
  }
}

Future<bool> isCdpUp(String host, int port) async {
  final client = HttpClient();
  try {
    final request = await client
        .getUrl(Uri.parse('http://$host:$port/json/version'))
        .timeout(const Duration(seconds: 8));
    final response = await request.close().timeout(const Duration(seconds: 8));
    return response.statusCode == 200;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

/// Kills any stale TradingView process and relaunches it with the CDP debug
/// port open. Waits until the port responds, or gives up after [timeout].
Future<bool> launchTradingView(
  String host,
  int port,
  LaunchConfig config, {
  Duration timeout = const Duration(seconds: 30),
  // Manual, user-controlled (AppConfig.remoteSession) - NOT auto-detected.
  // true (the default, matching the config default): isolate TradingView on
  // virtualDisplay, invisible, since opening it on the real display has
  // repeatedly crashed this kind of remote-access session (confirmed live
  // 2026-09-04). false: show it normally on the real display, for a
  // genuinely local/direct session where that risk doesn't apply and the
  // user actually wants to see the chart.
  bool remoteSession = true,
}) async {
  if (Platform.isWindows) {
    return _launchTradingViewWindows(host, port, config, timeout: timeout);
  }

  try {
    await Process.run('pkill', ['-9', '-f', config.binaryPath]);
  } catch (_) {}
  await Future<void>.delayed(const Duration(seconds: 2));

  final home = Platform.environment['HOME'] ?? '';
  final Map<String, String> env;
  if (remoteSession) {
    await ensureVirtualDisplayUp();
    // Inherits XAUTHORITY/DBUS_SESSION_BUS_ADDRESS/XDG_RUNTIME_DIR from the
    // engine's own live environment (harmless - TradingView doesn't need
    // the real session's X auth since it's not touching the real display
    // at all). DISPLAY is forced to the isolated virtualDisplay, never the
    // caller's config or the inherited real one - see virtualDisplay's doc
    // comment for why.
    env = {
      ...Platform.environment,
      if (config.xauthority != null) 'XAUTHORITY': config.xauthority!,
      if (config.dbusSessionBusAddress != null)
        'DBUS_SESSION_BUS_ADDRESS': config.dbusSessionBusAddress!,
      if (config.xdgRuntimeDir != null)
        'XDG_RUNTIME_DIR': config.xdgRuntimeDir!,
      'HOME': home,
      'DISPLAY': virtualDisplay,
    }..remove('WAYLAND_DISPLAY');
  } else {
    // Local/direct session - show it for real. Inherits the engine's own
    // live DISPLAY/WAYLAND_DISPLAY/XAUTHORITY/etc as-is (correct for
    // whatever session it's actually running in), only overridden if a
    // caller explicitly passed a value.
    env = {
      ...Platform.environment,
      if (config.display != null) 'DISPLAY': config.display!,
      if (config.xauthority != null) 'XAUTHORITY': config.xauthority!,
      if (config.dbusSessionBusAddress != null)
        'DBUS_SESSION_BUS_ADDRESS': config.dbusSessionBusAddress!,
      if (config.xdgRuntimeDir != null)
        'XDG_RUNTIME_DIR': config.xdgRuntimeDir!,
      'HOME': home,
    };
    // Fixed 2026-09-28, per the user - same generic-icon bug MT5's launcher
    // already had to fix (see the doc comment on Mt5LaunchConfig.desktopFile):
    // blindly copying Platform.environment carries this ENGINE process's own
    // inherited GIO_LAUNCHED_DESKTOP_FILE (pointing at whatever launched
    // Claude/the engine, not TradingView), which told GNOME Shell the new
    // window belonged to the wrong app and fell back to a generic icon in
    // the dock instead of TradingView's real one. Can't fix this the way MT5
    // did (`gio launch <desktopFile>`) - its fixed Exec= line can't carry the
    // --remote-debugging-port/--ozone-platform flags CDP automation needs -
    // so instead: strip the stale value and set it explicitly to
    // TradingView's own installed .desktop file, which is what `gio launch`
    // itself would have set, while still spawning the binary directly with
    // our required flags.
    env.remove('GIO_LAUNCHED_DESKTOP_FILE');
    env.remove('DESKTOP_STARTUP_ID');
    env.remove('XDG_ACTIVATION_TOKEN');
    if (config.desktopFile != null && File(config.desktopFile!).existsSync()) {
      env['GIO_LAUNCHED_DESKTOP_FILE'] = config.desktopFile!;
    }
  }

  await Process.start(
    config.binaryPath,
    [
      '--remote-debugging-port=$port',
      '--ozone-platform=x11',
      // Only needed for the isolated/invisible path - virtualDisplay
      // isolation is what actually prevents a crash from reaching the
      // user's real session, but there's no reason to burn real GPU
      // compositing on a display nobody ever looks at either. A genuinely
      // local, visible session should render normally.
      if (remoteSession) '--disable-gpu',
    ],
    environment: env,
    mode: ProcessStartMode.detached,
  );

  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await isCdpUp(host, port)) return true;
    await Future<void>.delayed(const Duration(milliseconds: 800));
  }
  return false;
}

/// Windows port of [launchTradingView] (2026-10-07, UNTESTED against a
/// real Windows machine). Much simpler than the Linux path: no
/// Xvfb/virtualDisplay isolation needed at all - the crash this whole
/// mechanism exists to work around (TradingView killing Mutter/GNOME Shell)
/// is specific to that Linux compositor; nothing like it has ever been
/// reported here, so TradingView just launches visibly, same as any other
/// Windows app. No DISPLAY/XAUTHORITY/DBUS/XDG_RUNTIME_DIR concepts exist
/// on Windows, and `--ozone-platform=x11` is a Linux-only Chromium flag -
/// omitted entirely. Windows resolves the taskbar icon from the exe's own
/// identity, so none of the GIO_LAUNCHED_DESKTOP_FILE dance applies either.
Future<bool> _launchTradingViewWindows(
  String host,
  int port,
  LaunchConfig config, {
  required Duration timeout,
}) async {
  await _taskkillByBinaryPath(config.binaryPath);
  await Future<void>.delayed(const Duration(seconds: 2));

  await Process.start(
    config.binaryPath,
    ['--remote-debugging-port=$port'],
    mode: ProcessStartMode.detached,
  );

  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await isCdpUp(host, port)) return true;
    await Future<void>.delayed(const Duration(milliseconds: 800));
  }
  return false;
}

/// `taskkill /IM` wants just the executable's filename, not a full path -
/// unlike Linux's `pkill -f`, which matches anywhere in the command line.
Future<void> _taskkillByBinaryPath(String binaryPath) async {
  final imageName = binaryPath.split(RegExp(r'[\\/]')).last;
  try {
    await Process.run('taskkill', ['/F', '/IM', imageName]);
  } catch (_) {}
}

/// Kills TradingView Desktop if it's running, and waits until CDP stops
/// responding (or gives up after [timeout]) so the caller knows the process
/// is actually gone before reporting success.
Future<bool> stopTradingView(
  String host,
  int port,
  LaunchConfig config, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  if (Platform.isWindows) {
    await _taskkillByBinaryPath(config.binaryPath);
  } else {
    try {
      await Process.run('pkill', ['-9', '-f', config.binaryPath]);
    } catch (_) {}
  }

  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (!await isCdpUp(host, port)) return true;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  return false;
}
