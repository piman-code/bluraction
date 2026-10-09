# Windows local4 작업 종료 및 Mac handoff — 2026-10-09

GitHub 저장소: https://github.com/piman-code/bluraction
작업 브랜치: `codex/windows-auto-find-local`

## 현재 상태

사용자는 Windows local4가 정상 작동한다고 확인했으며, 모든 추적 옵션을 켠 경우의 속도 저하는 남아 있다. 정확도에 영향을 줄 수 있는 추가 알고리즘 변경은 보류하고 배포 준비 폴더/ZIP을 만들었다. 공개 배포나 설치본 완성으로 판정하지 않았다.

Windows 소스 작업은 `66b29e7df0779548d9c28e4bbb0f0963fa34a894`에서 시작했다. Mac 동작 참고는 `2c2c6aa601766c6d0f3a360afecb2d9d5673ca1a`이다. handoff 직전 원격 main `529a5584c955c9a7b7f76ff5cb664438bc4dc2fe`를 fast-forward로 포함했다. 이 브랜치는 최신 Mac 0.9.1 코드와 아래 Windows 변경을 함께 포함한다. Windows에서 Swift/Mac 네이티브 실행을 검증한 것은 아니다.

## 완료한 Windows 변경

- 일반 PDF의 투명한 종이를 흰 배경으로 합성해 검은 글자가 보이지 않던 문제를 수정했다. PNG 원본의 alpha는 유지한다.
- PDF의 page-local UserUnit을 새 Windows 로드에서 반영하며 crop/rotation/프로젝트/출력 검사를 추가했다. 이전 편집 좌표는 기존 검토 정책을 유지한다.
- 영상 SAR은 실제 frame → codec → stream의 유효한 값 순서로 해석한다. 메타데이터가 모두 생략된 일반 영상은 square-pixel 정책을 적용한다. 잘못된 음수/형식은 거부한다. 원본 관측 메타데이터 자체를 바꾸지 않는다.
- 오프라인 YuNet 얼굴 검출과 PP-OCRv3 글자 영역 검출, 중복 제거, 현재 화면 찾기, 원자적 undo/redo, 찾은 것 선택/삭제 및 취소를 추가했다. 글자 영역 찾기는 OCR 내용 전사가 아니다.
- 여러 대상의 CSRT 추적, 실제 PTS 기록, 앞/뒤/양방향, 흔들림 완화, 제한된 얼굴 재검출을 추가했다. 재검출은 신원 확인이 아니며 근접한 얼굴이 모호하면 자동 연결하지 않는다.
- 디코더 2-worker SLICE 설정, 검증된 연속 프레임 디코더 재사용, Windows TCP_NODELAY, 재생 전용 640-pixel proxy와 원본 크기 일시정지/찾기/출력을 적용했다.
- 블러를 필요한 범위와 유한 halo로 제한하고, 가림 픽셀만 양자화하며 미리보기 작업 QThread를 재사용한다. normalized 가림 좌표와 원본 시간축 계약을 유지한다.
- ‘영상에서 찾은 뒤 앞뒤로 추적’의 기본 체크를 해제했다.
- 실행 파일 한글 이름에서 window.show 중 native abort를 재현했다. 동일 bytes의 영문 파일명은 정상 시작/종료했다. 배포 준비본은 `BlurAction.exe`를 사용한다. 근본 Qt/CRT 충돌 수정으로 주장하지 않는다.
- Windows 패키징 기본 버전을 local4로 맞추고 모델/라이선스를 hash-check해서 포함하도록 했다. 기존 산출물 삭제/clean 명령을 제거한 수정도 함께 보관한다.

## 모델과 소스 위치

`Resources/windows-auto-find/README.md`에 pinned revision, SHA-256, MIT/Apache-2.0 원문이 있다. 모델은 Git에 포함되어 있어 앱이 실행 중 다운로드하지 않는다.

핵심: `platforms/windows/bluraction/auto_find.py`, `auto_tracking.py`, `find_actions.py`, `display_geometry.py`, `canonical_video.py`, `canonical_transport.py`, `video.py`, `renderer.py`, `preview_worker.py`, `ui.py`.

검사: `Tests/WindowsAppTests/test_auto_find_windows.py`, `test_display_geometry.py`, `test_pdf_user_unit.py`, `test_windows_performance.py`와 기존 수정 테스트.

`windows_ocr.py`와 `Resources/windows-auto-find/windows-ocr.ps1`은 보존한 Windows OCR 프로토타입이다. local4 EXE에 동봉하거나 실행하지 않았고 제품 경로는 `auto_find.py`이다.

## 검증과 재현

공개 요약은 [windows-local4-validation-20261009.json](handoff/windows-local4-validation-20261009.json)에 있다. 원본/실명/로컬 상세 로그/검수 영상은 업로드하지 않는다.

- 2026-10-09 선택 회귀 97개 통과. 기존 91개에 실제 PDF UserUnit/종이/alpha 검사 6개를 더했다. 파일 보존을 위해 삭제 여부를 주장하는 기존 2개 테스트는 제외했다. 전체 테스트 통과라고 표현하지 않는다.
- 실제 Windows EXE 영상 9사례 및 가림 native 출력 4사례는 이전 r4 EXE에서 통과했고, 해당 영상 핵심 모듈들은 최종 EXE와 같은 source SHA이다.
- 새 배포 폴더의 최종 EXE에서 얼굴/한글·영문 글자 찾기, 2대상 실제 CSRT 양방향 추적, VFR PTS, undo/redo와 가림 픽셀 검사를 다시 통과했다. 일반 Windows 창 생성/응답/종료도 별도로 확인했다.
- 10초 1080p/블러 4개: 당시 열기 4.274초, 연속 decode+render 약 13.7–14.9fps, 실제 offscreen Qt loop 약 5.50fps. 부하에 따라 크게 달라지고 30fps 보장은 없다.
- 로컬 포장은 기존 native runtime을 재사용한 PyInstaller PYZ repack이다. 새로운 전체 PyInstaller 빌드/설치 프로그램/전자서명/공개 릴리스는 아니다.

이미 준비된 Qt/media Python 환경에서 저장소 루트 기준으로 아래 선택 검사를 실행할 수 있다. 스크립트는 의존성을 설치하지 않는다. 출력 경로는 존재하지 않는 새 경로여야 한다.

```text
python scripts/verify_windows_local4_retained.py --output qa-local4-handoff-new
```

Windows requirements는 `platforms/windows/requirements-dev.txt`를 확인한다. Mac Python 환경에서 같은 Qt 검사 실행을 완료했다고 주장하지 않는다. 기본 `candidate_smoke.run()` 및 전체 테스트는 자동 임시파일 cleanup을 수행할 수 있으므로 파일 삭제 금지 조건에서 그대로 실행하지 않는다. retained runner와 `--auto-find-only`, `--video-fixtures`, `--performance-fixture` 진단의 범위를 구분한다.

## 성능이 느린 이유와 다음 개선 후보

조사 당시 PC는 i5-1335U / 약 7.7GiB RAM / Iris Xe였다. 한 측정에서 여유 RAM 0.67GiB와 CPU 전체 사용률 97%를 관측했지만 지속 측정이나 앱 단독 점유율은 아니다.

현재 자동 찾기+추적은 원본 크기 프레임과 각 대상의 CSRT를 사용한다. 양방향 추적은 현재 프레임의 앞뒤를 처리하고, 뒤로 추적은 반복적인 이전 프레임 seek가 병목이다. 놓친 얼굴을 다시 찾으면 검출을 추가 실행한다. 글자 검출은 1080p 화면에서 최대 25회 tiled passes를 사용한다. 흔들림 완화보다 프레임 디코딩/대상별 추적/재검출이 큰 비용일 가능성이 높다.

추가 개선은 별도 후보에서 축소 추적, bounded reverse-frame block, 재검출 간격, 모델 재사용 등을 비교한다. 품질 저하나 오가림 없이 원본 좌표·원본 PTS·VFR·회전·SAR·취소·원본 지문을 유지하는 증거가 있어야 기본값을 바꾼다. 실행 재생 proxy를 자동 찾기/출력의 원본 픽셀로 오인하지 않는다.

## 공개 배포 전 남은 사항

`docs/의존성과-라이선스-검토.md`, `docs/Windows-설치후보-검증-20261003.md`의 미완료 항목을 확인한다. stock Qt·FFmpeg·HEIF 및 하위 바이너리에 대응하는 source/build 자료와 배포 조건 검토가 남아 있다. 앱 MIT LICENSE나 모델 원문만으로 전체 결합 배포 승인을 대신하지 않는다. 기존 pending 기록을 임의로 reviewed로 바꾸지 않는다.

이번 작업으로 만든 ZIP은 로컬 준비본이다. 앱 소스 snapshot도 전체 native 대응 소스를 대신하지 않는다. GitHub에는 native DLL/EXE/검수 영상/ZIP을 올리지 않는다. remote CI는 이번 handoff 커밋에서 dispatch하지 않는다.

## Windows에 보존한 자료

다음 경로는 Windows 로컬이며 Mac에 존재한다고 가정하지 않는다.

- `C:/Users/user/Desktop/개발/배포준비-20261007/BlurAction-Windows-0.9.1-local4/BlurAction.exe`
- 같은 상위 폴더의 portable ZIP, 앱 source ZIP, SHA256SUMS.txt 및 배포준비-안내.md
- `C:/Users/user/Desktop/개발/outputs/BlurAction-성능개선-20261007`: 이전 빌드/성능/영상/자동 찾기 증거
- `C:/Users/user/Desktop/개발/outputs/BlurAction-배포준비-20261007`: 새 패키지 검사와 ZIP manifest 검증
- `C:/Users/user/Desktop/개발/outputs/BlurAction-handoff-20261009`: 이번 97개 검사 원본 기록
- 바탕화면 `BlurAction (성능개선).lnk`는 새 배포 준비 폴더를 가리킨다.

최종 EXE SHA-256: `33ed9550da34223c932c54de44539481cb064e6689c0dd481142b757df2d2b9e`.
portable ZIP SHA-256: `b3bbb73778267805b83290fa967c155131816e7dda59ed766141b24aad118323`.

## Mac에서 이어갈 때

1. 현재 Mac checkout과 변경/운영 앱 상태부터 확인한다. 사용자 변경을 보존한 뒤 origin의 `codex/windows-auto-find-local`을 가져온다. 이 브랜치는 위 main까지 포함하므로 오래된 Mac 코드를 다시 옮기지 않는다.
2. 이 문서와 검증 요약을 읽고 현재 Mac native 구현/실제 앱 버전을 확인한다. Windows 검사 통과는 Mac GUI 또는 설치 검수를 대신하지 않는다.
3. Mac의 `AutoDetector.swift`, `ObjectTracker.swift`, `MainWindowController.swift`와 Windows 구현의 시간축/취소/undo/가림 coverage 계약을 비교한다. 기능이 이미 있는 Mac에 중복 이식하지 않는다.
4. 다음 단계는 공개 배포 준비의 남은 의존성 대응 source/build 검토를 이어가는 것이다. 속도 개선은 정확도 검증이 가능한 별도 후보에서만 진행한다.
5. 기존 `/Applications/BlurAction.app`, 프로젝트/원본/백업은 보존한다. Mac 빌드는 `scripts/build_app.sh --build-only --no-install` 경로와 그 내부 동작을 먼저 읽고 판단한다. 이번 handoff를 운영 앱 교체나 공개 게시 승인으로 확대 해석하지 않는다.

사용자 작업 규칙: `rm`/`rg` 사용 금지(우회 포함), 파일 영구 삭제 금지, 정리가 요청되면 휴지통만 사용, 빌드/설치 전 삭제 동작을 확인하고 새 산출물 경로 사용. Computer Use는 사용하지 않으며 CLI는 허용했다. 이 규칙을 Mac 작업에서도 계속 지킨다.
