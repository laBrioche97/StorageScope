#ifndef AppVersion
  #define AppVersion "3.2.0"
#endif
#ifndef AppPublisher
  #define AppPublisher "La Brioche"
#endif
[Setup]
AppId={{A81A6E79-891C-4B17-AE21-51A679265149}
AppName=StorageScope
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppMutex=Local\StorageScope.Application
SetupIconFile=Branding\StorageScope.ico
DefaultDirName={localappdata}\Programs\StorageScope
DefaultGroupName=StorageScope
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible or arm64
ArchitecturesInstallIn64BitMode=x64compatible or arm64
MinVersion=10.0.19041
OutputDir=..\release-assets
#ifdef UnsignedWindowsBuild
OutputBaseFilename=StorageScope-Windows-Setup-DEVELOPMENT
#else
OutputBaseFilename=StorageScope-Windows-Setup
#endif
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
DisableProgramGroupPage=yes
DisableDirPage=yes
CloseApplications=yes
RestartApplications=no
UninstallDisplayIcon={app}\versions\{#AppVersion}\StorageScope.exe
UninstallFilesDir={app}
SetupLogging=yes
#ifdef SignedBuild
SignTool=publisher
SignedUninstaller=yes
#endif

[Languages]
Name: "french"; MessagesFile: "compiler:Languages\French.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "..\dist\win-x64\*"; DestDir: "{app}\versions\{#AppVersion}"; Flags: recursesubdirs createallsubdirs ignoreversion; Check: not IsNativeArm64
Source: "..\dist\win-arm64\*"; DestDir: "{app}\versions\{#AppVersion}"; Flags: recursesubdirs createallsubdirs ignoreversion; Check: IsNativeArm64

[Icons]
Name: "{userprograms}\StorageScope"; Filename: "{app}\versions\{#AppVersion}\StorageScope.exe"; WorkingDir: "{app}\versions\{#AppVersion}"

[Run]
Filename: "{app}\versions\{#AppVersion}\StorageScope.exe"; Description: "Lancer StorageScope"; Flags: nowait postinstall skipifsilent; Check: InstallationHealthy
Filename: "{app}\versions\{#AppVersion}\StorageScope.exe"; Flags: nowait; Check: RestartAfterUpdate

[Code]
var PreviousVersion: String;
var Healthy: Boolean;

function GetFileAttributes(FileName: String): LongWord;
external 'GetFileAttributesW@kernel32.dll stdcall';

function SafeTree(Path: String): Boolean;
var Entry: TFindRec;
begin
  Result := False;
  if (GetFileAttributes(Path) and $400) <> 0 then exit;
  if FindFirst(AddBackslash(Path) + '*', Entry) then begin
    try
      repeat
        if (Entry.Name <> '.') and (Entry.Name <> '..') then begin
          if (Entry.Attributes and $400) <> 0 then exit;
          if ((Entry.Attributes and FILE_ATTRIBUTE_DIRECTORY) <> 0) and not SafeTree(AddBackslash(Path) + Entry.Name) then exit;
        end;
      until not FindNext(Entry);
    finally FindClose(Entry); end;
  end;
  Result := True;
end;

function VersionName(Name: String): Boolean;
var I: Integer; Dots: Integer;
begin
  Result := False; Dots := 0;
  for I := 1 to Length(Name) do
    if Name[I] = '.' then Dots := Dots + 1
    else if (Name[I] < '0') or (Name[I] > '9') then exit;
  Result := (Length(Name) >= 5) and (Dots = 2);
end;

procedure RemoveOldVersions;
var Entry: TFindRec; Root: String; Candidate: String; Attempt: Integer;
begin
  Root := AddBackslash(ExpandFileName(ExpandConstant('{app}\versions')));
  if not SafeTree(ExpandConstant('{app}')) then begin Log('Old-version cleanup deferred: reparse point detected.'); exit; end;
  if FindFirst(Root + '*', Entry) then begin
    try
      repeat
        if ((Entry.Attributes and FILE_ATTRIBUTE_DIRECTORY) <> 0) and VersionName(Entry.Name) and (Entry.Name <> '{#AppVersion}') then begin
          Candidate := ExpandFileName(Root + Entry.Name);
          if (Pos(Lowercase(Root), Lowercase(AddBackslash(Candidate))) = 1) and FileExists(AddBackslash(Candidate) + 'StorageScope.exe') and SafeTree(Candidate) then begin
            for Attempt := 1 to 5 do begin
              if DelTree(Candidate, True, True, True) then break;
              Sleep(500);
            end;
            if DirExists(Candidate) then Log('Old version still in use; cleanup deferred: ' + Entry.Name);
          end;
        end;
      until not FindNext(Entry);
    finally FindClose(Entry); end;
  end;
end;

function IsNativeArm64: Boolean;
begin
  Result := ProcessorArchitecture = paArm64;
end;

function InstallationHealthy: Boolean;
begin
  Result := Healthy and (ExpandConstant('{param:UPDATE|0}') <> '1');
end;

function RestartAfterUpdate: Boolean;
begin
  Result := Healthy and (ExpandConstant('{param:UPDATE|0}') = '1');
end;

function InitializeSetup: Boolean;
begin
  RegQueryStringValue(HKCU, 'Software\LaBrioche\StorageScope', 'CurrentVersion', PreviousVersion);
  if not VersionName(PreviousVersion) then PreviousVersion := '';
  if PreviousVersion = '{#AppVersion}' then begin
    MsgBox('Cette version de StorageScope est déjà installée. Ouvrez StorageScope depuis le menu Démarrer.', mbInformation, MB_OK);
    Result := False;
    exit;
  end;
  Result := True;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var ExitCode: Integer; Target: String; OldTarget: String;
begin
  if CurStep <> ssPostInstall then exit;
  Target := ExpandConstant('{app}\versions\{#AppVersion}\StorageScope.exe');
  Healthy := Exec(Target, '--verify-installation', ExtractFileDir(Target), SW_HIDE, ewWaitUntilTerminated, ExitCode) and (ExitCode = 0);
  if not Healthy then begin
    if (PreviousVersion <> '{#AppVersion}') and SafeTree(ExpandConstant('{app}\versions\{#AppVersion}')) then
      DelTree(ExpandConstant('{app}\versions\{#AppVersion}'), True, True, True);
    OldTarget := ExpandConstant('{app}\versions\') + PreviousVersion + '\StorageScope.exe';
    if (PreviousVersion <> '') and FileExists(OldTarget) then
      CreateShellLink(ExpandConstant('{userprograms}\StorageScope.lnk'), 'StorageScope', OldTarget, '', ExtractFileDir(OldTarget), OldTarget, 0, SW_SHOWNORMAL)
    else
      DeleteFile(ExpandConstant('{userprograms}\StorageScope.lnk'));
    RaiseException('La nouvelle version ne peut pas démarrer. La version précédente a été conservée.');
  end;
  RegWriteStringValue(HKCU, 'Software\LaBrioche\StorageScope', 'CurrentVersion', '{#AppVersion}');
  RemoveOldVersions;
end;
