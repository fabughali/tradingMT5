; TradingMT5 Windows installer (2026-10-09, per the user: "i am not looking
; for exe direct run file. i want a setup exe file where it setup all and
; everything on windows") - an Inno Setup script compiled by the Windows CI
; workflow (.github/workflows/windows-build.yml) into a real installer
; (TradingMT5-Setup-<version>.exe), replacing the old "download a zip,
; extract it yourself, double-click the bare exe" flow. Installs the
; already-built Release folder (GUI bundle + the engine exe sitting
; alongside it - both produced by that same workflow's earlier steps) to a
; per-user location, creates Start Menu/Desktop shortcuts, and registers a
; normal Windows uninstaller entry.
;
; ISCC.exe is invoked with /DMyAppVersion=<pubspec.yaml's version> from the
; CI workflow - this file never hardcodes a version, matching the rest of
; the release pipeline's "pubspec.yaml is the one source of truth" rule
; (see PRD.md §18, invariant 15). MyAppVersion defaults to 0.0.0 only so a
; developer can still open/compile this script by hand locally without
; passing the define.
#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif

#define MyAppName "TradingMT5"
#define MyAppExeName "trading_mt5.exe"
#define MyAppPublisher "TradingMT5"

[Setup]
AppId={{011FFED1-07A6-4DD1-88F3-914DABF0969F}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppSupportURL=https://github.com/fabughali/tradingMT5
; Per-user install, no admin/UAC prompt required - same convention the app
; itself already uses for MT5/TradingView's own default Windows install
; paths (LaunchConfig.defaultForWindows / Mt5LaunchConfig.defaultForWindows:
; %LOCALAPPDATA%\Programs\<app>). Keeping the installer consistent with
; that avoids a confusing double-standard (some things need admin, this one
; doesn't).
DefaultDirName={localappdata}\Programs\{#MyAppName}
PrivilegesRequired=lowest
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=..\installer_output
OutputBaseFilename=TradingMT5-Setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\{#MyAppExeName}
ArchitecturesInstallIn64BitMode=x64
; The engine exe and the GUI exe must stay SIBLING files in the install
; directory - EngineControlRepository._enginePath (Windows branch) resolves
; tradingmt5_engine.exe relative to Platform.resolvedExecutable, not a
; hardcoded path. The single [Files] entry below, copying the whole Release
; folder as-is, preserves that automatically.

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional shortcuts:"

[Files]
; Source is the Release folder the CI workflow's own "Build GUI (release)"
; and "Build engine (release)" steps already populated, both the GUI
; bundle (trading_mt5.exe, its DLLs, data\) and tradingmt5_engine.exe -
; relative to THIS script's own directory (windows_installer\), not the
; compiler's invocation directory, per Inno Setup's default path rule.
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; The Microsoft Visual C++ Redistributable (2026-10-09, per the user's real
; first-install error: "the code execution cannot proceed because
; MSVCP140.dll / VCRUNTIME140_1.dll was not found"). Flutter's Windows
; release build links against this runtime but does NOT bundle its DLLs -
; it's present on the GitHub Actions build machine (so the app runs fine
; there and compiles clean) but not guaranteed on an end user's real
; Windows machine at all, which is exactly what happened on the first real
; install this app has ever had. Downloaded fresh by the CI workflow (the
; stable Microsoft-hosted https://aka.ms/vs/17/release/vc_redist.x64.exe
; redirect, never committed to the repo) right before ISCC runs, staged to
; {tmp} (not {app} - it's a one-time system installer, not an app file)
; and deleted the moment setup finishes.
Source: "vc_redist.x64.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
; Silently installs the VC++ runtime BEFORE the app ever tries to launch -
; skipped entirely via [Code]'s VCRedistNeedsInstall check on a machine
; that already has it (most will, from some other app), so repeat/upgrade
; installs stay fast. vc_redist.x64.exe carries its own UAC manifest and
; will show exactly one elevation prompt for this one step, regardless of
; this installer's own PrivilegesRequired=lowest - the rest of the install
; (copying {#MyAppName} itself) stays fully per-user/unelevated either way.
Filename: "{tmp}\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "Installing the Microsoft Visual C++ Runtime (required, one-time)..."; Check: VCRedistNeedsInstall; Flags: waituntilterminated
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent

[Code]
// True when the x64 VC++ 2015-2022 runtime (what every version since VS
// 2015 shares, version 14.x) isn't already installed - checked via the
// same registry key Microsoft's own installers use to detect it. Forces
// the 64-bit registry view (HKLM64) since this is specifically the x64
// runtime's own install marker, distinct from any 32-bit one that might
// also be present.
function VCRedistNeedsInstall: Boolean;
var
  Installed: Cardinal;
begin
  Result := True;
  if RegQueryDWordValue(HKLM64, 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64', 'Installed', Installed) then
  begin
    if Installed = 1 then
      Result := False;
  end;
end;
