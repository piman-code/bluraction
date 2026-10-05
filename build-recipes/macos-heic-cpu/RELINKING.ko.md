# Mac CPU HEIC: 변경 라이브러리와 대응 소스 자료

BlurAction의 CPU HEIC helper는 libheif 1.23.5, libde265 1.1.3, Kvazaar 2.3.2의 세 공유 라이브러리를 사용한다. 실제 upstream COPYING에서 libheif/libde265의 LGPL3와 Kvazaar의 BSD3 및 별도 notice를 확인한다. 앱 소스의 MIT 라이선스를 자동 변경하지 않는다. 라이브러리 notice와 GNU GPL/LGPL 전문은 배포 자료에 함께 제공해야 한다.

[GNU LGPL3 §4(d/e)](https://www.gnu.org/licenses/lgpl%2Bgpl-3.0-standalone.html)는 대응 소스·애플리케이션 코드로 재결합할 수 있는 경로 또는 호환되는 변경 라이브러리를 사용하는 공유 링크 경로, 해당될 때 변경본 설치·실행 정보를 다룬다. 아래 도구는 실제 새 복사본과 자료의 해시를 확인하는 준비 도구다. 어느 선택이 전체 배포 의무를 충족하는지, User Product 조건의 적용, 다른 의존성의 의무를 법률적으로 확정하지 않는다. 역공학·라이브러리 수정 권리를 제한하는 추가 조건을 두지 않는다.

## 원본 보존과 변경본

원본 앱·빌드 prefix·설치본은 수정하지 않는다. 실제 macOS에서 root가 준비한 별도 작업 폴더와 새 `.app` 이름을 사용한다. `/Applications`, 사용자 Applications, 시스템 경로는 출력으로 허용되지 않는다. 입력·부모 경로는 symlink 없이 canonical 절대 경로여야 한다. `/tmp`·`/var` 별칭 대신 실제 `/private/...` 경로를 쓴다. 출력이나 `.app.relink.json`이 이미 있으면 다른 이름을 선택한다.

1. `pins.json`에 고정된 세 source archive의 실제 SHA를 확인한다. 별도 소스 복사본에서 원하는 LGPL 라이브러리를 수정한다. 버전·ABI·install name을 유지하고, 변경 source/patch와 실제 CMake flags/toolchain을 보존한다. 수정하지 않은 원본 archive만 제공하고 변경 source를 누락해서는 안 된다.
2. `build_recipe.py`가 기록하는 macOS14 deployment target·동일 architecture·공유 라이브러리·Kvazaar/libde265 built-in 구성으로 별도 prefix에 다시 빌드한다. helper를 다른 ABI에 맞춰 바꿔야 하는 수정은 아래 library-only 도구의 지원 계약 밖이므로 함께 helper/application source를 다시 빌드해야 한다.
3. 입력은 symlink 별칭이 아닌 실제 versioned dylib 세 개다. 원본 app의 helper는 그대로 복사한다. 도구는 새 복사본의 CWD rpath만 제거하며 known `@rpath/libheif.1.dylib`, `libde265.0.dylib`, `libkvazaar.7.dylib` 및 Apple system 링크만 허용한다. helper의 유일 rpath는 `@loader_path/../Frameworks/HEIC`다.

```sh
python3 scripts/relink_heic_cpu.py \
  --source-app /absolute/owned-original/BlurAction.app \
  --libheif /absolute/modified-inputs/libheif.1.dylib \
  --libde265 /absolute/modified-inputs/libde265.0.dylib \
  --libkvazaar /absolute/modified-inputs/libkvazaar.7.dylib \
  --output-app /absolute/new-work/BlurAction-owner-modified.app
```

실제 versioned 파일 이름은 빌드 inventory를 사용한다. 예시의 modified-inputs는 그 실제 파일을 위 이름으로 복사한 별도 regular file이며 symlink가 아니다. 결과 앱은 helper·세 라이브러리의 새 SHA를 Info.plist에 기록하고 세 라이브러리/helper/app을 ad-hoc 서명·검증한다. 기본 integrity 정책을 우회하는 제품 옵션은 추가하지 않는다. 새 앱의 library source 기록은 원래 upstream 기록과 분리하며 변경 source 대응은 검증 전 상태로 남긴다. notarization·공식 서명·설치/공개는 수행하지 않는다.

원본 전체 파일과 입력 dylib의 identity/SHA를 전후 비교한다. 실패한 새 app/journal은 소유자가 검토할 수 있게 남긴다. 원본을 되돌리는 작업은 필요하지 않으며 실패 출력의 자동 삭제·재사용도 하지 않는다. 도구는 앱/helper를 실행하지 않으므로 실제 변경본 인코딩의 성공 증거는 별도다.

작업 디렉터리는 한 소유자가 사용하며 실행 중 다른 작업이 입력·출력 경로를 변경하지 않도록 한다. 고정 Apple 도구 호출에는 개별 120초·출력 4MiB 제한과 새 process group 종료/direct child reap이 있지만, root의 별도 전체 작업 watchdog도 유지한다. 네이티브 검사·서명이 멈추거나 정리 실패가 보고되면 미완료 결과를 성공본으로 사용하지 않는다.

root의 실제 검수는 원본과 새 변경본에서 같은 합성 RGBA 입력을 인코딩하고 native ImageIO 재열기를 확인한다. 변경 library의 알려진 기능·버전 표식이 runtime에서 관측돼야 하며, 픽셀·alpha·metadata/차폐·codec 기능을 검사한다. 변경 library를 쓰면서 원본 bundle·원본 library가 그대로인지 확인한다. ad-hoc 서명 검증만으로 이 검수를 통과했다고 하지 않는다. Gatekeeper/공증·깨끗한 사용자 설치는 후속 실제 검수로 남는다. 시스템 보안 설정을 전역으로 바꾸는 명령을 제공하지 않는다.

## 대응 소스 ZIP 준비

`package_mac_heic_sources.py`는 원래 검수된 owned build와 원래 app manifest를 대상으로 한다. 임의 변경 library의 대응 source를 자동으로 원래 archive에 연결하지 않는다. 변경본 배포 자료는 실제 변경 source/patch와 재현 설정을 추가로 검수해야 한다.

필수 입력은 실제 owned archives3/acquisition/build/licenses, 원래 app manifest·helper/source/library 해시, root가 검수한 전체 앱 소스 archive의 SHA와 commit, 실제 GNU GPL3/LGPL3 전문 파일과 각각의 SHA다. GNU 전문은 공식 원문을 확보해 사용하며 placeholder·요약문으로 대체하지 않는다. source archive는 extraction 없이 member·크기·링크·경로를 검사한다. 전체 application source의 committed 합성 fixture 데이터는 보존하지만 compiled executable/object, `.build`, QA 폴더, raw 로그·개인 환경자료는 거부한다. 이 archive의 privacy/secret 검수는 root의 최종 공개 자료 검수와 함께 수행한다.

```sh
python3 scripts/package_mac_heic_sources.py \
  --owned-root /absolute/owned/source-build \
  --source-app /absolute/owned-original/BlurAction.app \
  --app-source-archive /absolute/curated/BlurAction-full-source.tar.gz \
  --app-source-sha256 ACTUAL_64_HEX \
  --app-source-commit ACTUAL_40_HEX \
  --gpl-text /absolute/verified/GNU-GPL-3.0.txt --gpl-sha256 ACTUAL_64_HEX \
  --lgpl-text /absolute/verified/GNU-LGPL-3.0.txt --lgpl-sha256 ACTUAL_64_HEX \
  --output /absolute/new-work/BlurAction-HEIC-source-materials.zip
```

ZIP에는 정확 upstream archives3, 실제 notice 전문, GNU 전문, recipe/helper source·build instructions·relink 도구, 전체 앱 source archive, 경로를 제거한 실제 build settings, bounded member SHA manifest가 들어간다. helper/dylib/app 실행파일, compiler 생성물, raw absolute-path build logs는 들어가지 않는다. 원본 입력의 SHA/identity를 재검사하고 ZIP member SHA를 다시 읽는다. 공개 이름을 exclusive 생성하므로 실패한 partial ZIP은 자동 삭제·교체하지 않는다. root가 incomplete 결과를 검토한 뒤 별도 새 이름으로 다시 준비한다.

도구는 `scripts/`, recipe는 `build-recipes/macos-heic-cpu/`, identity 보조 코드는 `shared/source_identity.py` 상대 경로를 유지한다. 검수한 ZIP을 새 폴더에 풀어 그 루트에서 같은 명령을 사용할 수 있다. 소스 재현에 필요한 Python 버전은 3.11 이상이며 실제 앱 빌드는 recipe의 고정 CMake/Ninja 및 Apple compiler/SDK 계약을 따른다. 자동 환경 설치는 하지 않는다.

이 결과의 `sourceMaterialsHashBound`는 자료의 byte binding이다. 앱 binary reproducibility, 실제 modified-library encode, 전체 legal corresponding-source certification, release approval은 false로 남는다. 실제 source-built 원본 archive와 빌드/notice를 함께 제공하고 직접 받을 수 있는 source asset을 준비하며, 아직 없는 source asset이나 임의 장기 written offer를 완료 증거로 표시하지 않는다.
