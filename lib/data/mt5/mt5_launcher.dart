import 'dart:io';

/// Launches/verifies the MT5 terminal is up — the MT5 equivalent of
/// `tradingview/launch.dart`'s `launchTradingView`/`isCdpUp`. Per the user
/// (2026-09-19): "once tradingMT5 on, mt5 should be running" - the app
/// itself ensures that, instead of a human relaunching MT5 by hand.
///
/// Windows only (2026-11-13, per the user: "i dont use this app anymore in
/// linux ... remove any linux code"). The Wine/X11/.desktop launch path is
/// gone; MT5 is the native Windows terminal.
class Mt5LaunchConfig {
  const Mt5LaunchConfig({required this.terminalPath});

  final String terminalPath;

  /// MT5's default Windows install path (verified live on this PC).
  static Mt5LaunchConfig defaultForWindows() => const Mt5LaunchConfig(
    terminalPath: r'C:\Program Files\MetaTrader 5\terminal64.exe',
  );
}

/// Checked BEFORE ever attempting a launch (2026-10-07) - a missing install
/// fails fast with a clear message ([PowerHealthState.mt5NotInstalled])
/// instead of a confusing process-spawn error.
Future<bool> isMt5Installed(Mt5LaunchConfig config) async => File(config.terminalPath).existsSync();

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

/// Checks [isMt5Up] first; if not, launches the terminal and polls until the
/// MCP port responds or [timeout] elapses. Does NOT kill an existing
/// instance first (unlike `launchTradingView`) — MT5 is a live trading
/// terminal with a real broker session.
Future<bool> ensureMt5Running(
  String host,
  int port,
  Mt5LaunchConfig config, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  if (await isMt5Up(host, port)) return true;

  try {
    await Process.start(
      config.terminalPath,
      const [],
      mode: ProcessStartMode.detached,
    );
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
