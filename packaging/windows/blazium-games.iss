; BlaziumLauncher.
; App folder: {autopf}\Blazium\Games. Shared tools live in {autopf}\Blazium.
; Ships chauffeur and, when missing, blazium-cli into the shared root.
; crash_reporter.exe is installed next to BlaziumLauncher.exe.
; Does not delete BlaziumHub's Engine folder.
;
; /NOCLI does not register blazium://. That is how BlaziumHub installs this app
; without replacing its own handler.
; /INSTALLHUB downloads BlaziumHub from https://cdn.blazium.app/hub/hub.json
; unless /HUBSETUP points at a local setup.

#define MyAppName "BlaziumLauncher"
#ifndef MyAppVersion
  #define MyAppVersion "0.1.0"
#endif
#define MyAppPublisher "Blazium Games"
#define MyAppURL "https://blazium.games"
#define MyAppExeName "BlaziumLauncher.exe"
#ifndef MyAppSourceDir
  #define MyAppSourceDir "..\..\export"
#endif

[Setup]
AppId={{B1A21E00-6A4E-4C3A-9F10-6A7E1A0C4D21}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
DefaultDirName={autopf}\Blazium\Games
DefaultGroupName=Blazium
OutputDir=Output
OutputBaseFilename=BlaziumLauncher-Setup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
ChangesAssociations=yes
UninstallDisplayIcon={app}\{#MyAppExeName}
CloseApplications=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "installhub"; Description: "Download and install BlaziumHub into the shared Blazium folder"; GroupDescription: "Optional tools:"; Flags: unchecked

[Files]
Source: "{#MyAppSourceDir}\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#MyAppSourceDir}\crash_reporter.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#MyAppSourceDir}\chauffeur.exe"; DestDir: "{autopf}\Blazium"; Flags: ignoreversion
Source: "{#MyAppSourceDir}\blazium-cli.exe"; DestDir: "{autopf}\Blazium"; Flags: ignoreversion onlyifdoesntexist uninsneveruninstall
Source: "games.cmd"; DestDir: "{autopf}\Blazium"; Flags: ignoreversion uninsneveruninstall

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"

[Code]
const
  EnvironmentKey = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment';
  ProtocolOwnerKey = 'SOFTWARE\BlaziumLauncher';

var
  HubSetup: String;
  SkipProtocol: Boolean;
  CliWasPresent: Boolean;

function SharedRoot: String;
begin
  Result := ExpandConstant('{autopf}\Blazium');
end;

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
  Result := CliDirFrom(SharedRoot);
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

function SaveText(const Path, Contents: String): Boolean;
begin
  Result := SaveStringToFile(Path, Contents, False);
end;

function DownloadToFile(const URL, Dest: String): Boolean;
var
  ResultCode: Integer;
  ScriptPath: String;
begin
  Result := False;
  ForceDirectories(ExpandConstant('{tmp}'));
  ScriptPath := ExpandConstant('{tmp}\blazium-download.ps1');
  if not SaveText(ScriptPath,
    '$ProgressPreference = ''SilentlyContinue''; Invoke-WebRequest -UseBasicParsing -Uri ''' + URL + ''' -OutFile ''' + Dest + '''') then
    exit;
  if Exec('powershell.exe', '-NoProfile -ExecutionPolicy Bypass -File "' + ScriptPath + '"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    Result := (ResultCode = 0) and FileExists(Dest);
end;

function HubSetupFromManifest: String;
var
  JsonPath, SetupPath, ScriptPath: String;
  ResultCode: Integer;
begin
  Result := '';
  JsonPath := ExpandConstant('{tmp}\hub.json');
  SetupPath := ExpandConstant('{tmp}\BlaziumHub-Setup.exe');
  if not DownloadToFile('https://cdn.blazium.app/hub/hub.json', JsonPath) then
  begin
    Log('Could not download hub.json');
    exit;
  end;
  ScriptPath := ExpandConstant('{tmp}\blazium-hub-pick.ps1');
  if not SaveText(ScriptPath,
    '$ProgressPreference = ''SilentlyContinue''; ' +
    '$m = Get-Content -Raw ''' + JsonPath + ''' | ConvertFrom-Json; ' +
    '$ver = [string]$m.latest; ' +
    '$entry = $m.versions.PSObject.Properties[$ver].Value; ' +
    '$d = $entry.downloads | Where-Object { $_.platform -eq ''windows'' -and ($_.arch -eq ''x86_64'' -or $_.arch -eq ''amd64'') } | Select-Object -First 1; ' +
    'if (-not $d.download_url) { exit 1 }; ' +
    'Invoke-WebRequest -UseBasicParsing -Uri $d.download_url -OutFile ''' + SetupPath + '''') then
    exit;
  if Exec('powershell.exe', '-NoProfile -ExecutionPolicy Bypass -File "' + ScriptPath + '"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    if (ResultCode = 0) and FileExists(SetupPath) then
      Result := SetupPath;
end;

procedure InstallHubNow;
var
  Setup, Args: String;
  ResultCode: Integer;
begin
  Setup := HubSetup;
  if (Setup = '') or not FileExists(Setup) then
    Setup := HubSetupFromManifest;
  if (Setup = '') or not FileExists(Setup) then
  begin
    Log('BlaziumHub setup was not found');
    exit;
  end;
  Args := '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR="' + SharedRoot + '"';
  Log('Running BlaziumHub setup ' + Setup);
  Exec(Setup, Args, '', SW_SHOW, ewWaitUntilTerminated, ResultCode);
  Log('BlaziumHub setup exit=' + IntToStr(ResultCode));
end;

function InitializeSetup: Boolean;
var
  I: Integer;
  Arg: String;
begin
  Result := True;
  SkipProtocol := False;
  CliWasPresent := CliAlreadyInstalled;
  HubSetup := ExpandConstant('{param:HUBSETUP}');
  for I := 1 to ParamCount do
  begin
    Arg := Uppercase(ParamStr(I));
    if Arg = '/NOCLI' then
      SkipProtocol := True;
    if Arg = '/INSTALLHUB' then
      WizardSelectTasks('installhub');
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Existing: String;
  ResultCode: Integer;
  Already: Boolean;
begin
  if CurStep <> ssPostInstall then
    exit;
  if WizardIsTaskSelected('installhub') or ((HubSetup <> '') and FileExists(HubSetup)) then
    InstallHubNow;
  Already := SkipProtocol or CliWasPresent;
  if not RegQueryStringValue(HKLM, EnvironmentKey, 'BLAZIUM', Existing) then
    RegWriteExpandStringValue(HKLM, EnvironmentKey, 'BLAZIUM', SharedRoot);
  EnvAddPath(SharedRoot);
  SaveText(ExpandConstant('{app}\VERSION'), '{#MyAppVersion}');
  if not Already then
  begin
    RegWriteStringValue(HKLM, ProtocolOwnerKey, 'ProtocolOwner', '1');
    RegWriteStringValue(HKCR, 'blazium', '', 'URL:Blazium Protocol');
    RegWriteStringValue(HKCR, 'blazium', 'URL Protocol', '');
    RegWriteStringValue(HKCR, 'blazium\shell\open\command', '', '"' + ExpandConstant('{app}\{#MyAppExeName}') + '" "%1"');
  end;
  Exec(ExpandConstant('{app}\{#MyAppExeName}'), '--ensure-launcher-remote', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Command, Owner: String;
  CliRemains, HubInstalled: Boolean;
begin
  if CurUninstallStep = usUninstall then
  begin
    DeleteFile(ExpandConstant('{app}\VERSION'));
    exit;
  end;
  if CurUninstallStep <> usPostUninstall then
    exit;
  HubInstalled := FileExists(AddBackslash(SharedRoot) + 'Engine\BlaziumHub.exe');
  if not HubInstalled then
    DeleteFile(AddBackslash(SharedRoot) + 'blazium-cli.exe');
  CliRemains := FileExists(AddBackslash(SharedRoot) + 'blazium-cli.exe') or HubInstalled;
  if not CliRemains then
  begin
    EnvRemovePath(SharedRoot);
    if not FileExists(AddBackslash(SharedRoot) + 'chauffeur.exe') then
      RegDeleteValue(HKLM, EnvironmentKey, 'BLAZIUM');
  end;
  if RegQueryStringValue(HKLM, ProtocolOwnerKey, 'ProtocolOwner', Owner) or
     RegQueryStringValue(HKLM, 'SOFTWARE\Blazium Games', 'ProtocolOwner', Owner) then
  begin
    if RegQueryStringValue(HKCR, 'blazium\shell\open\command', '', Command) then
    begin
      if (Pos('BlaziumLauncher.exe', Command) > 0) and not FileExists(AddBackslash(SharedRoot) + 'blazium-cli.exe') then
        RegDeleteKeyIncludingSubkeys(HKCR, 'blazium');
    end;
    RegDeleteKeyIncludingSubkeys(HKLM, ProtocolOwnerKey);
    RegDeleteKeyIncludingSubkeys(HKLM, 'SOFTWARE\Blazium Games');
  end;
  DeleteFile(ExpandConstant('{userappdata}\blazium\launcher_remote.json'));
  DeleteFile(AddBackslash(SharedRoot) + 'games.cmd');
end;
