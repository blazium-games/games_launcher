; Blazium Games launcher.
; Root: {autopf}\Blazium Games. Does not install into {autopf}\Blazium and does not delete Hub files.
;
; /NOCLI is the silent default and registers this launcher for blazium:// when blazium-cli is absent.
; /INSTALLCLI copies blazium-cli from /CLISOURCE (or an existing Hub install) into this directory
; and points the protocol at blazium-cli.exe handle-uri "%1".
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
var
  CliSource: String;
  HubSetup: String;

function CliAlreadyInstalled: Boolean;
var
  HubDir: String;
begin
  Result := RegKeyExists(HKLM, 'SOFTWARE\Blazium\Hub');
  if Result then
    exit;
  if RegQueryStringValue(HKLM, 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment', 'BLAZIUM', HubDir) then
  begin
    if FileExists(HubDir + '\blazium-cli.exe') or FileExists(HubDir + '\bin\blazium-cli.exe') then
      Result := True;
  end;
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
  Own: Boolean;
  ResultCode: Integer;
begin
  if CurStep <> ssPostInstall then
    exit;
  if WizardIsTaskSelected('installhub') and (HubSetup <> '') and FileExists(HubSetup) then
    Exec(HubSetup, '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART', '', SW_SHOW, ewWaitUntilTerminated, ResultCode);
  Own := not CliAlreadyInstalled;
  if WizardIsTaskSelected('installcli') then
  begin
    Source := CliSource;
    if (Source = '') and RegKeyExists(HKLM, 'SOFTWARE\Blazium\Hub') then
      Source := '';
    if (Source <> '') and FileExists(Source + '\blazium-cli.exe') then
    begin
      FileCopy(Source + '\blazium-cli.exe', ExpandConstant('{app}\blazium-cli.exe'), False);
      if FileExists(Source + '\crash_reporter.exe') then
        FileCopy(Source + '\crash_reporter.exe', ExpandConstant('{app}\crash_reporter.exe'), False);
      Handler := '"' + ExpandConstant('{app}\blazium-cli.exe') + '" handle-uri "%1"';
      Own := True;
    end
    else
      Handler := '"' + ExpandConstant('{app}\{#MyAppExeName}') + '" "%1"';
  end
  else if CliAlreadyInstalled then
  begin
    { Leave the existing handler and hub_remote.json alone. }
    Handler := '';
    Own := False;
  end
  else
    Handler := '"' + ExpandConstant('{app}\{#MyAppExeName}') + '" "%1"';
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
  DeleteFile(ExpandConstant('{userappdata}\blazium\launcher_remote.json'));
end;
