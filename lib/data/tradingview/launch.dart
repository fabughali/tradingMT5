import 'dart:convert';
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
    this.confirmedInstalled = false,
  });

  final String binaryPath;
  final String? display;
  final String? xauthority;
  final String? dbusSessionBusAddress;
  final String? xdgRuntimeDir;

  /// True when installation was already positively confirmed through a
  /// channel OTHER than a plain file-existence check (2026-10-11, confirmed
  /// live: a Microsoft Store/Appx install's `WindowsApps` folder carries a
  /// locked-down ACL that can make even [File.existsSync] on the OWNING
  /// user's own file come back false - `Get-ChildItem` on that exact folder
  /// returned nothing for a package the user's own `Get-AppxPackage` query
  /// confirmed was genuinely theirs). When true, [isTradingViewInstalled]
  /// trusts this instead of re-checking the filesystem.
  final bool confirmedInstalled;

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

  /// Windows port (2026-10-11, confirmed live against a real Windows
  /// machine, correcting the original 2026-10-07 guess). That original
  /// guess — a per-user electron-builder install under
  /// `%LOCALAPPDATA%\Programs` — is still tried FIRST, since it's exactly
  /// right for TradingView's direct, non-Store download from
  /// tradingview.com/desktop. But a real install was found live via the
  /// **Microsoft Store** instead: an MSIX/Appx package at
  /// `C:\Program Files\WindowsApps\TradingView.Desktop_VERSION_x64__HASH\TradingView.exe`
  /// — a completely different install mechanism no path guess could ever
  /// find, since that version+hash folder suffix changes on every
  /// TradingView update. Falls back to asking
  /// `Get-AppxPackage` directly (the same official API Windows itself
  /// uses to track installed Store apps) rather than hardcoding today's
  /// exact folder name, via [_resolveWindowsAppxTradingViewPath].
  static Future<LaunchConfig> defaultForWindows() async {
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    final traditionalPath = '$localAppData\\Programs\\tradingview\\TradingView.exe';
    if (File(traditionalPath).existsSync()) {
      return LaunchConfig(binaryPath: traditionalPath);
    }
    final appxPath = await _resolveWindowsAppxTradingViewPath();
    if (appxPath != null) {
      return LaunchConfig(binaryPath: appxPath, confirmedInstalled: true);
    }
    // Neither found - return the traditional guess anyway so the existing
    // "not installed" error path ([isTradingViewInstalled]) still fires
    // with a sensible, informative path in its own error message, rather
    // than an empty/null one.
    return LaunchConfig(binaryPath: traditionalPath);
  }
}

/// Asks PowerShell's `Get-AppxPackage` cmdlet directly for TradingView
/// Desktop's real install location when it was installed via the
/// Microsoft Store (2026-10-11, confirmed live: `(Get-AppxPackage
/// *TradingView*).InstallLocation` → `C:\Program Files\WindowsApps\
/// TradingView.Desktop_3.4.1.8194_x64__n534cwy3pjxzj`, with the manifest's
/// own `<Application Executable="...">` confirming the exe inside it is
/// named plainly `TradingView.exe`). Returns null (never throws) on any
/// failure — no Appx package found, PowerShell unavailable, etc. Returns
/// the constructed path directly from `Get-AppxPackage`'s own answer,
/// deliberately WITHOUT a [File.existsSync] re-check: that check is exactly
/// what [LaunchConfig.confirmedInstalled]'s own doc comment explains is
/// unreliable against this folder's locked-down ACL, so PowerShell's own
/// package-registry answer (queried as the SAME user, via the same API
/// Windows itself uses) is trusted directly instead.
Future<String?> _resolveWindowsAppxTradingViewPath() async {
  try {
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      r'(Get-AppxPackage -Name "*TradingView*" | Select-Object -First 1).InstallLocation',
    ]).timeout(const Duration(seconds: 10));
    final installLocation = (result.stdout as String).trim();
    if (installLocation.isEmpty) return null;
    return '$installLocation\\TradingView.exe';
  } catch (_) {
    return null;
  }
}

/// Checked BEFORE ever attempting a launch - see [isMt5Installed]'s own doc
/// comment for the exact same reasoning, mirrored here
/// ([PowerHealthState.tradingViewNotInstalled]). Unlike MT5, TradingView
/// Desktop is native on Linux too (no Wine) - just the one file-existence
/// check on either platform, UNLESS [LaunchConfig.confirmedInstalled] is
/// already true (a Microsoft Store/Appx install, confirmed via a channel
/// other than the filesystem - see that field's own doc comment for why a
/// plain file check can't be trusted there).
bool isTradingViewInstalled(LaunchConfig config) =>
    config.confirmedInstalled || File(config.binaryPath).existsSync();

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
  void Function(String message, {String? level})? onLog,
}) async {
  if (Platform.isWindows) {
    return _launchTradingViewWindows(host, port, config, timeout: timeout, onLog: onLog);
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
  void Function(String message, {String? level})? onLog,
}) async {
  // Verified, not fire-and-forget (2026-10-16) - see
  // [taskkillOwnTradingView]'s own doc comment: launching a fresh instance
  // right after a kill that silently failed just adds a SECOND process
  // fighting the first one for the same port, which looks identical to
  // "TradingView won't come up" from the caller's side.
  await taskkillOwnTradingView(config.binaryPath, port, onLog: onLog);
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

/// One running TradingView process, as Windows reports it.
class TradingViewProcess {
  const TradingViewProcess({required this.pid, required this.parentPid, required this.commandLine});

  final int pid;
  final int parentPid;

  /// Null when Windows wouldn't say - such a process is never killed.
  final String? commandLine;
}

/// Which of [processes] belong to this app (2026-11-01, v1.6.60, per the user:
/// TradingPionex runs its own TradingView on port 9333 and the two apps must be
/// 100% independent; `taskkill /IM` killed every instance on the machine).
/// Ours: anything on our [port], or a main process with no debug port and no
/// data folder of its own, because that one holds the default folder and would
/// swallow our relaunch. Children of a killed process are left out, since
/// `taskkill /T` takes them with it.
List<int> ownTradingViewPidsToKill(List<TradingViewProcess> processes, int port) {
  bool isOurs(String commandLine) {
    final debugPort = RegExp(r'--remote-debugging-port=(\d+)').firstMatch(commandLine);
    if (debugPort != null) return int.parse(debugPort.group(1)!) == port;
    return !commandLine.contains('--type=') && !commandLine.contains('--user-data-dir');
  }

  final ours = {
    for (final p in processes)
      if (p.commandLine != null && isOurs(p.commandLine!)) p.pid: p,
  };
  return [
    for (final p in ours.values)
      if (!ours.containsKey(p.parentPid)) p.pid,
  ];
}

/// Every running [imageName] process with its command line, or null if Windows
/// couldn't be asked.
Future<List<TradingViewProcess>?> _listWindowsProcesses(String imageName) async {
  try {
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      "ConvertTo-Json -Compress -InputObject @(Get-CimInstance Win32_Process -Filter 'Name=''$imageName''' "
          '| Select-Object ProcessId,ParentProcessId,CommandLine)',
    ]).timeout(const Duration(seconds: 15));
    if (result.exitCode != 0) return null;
    return [
      for (final p in (jsonDecode(result.stdout as String) as List).cast<Map<String, dynamic>>())
        TradingViewProcess(
          pid: (p['ProcessId'] as num).toInt(),
          parentPid: (p['ParentProcessId'] as num).toInt(),
          commandLine: p['CommandLine'] as String?,
        ),
    ];
  } catch (_) {
    return null;
  }
}

/// Kills this app's own TradingView and no other instance - see
/// [ownTradingViewPidsToKill]. VERIFIES it's actually gone afterward and retries
/// a few times (2026-10-16, per the user, after a real Windows stall: the
/// engine's "TradingView not ready" check failed in a loop for roughly 10 hours
/// with no recovery, matching exactly what happens if `taskkill` silently fails
/// and nothing notices). Returns true only once none of ours is left running.
Future<bool> taskkillOwnTradingView(
  String binaryPath,
  int port, {
  void Function(String message, {String? level})? onLog,
}) async {
  final imageName = binaryPath.split(RegExp(r'[\\/]')).last;
  for (var attempt = 1; attempt <= 3; attempt++) {
    final processes = await _listWindowsProcesses(imageName);
    if (processes == null) {
      onLog?.call(
        'Could not list $imageName processes (attempt $attempt/3) - killing nothing.',
        level: 'WARNING',
      );
    } else {
      final pids = ownTradingViewPidsToKill(processes, port);
      if (pids.isEmpty) return true;
      for (final pid in pids) {
        try {
          final result = await Process.run('taskkill', ['/F', '/T', '/PID', '$pid']);
          onLog?.call(
            'TradingView kill: taskkill /F /T /PID $pid exited ${result.exitCode} (attempt $attempt/3)'
            '${result.exitCode == 0 ? '' : ': ${(result.stderr as String).trim()}'}',
            level: result.exitCode == 0 ? 'INFO' : 'WARNING',
          );
        } catch (e) {
          onLog?.call('TradingView kill: PID $pid threw (attempt $attempt/3): $e', level: 'WARNING');
        }
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  final left = await _listWindowsProcesses(imageName);
  if (left != null && ownTradingViewPidsToKill(left, port).isEmpty) return true;
  onLog?.call(
    'TradingView kill: could not stop this app\'s TradingView (port $port) after 3 attempts - '
    'it may need admin rights or manual intervention (check Task Manager).',
    level: 'CRITICAL',
  );
  return false;
}

/// PIDs owning the server side of TCP [port], parsed from `netstat -ano -p
/// TCP` output: any row whose LOCAL address is `...:port`, in any state
/// (`TCP  127.0.0.1:9222  127.0.0.1:59103  ESTABLISHED  9548`). Not just
/// LISTENING rows - confirmed live 2026-10-30 on this PC that netstat omits
/// the LISTENING rows for TradingView's 9222 and MT5's 22346 entirely while
/// still showing their connected sockets with the right PID.
List<int> parseNetstatPortOwnerPids(String netstatOutput, int port) {
  final pids = <int>{};
  for (final line in netstatOutput.split(RegExp(r'\r?\n'))) {
    final f = line.trim().split(RegExp(r'\s+'));
    if (f.length < 5 || f[0].toUpperCase() != 'TCP') continue;
    if (!f[1].endsWith(':$port')) continue;
    final pid = int.tryParse(f[4]);
    if (pid != null && pid > 0) pids.add(pid);
  }
  return pids.toList();
}

/// The process(es) actually holding [port] on Windows, as `pid -> image
/// name` (name null if it couldn't be read). Holds its own connection open
/// while reading netstat so there is always a server-side row to find.
Future<Map<int, String?>> windowsProcessesListeningOn(int port) async {
  Socket? probe;
  try {
    probe = await Socket.connect('127.0.0.1', port, timeout: const Duration(seconds: 2));
  } catch (_) {}
  final ProcessResult result;
  try {
    result = await Process.run('netstat', ['-ano', '-p', 'TCP']);
  } finally {
    probe?.destroy();
  }
  final out = <int, String?>{};
  for (final pid in parseNetstatPortOwnerPids(result.stdout as String, port)) {
    String? name;
    try {
      final r = await Process.run('tasklist', ['/FI', 'PID eq $pid', '/FO', 'CSV', '/NH']);
      final first = (r.stdout as String).trim().split(RegExp(r'\r?\n')).first;
      if (first.startsWith('"')) name = first.split('","').first.replaceAll('"', '');
    } catch (_) {}
    out[pid] = name;
  }
  return out;
}

/// Kills TradingView by whatever actually holds its CDP [port] - found live
/// 2026-10-29: `taskkill /IM TradingView.exe` said "not found" 16 times in a
/// row while the port kept answering, so the name-based kill never reached
/// the stuck process. Kills only processes whose image name contains
/// "tradingview" (never some unrelated program that happens to own the
/// port), with `/T` so its children go too. Returns the PIDs it killed.
Future<List<int>> taskkillTradingViewByPort(
  int port, {
  void Function(String message, {String? level})? onLog,
}) async {
  final killed = <int>[];
  final holders = await windowsProcessesListeningOn(port);
  if (holders.isEmpty) {
    onLog?.call('TradingView kill by port: nothing is listening on $port.');
    return killed;
  }
  for (final entry in holders.entries) {
    final name = entry.value ?? '?';
    if (!name.toLowerCase().contains('tradingview')) {
      onLog?.call(
        'TradingView kill by port: port $port is held by $name (pid ${entry.key}), '
        'not TradingView - leaving it alone.',
        level: 'CRITICAL',
      );
      continue;
    }
    final r = await Process.run('taskkill', ['/F', '/T', '/PID', '${entry.key}']);
    onLog?.call(
      'TradingView kill by port: taskkill /F /T /PID ${entry.key} ($name) exited ${r.exitCode}'
      '${r.exitCode == 0 ? '' : ': ${(r.stderr as String).trim()}'}',
      level: r.exitCode == 0 ? 'INFO' : 'WARNING',
    );
    if (r.exitCode == 0) killed.add(entry.key);
  }
  return killed;
}

/// Kills TradingView Desktop if it's running, and waits until CDP stops
/// responding (or gives up after [timeout]) so the caller knows the process
/// is actually gone before reporting success.
Future<bool> stopTradingView(
  String host,
  int port,
  LaunchConfig config, {
  Duration timeout = const Duration(seconds: 15),
  void Function(String message, {String? level})? onLog,
}) async {
  if (Platform.isWindows) {
    await taskkillOwnTradingView(config.binaryPath, port, onLog: onLog);
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
