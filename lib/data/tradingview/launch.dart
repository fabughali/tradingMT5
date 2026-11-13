import 'dart:convert';
import 'dart:io';

/// TradingView Desktop launch settings. Windows only (2026-11-13, per the
/// user: "i dont use this app anymore in linux ... remove any linux code"):
/// the Linux Xvfb/X11/.desktop launch path is gone.
class LaunchConfig {
  const LaunchConfig({
    required this.binaryPath,
    this.confirmedInstalled = false,
  });

  final String binaryPath;

  /// True when installation was already positively confirmed through a
  /// channel OTHER than a plain file-existence check (2026-10-11, confirmed
  /// live: a Microsoft Store/Appx install's `WindowsApps` folder carries a
  /// locked-down ACL that can make even [File.existsSync] on the OWNING
  /// user's own file come back false - `Get-ChildItem` on that exact folder
  /// returned nothing for a package the user's own `Get-AppxPackage` query
  /// confirmed was genuinely theirs). When true, [isTradingViewInstalled]
  /// trusts this instead of re-checking the filesystem.
  final bool confirmedInstalled;

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
/// ([PowerHealthState.tradingViewNotInstalled]). One file-existence check,
/// UNLESS [LaunchConfig.confirmedInstalled] is
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

/// Kills this app's own stale TradingView and relaunches it with the CDP
/// debug port open, then waits until the port responds or [timeout] passes.
/// Verified, not fire-and-forget (2026-10-16) - see [taskkillOwnTradingView]:
/// launching a fresh instance right after a kill that silently failed just
/// adds a SECOND process fighting the first one for the same port.
Future<bool> launchTradingView(
  String host,
  int port,
  LaunchConfig config, {
  Duration timeout = const Duration(seconds: 30),
  void Function(String message, {String? level})? onLog,
}) async {
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

/// Whether a TradingView process started with our debug [port] is running
/// (null = couldn't tell). Used so a CDP port that is slow to
/// answer is treated as "maybe stuck", not "not running" - relaunching kills
/// the shared TradingView, TradingPionex's tab included (2026-11-04, v1.6.63).
Future<bool?> isTradingViewRunningOnPort(String binaryPath, int port) async {
  final processes = await _listWindowsProcesses(binaryPath.split(RegExp(r'[\\/]')).last);
  if (processes == null) return null;
  return processes.any((p) => p.commandLine?.contains('--remote-debugging-port=$port') ?? false);
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
  await taskkillOwnTradingView(config.binaryPath, port, onLog: onLog);

  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (!await isCdpUp(host, port)) return true;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  return false;
}
