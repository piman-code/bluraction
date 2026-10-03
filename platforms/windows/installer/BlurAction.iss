; Compile through build_installer.ps1 after the exact bundle/license review.
; The installer is version-isolated and refuses an existing destination.
#ifndef SourceDir
  #error SourceDir must name the reviewed PyInstaller onedir bundle.
#endif
#ifndef AppVersion
  #error AppVersion must identify this candidate.
#endif
#ifndef BundleManifestFile
  #error BundleManifestFile is required.
#endif
#ifndef LicenseReviewFile
  #error LicenseReviewFile is required. No reviewed record is supplied in this repository.
#endif
#if !FileExists(SourceDir + "\BlurAction.exe")
  #error The Windows executable is missing.
#endif
#if !FileExists(SourceDir + "\licenses\NOTICE.txt")
  #error The dependency notice bundle is missing.
#endif
#if !FileExists(SourceDir + "\licenses\dependencies.json")
  #error The dependency license manifest is missing.
#endif
#if !FileExists(LicenseReviewFile)
  #error The bundle license review record is missing.
#endif
#if !FileExists(BundleManifestFile)
  #error The exact bundle manifest is missing.
#endif

[Setup]
AppId=BlurAction.Windows.Candidate.{#AppVersion}
AppName=BlurAction
AppVersion={#AppVersion}
AppVerName=BlurAction {#AppVersion} (검수 후보)
AppPublisher=piman-code
AppPublisherURL=https://github.com/piman-code/bluraction
DefaultDirName={localappdata}\Programs\BlurAction\{#AppVersion}
DefaultGroupName=BlurAction {#AppVersion}
UsePreviousAppDir=no
UsePreviousGroup=no
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible and not arm64
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19045
UninstallDisplayIcon={app}\BlurAction.exe
OutputBaseFilename=BlurAction-{#AppVersion}-windows-x64-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
DisableProgramGroupPage=yes
LicenseFile={#SourceDir}\LICENSE.txt
CloseApplications=no
RestartApplications=no
SetupLogging=yes

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#BundleManifestFile}"; DestDir: "{app}\licenses"; DestName: "bundle-manifest.json"; Flags: ignoreversion
Source: "{#LicenseReviewFile}"; DestDir: "{app}\licenses"; DestName: "reviewed-bundle.json"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\BlurAction {#AppVersion}"; Filename: "{app}\BlurAction.exe"

; No [Run], file association, system codec, font, service or startup changes.
; Uninstall removes installed files; there is no recursive user-data deletion.
[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if DirExists(ExpandConstant('{app}')) then
    Result := '기존 설치와 파일을 보존합니다. 존재하지 않는 새 설치 폴더를 선택하세요.';
end;
