#ifndef AppVersion
  #define AppVersion "3.1.0"
#endif
#ifndef AppPublisher
  #define AppPublisher "La Brioche"
#endif
[Setup]
AppId={{A81A6E79-891C-4B17-AE21-51A679265149}
AppName=StorageScope
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
SetupIconFile=Branding\StorageScope.ico
DefaultDirName={localappdata}\Programs\StorageScope
DefaultGroupName=StorageScope
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible or arm64
ArchitecturesInstallIn64BitMode=x64compatible or arm64
MinVersion=10.0.19041
OutputDir=..\release-assets
OutputBaseFilename=StorageScope-Windows-Setup
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

[Code]
var PreviousVersion: String;
var Healthy: Boolean;

function IsNativeArm64: Boolean;
begin
  Result := ProcessorArchitecture = paArm64;
end;

function InstallationHealthy: Boolean;
begin
  Result := Healthy;
end;

function InitializeSetup: Boolean;
begin
  RegQueryStringValue(HKCU, 'Software\LaBrioche\StorageScope', 'CurrentVersion', PreviousVersion);
  Result := True;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var ExitCode: Integer; Target: String; OldTarget: String;
begin
  if CurStep <> ssPostInstall then exit;
  Target := ExpandConstant('{app}\versions\{#AppVersion}\StorageScope.exe');
  Healthy := Exec(Target, '--verify-installation', ExtractFileDir(Target), SW_HIDE, ewWaitUntilTerminated, ExitCode) and (ExitCode = 0);
  if not Healthy then begin
    OldTarget := ExpandConstant('{app}\versions\') + PreviousVersion + '\StorageScope.exe';
    if (PreviousVersion <> '') and FileExists(OldTarget) then
      CreateShellLink(ExpandConstant('{userprograms}\StorageScope.lnk'), 'StorageScope', OldTarget, '', ExtractFileDir(OldTarget), OldTarget, 0, SW_SHOWNORMAL)
    else
      DeleteFile(ExpandConstant('{userprograms}\StorageScope.lnk'));
    RaiseException('La nouvelle version ne peut pas démarrer. La version précédente a été conservée.');
  end;
  RegWriteStringValue(HKCU, 'Software\LaBrioche\StorageScope', 'CurrentVersion', '{#AppVersion}');
end;
