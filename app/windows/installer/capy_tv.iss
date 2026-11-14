; Capy TV's installer for Windows, made with Inno Setup 6 by tool/build_windows.sh, which passes:
;   Version  the app's version (pubspec.yaml), such as 0.1.0
;   Build    its build number, the same as the APKs of that release
;   Source   the folder flutter build windows made (build\windows\x64\runner\Release)
;   Output   where CapyTV-Setup.exe goes
;
; For the person using the computer alone, so it asks for no administrator: in
; %LOCALAPPDATA%\Programs\Capy TV, with a Start menu entry, a desktop one if wanted, and an
; uninstaller. Installed again over itself (an update, which the app downloads from the sync
; server and runs with /SILENT), it closes the app, replaces the program and opens it again. What
; the app keeps (playlists, settings, recordings) lives apart from the program, and stays.

#ifndef Version
  #error Pass /DVersion=...
#endif
#ifndef Build
  #error Pass /DBuild=...
#endif

[Setup]
; Never changes: Windows knows the app by it, and an update goes over the same install
AppId={{7D8519EC-773A-4C39-A7C4-FC48F49F6D80}
AppName=Capy TV
AppVersion={#Version} ({#Build})
AppVerName=Capy TV {#Version} ({#Build})
AppPublisher=Capy TV
VersionInfoVersion={#Version}.{#Build}
DefaultDirName={localappdata}\Programs\Capy TV
DefaultGroupName=Capy TV
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\capy_tv.exe
UninstallDisplayName=Capy TV
OutputDir={#Output}
OutputBaseFilename=CapyTV-Setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; An update closes the app that is running; the app also closes itself as it starts one
CloseApplications=force
RestartApplications=no

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "es"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
; The program's own files of the version before, so none it no longer has is left behind
Type: filesandordirs; Name: "{app}\data"

[Files]
Source: "{#Source}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Capy TV"; Filename: "{app}\capy_tv.exe"
Name: "{autodesktop}\Capy TV"; Filename: "{app}\capy_tv.exe"; Tasks: desktopicon

[Run]
; Offered at the end of an install by hand; run by itself after an update (/SILENT)
Filename: "{app}\capy_tv.exe"; Description: "{cm:LaunchProgram,Capy TV}"; Flags: nowait postinstall
