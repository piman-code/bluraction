; Personal verification only. Final release uses the unchanged BlurAction.iss.
#ifndef SourceDir
  #error SourceDir required
#endif
#ifndef AppVersion
  #error AppVersion required
#endif
#ifndef BundleManifestFile
  #error BundleManifestFile required
#endif
#ifndef PersonalStatusFile
  #error PersonalStatusFile required
#endif
#if !FileExists(SourceDir + "\BlurAction.exe")
  #error Windows candidate missing
#endif
#if !FileExists(PersonalStatusFile)
  #error Personal candidate status missing
#endif
[Setup]
AppId=BlurAction.Windows.PersonalTest.{#AppVersion}
AppName=BlurAction 개인 검수 후보
AppVersion={#AppVersion}
AppVerName=BlurAction {#AppVersion} (개인 검수 후보)
AppPublisher=piman-code
DefaultDirName={localappdata}\Programs\BlurAction-PrivateTest\{#AppVersion}
DefaultGroupName=BlurAction 개인 검수 {#AppVersion}
UsePreviousAppDir=no
UsePreviousGroup=no
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible and not arm64
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19045
UninstallDisplayIcon={app}\BlurAction.exe
OutputBaseFilename=BlurAction-{#AppVersion}-windows-x64-personal-setup
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
Source: "{#PersonalStatusFile}"; DestDir: "{app}\licenses"; DestName: "personal-test-status.json"; Flags: ignoreversion
[Icons]
Name: "{userprograms}\BlurAction 개인 검수 {#AppVersion}"; Filename: "{app}\BlurAction.exe"
[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if DirExists(ExpandConstant('{app}')) then
    Result := '기존 파일을 보존합니다. 존재하지 않는 새 설치 폴더를 선택하세요.';
end;
