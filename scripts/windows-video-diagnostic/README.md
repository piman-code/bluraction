# 합성 MOV 디코더 색 변환 관찰

소스 준비 상태이며 아직 실행하지 않았다. CI9에서 마커/PTS 검사 뒤 기존 RGB SHA 비교가 실패했다. 이 도구는 기존 테스트, SHA 기준, 생산 코드를 변경하지 않고 실제 원시 YUV와 RGB 변환을 분리해 기록한다. 출력 완료는 관찰 완료이며 제품 통과/색상 호환성/시간축 P1 종결이 아니다.

실행은 검토한 Python/PyAV 19.0.0/Pillow 환경에서 저장소 루트를 지정한다. PowerShell 예:

```powershell
& $HostPython scripts/windows-video-diagnostic/run_video_diagnostic.py --repository $PWD.Path
```

Mac에서도 같은 명령을 실제 승인된 전용 Python으로 실행하면 호스트를 `darwin`으로 기록한다. Windows 실행으로 표현하지 않는다. 드라이버는 SHA 고정된 `scripts/verify_windows.py`의 `run_command`를 사용한다. Windows에서는 자식 부트스트랩을 private Job에 배정한 뒤 stdin G를 열고, POSIX에서는 별도 프로세스 그룹을 사용한다. 60초 제한 및 종료 후 후손 정리를 그대로 적용한다. 직접 관찰기 실행은 이 외부 시간 제한을 우회하므로 사용하지 않는다.

입력은 SHA 고정된 공개 `shared/fixtures/video-timelines/manifest.json`과 명시된 합성 MOV 8개뿐이다. 새 `.build/video-decoder-diagnostic-UUID/`(POSIX mode 0700)에만 배타 생성한다. 임의 미디어 경로, URL, 새 원본, 원본 수정, OS 입력, Qt import, CPU 강제, 전역 설정, ctypes 호출은 없다. 기존 private runner의 Windows Job 구현을 재사용하며 새 native 메모리 API를 만들지 않는다. Windows에서 mode 0700은 Unix 권한/ACL 보장으로 주장하지 않는다.

읽기는 원본 path/fd의 각 완전 metadata, cross-domain 일치, canonical parent binding, SHA before/after 및 captured-size bounded fd를 유지한다. PyAV는 `open_local_decoder`의 sticky secondary `io_open` 거부 경계를 통과한다. 무시된 secondary callback도 정상 완료를 막는다. MOV editlist 옵션은 생산 canonical provider와 같은 `advanced_editlist=1`, `ignore_editlist=0`이다. 모든 관찰 프레임을 EOF까지 읽되 최대 128개/파일, 고정 192×128 프레임을 요구한다. 이 진단의 8-bit YUV420 제한은 합성 자료 형식의 명시 조건이며 제품 지원 범위 변경이 아니다.

각 프레임에 다음을 저장한다.

- 원시 PTS/duration/timebase와 exact Fraction, stream/codec SAR, format, rotation 및 color space/range/transfer/primaries/chroma 값
- Y/U/V 각 평면의 보이는 width×height 바이트와 SHA, 별도 원래 stride/buffer 크기. 줄 패딩은 해시에 들어가지 않는다.
- 생산 경로 `frame.to_image().convert('RGB')`, 기본 `frame.reformat(format='rgb24')`, 별도 reformatter의 `BILINEAR | BITEXACT` RGB24 바이트/SHA
- 순수 관찰인 마커 patch sum과 역사적 Mac oracle의 같은 exact PTS 항목. raw preroll/unknown 마커도 버리지 않고 기록한다. SHA 불일치가 관찰 완료를 실패로 바꾸지는 않으며 `RGBParityProven`은 항상 false다.

각 프레임의 JSON/픽셀은 즉시 배타 저장하므로 실패/timeout 뒤 이미 얻은 관찰을 보존한다. 정상 EOF, native close, fd/path/SHA 최종 검사를 모두 마친 case만 완성 report에 들어간다. 전체 report와 source before/after SHA가 없으면 실패/미완료이다. 입력/스크립트 변경과 crash/timeout을 통과로 취급하지 않는다.

`Interpolation`은 알고리즘과 option flag를 조합할 수 있다. 기본 변환과 같은 BILINEAR에 BITEXACT만 추가하며 ACCURATE_RND, CPU dispatch, threads, 색공간/범위 또는 transfer tag를 조용히 변경하지 않는다. 출력 trc/primaries tag 설정은 색 변환의 증거가 아니므로 사용하지 않는다. 근거: [PyAV 19 reformatter 원문](https://github.com/PyAV-Org/PyAV/blob/v19.0.0/av/video/reformatter.py), [PyAV 19 영상 API](https://pyav.basswood.io/docs/stable/api/video.html).

두 호스트 report를 exact fixture SHA/PTS/format/color metadata로 짝지어 YUV visible SHA를 먼저 비교한다. YUV가 같고 기본 RGB만 다르면 변환 차이의 근거가 된다. BITEXACT RGB도 별도 대조하며 일치 여부를 미리 가정하지 않는다. YUV부터 다르면 decoder/runtime 경로를 조사한다. 조합별 실제 libav* 버전도 report에 남긴다. 새 수용 tolerance나 기존 oracle 변경은 이 진단에서 결정하지 않는다.
