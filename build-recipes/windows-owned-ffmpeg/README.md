# 실행 준비된 owned Windows FFmpeg/PyAV QA draft

이 폴더만 신규 QA로 작성했다. 아직 Python/PowerShell/Bash syntax parser·build·native smoke를 실행하지 않았으며, 제품·Tests·실제 workflow·Git·운영 앱을 변경하지 않았다. root가 읽기 검토와 정적/actual Windows 실행을 순서대로 수행해야 한다.

## 선택한 경로

기존 vendor wheel의15개 전체 DLL bytes 변경·MSYS runtime/compiler 출처가 아직 닫히지 않아 **새 stock FFmpeg9.0.2+PyAV19 후보**를 만든다. 옛 wheel 전체 재현이라고 하지 않는다. stock GPL/version3·shared·MediaFoundation을 사용하고 configure의 GPL→VERSION3 이동 patch를 복사하지 않는다. 기존 앱 Windows encoder도 `h264_mf`이므로 제품의 encoder 호출이나 화면 변경을 요구하지 않는다.

첫 코어 빌드는 외부 x264/x265/dav1d/vpx/SVT와 HEIF/Qt/app integration을 완료하지 않는다. 네트워크 기능은 local source 계약에 맞춰 disabled다. 모든 기존 미디어 형식·HEIC·HDR·IME·tracking·오디오·프로젝트·타임라인 지원 목표는 유지되며 뒤 단계에서 필요한 라이브러리/backend를 pin해 확장해야 한다. smoke 통과를 whole Goal·P1 종료로 표시하지 않는다.

## 정확 pin과 acquired lock

`pins.json`의 FFmpeg hash는 이미 취득한 vendor source catalog의 공식9.0.2 archive와 같다. PyAV19 sdist SHA·tag commit `b484ef4987c9722d36731ec289130a85a8c99b5d`는 공식 PyPI/GitHub metadata를 읽었다. MSYS2 base20260927 digest는 공식 GitHub release asset의 실제 SHA이고 GCC16.2.0-4/NASM3.02-1/pkgconf1~3.0.7-1은 공식 package 페이지의 actual filename/SHA다. Python3.14.7은 exact setup-python이며3.14.8로 대체하지 않는다.

build-tool wheel7개(Python pip26.2.1/setuptools82.0.0/Cython3.3.0/wheel0.46.3/packaging26.3/delvewheel1.13.1/pefile2024.8.26)는 공식 PyPI 파일 URL/SHA로 고정했다. `--no-index --no-deps`로 새 venv에 설치하여 backend build isolation이 별도 version을 고르지 못하게 한다. 이 버전들은 아직 actual 빌드로 검증되지 않았다.

GCC transitive dependency versions는 지어내지 않았다. SHA 고정 base에서 공식 repo만 사용하여 pacman closure의 name/version/filename/URL/SHA를 먼저 보존하고 아래의 mandatory signature 정책으로 서명 bytes·출처를 freeze한다. top4(GCC/NASM/pkgconf/diffutils) drift·필수 서명 부재·unknown server는 거부한다. 모든 acquired 파일은 hash 검증, native installer의 Required signature 확인 뒤 **offline config**로만 설치한다. replay는 이 lock+package archives를 재사용해야 하며 현재 draft가 다른 날의 새 repository closure를 같은 빌드라고 부르지 않는다.

PyAV Cython extension의 MSVC는 disposable GitHub worker에 이미 있는 native tool을 이용한다. VsDevCmd에서 허용 env 필드만 현재 process에 적용하고 실제 VCTools/SDK 버전·cl/link/lib SHA를 build 전에 freeze, 뒤에 재확인한다. runner 이미지가 바뀌면 이 acquired compiler lock도 다르다. **원래 vendor compiler 재현이나 cross-run 고정 완료가 아니며**, 첫 실제 lock을 선별·보존한 뒤 같은 compiler package/source를 확보해 replay pin을 보완해야 한다. MSYS/VS/Python을 사용자의 전역 환경에 설치하지 않는다.

## root 실행 방법

승인한 깨끗한 Windows2025 x64 일회성 worker에서(기존 사용자 파일을 읽지 않음):

```powershell
$attempt = Join-Path $env:RUNNER_TEMP ('bluraction-owned-ffmpeg-' + [guid]::NewGuid())
./BuildOwnedCandidate.ps1 -Destination $attempt -Repository $env:GITHUB_WORKSPACE -Python python
```

호스트 `python`은 실제3.14.7이어야 한다. 먼저 이 QA 폴더를 검수한 source directory로 curate하고 `workflow.draft.yml`의 해당 위치를 지정한다. 기존 `.github/workflows/verify.yml`과 parallel job·제품 source는 바꾸지 않는다. 작업 폴더가 있거나 helper pin/actual API/source hash가 달라지면 실패하고 partial evidence를 보존한다.

`run_owned_command.py`는 reviewed `scripts/verify_windows.py` SHA `312931a7…`의 WindowsJob를 재사용한다. stdin gate 이전에 child를 private Job Object에 넣고 command timeout 뒤 descendants를 종료·drain한 후 log SHA를 기록한다. 기존 runner가 바뀌면 조용히 대체하지 않고 재검토를 요구한다. native smoke90초/각 build2400초(최대3600초)/workflow90분 제한이다.

## 실제 성공 조건

1. source SHA 획득, top4 compiler/build-tool package 및 transitive locked packages의 실제 서명 검증/설치 완료.
2. stock FFmpeg GPL3/shared/MF compile; actual DLL export에서 생성한 MSVC `.def/.lib`와 source-built PyAV19 wheel SHA 기록.
3. pefile의 일반+delay imports를 추적해 필요한 MinGW runtime만 copy; unresolved DLL이면 실패. 이후 delvewheel1.13.1 repair의 exact command·새 wheel SHA 기록. 데이터 변경은 새로운 후보의 repair 결과이며 옛15DLL 일치 주장 없음.
4. 실제 `h264_mf` **software** open/encode→MOV VFR `[0,1,3,6]/24` decode의 exact Fraction PTS와 증가하는 authored 밝기, 실제 PCM4000samples, 원본 SHA 보존. 같은 encoded packet의 MP4 remux와 decoded exact PTS 확인. 평균FPS/epsilon/기간 변경·다른 encoder fallback 없음. encoder가 VFR을 바꾸거나 software unavailable이면 그대로 실패한다.
5. actual process loaded DLL census와 각 SHA, actual FFmpeg configuration, source archives/build scripts/tool locks/output manifest를 기록. imported DLL 등록 목록만을 actual load proof로 쓰지 않는다.

현재 smoke는 audio samples만 검사하며 audio packet bytes/lead/tail/seek/audio clock proof가 아니다. codec pixel quality/exact RGBA 전체 비교·full formats·MF hardware·HEIF·Qt·IME·실제 설치/사용·P1을 별도로 이어 검증한다. 런타임 DLL의 source-only MSYS package/PKGBUILD 및 Qt/PySide source, HEIF external sources, 재링크 자료까지 묶이기 전 `correspondingSourceComplete=false`를 유지한다. build binaries가 생성됐다는 이유만으로 final reviewed record를 만들지 않는다.

## artifact·공개 경계

기본 workflow는 report/log/manifest만 업로드한다. public repo Actions artifact를 private이라고 부르지 않으며 wheel/DLL은 공개하지 않는다. 실제 private repository일 때에만 candidate wheel/download archive 보존 step이 실행된다. public runner의 ephemeral wheel을 가져와야 한다면 별도의 승인된 비공개 저장·정확 payload 검토 경로를 root가 구성해야 한다. 이 draft에는 Release/installer/운영 설치·공개 binary upload가 없다.

대응 source archive는 앱 commit·FFmpeg/PyAV 및 실제 codec/runtime source·패치·build/config/repair/toolchain·NOTICE/license·필요한 재링크 자료를 실제로 제공해야 한다. 임의3년 written offer 또는 존재하지 않는 source asset을 넣지 않는다. SOURCE MIT를 보존하며 binary의 호환 GPL3 조건 선택을 검토할 수 있으나 실제 최종 적합 판정은 pending이다.

## 공식 원문

- [PyAV19 setup.py](https://raw.githubusercontent.com/PyAV-Org/PyAV/v19.0.0/setup.py): `--ffmpeg-dir`와 shared library set.
- [PyAV19 build metadata](https://raw.githubusercontent.com/PyAV-Org/PyAV/v19.0.0/pyproject.toml): setuptools/Cython requirements.
- [MSYS2 base release](https://api.github.com/repos/msys2/msys2-installer/releases/tags/2026-09-27), [GCC package](https://packages.msys2.org/packages/mingw-w64-x86_64-gcc), [NASM](https://packages.msys2.org/packages/mingw-w64-x86_64-nasm), [pkgconf](https://packages.msys2.org/packages/mingw-w64-x86_64-pkgconf).
- [pacman print fields/signatures](https://man.archlinux.org/man/pacman.8.en).
- [FFmpeg legal/build obligations](https://ffmpeg.org/legal.html).
- PyPI version JSON URLs correspond exactly to every wheel's named version. Initial Python metadata read failed CA verification; system TLS-verifying curl read succeeded. TLS checks were never disabled; actual packages were not downloaded during authoring.

검수 상태: **source draft prepared, unexecuted**. Root must syntax-check PowerShell/Bash/Python and run the fresh owned Windows route before accepting build or smoke claims.

## CI11 이후 mandatory 서명 획득 수리

실제 CI11에서 name-only와 SHA 출력은 같은24-package closure로 성공하고 `%g`만139로 실패했다. 보존된 mingw64 DB의23개 선택 항목에는 `%PGPSIG%`가 없고 msys make1개에는 있었다. 이번 source는 nullable `%g`를 다시 호출하지 않고 안전한5field `%n|%v|%f|%h|%l`만 요청한다. core stack 없이 정확한 C crash instruction을 입증했다고 하지 않는다.

copied `msys.db`/`mingw64.db`를 디스크 extraction 없이 bounded tar-image로 읽어 선택 항목의 name/version/filename/SHA를 정확히 대조한다. DB64MiB·100000 members·expanded512MiB·desc64KiB·plan1MiB·closure160개 제한이며 duplicate/unsafe/unknown/mismatched rows는 acquisition 전에 실패한다. 기존 top3 pin과 모든 archive expectedSHA는 유지한다. CI15 수리에서 exact diffutils를 네 번째 필수 pin으로 추가했다.

실제 CI14 copied DB는 Zstandard magic `28b52ffd`였다. 이전12개 authored gzip 검사의 성공은 이 실제 압축 형식 지원을 검증하지 못했고, 기존 parser는 이를 plain tar로 전달하여 실패했다. 이제 gzip·Zstandard·plain tar 경로 모두 tar/PAX 해석 전에 expanded512MiB+1 한도로 읽고 초과 시 실패한다. Zstandard는 Python3.14 표준 `compression.zstd.ZstdFile`을 사용하며 decoder history window도512MiB로 제한한다. 이 optional stdlib 모듈이 없는 interpreter에서는 실패하며 외부 decoder 설치나 무제한 fallback은 없다. compressed DB bytes의 SHA/identity 검사는 유지하며 signature/HTTP/pacman Required trust 규칙은 변경하지 않는다. 실제 copied DB 재검증과 Windows CI 결과는 별도 증거로 기록한다.

서명은 다음 명시적 정책을 따른다. DB에 `%PGPSIG%`가 있으면 strict base64로 해석한 binary bytes를 쓴다. 필드가 있으나 invalid/empty면 fallback 없이 실패한다. 필드 자체가 없으면 그 패키지의 검증된 **동일한 `https://repo.msys2.org/.../<exactfilename>` URL에 `.sig`를 붙인 주소만** 요청한다. HTTPS 인증·정확 host/path·redirect guard는 유지하며 다른 recipe host로도 이동하지 않는다. 서명128..65536B, binary signature packet framing과 HTTP length를 검사한다. acquisition read loop45초와 각 socket15초 제한을 두고 실패 자료를 보존한다; cryptographic verification으로 오해하지 않는다.

[MSYS2 공식 signing 문서](https://www.msys2.org/wiki/Signing-packages/)는 non-armored detached package signature와 pacman의 자체 keyring/trust를 설명한다. 사용자 key를 추가하거나 임의 trust를 부여하는 단계는 새로 넣지 않았다. 실제 공식 GCC/NASM/pkgconf `.sig` 각각566B TLS 취득 관측은 존재하지만 당시 `PGPVerified=false`였다.

lock에는 full planSHA·각 DB SHA·package expectedSHA·signature bytes/SHA/sourceType(URL 포함)를 기록한다. DB/plan이 acquisition 중 바뀌면 install lock을 발행하지 않는다. `install_compiler.sh`의 offline `SigLevel=Required`, `LocalFileSigLevel=Required`, 모든 package+sig 존재 검사와 `pacman -U`는 그대로다. **전체 native PGP/trust/content 검증과 설치가 성공하기 전 다음 compiler/build command는 실행하지 않는다.** 파일을 받거나 구조를 읽은 것만으로 signatureVerified/releaseApproved를 표시하지 않는다.

새 offline unit `Tests/PackagingTests/test_owned_recipe_signatures.py`는 CI11의 공개24-row metadata로 authored DB를 만들고 missing23/embedded1 경로, plan/DB/pin mismatch, malformed signatures, HTTP/redirect/size 실패, acquisition 중 DB 변경을 검사한다. 테스트의 synthetic signature packet은 crypto 검증 자료가 아니다. 저자는 AST 정적검사만 수행하며 root가 unit/Windows/PGP/build를 실행한다. 대응 source/license/최종 bundle과 전체 Goal은 계속 미완료다.


## CI15 stock MF 컴파일 및 configure 도구 수리

CI15에서 실제 Zstandard DB 처리·24패키지 mandatory offline `pacman -U` 설치는 성공했고 FFmpeg9.0.2 stock compile에서 D3D11 타입이 정의되지 않아 실패했다. 고정 archive의 `mfenc.c`는 `CONFIG_D3D11VA`일 때만 D3D11 header를 포함하지만 `MFContext`의 D3D11 타입은 무조건 사용한다. `--disable-autodetect`는 유지하고 `--enable-d3d11va`를 명시한다. configure 후 실제 `CONFIG_D3D11VA`, `CONFIG_MEDIAFOUNDATION`, `CONFIG_H264_MF_ENCODER`가 모두1인지 확인하고 config 자료를 make 전에 보존한다. 실패하면 빌드를 진행하지 않는다. upstream source patch·MF 제외·hardware encoder 강제는 없다. [공식 MF 문서](https://ffmpeg.org/ffmpeg-all.html#MediaFoundation)와 고정 소스의 `hw_encoding` 기본값0 및 conditional hardware 경로를 유지하며 기존 software smoke의 옵션도 바꾸지 않는다. 실제 새 compile/software smoke 결과는 아직 대기다.

같은 configure stderr의 `cmp: command not found`는 stock configure가 `cmp -s`를 사용하는 데서 발생했다. [공식 diffutils package](https://packages.msys2.org/packages/diffutils)와 CI15 copied `msys.db`의 exact `diffutils=3.12-1`, `diffutils-3.12-1-x86_64.pkg.tar.zst`, SHA `7902c8ce3d4dd69a0f5e98dc9d5c83c17b23314ba486169db57ef6e2835ce3b6`를 네 번째 필수 pin으로 넣는다. `/usr/bin/cmp.exe`가 해당 패키지에 속하는지/설치 version/command path를 확인하고 실제 cmp version·파일 SHA를 configure 전에 기록한다. 새 패키지와 모든 새 transitive 항목도 기존 full closure lock·DB 대조·expectedSHA·mandatory signature/offline Required trust 검증을 그대로 거친다. CI15 DB의 diffutils에는 embeddedPGPSIG가 있지만 다른 날 필드가 없으면 기존 동일한 공식 URL `.sig` 규칙만 허용한다.

공개 unit 자료의 기존24개 metadata 원문은 보존하고, 별도 diffutils row를 추가한25-row authored control로 검사를 확장한다. 이는 다음 실제 dependency closure가25개라고 가정하지 않는다. 역사24만으로는 새 필수 pin이 누락되어 거부해야 한다. 새 exact-pin/DB mismatch/invalid-present-signature/no-fallback/lock-binding 회귀는 offline structural 검사이며 crypto·실제 Windows compile·software encode 성공 증거로 쓰지 않는다. `recipe_support.py`와 `install_compiler.sh`의 보안 경로는 변경하지 않았다.
