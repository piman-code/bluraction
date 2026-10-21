# MainWindowController 분리 설계 — 2026-10-21

상태: 설계안. 코드는 바꾸지 않았다. 기준 파일은 커밋 `306fe5c`의 `Sources/BlurAction/MainWindowController.swift`(5,512줄)다.

## 왜 나누나

모든 기능이 이 파일 하나에 들어 있다. 추적 하나를 고치려 해도 5,500줄을 읽어야 한다. 목표는 **동작을 하나도 바꾸지 않고** 기능별로 파일을 나눠, 한 기능을 고칠 때 수백 줄만 읽으면 되게 하는 것이다.

## 알아둘 사실 (확인한 근거)

**MARK 구획 이름표가 실제 내용과 다르다. MARK 기준이 아니라 기능 기준으로 나눠야 한다.**
- "Layer list: drag"(2426–2753) 안에 `setExporting`(2482), 이미지 내보내기, 실행취소/다시실행(2576–2612), 도구 설정 처리가 있다.
- "Selected item timing"(3888–4608) 안에 미디어 열기 `load`(4174–4340), 페이지 이동, `refreshRegionList`(4594)가 있다.
- "Layout"(335–1419) 안에 캔버스 연결 클로저(440–588), `playheadTime`, `checkpoint`(609), 재생기가 있다.

**공통 핵심 상태는 따로 떼기 어렵다.**
- 핵심 상태: `doc`, `pageWorkspace`, `pairs`, `annotations`, 선택 3종, 실행취소 기록, `isExporting`, `canvas`, `liveBlur`, `player`
- 공통 도우미: `checkpoint`, `setExporting`, `playheadTime`, `refreshRegionList`, `refreshAfterEdit`, `showError`
- `pairs`는 15개 구획이 쓰고, `checkpoint`는 16개 구획에서 부른다.

**테스트가 기대는 것**
- `@testable import`로 internal 멤버 약 55개를 직접 부른다.
- private `@objc` 동작을 이름 문자열로 직접 부른다. 예: `perform(NSSelectorFromString("undoTapped"))` 72회, `addRegionTapped` 45회, `redoTapped` 15회.
  - **이 동작들을 컨트롤러 밖으로 옮기면 빌드는 통과하지만 테스트가 실행 중에 깨진다.**
- 버튼 제목과 뷰 계층으로 컨트롤을 찾는다. 예: "붙이기", "이 구간 다시 추적", 3칸 탭.
- 편집기 테스트 도구(`EditorSession`)는 `init` 직후 캔버스 클로저(`regionsBinding`, `effectForID`)가 연결돼 있어야 한다.

**접근 제어**
- `private` 선언이 405개 있고, 그중 약 335개가 다른 구획에서 쓰인다(이름 기준 추정치).
- Swift의 `private`은 파일 단위다. 파일을 나누면 이 멤버들을 internal로 넓혀야 한다.

## 단계

### 1단계: 같은 타입의 extension으로 파일만 옮긴다 (먼저, 한 번에)

- 저장 속성은 extension에 둘 수 없으므로 본 파일에 남긴다.
- 옮긴 코드가 쓰는 `private`만 internal로 바꾼다. 서명, `@objc` 이름, 버튼 제목, 호출 순서는 그대로 둔다.
- 순서가 바뀌는 곳은 단 한 군데다. `configureContent`에서 캔버스 연결 부분을 `configureCanvasBindings()`로 떼어, 같은 자리에서 부른다.
- 테스트 수정은 필요 없을 것으로 예상한다.

`Sources/BlurAction/MainWindow/` 아래 예상 구성:

| 파일 | 내용 | 줄 수 |
|---|---|---|
| `MainWindowController.swift` | 속성, init, setupUI, checkpoint/제스처, 실행취소, setExporting, showError, 취소, 목록 갱신 | ~800 |
| `+CanvasBindings.swift` | 캔버스·liveBlur 클로저 | ~160 |
| `+Sidebar.swift` | configureSidebar~configureMenu | ~660 |
| `+Playback.swift` | 재생기, 재생 동작 | ~230 |
| `+Export.swift` | 영상·이미지 내보내기 | ~240 |
| `+Tracking.swift` | 자동 추적 | ~350 |
| `+Finding.swift` | 얼굴·글자·문구 찾기 | ~500 |
| `+ToolInspector.swift` | 도구·지우개·글자 설정 | ~430 |
| `+ItemEditing.swift` | 그리기·지우기·그룹·레이어 속성·순서 | ~560 |
| `+Project.swift` | 프로젝트 저장·열기 | ~400 |
| `+SelectedItem.swift` | 선택 항목 시간 편집 | ~290 |
| `+MediaAndPages.swift` | 미디어 열기, 페이지 | ~420 |
| `+ContextMenu.swift` | 우클릭 메뉴 | ~190 |
| `+LayerList.swift` | 도구막대·표 delegate | ~250 |
| `+CoverReview.swift` | 가림 글자·확인 구간 | ~410 |

검증 순서:
1. `./scripts/test.sh --build-only`
2. 관련 묶음을 먼저 돌린다: AutoFindTrackingLayerList, EditorInteraction, MotionAndTools, PortableProjectCompatibility, MacCoverWorkflow.
3. 전체 `verify_mac.py`를 돌린다(HEICCPUExporterTests 제외, `--suite`는 bash 배열로 전달).
4. diff를 보고, 옮긴 줄 밖에서는 `private` 키워드만 바뀌었는지 확인한다.

위험은 낮다. 접근 오류는 빌드에서 모두 잡힌다.

### 2단계: 화면과 무관한 로직을 값 타입으로 뺀다

- **`EditHistory`**(~120줄): 실행취소·다시실행·병합 편집·제스처 스냅샷·50개 제한.
  - 지금은 실행취소 기록을 쓰는 곳이 7군데로 흩어져 있다(checkpoint, endGesture, undo/redo, 창 크기 변경, applyProject, 미디어 열기, 페이지 저장·복원). 이것을 인터페이스 하나 뒤로 모은다.
  - `checkpoint()`는 컨트롤러에 한 줄 전달 함수로 남겨, 부르는 곳은 바꾸지 않는다.
- **`TrackingMerge`**: 추적 결과 병합·연장, `fittedCover`, `refinementGaps`. 순수 함수로 만들고 단위 테스트를 추가한다.
- **`FindPlacement`**: `coverFound`의 "이미 가려졌는지" 판정과 확대 로직.
- 프로젝트 변환 도우미(`clipped`/`newGroup` 등)를 정적 함수로 뺀다.

### 3단계: 상태를 가진 협력 객체 (나중에, 필요할 때만)

- `TrackingCoordinator`, `FindCoordinator`, `ProjectIO`, 사이드바 컨트롤 묶음(`InspectorControls`)
- 작업 중 잠금 목록을 구성 요소별 등록 방식으로 바꾼다. 지금 `setExporting`은 컨트롤 약 36개를 이름으로 직접 나열한다.
- 위험은 중간~높음이다. 모든 협력 객체가 `setExporting`, `checkpoint`, 진행 표시를 위해 컨트롤러를 다시 불러야 한다. 협력 객체는 컨트롤러를 `weak`로 잡아야 한다.

## 함정

- **실행취소 한 단계 규칙**
  - 찾기 뒤 추적은 앞 단계를 재사용해서 한 단계가 된다(`undoWithPrevious: true`, 2186·2392행, `newUndoStep:` 1884행).
  - 마우스 제스처는 `checkpoint`가 아니라 `endGesture`로 기록을 쌓는다.
- **작업 중 잠금:** `isExporting`은 `private(set)`을 유지하고, 쓰는 곳은 `setExporting` 하나뿐이어야 한다. 잠금 목록에서 빠진 컨트롤은 내보내기 중에도 눌린다.
- **캔버스 클로저:** `[weak self]` 클로저 약 50개가 `init`에서 연결된다. `regionsUpdate`는 그룹 이동과 실행취소 기록을 함께 다루므로 한 덩어리로 옮긴다.
- **표 delegate:** `refreshingList`가 선택 변경이 다시 목록 갱신으로 이어지는 되먹임을 막는다. delegate는 컨트롤러로 유지한다.
- **비동기 작업 결과 확인:** 결과를 적용하기 전에 문서가 바뀌지 않았는지 확인한다(`FindContext` 비교, `doc === operating`). `cancelTapped`의 우선순위 순서와, 창을 닫을 때 작업 5개를 취소하는 부분도 그대로 유지한다.
- **구성 순서:** content → sidebar → toolbar → menu → player 순서다. `applyInspectorPolish` 뒤에 `inspectorConfigured = true`가 온다. `seekCoordinator`는 lazy다. 이 순서를 모두 유지한다.

## 하지 말 것

- 테스트가 이름으로 부르는 `@objc` 동작을 컨트롤러 밖으로 옮기지 않는다.
- 기존 MARK 이름표대로 나누지 않는다.
- 코드 이동과 로직 변경·이름 변경을 한 변경에 섞지 않는다.
- 사이드바 컨트롤 묶음이나 협력 객체부터 시작하지 않는다.
- `VideoCanvasView`와 컨트롤러 사이에 프로토콜이나 서비스 계층을 끼우지 않는다.

## 함께 정리할 것

- 분리 후 CLAUDE.md의 "~4.4k lines" 설명을 갱신한다.
- `SidebarViewController.swift`는 쓰는 곳이 없어 보인다. 이번 분리와는 별개로 판단한다.
- Codex의 커밋되지 않은 `docs/*`, `build-recipes/*`는 건드리지 않는다. 바뀐 Swift 파일만 명시해서 올린다.
