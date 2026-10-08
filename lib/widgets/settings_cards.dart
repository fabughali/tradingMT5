import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/core_constants.dart';
import '../data/backup/backup_service.dart';
import '../data/mt5/mt5_client.dart';
import '../data/net/connectivity.dart';
import '../data/providers/app_providers.dart';
import '../data/tradingview/launch.dart';

/// Settings screen (2026-10-03, per the user: "i dont like the design of
/// setting screen ... re-design ... make each section as card", then
/// revised same day: "dont make wrapped cards. make once card, name it
/// 'connections', and each section has a devide line with spacing...
/// another card for theme... another for app version") — three cards
/// total: [AppearanceCard], [ConnectionsCard] (TradingView/MT5/Internet as
/// divided sections within ONE card, not three separate cards), and
/// [AboutCard].
class _SettingsCard extends StatelessWidget {
  const _SettingsCard({required this.icon, required this.title, required this.child});

  final IconData icon;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: scheme.primary),
                const SizedBox(width: 10),
                Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

enum _TestState { idle, testing, success, failure }

/// Shared Test(+Save) row — one consistent control vocabulary across every
/// connection section. [onSave] is null to hide the Save button entirely
/// (the Internet section has nothing to save); when non-null, the caller
/// controls enabled/disabled via [saveEnabled] (2026-10-03, per the user:
/// "save button should be deactive if there is not change").
class _TestRow extends StatelessWidget {
  const _TestRow({
    required this.state,
    required this.onTest,
    this.message,
    this.onSave,
    this.saveEnabled = true,
  });

  final _TestState state;
  final String? message;
  final VoidCallback onTest;
  final VoidCallback? onSave;
  final bool saveEnabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Color? msgColor;
    IconData? icon;
    switch (state) {
      case _TestState.idle:
      case _TestState.testing:
        break;
      case _TestState.success:
        icon = Icons.check_circle;
        msgColor = Colors.green;
      case _TestState.failure:
        icon = Icons.error;
        msgColor = Colors.red;
    }
    return Row(
      children: [
        OutlinedButton.icon(
          onPressed: state == _TestState.testing ? null : onTest,
          icon: state == _TestState.testing
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.wifi_tethering, size: 16),
          label: const Text('Test'),
        ),
        if (onSave != null) ...[
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: saveEnabled ? onSave : null,
            icon: const Icon(Icons.save, size: 16),
            label: const Text('Save'),
          ),
        ],
        const SizedBox(width: 12),
        if (icon != null) Icon(icon, size: 16, color: msgColor),
        if (message != null)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                message!,
                style: TextStyle(color: msgColor ?? scheme.onSurfaceVariant, fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
      ],
    );
  }
}

class AppearanceCard extends ConsumerWidget {
  const AppearanceCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    return _SettingsCard(
      icon: Icons.palette_outlined,
      title: 'Appearance',
      child: SegmentedButton<AppThemeMode>(
        segments: const [
          ButtonSegment(value: AppThemeMode.system, label: Text('System')),
          ButtonSegment(value: AppThemeMode.light, label: Text('Light')),
          ButtonSegment(value: AppThemeMode.dark, label: Text('Dark')),
        ],
        selected: {themeMode},
        onSelectionChanged: (s) => ref.read(themeModeProvider.notifier).setMode(s.first),
      ),
    );
  }
}

class ConnectionsCard extends ConsumerStatefulWidget {
  const ConnectionsCard({super.key});

  @override
  ConsumerState<ConnectionsCard> createState() => _ConnectionsCardState();
}

class _ConnectionsCardState extends ConsumerState<ConnectionsCard> {
  late final TextEditingController _tvHostCtrl;
  late final TextEditingController _tvPortCtrl;
  late final TextEditingController _mt5HostCtrl;
  late final TextEditingController _mt5PortCtrl;
  late final TextEditingController _mt5KeyCtrl;
  bool _obscureKey = true;

  // The last-SAVED values, compared against the controllers' live text to
  // decide whether each section's Save button should be enabled at all
  // (2026-10-03, per the user: "save button should be deactive if there is
  // not change"). Updated on load and after every successful save.
  late String _tvHostSaved;
  late String _tvPortSaved;
  late String _mt5HostSaved;
  late String _mt5PortSaved;
  late String _mt5KeySaved;

  _TestState _tvState = _TestState.idle;
  String? _tvMessage;
  _TestState _mt5State = _TestState.idle;
  String? _mt5Message;
  _TestState _netState = _TestState.idle;
  String? _netMessage;

  @override
  void initState() {
    super.initState();
    final repo = ref.read(controlRepositoryProvider);
    final config = repo.currentConfig;
    _tvHostSaved = config.cdp.host;
    _tvPortSaved = config.cdp.port.toString();
    _mt5HostSaved = config.mt5.mcpHost;
    _mt5PortSaved = config.mt5.mcpPort.toString();
    _mt5KeySaved = repo.currentMt5ApiKey;

    _tvHostCtrl = TextEditingController(text: _tvHostSaved)..addListener(_onFieldChanged);
    _tvPortCtrl = TextEditingController(text: _tvPortSaved)..addListener(_onFieldChanged);
    _mt5HostCtrl = TextEditingController(text: _mt5HostSaved)..addListener(_onFieldChanged);
    _mt5PortCtrl = TextEditingController(text: _mt5PortSaved)..addListener(_onFieldChanged);
    _mt5KeyCtrl = TextEditingController(text: _mt5KeySaved)..addListener(_onFieldChanged);
  }

  void _onFieldChanged() => setState(() {});

  @override
  void dispose() {
    _tvHostCtrl.dispose();
    _tvPortCtrl.dispose();
    _mt5HostCtrl.dispose();
    _mt5PortCtrl.dispose();
    _mt5KeyCtrl.dispose();
    super.dispose();
  }

  bool get _tvDirty => _tvHostCtrl.text != _tvHostSaved || _tvPortCtrl.text != _tvPortSaved;
  bool get _mt5Dirty =>
      _mt5HostCtrl.text != _mt5HostSaved ||
      _mt5PortCtrl.text != _mt5PortSaved ||
      _mt5KeyCtrl.text != _mt5KeySaved;

  Future<void> _testTradingView() async {
    setState(() {
      _tvState = _TestState.testing;
      _tvMessage = null;
    });
    final port = int.tryParse(_tvPortCtrl.text.trim());
    if (port == null) {
      setState(() {
        _tvState = _TestState.failure;
        _tvMessage = 'Invalid port number';
      });
      return;
    }
    final ok = await isCdpUp(_tvHostCtrl.text.trim(), port);
    if (!mounted) return;
    setState(() {
      _tvState = ok ? _TestState.success : _TestState.failure;
      _tvMessage = ok ? 'Reachable.' : 'Could not reach TradingView\'s debug port.';
    });
  }

  Future<void> _testMt5() async {
    setState(() {
      _mt5State = _TestState.testing;
      _mt5Message = null;
    });
    final port = int.tryParse(_mt5PortCtrl.text.trim());
    if (port == null) {
      setState(() {
        _mt5State = _TestState.failure;
        _mt5Message = 'Invalid port number';
      });
      return;
    }
    final client = Mt5Client(apiKey: _mt5KeyCtrl.text.trim(), host: _mt5HostCtrl.text.trim(), port: port);
    try {
      await client.connect();
      await client.getAccountInfo();
      if (!mounted) return;
      setState(() {
        _mt5State = _TestState.success;
        _mt5Message = 'Connected and authenticated.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _mt5State = _TestState.failure;
        _mt5Message = '$e';
      });
    } finally {
      client.close();
    }
  }

  Future<void> _testInternet() async {
    setState(() {
      _netState = _TestState.testing;
      _netMessage = null;
    });
    final ok = await hasInternetConnection();
    if (!mounted) return;
    setState(() {
      _netState = ok ? _TestState.success : _TestState.failure;
      _netMessage = ok ? 'Internet reachable.' : 'No internet connection detected.';
    });
  }

  void _saveTradingView() {
    final port = int.tryParse(_tvPortCtrl.text.trim());
    if (port == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invalid port number.')));
      return;
    }
    ref.read(controlRepositoryProvider).updateCdpConfig(host: _tvHostCtrl.text.trim(), port: port);
    setState(() {
      _tvHostSaved = _tvHostCtrl.text;
      _tvPortSaved = _tvPortCtrl.text;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Saved. Restart the engine for this to take effect.')),
    );
  }

  void _saveMt5() {
    final port = int.tryParse(_mt5PortCtrl.text.trim());
    if (port == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invalid port number.')));
      return;
    }
    final repo = ref.read(controlRepositoryProvider);
    repo.updateMt5Config(host: _mt5HostCtrl.text.trim(), port: port);
    repo.updateMt5ApiKey(_mt5KeyCtrl.text.trim());
    setState(() {
      _mt5HostSaved = _mt5HostCtrl.text;
      _mt5PortSaved = _mt5PortCtrl.text;
      _mt5KeySaved = _mt5KeyCtrl.text;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Saved. Restart the engine for this to take effect.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _SettingsCard(
      icon: Icons.cable,
      title: 'Connections',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'TradingView',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _tvHostCtrl,
                  decoration: const InputDecoration(labelText: 'Host / IP', isDense: true),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _tvPortCtrl,
                  decoration: const InputDecoration(labelText: 'Port', isDense: true),
                  keyboardType: TextInputType.number,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _TestRow(
            state: _tvState,
            message: _tvMessage,
            onTest: _testTradingView,
            onSave: _saveTradingView,
            saveEnabled: _tvDirty,
          ),
          const SizedBox(height: 20),
          const Divider(height: 1),
          const SizedBox(height: 20),
          Text(
            'MT5',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _mt5HostCtrl,
                  decoration: const InputDecoration(labelText: 'Host / IP', isDense: true),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _mt5PortCtrl,
                  decoration: const InputDecoration(labelText: 'Port', isDense: true),
                  keyboardType: TextInputType.number,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _mt5KeyCtrl,
            obscureText: _obscureKey,
            decoration: InputDecoration(
              labelText: 'MCP API Key',
              isDense: true,
              suffixIcon: IconButton(
                icon: Icon(_obscureKey ? Icons.visibility : Icons.visibility_off, size: 18),
                onPressed: () => setState(() => _obscureKey = !_obscureKey),
              ),
            ),
          ),
          const SizedBox(height: 10),
          _TestRow(
            state: _mt5State,
            message: _mt5Message,
            onTest: _testMt5,
            onSave: _saveMt5,
            saveEnabled: _mt5Dirty,
          ),
          const SizedBox(height: 20),
          const Divider(height: 1),
          const SizedBox(height: 20),
          Text(
            'Internet',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          _TestRow(state: _netState, message: _netMessage, onTest: _testInternet),
        ],
      ),
    );
  }
}

enum _BackupOpState { idle, working }

/// Settings card (2026-10-03, per the user: "export setting and all data
/// related to current user ... user can setup this app in different
/// machine and then import this data ... everything is settled and user
/// can continue from the timestamp of file extraction date" + "the
/// exported file should be encrypted, with high security level") — a plain
/// path text field rather than a native file-picker dialog, since
/// `file_picker`'s Linux plugin needs a symlink to build and this project
/// lives on a `vfat` (FAT32) partition, which can't hold one.
class BackupRestoreCard extends ConsumerStatefulWidget {
  const BackupRestoreCard({super.key});

  @override
  ConsumerState<BackupRestoreCard> createState() => _BackupRestoreCardState();
}

class _BackupRestoreCardState extends ConsumerState<BackupRestoreCard> {
  late final TextEditingController _exportPathCtrl;
  late final TextEditingController _importPathCtrl;
  _BackupOpState _exportState = _BackupOpState.idle;
  _BackupOpState _importState = _BackupOpState.idle;
  String? _exportMessage;
  Color? _exportMessageColor;
  String? _importMessage;
  Color? _importMessageColor;

  @override
  void initState() {
    super.initState();
    // 2026-10-03, per the user: "create a app backup folder in the root" -
    // defaults exports into CoreStorage.backupsDir instead of bare $HOME,
    // and ensures that folder actually exists right now rather than lazily
    // on first export.
    final storage = ref.read(storageProvider);
    storage.ensureDir(storage.backupsDir);
    final stamp = DateTime.now().toIso8601String().split('T').first;
    _exportPathCtrl = TextEditingController(text: '${storage.backupsDir}/tradingmt5-backup-$stamp.tmt5');
    _importPathCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _exportPathCtrl.dispose();
    _importPathCtrl.dispose();
    super.dispose();
  }

  /// Prompts for a password, with a confirmation field when [confirm] is
  /// true (export - a typo in a password nobody can recover from otherwise
  /// matters a lot more than a typo on import, which just fails cleanly
  /// with "wrong password"). Returns null if cancelled or the two fields
  /// didn't match.
  Future<String?> _promptPassword({required bool confirm}) async {
    final passwordCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          var obscure = true;
          return StatefulBuilder(
            builder: (context, setObscureState) => AlertDialog(
              title: Text(confirm ? 'Set a backup password' : 'Enter backup password'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (confirm)
                    Text(
                      'This password encrypts the backup file. There is no way to recover it '
                      'without this password — store it somewhere safe.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: passwordCtrl,
                    obscureText: obscure,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      isDense: true,
                      suffixIcon: IconButton(
                        icon: Icon(obscure ? Icons.visibility : Icons.visibility_off, size: 18),
                        onPressed: () => setObscureState(() => obscure = !obscure),
                      ),
                    ),
                  ),
                  if (confirm) ...[
                    const SizedBox(height: 10),
                    TextField(
                      controller: confirmCtrl,
                      obscureText: obscure,
                      decoration: const InputDecoration(labelText: 'Confirm password', isDense: true),
                      onSubmitted: (_) => Navigator.of(context).pop(passwordCtrl.text),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(onPressed: () => Navigator.of(context).pop(null), child: const Text('Cancel')),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(passwordCtrl.text),
                  child: const Text('Continue'),
                ),
              ],
            ),
          );
        },
      ),
    );
    if (result == null || result.isEmpty) return null;
    if (confirm && result != confirmCtrl.text) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Passwords did not match.')),
        );
      }
      return null;
    }
    return result;
  }

  Future<void> _doExport() async {
    final password = await _promptPassword(confirm: true);
    if (password == null) return;
    setState(() {
      _exportState = _BackupOpState.working;
      _exportMessage = null;
    });
    try {
      await BackupService(ref.read(storageProvider)).exportTo(_exportPathCtrl.text.trim(), password);
      if (!mounted) return;
      setState(() {
        _exportMessage = 'Exported to ${_exportPathCtrl.text.trim()}';
        _exportMessageColor = Colors.green;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _exportMessage = 'Export failed: $e';
        _exportMessageColor = Colors.red;
      });
    } finally {
      if (mounted) setState(() => _exportState = _BackupOpState.idle);
    }
  }

  Future<void> _doImport() async {
    final path = _importPathCtrl.text.trim();
    if (path.isEmpty || !File(path).existsSync()) {
      setState(() {
        _importMessage = 'File not found: $path';
        _importMessageColor = Colors.red;
      });
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Overwrite everything on this machine?'),
        content: const Text(
          'Importing replaces config, connection settings, auto-managed pairs, trade '
          'history, and every other piece of trading state currently on THIS machine '
          'with what\'s in the backup file. This cannot be undone. The app and engine '
          'need a restart afterward to pick up the imported data.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Overwrite'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final password = await _promptPassword(confirm: false);
    if (password == null) return;
    setState(() {
      _importState = _BackupOpState.working;
      _importMessage = null;
    });
    try {
      await BackupService(ref.read(storageProvider)).importFrom(path, password);
      if (!mounted) return;
      setState(() {
        _importMessage = 'Imported. Restart the app and engine now.';
        _importMessageColor = Colors.green;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _importMessage = 'Import failed: wrong password, or not a valid backup file.';
        _importMessageColor = Colors.red;
      });
    } finally {
      if (mounted) setState(() => _importState = _BackupOpState.idle);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _SettingsCard(
      icon: Icons.backup_outlined,
      title: 'Backup & Restore',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Export',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            'Everything needed to continue on another machine - config, connections, '
            'auto-managed pairs, trade history - as one password-encrypted file.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _exportPathCtrl,
            decoration: const InputDecoration(labelText: 'Save to path', isDense: true),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton.icon(
                onPressed: _exportState == _BackupOpState.working ? null : _doExport,
                icon: _exportState == _BackupOpState.working
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.upload, size: 16),
                label: const Text('Export'),
              ),
              const SizedBox(width: 12),
              if (_exportMessage != null)
                Expanded(
                  child: Text(
                    _exportMessage!,
                    style: TextStyle(color: _exportMessageColor ?? scheme.onSurfaceVariant, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          const Divider(height: 1),
          const SizedBox(height: 20),
          Text(
            'Import',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            'Overwrites everything on THIS machine with a backup\'s contents.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _importPathCtrl,
            decoration: const InputDecoration(labelText: 'Backup file path', isDense: true),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _importState == _BackupOpState.working ? null : _doImport,
                icon: _importState == _BackupOpState.working
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.download, size: 16),
                label: const Text('Import'),
              ),
              const SizedBox(width: 12),
              if (_importMessage != null)
                Expanded(
                  child: Text(
                    _importMessage!,
                    style: TextStyle(color: _importMessageColor ?? scheme.onSurfaceVariant, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class AboutCard extends StatelessWidget {
  const AboutCard({super.key});

  /// Reads the real version straight out of pubspec.yaml itself, bundled
  /// as a plain asset (2026-10-08, per the user: "why app version still
  /// fixed?? ... is exe file matching with linux?" - found live: the
  /// PREVIOUS version of this card showed a hand-typed string constant
  /// that was supposed to be "kept in sync with pubspec.yaml" manually on
  /// every bump - it was updated exactly once, at `1.0.0+1`, and silently
  /// drifted for every release after that (1.1.0 through 1.2.2) since
  /// nothing ever enforced the sync. `package_info_plus` would normally be
  /// the standard fix, but this project's working directory sits on a
  /// FAT32-formatted drive, which doesn't support symlinks at all -
  /// Flutter's native-plugin build step needs one for ANY plugin with real
  /// platform code and fails outright here. Reading pubspec.yaml's own
  /// `version:` line back out of the asset bundle needs no native plugin
  /// and no symlink, and is still a single source of truth - there is no
  /// second copy left to drift from here on.
  Future<String> _readVersion() async {
    final text = await rootBundle.loadString('pubspec.yaml');
    final match = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(text);
    return match?.group(1) ?? 'unknown';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _SettingsCard(
      icon: Icons.info_outline,
      title: 'About',
      child: FutureBuilder<String>(
        future: _readVersion(),
        builder: (context, snapshot) {
          final versionText = snapshot.data == null ? 'version …' : 'version ${snapshot.data}';
          return Text(
            '${CoreConstants.appName} · $versionText',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          );
        },
      ),
    );
  }
}
