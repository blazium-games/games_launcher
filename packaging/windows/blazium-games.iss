; Blazium Games launcher.
; Root: {autopf}\Blazium Games. Does not install into {autopf}\Blazium and does not delete Hub files.
;
; /NOCLI is the silent default and registers this launcher for blazium:// when blazium-cli is absent.
; /INSTALLCLI copies blazium-cli from /CLISOURCE, or from the Hub install directory when that is empty.
; The protocol is pointed at that copy only when blazium-cli is not already on PATH, in Hub, or in BLAZIUM.
; {app} is added to PATH so games.cmd can start chauffeur.exe. Uninstall removes that PATH entry.
; /INSTALLHUB is off unless passed. It runs a Hub installer from /HUBSETUP. It does not invent a download URL.

#define MyAppName "Blazium Games"
#ifndef MyAppVersion
  #define MyAppVersion "0.1.0"
#endif
#define MyAppPublisher "Blazium Games"
#define MyAppURL "https://blazium.games"
#define MyAppExeName "BlaziumGames.exe"
#ifndef MyAppSourceDir
  #define MyAppSourceDir "..\..\export"
#endif

[Setup]
AppId={{B1A21E00-6A4E-4C3A-9F10-6A7E1A0C4D21}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
DefaultDirName={autopf}\Blazium Games
DefaultGroupName=Blazium Games
OutputDir=Output
OutputBaseFilename=BlaziumGames-Setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
ChangesAssociations=yes
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "installcli"; Description: "Install blazium-cli into this folder and let it handle blazium:// links"; GroupDescription: "Optional tools:"; Flags: unchecked
Name: "installhub"; Description: "Run the Blazium Hub installer from a packager-supplied setup"; GroupDescription: "Optional tools:"; Flags: unchecked

[Files]
Source: "{#MyAppSourceDir}\BlaziumGames.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#MyAppSourceDir}\chauffeur.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "games.cmd"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Blazium Games"; Filename: "{app}\{#MyAppExeName}"

[Code]
const
  EnvironmentKey = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment';

var
  CliSource: String;
  HubSetup: String;

function FileOnPath(FileName: String): Boolean;
var
  Path, Dir: String;
  P: Integer;
begin
  Result := False;
  Path := GetEnv('PATH');
  while Path <> '' do
  begin
    P := Pos(';', Path);
    if P > 0 then
    begin
      Dir := Copy(Path, 1, P - 1);
      Path := Copy(Path, P + 1, Length(Path));
    end
    else
    begin
      Dir := Path;
      Path := '';
    end;
    if (Dir <> '') and FileExists(AddBackslash(Dir) + FileName) then
    begin
      Result := True;
      exit;
    end;
  end;
end;

function CliDirFrom(Root: String): String;
begin
  Result := '';
  if Root = '' then
    exit;
  if FileExists(AddBackslash(Root) + 'blazium-cli.exe') then
    Result := Root
  else if FileExists(AddBackslash(Root) + 'bin\blazium-cli.exe') then
    Result := AddBackslash(Root) + 'bin';
end;

function HubCliDir: String;
var
  Root: String;
begin
  Result := '';
  if RegQueryStringValue(HKLM, EnvironmentKey, 'BLAZIUM', Root) then
    Result := CliDirFrom(Root);
  if Result <> '' then
    exit;
  Result := CliDirFrom(ExpandConstant('{autopf}\Blazium'));
end;

function CliAlreadyInstalled: Boolean;
begin
  Result := FileOnPath('blazium-cli.exe') or (HubCliDir <> '') or RegKeyExists(HKLM, 'SOFTWARE\Blazium\Hub');
end;

function NeedsAddPath(Path: string): Boolean;
var
  OrigPath: string;
begin
  if not RegQueryStringValue(HKLM, EnvironmentKey, 'Path', OrigPath) then
  begin
    Result := True;
    exit;
  end;
  Result := Pos(';' + Uppercase(Path) + ';', ';' + Uppercase(OrigPath) + ';') = 0;
end;

procedure EnvAddPath(Path: string);
var
  Paths: string;
begin
  if not NeedsAddPath(Path) then
    exit;
  if not RegQueryStringValue(HKLM, EnvironmentKey, 'Path', Paths) then
    Paths := '';
  if Paths <> '' then
    Paths := Paths + ';' + Path
  else
    Paths := Path;
  RegWriteExpandStringValue(HKLM, EnvironmentKey, 'Path', Paths);
end;

procedure EnvRemovePath(Path: string);
var
  Paths: string;
  P: Integer;
begin
  if not RegQueryStringValue(HKLM, EnvironmentKey, 'Path', Paths) then
    exit;
  P := Pos(';' + Uppercase(Path) + ';', ';' + Uppercase(Paths) + ';');
  if P = 0 then
    exit;
  Delete(Paths, P, Length(Path) + 1);
  while (Length(Paths) > 0) and (Paths[1] = ';') do
    Delete(Paths, 1, 1);
  while (Length(Paths) > 0) and (Paths[Length(Paths)] = ';') do
    Delete(Paths, Length(Paths), 1);
  RegWriteExpandStringValue(HKLM, EnvironmentKey, 'Path', Paths);
end;

function InitializeSetup: Boolean;
var
  I: Integer;
  Arg: String;
begin
  Result := True;
  CliSource := ExpandConstant('{param:CLISOURCE}');
  HubSetup := ExpandConstant('{param:HUBSETUP}');
  for I := 1 to ParamCount do
  begin
    Arg := Uppercase(ParamStr(I));
    if Arg = '/NOCLI' then
      WizardSelectTasks('');
    if Arg = '/INSTALLCLI' then
      WizardSelectTasks('installcli');
    if Arg = '/INSTALLHUB' then
      WizardSelectTasks('installhub');
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Handler, Source: String;
  ResultCode: Integer;
  Already: Boolean;
begin
  if CurStep <> ssPostInstall then
    exit;
  if WizardIsTaskSelected('installhub') and (HubSetup <> '') and FileExists(HubSetup) then
    Exec(HubSetup, '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART', '', SW_SHOW, ewWaitUntilTerminated, ResultCode);
  Already := CliAlreadyInstalled;
  Handler := '';
  if WizardIsTaskSelected('installcli') then
  begin
    Source := CliSource;
    if Source = '' then
      Source := HubCliDir;
    if (Source <> '') and FileExists(AddBackslash(Source) + 'blazium-cli.exe') then
    begin
      CopyFile(AddBackslash(Source) + 'blazium-cli.exe', ExpandConstant('{app}\blazium-cli.exe'), False);
      if FileExists(AddBackslash(Source) + 'crash_reporter.exe') then
        CopyFile(AddBackslash(Source) + 'crash_reporter.exe', ExpandConstant('{app}\crash_reporter.exe'), False);
      if not Already then
        Handler := '"' + ExpandConstant('{app}\blazium-cli.exe') + '" handle-uri "%1"';
    end
    else if not Already then
      Handler := '"' + ExpandConstant('{app}\{#MyAppExeName}') + '" "%1"';
  end
  else if not Already then
    Handler := '"' + ExpandConstant('{app}\{#MyAppExeName}') + '" "%1"';
  EnvAddPath(ExpandConstant('{app}'));
  if Handler <> '' then
  begin
    RegWriteStringValue(HKLM, 'SOFTWARE\Blazium Games', 'ProtocolOwner', '1');
    RegWriteStringValue(HKCR, 'blazium', '', 'URL:Blazium Protocol');
    RegWriteStringValue(HKCR, 'blazium', 'URL Protocol', '');
    RegWriteStringValue(HKCR, 'blazium\shell\open\command', '', Handler);
  end;
  Exec(ExpandConstant('{app}\{#MyAppExeName}'), '--ensure-launcher-remote', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Command: String;
begin
  if CurUninstallStep <> usPostUninstall then
    exit;
  if RegQueryStringValue(HKLM, 'SOFTWARE\Blazium Games', 'ProtocolOwner', Command) then
  begin
    if RegQueryStringValue(HKCR, 'blazium\shell\open\command', '', Command) then
    begin
      if Pos('Blazium Games', Command) > 0 then
        RegDeleteKeyIncludingSubkeys(HKCR, 'blazium');
    end;
    RegDeleteKeyIncludingSubkeys(HKLM, 'SOFTWARE\Blazium Games');
  end;
  EnvRemovePath(ExpandConstant('{app}'));
  DeleteFile(ExpandConstant('{userappdata}\blazium\launcher_remote.json'));
end;
