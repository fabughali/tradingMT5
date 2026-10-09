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

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent
