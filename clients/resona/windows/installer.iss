#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef BuildNumber
  #error BuildNumber is required
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

; Never change this identity: it is how a newer installer finds the existing copy.
#define AppId "{{8F3A1C2E-6B47-4D91-9E5A-2C7B0A4D6F18}"

[Setup]
AppId={#AppId}
AppName=Resona
AppVersion={#AppVersion}
AppVerName=Resona {#AppVersion}
AppPublisher=Resona
DefaultDirName={autopf}\Resona
DefaultGroupName=Resona
DisableProgramGroupPage=yes
DisableDirPage=auto
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBase}
SetupIconFile=runner\resources\app_icon.ico
UninstallDisplayIcon={app}\Resona.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
MinVersion=10.0
PrivilegesRequired=admin
CloseApplications=yes
RestartApplications=no
SetupMutex=ResonaSetup
VersionInfoVersion={#AppVersion}
VersionInfoProductVersion={#AppVersion}
VersionInfoProductTextVersion={#AppVersion}
VersionInfoCompany=Resona
VersionInfoDescription=Resona Setup

[Languages]
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs; Excludes: "*.pdb"

[Icons]
Name: "{group}\Resona"; Filename: "{app}\Resona.exe"
Name: "{autodesktop}\Resona"; Filename: "{app}\Resona.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\Resona.exe"; Description: "{cm:LaunchProgram,Resona}"; Flags: nowait postinstall skipifsilent

[Code]
function BuildNumber(const Value: String): Integer;
var
  Dot: Integer;
begin
  Dot := LastDelimiter('.', Value);
  Result := StrToIntDef(Copy(Value, Dot + 1, 10), 0);
end;

function InitializeSetup: Boolean;
var
  Installed, Key: String;
begin
  Result := True;
  Key := 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{8F3A1C2E-6B47-4D91-9E5A-2C7B0A4D6F18}_is1';
  if RegQueryStringValue(HKLM, Key, 'DisplayVersion', Installed) and (BuildNumber(Installed) > {#BuildNumber}) then
  begin
    MsgBox('已安装更新的 Resona ' + Installed + '。请使用更新的安装包，不要覆盖安装旧版本。', mbError, MB_OK);
    Result := False;
  end;
end;
