# 실제 Mac → Windows → Mac 영상 v3 왕복 검사

이 별도 필수 검사는 실제 운영체제에서 프로젝트를 생성·읽기·편집·저장하고 원본을 다시 확인한다. 정상 Mac/Windows 회귀 검사와 구분한다. `VideoProjectCrossPlatformRoundTripHarness.swift`는 기본 `*Tests.swift` 목록에 들어가지 않고, Windows 단계도 기본 `test_*.py` 목록 밖에 있다. 환경 변수가 없는 Swift 검사의 disabled 결과는 성공 증거가 아니다. driver는 잘못된 실제 OS, 누락 입력, timeout, skip, 불완전 summary/packet, 입력 변경을 nonzero로 거부한다.

현재 두 허용 원본은 저장소의 합성 `nonzero-origin.mov`와 `video-negative-twelfth-audio-negative-quarter.mov`다. 원본·manifest SHA를 코드에 고정했고 학생 자료, 외부 미디어, 파일 패널, OS 입력, 앱 설치를 사용하지 않는다. descriptor/RGB를 호스트별 상수로 추측하지 않는다. 실제 Mac AVFoundation 바인딩과 Windows owned PyAV 바인딩이 같은 exact timeline을 보고해야 한다.

## 실행 단계

저장소 루트에서 실행한다. 아래 `.build` 대상 이름은 매번 새 이름이어야 한다. 각 driver는 0700 새 attempt와 `payload/`를 만들며 180초의 private process group 또는 Windows Job Object로 자신이 시작한 자식을 정리한다. 로그와 `report.json`은 실패해도 보존한다. Mac은 기존 `scripts/test.sh`와 macOS 14 이상 Swift Testing 환경, Windows는 실제 Python 환경의 모든 고정 native 의존성이 필요하다. 추가 설치·다운로드는 driver에 없다.

```sh
python3 scripts/video-project-roundtrip/run_stage.py --stage mac-emit --output .build/roundtrip-mac-emit-NEW
```

Mac의 `payload/`만 Windows의 저장소 `.build/roundtrip-incoming-mac-NEW/`로 전달한다. 해당 디렉터리에는 payload 파일만 둔다. 실제 Windows에서:

```powershell
python scripts/video-project-roundtrip/run_stage.py --stage windows-edit --input .build/roundtrip-incoming-mac-NEW --output .build/roundtrip-windows-edit-NEW
```

Windows의 `payload/`만 Mac의 `.build/roundtrip-incoming-windows-NEW/`로 전달한다. 실제 Mac에서:

```sh
python3 scripts/video-project-roundtrip/run_stage.py --stage mac-verify --input .build/roundtrip-incoming-windows-NEW --output .build/roundtrip-mac-verify-NEW
```

Mac의 첫 단계는 실제 `MainWindowController.openVideoProject/saveVideoProject`를 사용한다. 사각·타원·다각 효과와 6종 그림, 반투명 색·채움, 그룹/순서, 중복·역순 motion keyframe, 전체/시점 지우개, 원본 기간 밖 시간 범위, explicit null을 생성한다. Mac의 숫자 `1.2500e+1` 원문 보존도 첫 저장에서 확인한다. Windows는 실제 `Workspace.load_project`, 원본 바인딩, 실제 frame decode와 renderer 적용, 그림 하나의 이름 변경, undo/redo, `save_project`를 검사한다. 마지막 Mac 단계는 Windows 출력에서 그 명시적 변경만 달라졌는지 검사하고 실제 controller로 다시 저장한다. Windows JSON 숫자 표기 정규화와 값/원본 시간 보존은 구분하며, 숫자 lexeme 전체가 양 OS에서 동일하다고 주장하지 않는다.

## 전달물과 판정

전달 가능한 자료는 검증된 `payload/`만이다. 원본 MOV 2개, 프로젝트 2개/4개, 경로 없는 packet와 Windows pixel observations를 포함한다. driver는 정확한 이름/개수/SHA를 검사한다. 실패 attempt나 private 실행 로그/절대 경로 source snapshot을 전송할 자료로 사용하지 않는다. CI에서 세 단계를 순차 실행하고 마지막 두 `mac-return` 프로젝트와 세 report가 모두 completed이어야 이 gate가 완료다. 직접 Swift 테스트 실행 또는 Windows 파일 직접 실행만으로 gate 통과를 기록하지 않는다.

현재는 실행 전 source 준비 상태다. 실제 Windows, 양 OS 왕복 통과, 원본 렌더 AA/글꼴 완전 동등성, 영상 내보내기/오디오 장치, HDR, 일반 컨테이너, 설치/릴리스/전체 Goal 완료의 증거가 아니다. source hash와 소유 process tree의 종료도 driver가 확인한다.
