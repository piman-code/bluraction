# Windows 설치 패키지 준비

이 폴더는 **검토 가능한 설치 스크립트**다. 현재 Windows에서 Inno 컴파일·설치·앱 실행을 검증하지 않았고, 라이선스 검수를 마친 bundle record도 없다. 기존 Mac 운영 설치나 원본을 수정하지 않는다. Python/PyInstaller/Inno 설치, 실제 설치본 교체와 원격 공개는 각각 해당 승인을 확인한 뒤 실행한다.

Qt 화면은 사용자 승인한 Mac 배치를 따르지만 그 승인은 새 도구 설치/운영 앱 교체/공개 승인이 아니다. 빌드·내부 검사·설치·OS 파일 패널/Explorer drop·실제 출력 검수를 구분한다.

## 대상과 설치 방식

초기 설치 스크립트 대상은 Windows 10 22H2(19045) 이상 / Windows 11 **x64**다. ARM64 emulation은 명시적으로 허용하지 않는다. 실제 Windows10/11 검사 전 지원 완료라고 광고하지 않는다. 기존 Qt6.11 지원 목록은 전체 앱 DLL/codec/encoder의 실행 증거가 아니다.

Inno Setup은 Windows 설치 EXE, 사용자별 설치, 제거 기능을 제공한다. `PrivilegesRequired=lowest`는 UAC 관리자 승격을 요청하지 않는다. [Inno 소개](https://jrsoftware.org/isinfo.php), [설치 권한](https://jrsoftware.org/ishelp/topic_setup_privilegesrequired.htm) 기본 설치 위치는 `%LOCALAPPDATA%\Programs\BlurAction\<버전>`이며 같은 버전/다른 앱의 기존 폴더도 덮어쓰지 않는다. 후보마다 AppId·시작 메뉴 이름을 분리한다. `PrepareToInstall`이 기존 폴더를 거부하므로 재설치는 제거 후 새 폴더를 선택한다. AppId가 uninstall identity를 결정한다. [AppId](https://jrsoftware.org/ishelp/topic_setup_appid.htm)

자동 앱 실행, 파일 연결, 시작 프로그램, 서비스, system codec/font 설치는 없다. 제거는 설치한 파일과 비어 있는 설치 폴더에 한정한다. 프로젝트·원본·결과는 사용자 작업 폴더에 두고 설치 폴더에 저장하지 않는다. 이전 버전의 바로가기/실행 파일은 남겨 복구할 수 있다. 새 후보를 기존 운영 폴더에 덮어 설치하는 경로는 제공하지 않는다.

Inno 자체 라이선스는 조건을 지킨 상업적 사용을 허용하며 공식 사이트는 상업 사용자의 구매를 요청한다. 무료 도구라고 모든 의존성의 배포가 자동 허용되는 것은 아니다. [Inno License](https://jrsoftware.org/files/is/license.txt) GitHub Windows2025 runner의 조사 당시 목록에는 InnoSetup 6.7.1이 있다. 그 목록은 실제 실행 증거가 아니므로 스크립트가 compiler 존재를 다시 확인한다. [공식 runner inventory](https://github.com/actions/runner-images/blob/main/images/windows/Windows2025-Readme.md)

## 라이선스와 정확한 bundle gate

`platforms/windows/build_package.ps1`는 검수용 onedir 준비와 검수된 portable ZIP 생성을 분리한다. 그 자체로 installer/라이선스/Windows 실제 실행 통과가 아니다. Qt/PDFium·PyAV/실제 FFmpeg DLL·OpenCV·Pillow·NumPy·Python·PyInstaller·선택 HEIC codec의 버전·원문 notices·source/configure/재배포 요구를 실제 binary 기준으로 검수한다. PyAV wrapper 조건과 FFmpeg binary 구성 조건을 혼동하지 않는다. 실제 av wheel에 libx264 등 GPL 구성 요소가 포함되어 있으면 wrapper의 BSD 또는 LGPL이라는 설명만으로 배포를 허용하지 않는다. 구성 확인과 해당 GPL 재배포 조건/소스 제공 검수 또는 별도 승인한 대체 빌드가 남는다. 일반 `pillow-heif` wheel은 bundled GPLv2라고 요약되어 있으므로 exact wheel의 모든 license grant·빌드·대응 소스와 Qt 결합 조건을 확인한다. GPLv3 결합 배포 경로 또는 HEIC 인코더까지 포함한 검수된 대체 빌드를 검토하며, decode-only 대안은 전체 읽기·쓰기 범위를 대신하지 않는다. 실제 DLL과 자료를 확인한 판정은 아직 없다. 자세한 선택지와 준비 자료는 [라이선스 검토](../../../docs/의존성과-라이선스-검토.md)를 따른다. [FFmpeg 배포 조건](https://www.ffmpeg.org/legal.html), [pillow-heif bundled licenses](https://github.com/bigcat88/pillow_heif/blob/master/LICENSES_bundled.txt)

검수 전에 installer builder가 거부하는 것:

- `BlurAction.exe`, root `LICENSE.txt`, `licenses/NOTICE.txt`, `licenses/dependencies.json` 누락.
- status `reviewed`, 해당 version, reviewer/date/dependency findings가 없는 review record.
- record의 SHA256와 다른 `bundle-manifest.json`, manifest 파일 bytes 변경, 새 unlisted file, 중복/경로 이탈/reparse leaf.
- 기존 출력 폴더, Windows 아닌 host, Inno compiler 누락.

`license-review.example.json`은 `pending` 예시라 실행 승인이 아니며 그대로 통과하지 않는다. 검수 record는 실제 dependency 증거와 exact manifest hash를 기록한다. compile gate는 공개 승인·실제 기능/OS 검수의 대체물이 아니다. 수정한 NOTICE/파일을 추가하면 manifest를 다시 만들고 해당 bytes로 검수한다. 일반 ZIP도 같은 notices를 포함해야 하므로 zip 생성 전에 자료를 준비하고 검수한 이후 결과 hash를 재확인한다.

패키징의 `-LicenseMaterials` 폴더는 `NOTICE.txt`, `dependencies.json`, 각 의존성의 원문 라이선스와 실제 바이너리/빌드 증거를 포함한다. dependencies.json 구조는 `{"dependencies":[...]}`이며 항목마다 `id`, `version`, `license`, `redistribution_review`, `license_files`와 `evidence_files`를 기록한다. 두 file 배열은 이 폴더 안의 상대 경로를 가리킨다. 필수 id는 `python`, `pyside6`, `qt`, `pdfium`, `pyav`, `ffmpeg`, `opencv`, `pillow`, `numpy`, `pyinstaller`, `pypdf`, `pillow-heif`, `libheif`, `heif-codecs`다. `pypdf`와 `pillow-heif`는 각각 `6.19.0`, `1.8.0`이어야 한다. `heif-codecs` 증거에는 실제 `libheif_info()` 출력, 사용한 decoder/encoder 구성과 각 binary의 버전·해시·라이선스·빌드/소스 조건을 포함한다. libde265+x265 또는 kvazaar 등 이름을 고정하지 않고 실제 구성에 맞춰 개별 decoder/DLL도 목록에 더한다. 특정 GPL codec을 필수 선택으로 강제하지 않는다. 파일 존재 검사는 법적 적합성을 자동 판정하지 않는다. placeholder를 실제 증거로 표시하지 않으며, 실제 FFmpeg/HEIF DLL 구성·필요 소스/빌드 자료·LGPL 교체 가능성 등을 사람이 exact bundle 대상으로 검수해야 한다. 현재 완성된 자료/검수 기록은 없다.

`-PrepareForReview`는 실제 자료가 있을 때만 새 onedir와 manifest를 만들고 **ZIP을 만들지 않는다**. 검수자가 그 파일들에 대한 record를 만든 뒤 `-FinalizeReviewedBundle`로 같은 onedir bytes를 다시 확인해 ZIP을 만든다. 기본 ZIP 모드도 검수 기록 없이는 거부한다. ZIP 직전/직후 파일 목록과 해시를 재검사하며, source 변경을 발견하면 자기 ZIP을 남기지 않는다. 내부 테스트는 portable 120초·Qt/media 900초 제한이며, 실패/예외에도 이전 `QT_QPA_PLATFORM` 값을 finally에서 복원한다. 새 패키징 스크립트를 Windows에서 실행/파싱한 증거는 아직 없다.

`-VerifyRuntimeOnly`는 exact PDF/HEIF pin, 실제 native HEIF 모듈·codec inventory와 필수 actual PDF/HEIF 테스트를 확인한다. 이 두 실제 backend 클래스의 skip·0 tests·실패는 승인으로 취급하지 않고 실패한다(300초 제한). 개발용 일반 unittest의 명시적 dependency skip은 미검증 표시이며 CI/패키징 완료 증거가 아니다. CI Windows job은 이 검사를 필수로 호출한다. 선택적 onedir 단계는 `windows_license_materials_path`가 비어 있으면 자료 미완성을 명시하고 멈춘다. 해당 입력은 runner에 이미 존재하는 승인된 실제 자료 경로이며 스크립트가 다운로드하거나 가짜 review record를 만들지 않는다. 정상 준비된 경우에도 manifest만 보관하고 unchecked binary는 업로드하지 않는다.

HEIF PyInstaller 준비는 `collect_all('pillow_heif')`와 `collect_delvewheel_libs_directory('pillow_heif')`를 사용하는 로컬 build hook을 새 work 폴더에 생성하고 `_pillow_heif` native 모듈 및 pypdf를 명시 수집한다. [공식 hook helpers](https://pyinstaller.org/en/stable/hooks.html#PyInstaller.utils.hooks.collect_delvewheel_libs_directory), [공식 수집 옵션](https://pyinstaller.org/en/stable/usage.html#what-to-bundle-where-to-search) 전용 pillow-heif upstream hook이 자동 존재한다고 가정하지 않는다. [pillow-heif Windows wheel 설정](https://github.com/bigcat88/pillow_heif/blob/v1.8.0/pyproject.toml)의 delvewheel 경로를 대상으로 준비했지만 실제 Windows DLL 수집·동결 앱 HEIF decode/encode는 아직 검증하지 않았다. interpreter의 실제 backend 테스트 성공도 frozen bundle 실행의 대체물이 아니다.

## Windows에서의 재현 절차

아래 명령은 아직 실행하지 않았다. 새 도구 설치는 이미 승인된 isolated environment에만 한다. existing compiler가 없다면 공식 Inno 버전·installer hash·설치 위치·제거 복구안을 제시하고 승인을 받은 뒤 설치한다. script가 pip/winget/choco로 도구를 자동 설치하지 않는다.

```powershell
# Repository root; use an already approved isolated interpreter.
$CandidateVersion = '0.8.0-dev1'
$CandidatePython = 'C:\approved-env\Scripts\python.exe'
& $CandidatePython -m unittest discover -s Tests/PortableProjectTests -v
if ($LASTEXITCODE -ne 0) { throw 'Portable regression failed.' }
$PriorQtPlatform = [Environment]::GetEnvironmentVariable('QT_QPA_PLATFORM', 'Process')
try {
  [Environment]::SetEnvironmentVariable('QT_QPA_PLATFORM', 'offscreen', 'Process')
  ./platforms/windows/build_package.ps1 -Python $CandidatePython -VerifyRuntimeOnly
  & $CandidatePython -c "import subprocess,sys; subprocess.run([sys.executable,'-m','unittest','discover','-s','Tests/WindowsAppTests','-v'],check=True,timeout=900)"
  if ($LASTEXITCODE -ne 0) { throw 'Windows regressions failed or timed out.' }
} finally {
  [Environment]::SetEnvironmentVariable('QT_QPA_PLATFORM', $PriorQtPlatform, 'Process')
}
./platforms/windows/build_package.ps1 -Python $CandidatePython -Version $CandidateVersion `
  -LicenseMaterials 'C:\reviewed-candidate\dependency-materials' -PrepareForReview

# After reviewing these exact generated bundle bytes, finalize without rebuilding.
./platforms/windows/build_package.ps1 -Version $CandidateVersion `
  -FinalizeReviewedBundle -LicenseReview 'C:\reviewed-candidate\license-review.json'

# Review real bundle licenses and produce the matching record first.
./platforms/windows/installer/build_installer.ps1 `
  -Bundle ".build/windows-packages/$CandidateVersion/dist/BlurAction" `
  -BundleManifest ".build/windows-packages/$CandidateVersion/bundle-manifest.json" `
  -LicenseReview 'C:\reviewed-candidate\license-review.json' `
  -Version $CandidateVersion `
  -OutputDirectory ".build/windows-installers/$CandidateVersion"
```

PyInstaller Windows package는 Windows에서 만들어야 한다. Mac에 PySide가 있다는 사실이나 onedir 폴더 이름으로 Windows 실행을 선언하지 않는다. [PyInstaller](https://pyinstaller.org/en/stable/index.html) `requirements-packaging.txt`는 신규 PyInstaller 6.22.3 대상의 검토 가능한 pin이며 아직 설치했다는 뜻이 아니다.

PowerShell wrapper는 bundle bytes를 다시 확인한 후 compiler만 호출하고 installer-report.json에 SHA256/서명 상태를 기록한다. installer를 실행하거나 OS settings를 변경하지 않는다. 서명 인증서가 없으면 실제 `NotSigned` 상태를 유지해 보고한다. 사설 인증서를 신뢰시키는 명령이나 SmartScreen/보안을 끄는 절차를 넣지 않는다.

## CI와 실제 사용자 검수

새 `.github/workflows/verify.yml`은 remote에서 아직 실행하지 않았다. permissions는 contents read, credential persistence 없음, action SHA는 2026-10-02 공식 Git 태그 readback으로 고정했다. portable data 검사, Mac native 검사/설치 없는 build, Windows exact wheel 환경과 bounded 내부 검사를 구성했다. Windows fixture/video/audio 확인은 PyAV를 사용하며 FFmpeg CLI subprocess에 의존하지 않는다고 video 담당이 확인했다. h264_mf/CSRT가 없으면 기본 기능을 조용히 제외하지 않고 실패한다.

manual dispatch의 candidate flag는 명시적으로 승인한 runner 의존성을 쓰는 준비 단계다. 현재 CI에는 실제 license materials/review record 공급 경로가 없으므로 수정된 packaging gate가 그 단계를 거부한다. 이를 검수 통과로 표시하지 않으며 자료 없이 gate를 우회하지 않는다. unchecked binary를 upload하지 않고 candidate manifest만 보관하도록 설계했다. installer compile은 matching review record를 공급한 Windows 단계에서 한다. installer artifact와 public Release는 라이선스·실제 host 검수·공개 승인 후 별도 단계다. 기본 CI pass가 installer/user acceptance/full release를 뜻하지 않는다.

필수 실제 Windows 사용자 검수는 `shared/fixtures/manual-os` 합성 파일로 수행한다. 깨끗한 x64 host의 일반 사용자 계정에서 설치, 시작 메뉴 실행, PDF+세 PNG Explorer drop, 페이지별·전체 복사·다시 수정, save/reopen와 Mac↔Windows 원본 재연결, PNG/PDF 모든 page/표식, 영상 탐색·시간 구간·동작 기록·부분 지우개·추적/취소·오디오·회전·대표 frame을 확인한다. 긴 한글/영문·예약 이름·기존 결과 충돌·원본 hash·작업 중 입력 차단·취소·부분 성공을 확인하고 candidate version/hash/Windows build와 결과만 전달한다. Computer Use나 OS 입력 자동화를 요청하지 않는다.

실제 Windows host가 없으면 로컬 구현/검사/문서/패키징 준비를 계속하되 전체 완료는 남긴다. clean Windows 실제 설치·실행, signing/license bundle, user OS panel/drop, full media outputs 또는 승인한 GitHub 공개 중 하나라도 남으면 전체 목표 완료로 표시하지 않는다.
