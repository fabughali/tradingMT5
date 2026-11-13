import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart' as pkg_ffi;
import 'package:path/path.dart' as p;

/// Status icon in the Windows notification area, next to the clock
/// (2026-11-14, per the user: "add"). Green = Power on and Ready, amber =
/// on but still checking or a problem, red = Power off; hovering shows the
/// status text. Status only - it has no menu or click action.
///
/// Calls `Shell_NotifyIconW` directly through `dart:ffi` (no tray plugin, so
/// no new native build step). The icons are the app's own assets
/// (`assets/tray/*.ico`), loaded from the installed `data/flutter_assets`.
/// Every failure is swallowed: the icon is a convenience and must never
/// affect the app.
class TrayIcon {
  TrayIcon._();

  static const _nimAdd = 0;
  static const _nimModify = 1;
  static const _nimDelete = 2;
  static const _nifIcon = 0x2;
  static const _nifTip = 0x4;
  static const _imageIcon = 1;
  static const _lrLoadFromFile = 0x10;
  static const _iconId = 1;

  static int _hwnd = 0;
  static bool _added = false;
  static String? _shown;
  static final Map<String, int> _icons = {};

  static final _shell32 = ffi.DynamicLibrary.open('shell32.dll');
  static final _user32 = ffi.DynamicLibrary.open('user32.dll');

  static final _shellNotifyIcon = _shell32.lookupFunction<
      ffi.Int32 Function(ffi.Uint32, ffi.Pointer<_NotifyIconData>),
      int Function(int, ffi.Pointer<_NotifyIconData>)>('Shell_NotifyIconW');

  static final _findWindow = _user32.lookupFunction<
      ffi.IntPtr Function(ffi.Pointer<pkg_ffi.Utf16>, ffi.Pointer<pkg_ffi.Utf16>),
      int Function(ffi.Pointer<pkg_ffi.Utf16>, ffi.Pointer<pkg_ffi.Utf16>)>('FindWindowW');

  static final _loadImage = _user32.lookupFunction<
      ffi.IntPtr Function(ffi.IntPtr, ffi.Pointer<pkg_ffi.Utf16>, ffi.Uint32, ffi.Int32, ffi.Int32, ffi.Uint32),
      int Function(int, ffi.Pointer<pkg_ffi.Utf16>, int, int, int, int)>('LoadImageW');

  /// Shows [colour] ("green", "amber" or "red") with [tip] as hover text.
  /// Only calls Windows when something changed.
  static void show(String colour, String tip) {
    if (!Platform.isWindows) return;
    final key = '$colour|$tip';
    if (key == _shown && _added) return;
    try {
      if (_hwnd == 0) _hwnd = _ownWindow();
      if (_hwnd == 0) return; // window not created yet - next call retries
      final icon = _icons[colour] ??= _loadIcon(colour);
      if (icon == 0) return;
      final data = pkg_ffi.calloc<_NotifyIconData>();
      try {
        data.ref
          ..cbSize = ffi.sizeOf<_NotifyIconData>()
          ..hWnd = _hwnd
          ..uID = _iconId
          ..uFlags = _nifIcon | _nifTip
          ..hIcon = icon;
        final text = tip.length > 127 ? tip.substring(0, 127) : tip;
        for (var i = 0; i < text.length; i++) {
          data.ref.szTip[i] = text.codeUnitAt(i);
        }
        data.ref.szTip[text.length] = 0;
        var ok = _shellNotifyIcon(_added ? _nimModify : _nimAdd, data) != 0;
        // Explorer restarted and dropped our icon: add it again.
        if (!ok && _added) ok = _shellNotifyIcon(_nimAdd, data) != 0;
        if (ok) {
          _added = true;
          _shown = key;
        }
      } finally {
        pkg_ffi.calloc.free(data);
      }
    } catch (_) {}
  }

  /// Removes the icon (on app exit).
  static void remove() {
    if (!_added) return;
    try {
      final data = pkg_ffi.calloc<_NotifyIconData>();
      try {
        data.ref
          ..cbSize = ffi.sizeOf<_NotifyIconData>()
          ..hWnd = _hwnd
          ..uID = _iconId;
        _shellNotifyIcon(_nimDelete, data);
      } finally {
        pkg_ffi.calloc.free(data);
      }
    } catch (_) {}
    _added = false;
    _shown = null;
  }

  static int _ownWindow() {
    final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    final title = 'trading_mt5'.toNativeUtf16();
    try {
      return _findWindow(cls, title);
    } finally {
      pkg_ffi.calloc.free(cls);
      pkg_ffi.calloc.free(title);
    }
  }

  static int _loadIcon(String colour) {
    final file = p.join(p.dirname(Platform.resolvedExecutable), 'data', 'flutter_assets', 'assets', 'tray',
        'tray_$colour.ico');
    if (!File(file).existsSync()) return 0;
    final path = file.toNativeUtf16();
    try {
      return _loadImage(0, path, _imageIcon, 16, 16, _lrLoadFromFile);
    } finally {
      pkg_ffi.calloc.free(path);
    }
  }
}

/// NOTIFYICONDATAW (shellapi.h), full Vista+ layout.
final class _NotifyIconData extends ffi.Struct {
  @ffi.Uint32()
  external int cbSize;
  @ffi.IntPtr()
  external int hWnd;
  @ffi.Uint32()
  external int uID;
  @ffi.Uint32()
  external int uFlags;
  @ffi.Uint32()
  external int uCallbackMessage;
  @ffi.IntPtr()
  external int hIcon;
  @ffi.Array(128)
  external ffi.Array<ffi.Uint16> szTip;
  @ffi.Uint32()
  external int dwState;
  @ffi.Uint32()
  external int dwStateMask;
  @ffi.Array(256)
  external ffi.Array<ffi.Uint16> szInfo;
  @ffi.Uint32()
  external int uVersion;
  @ffi.Array(64)
  external ffi.Array<ffi.Uint16> szInfoTitle;
  @ffi.Uint32()
  external int dwInfoFlags;
  @ffi.Uint32()
  external int guidData1;
  @ffi.Uint16()
  external int guidData2;
  @ffi.Uint16()
  external int guidData3;
  @ffi.Array(8)
  external ffi.Array<ffi.Uint8> guidData4;
  @ffi.IntPtr()
  external int hBalloonIcon;
}
