#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef SourceDir
  #error SourceDir is required
#endif
#ifndef OutputDir
  #error OutputDir is required
#endif
#ifndef OutputBase
  #error OutputBase is required
#endif

[Setup]
; Keep this identity stable so updates reuse the installation and uninstall entry.
AppId={{8F3A1C2E-6B47-4D91-9E5A-2C7B0A4D6F18}
AppName=Resona
AppVersion={#AppVersion}
AppPublisher=Resona
DefaultDirName={autopf}\Resona
DefaultGroupName=Resona
DisableProgramGroupPage=yes
DisableDirPage=auto
UsePreviousAppDir=yes
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBase}
SetupIconFile=runner\resources\app_icon.ico
UninstallDisplayIcon={app}\Resona.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
PrivilegesRequired=admin
CloseApplications=yes
RestartApplications=no
SetupMutex=ResonaSetup
VersionInfoVersion={#AppVersion}
VersionInfoProductVersion={#AppVersion}
VersionInfoProductTextVersion={#AppVersion}
VersionInfoDescription=Resona Setup

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "*.pdb"

[Icons]
Name: "{group}\Resona"; Filename: "{app}\Resona.exe"
Name: "{autodesktop}\Resona"; Filename: "{app}\Resona.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\Resona.exe"; Description: "{cm:LaunchProgram,Resona}"; Flags: nowait postinstall skipifsilent; Check: not DesktopShellElevated
Filename: "{app}\Resona.exe"; Description: "{cm:LaunchProgram,Resona}"; Flags: nowait postinstall skipifsilent runascurrentuser; Check: DesktopShellElevated

[Code]
function DesktopWindow: HWND;
  external 'GetShellWindow@user32.dll stdcall';
function WindowProcessId(Window: HWND; var ProcessId: LongWord): LongWord;
  external 'GetWindowThreadProcessId@user32.dll stdcall';
function QueryProcess(Access: LongWord; Inherit: Boolean; ProcessId: LongWord): THandle;
  external 'OpenProcess@kernel32.dll stdcall';
function QueryProcessToken(Process: THandle; Access: LongWord; var Token: THandle): Boolean;
  external 'OpenProcessToken@advapi32.dll stdcall';
function QueryTokenElevation(Token: THandle; InfoClass: Integer;
  var Elevated: LongWord; BufferSize: LongWord; var RequiredSize: LongWord): Boolean;
  external 'GetTokenInformation@advapi32.dll stdcall';
function ReleaseHandle(Handle: THandle): Boolean;
  external 'CloseHandle@kernel32.dll stdcall';

function DesktopShellElevated: Boolean;
var
  ProcessId, Elevated, RequiredSize: LongWord;
  Process, Token: THandle;
begin
  Result := False;
  if WindowProcessId(DesktopWindow, ProcessId) = 0 then Exit;
  Process := QueryProcess($1000, False, ProcessId);
  if Process = 0 then Exit;
  try
    if not QueryProcessToken(Process, $0008, Token) then Exit;
    try
      Elevated := 0;
      { A lower-integrity client cannot register an icon with an elevated shell. }
      Result := QueryTokenElevation(Token, 20, Elevated, SizeOf(Elevated),
        RequiredSize) and (Elevated <> 0);
    finally
      ReleaseHandle(Token);
    end;
  finally
    ReleaseHandle(Process);
  end;
end;

function InitializeSetup: Boolean;
var
  Installed: String;
  InstalledVersion, PackageVersion: Int64;
begin
  Result := True;
  if RegQueryStringValue(HKLM64,
    'Software\Microsoft\Windows\CurrentVersion\Uninstall\{8F3A1C2E-6B47-4D91-9E5A-2C7B0A4D6F18}_is1',
    'DisplayVersion', Installed) then
  begin
    if not StrToVersion(Installed, InstalledVersion) then
    begin
      SuppressibleMsgBox('Cannot read the installed Resona version. Repair or uninstall it before continuing.', mbError, MB_OK, IDOK);
      Result := False;
    end
    else if StrToVersion('{#AppVersion}', PackageVersion) and
      (ComparePackedVersion(InstalledVersion, PackageVersion) > 0) then
    begin
      SuppressibleMsgBox('A newer Resona version is already installed. Please use a newer installer.', mbError, MB_OK, IDOK);
      Result := False;
    end;
  end;
end;
