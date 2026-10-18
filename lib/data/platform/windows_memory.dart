import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart' as pkg_ffi;

/// Windows counterpart to [EngineService]'s `/proc/meminfo` read on Linux
/// (2026-10-18, per the user: "check why ram is not showing same thing in
/// exe as linex in engine card" - the Dashboard's RAM light read Linux's
/// `/proc/meminfo`, which simply doesn't exist on Windows, so the
/// `File(...).readAsStringSync()` call there always threw and the figure
/// was silently null on every Windows install - not a different number,
/// no number at all). Calls the real Win32 system API directly
/// (`GlobalMemoryStatusEx` in `kernel32.dll`) rather than shelling out to
/// `wmic`/PowerShell - this runs on every status write (same cadence as
/// the Linux file read), so it needs to be as cheap as a direct syscall,
/// not a subprocess spawn.
///
/// `MEMORYSTATUSEX` is a stable, unchanged-since-Windows-2000 struct - see
/// https://learn.microsoft.com/windows/win32/api/sysinfoapi/ns-sysinfoapi-memorystatusex
final class _MemoryStatusEx extends ffi.Struct {
  @ffi.Uint32()
  external int dwLength;
  @ffi.Uint32()
  external int dwMemoryLoad;
  @ffi.Uint64()
  external int ullTotalPhys;
  @ffi.Uint64()
  external int ullAvailPhys;
  @ffi.Uint64()
  external int ullTotalPageFile;
  @ffi.Uint64()
  external int ullAvailPageFile;
  @ffi.Uint64()
  external int ullTotalVirtual;
  @ffi.Uint64()
  external int ullAvailVirtual;
  @ffi.Uint64()
  external int ullAvailExtendedVirtual;
}

typedef _GlobalMemoryStatusExNative = ffi.Int32 Function(ffi.Pointer<_MemoryStatusEx>);
typedef _GlobalMemoryStatusExDart = int Function(ffi.Pointer<_MemoryStatusEx>);

_GlobalMemoryStatusExDart? _globalMemoryStatusEx;

/// System-wide total/available RAM in MB, or null off-Windows or if the
/// call fails for any reason (mirrors the Linux read's own null-on-
/// failure contract - never treated as "low" when null, see
/// [EngineStatus.ramOk]).
({int totalMb, int availMb})? readWindowsMemoryMb() {
  if (!Platform.isWindows) return null;
  try {
    _globalMemoryStatusEx ??= ffi.DynamicLibrary.open('kernel32.dll')
        .lookupFunction<_GlobalMemoryStatusExNative, _GlobalMemoryStatusExDart>('GlobalMemoryStatusEx');
    final status = pkg_ffi.calloc<_MemoryStatusEx>();
    try {
      status.ref.dwLength = ffi.sizeOf<_MemoryStatusEx>();
      final ok = _globalMemoryStatusEx!(status);
      if (ok == 0) return null;
      const bytesPerMb = 1024 * 1024;
      return (totalMb: status.ref.ullTotalPhys ~/ bytesPerMb, availMb: status.ref.ullAvailPhys ~/ bytesPerMb);
    } finally {
      pkg_ffi.calloc.free(status);
    }
  } catch (_) {
    return null;
  }
}
