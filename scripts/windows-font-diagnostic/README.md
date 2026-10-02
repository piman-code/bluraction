# 새 Windows 글꼴 backend 진단 초안

CI7 원문 `test_ui.log`는43개 중 named-font 검사1065의 `font_available('Monospace')`에서1개 실패했다. 현재 renderer는 native FixedFont→실제 fixed family→style hint 순서이며, DB와 QFontInfo의 fixedPitch가 불일치/비어 있는 원인은 아직 관측하지 않았다. 제품·테스트·고정폭 단언은 변경하지 않았다. 이 QA는 미실행이며 syntax/actual Windows 결과를 root가 확인한다.

Qt **v6.11.1** 공식 소스에서 Windows offscreen은 QFreeTypeFontDatabase를 구성한다. 이 DB는 QT_QPA_FONTDIR 또는 Qt libraries/fonts의 파일을 탐색한다. native windows plugin과 같은 설치 글꼴 registry 결과라고 가정할 수 없다. offscreen FixedFont 요청도 literal monospace다. 이는 조사할 backend 차이이며 CI7의 실제 family census를 대신하지 않는다. [offscreen 구현](https://raw.githubusercontent.com/qt/qtbase/v6.11.1/src/plugins/platforms/offscreen/qoffscreenintegration.cpp), [FreeType DB](https://raw.githubusercontent.com/qt/qtbase/v6.11.1/src/gui/text/freetype/qfreetypefontdatabase.cpp), [fontDir](https://raw.githubusercontent.com/qt/qtbase/v6.11.1/src/gui/text/qplatformfontdatabase.cpp).

QFont의 요청 fixedPitch를 true로 설정한 사실만으로 실제 고정폭을 증명하지 않는다. QFontInfo는 matched face를 관측하고, 이 진단은 i/W의 실제 양수 advance·고정폭 flag·glyph availability를 별도로 기록한다. 한글의 advance를 ASCII와 같도록 강제하지 않으며 한글 glyph/fallback은 별도로 관측한다. [Qt6.11 QFontInfo](https://doc.qt.io/qt-6.11/qfontinfo.html), [DB](https://doc.qt.io/qt-6.11/qfontdatabase.html); docs 사이트는6.11.2로 표시되므로 implementation 근거는 위6.11.1 tag다.

## Root 실행

승인된 Windows CI의 현재 pin runtime과 검토한 source checkout에서:

```powershell
python path/to/run_font_diagnostic.py --repository $env:GITHUB_WORKSPACE --timeout 30
```

driver는 source hash 고정 runner의 private Job Object/stdin gate로 offscreen와 windows child를 각각 격리한다. QApplication만 만들고 QWidget/show/event loop/OS input은 없다. platform 선택은 해당 child 환경에만 적용한다. 기존 앱·글꼴 설치·전역 설정·외부 네트워크·사용자 파일을 조작하지 않는다. 새 UUID `.build/windows-font-diagnostic-*`에 reports/logs만 기록한다. source/hash 체크 실패·timeout·report 부재는 실패로 보존한다. 관측이 정상 완료되어도 generic Monospace가 아직 false일 수 있으며 이를 제품 PASS로 바꾸지 않는다. 진단 성공은 필수 UI regression을 대체하지 않는다.

family 최대4096/style64/상세font 관측8192, native child 최대30초(최대90초를 root가 명시할 수 있음). 상한을 넘으면 부분 관측 실패로 기록하며 몰래 잘라 통과하지 않는다. 각 font의 DB family/styles/isFixedPitch, 요청/실제 family/style/pointSize/pixelSize/fixedPitch/exactMatch, system fonts, product generic 결과, i/W ASCII와 한글 metrics, primary QRawFont glyph indexes를 기록한다. 글꼴 파일 경로·파일 bytes·user home·전체 환경은 수집하지 않는다. primary raw font의 미지원 한글은 per-glyph fallback 전체 증거가 아니므로 그 한계를 유지한다.

## 결과별 최소 수리안

- native windows에서는 실제 fixed candidate가 있고 offscreen에만 없으면 제품 고정폭 단언을 약화하지 않는다. 테스트 child의 플랫폼/공식fontdir 준비를 실제 설치 font 증거와 구분하여 수리하고 동일 단언을 재검사한다. 현 단계에 임의 글꼴 이름·파일 설치를 추가하지 않는다.
- DB fixed family는 있으나 default QFont가 proportional로 해석되고 특정 DB style/size가 실제 fixed이면 그 관측된 family/style로 generic resolver를 좁게 보완할 수 있다. named font 저장값은 변경하지 않는다.
- 모든 backend에 실재 fixed candidate가 없으면 현재 false를 숨기지 않고 actual acquisition/backend 준비를 이어 해결한다. metrics만 같거나 모두0인 결과를 fixed proof로 취급하지 않는다.
- 수리 후 actual Windows UI43 단언·named-font 보존/explicit apply/undo·preview/export 동일 resolver·한글 rendering/IME를 다시 확인한다. 이 진단은 실제 입력·IME·전체 앱·타임라인 P1 완료가 아니다.
