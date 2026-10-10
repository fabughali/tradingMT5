import 'dart:io';

/// Native "choose where to save"/"choose a file to open" dialogs for the
/// Settings screen's Backup & Restore card (2026-10-10, per the user: "once
/// user choose to export data, app need to make user choose where to export
/// that file by navigation" / "once user need to import data, app need to
/// make user choose the path by navigation").
///
/// Deliberately NOT a Flutter file-picker PLUGIN (`file_picker`/
/// `file_selector`) — this project's working directory sits on a
/// FAT32-formatted drive, which breaks Flutter's native-plugin build step
/// for ANY plugin with real platform code (see `CoreConstants.
/// readAppVersion`'s own doc comment for the identical, already-hit
/// `package_info_plus` precedent). Shelling out to a plain external process
/// — a tool the OS already has, not a compiled-in plugin — needs no plugin
/// registration and no symlink at all, so it sidesteps that constraint
/// entirely rather than working around it.
///
/// - Linux: `zenity` (a standard GTK dialog utility, present on this
///   machine and any typical GNOME/GTK desktop).
/// - Windows: PowerShell's built-in `System.Windows.Forms` dialogs — ships
///   with every Windows version this app targets, no separate install.
///
/// Both return null if the user cancels, OR if the underlying tool isn't
/// available/fails for any reason — the caller (BackupRestoreCard) treats
/// null as "nothing changed," always falling back to whatever path is
/// already typed into the text field, so a machine without zenity/
/// PowerShell still has a fully working (if less convenient) manual path.
Future<String?> pickSaveLocation({
  required String suggestedName,
  required String suggestedDir,
}) {
  if (Platform.isWindows) {
    return _powershellDialog(save: true, suggestedName: suggestedName, suggestedDir: suggestedDir);
  }
  return _zenityDialog(save: true, suggestedName: suggestedName, suggestedDir: suggestedDir);
}

Future<String?> pickOpenFile({required String suggestedDir}) {
  if (Platform.isWindows) {
    return _powershellDialog(save: false, suggestedName: '', suggestedDir: suggestedDir);
  }
  return _zenityDialog(save: false, suggestedName: '', suggestedDir: suggestedDir);
}

Future<String?> _zenityDialog({
  required bool save,
  required String suggestedName,
  required String suggestedDir,
}) async {
  final dir = suggestedDir.endsWith('/') ? suggestedDir : '$suggestedDir/';
  final args = [
    '--file-selection',
    if (save) '--save',
    if (save) '--confirm-overwrite',
    '--filename=$dir$suggestedName',
    '--file-filter=TradingMT5 Backup (*.tmt5) | *.tmt5',
    '--file-filter=All files | *',
  ];
  try {
    final result = await Process.run('zenity', args);
    // zenity exits 1 on Cancel - not an error, just "nothing picked".
    if (result.exitCode != 0) return null;
    final path = (result.stdout as String).trim();
    return path.isEmpty ? null : path;
  } catch (_) {
    return null; // zenity not installed - caller falls back to manual entry.
  }
}

/// Single-quoted PowerShell string literal - doubling an embedded `'` is
/// PowerShell's own escaping rule for that quoting style. Defensive only:
/// every real caller passes an app-generated path (CoreStorage.backupsDir
/// + a filename this app itself builds), never arbitrary user text, so a
/// literal `'` here is not an expected input in practice.
String _psQuote(String s) => "'${s.replaceAll("'", "''")}'";

Future<String?> _powershellDialog({
  required bool save,
  required String suggestedName,
  required String suggestedDir,
}) async {
  final dialogType = save ? 'SaveFileDialog' : 'OpenFileDialog';
  final script = '''
Add-Type -AssemblyName System.Windows.Forms
\$f = New-Object System.Windows.Forms.$dialogType
\$f.InitialDirectory = ${_psQuote(suggestedDir)}
\$f.Filter = 'TradingMT5 Backup (*.tmt5)|*.tmt5|All files (*.*)|*.*'
${save ? '\$f.FileName = ${_psQuote(suggestedName)}' : ''}
if (\$f.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Write-Output \$f.FileName }
''';
  try {
    final result = await Process.run('powershell', ['-NoProfile', '-NonInteractive', '-Command', script]);
    if (result.exitCode != 0) return null;
    final path = (result.stdout as String).trim();
    return path.isEmpty ? null : path;
  } catch (_) {
    return null;
  }
}
