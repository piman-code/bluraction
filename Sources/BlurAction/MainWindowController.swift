import AppKit
import AVKit
import AVFoundation
import UniformTypeIdentifiers
import os

/// 메인 윈도우 컨트롤러.
///
/// 구조 단순화: NSSplitViewController 없이 NSStackView(Horizontal) + NSDivider로 직접 layout.
final class MainWindowController: NSWindowController {
    private static let dropLoadLog = Logger(subsystem: "local.piman.BlurAction", category: "Drop")

    // 컨테이너 뷰
    private let rootStack = NSStackView()
    private let sidebarStack = NSStackView()
    private let sidebarHeader = NSStackView()
    private let timelineHost = NSView()

    // 메인 영역 (비디오 + 캔버스 + 블러)
    private var mainContainer: MainContainerViewController!
    private var canvas: VideoCanvasView!
    private var liveBlur: LiveBlurCompositor!

    // 사이드바 컨트롤
    private let fileTitle = NSTextField(labelWithString: "파일")
    private let fileLabel = NSTextField(labelWithString: "—")
    private let sourceInfoLabel = NSTextField(wrappingLabelWithString: "파일을 열면 원본 정보가 표시됩니다.")
    private let workflowHint = NSTextField(wrappingLabelWithString: "① 파일 열기·드롭  ② 영역 그리기  ③ 조정  ④ 내보내기")
    private let effectTitle = NSTextField(labelWithString: "블러 강도")
    private let blurSlider = EditingSlider()
    private let blurValueLabel = NSTextField(labelWithString: "25px")
    private let featherTitle = NSTextField(labelWithString: "경계 부드럽게")
    private let featherSlider = EditingSlider()
    private let featherValueLabel = NSTextField(labelWithString: "12px")
    private let toolSegment = NSSegmentedControl(labels: ["블러", "그리기", "지우개"], trackingMode: .selectOne, target: nil, action: nil)
    private let modeSegment = NSSegmentedControl(labels: ["사각형", "원", "점찍기", "자유"], trackingMode: .selectOne, target: nil, action: nil)
    private let annotationColorPopup = NSPopUpButton()
    private let annotationWidthTitle = NSTextField(labelWithString: "선 굵기")
    private let annotationWidthSlider = EditingSlider()
    private let annotationHint = NSTextField(wrappingLabelWithString: "그린 선을 클릭하면 선택되고, 끌어서 옮기거나 모서리로 크기를 바꿉니다. Delete·더블클릭으로 지웁니다. 영상에서는 그린 시점부터 표시됩니다.")
    private let annotationColorWell = NSColorWell()
    private let annotationPickButton = NSButton(title: "스포이드", target: nil, action: nil)
    private let annotationFillPopup = NSPopUpButton()
    private let coverTitle = NSTextField(labelWithString: "가리기 방식")
    private let coverSegment = NSSegmentedControl(labels: ["블러", "모자이크", "단색"], trackingMode: .selectOne, target: nil, action: nil)
    private let coverColorWell = NSColorWell()
    private let coverPickButton = NSButton(title: "스포이드", target: nil, action: nil)
    private let coverColorRow = NSStackView()
    private let eraserTools = NSStackView()
    private let eraserModeSegment = NSSegmentedControl(labels: ["부분 지우개", "항목 지우개"], trackingMode: .selectOne, target: nil, action: nil)
    private let eraserTargetPopup = NSPopUpButton()
    private let eraserSizeSlider = NSSlider(value: 24, minValue: 4, maxValue: 120, target: nil, action: nil)
    private let eraserSizeLabel = NSTextField(labelWithString: "크기 24pt")
    private let eraseFromNowCheckbox = NSButton(checkboxWithTitle: "영상: 지금 시점부터 지우기", target: nil, action: nil)
    private let eraserHint = NSTextField(wrappingLabelWithString: "")
    private let arrangeTools = NSStackView()
    private let textTools = NSStackView()
    private let textFontPopup = NSPopUpButton()
    private let textBoldCheckbox = NSButton(checkboxWithTitle: "굵게", target: nil, action: nil)
    private let textBackgroundPopup = NSPopUpButton()
    /// Extra items picked with Shift-click for grouping (may mix regions and drawings).
    private var multiSelection: [UUID] = []
    private var eraseFromNow = true
    /// A project waiting for its media to finish loading before its items are applied.
    private var pendingProject: ProjectFile?
    private let trackMotionCheckbox = NSButton(checkboxWithTitle: "움직임 기록", target: nil, action: nil)
    private let trackMotionHint = NSTextField(wrappingLabelWithString: "켜면 옮긴 시점의 위치가 기록되어 영역·그림이 움직임을 따라갑니다. 재생 중 끌어도, 멈춘 채 프레임을 넘기며 옮겨도 됩니다. 끄면 기록된 경로 전체가 함께 옮겨집니다.")
    private let motionTools = NSStackView()
    private let autoTrackButton = NSButton(title: "선택 항목 자동 추적", target: nil, action: nil)
    private var trackingCancellation: ObjectTracker.Cancellation?
    private var annotationColorRow: NSStackView?
    private let regionTitle = NSTextField(labelWithString: "레이어 (위가 앞)")
    private let regionScroll = NSScrollView()
    private let regionList = RegionTableView()
    private let timeRangeEditor = NSStackView()
    private let rangeStart = NSTextField(string: "0")
    private let rangeEnd = NSTextField(string: "0")
    private let rangeApply = NSButton(title: "구간 적용", target: nil, action: nil)
    private let rangeEntire = NSButton(title: "영상 전체", target: nil, action: nil)
    private let rangeHint = NSTextField(wrappingLabelWithString: "영역을 선택한 뒤 시간을 지정하세요.")
    private let preciseTools = NSStackView()
    private let frameRow = NSStackView()
    private let previousFrameButton = NSButton(title: "◀ 약 1프레임", target: nil, action: nil)
    private let nextFrameButton = NSButton(title: "약 1프레임 ▶", target: nil, action: nil)
    private let recordPositionButton = NSButton(title: "현재 위치 기록", target: nil, action: nil)
    private let previousKeyButton = NSButton(title: "◀ 이전 기록", target: nil, action: nil)
    private let nextKeyButton = NSButton(title: "다음 기록 ▶", target: nil, action: nil)
    private let positionX = NSTextField(string: "0")
    private let positionY = NSTextField(string: "0")
    private let positionWidth = NSTextField(string: "0")
    private let positionHeight = NSTextField(string: "0")
    private let applyPositionButton = NSButton(title: "좌표·크기 적용", target: nil, action: nil)
    private let qualityTitle = NSTextField(labelWithString: "내보내기 화질")
    private let qualityPopup = NSPopUpButton()
    private let qualityInfoLabel = NSTextField(wrappingLabelWithString: "파일을 열면 출력 사양이 표시됩니다.")
    private let exportButton = NSButton(title: "내보내기", target: nil, action: nil)
    private let cancelButton = NSButton(title: "취소", target: nil, action: nil)
    private let progressIndicator = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "")

    // 데이터
    private let doc = DocumentModel()
    private var pairs: [(shape: RegionShape, effect: RegionEffect)] = []
    private struct EditorSnapshot { var pairs: [(shape: RegionShape, effect: RegionEffect)]; var annotations: [DrawingAnnotation] }
    private var annotations: [DrawingAnnotation] = []
    private var undoStack: [EditorSnapshot] = []
    private var redoStack: [EditorSnapshot] = []
    private var selectedID: UUID? = nil
    /// Selected drawing (mutually exclusive with `selectedID`).
    private var selectedDrawingID: UUID?
    private var gestureSnapshot: [RegionEditing.Pair]?
    private var gestureAnnotations: [DrawingAnnotation]?
    /// Motion recording switch: edits on video become positions at the edit time.
    private var trackMotion = true
    private var motionRecording: Bool { trackMotion && doc.hasVideo }
    private var defaultCoverStyle: RegionEffect.CoverStyle = .blur
    private var gestureStartTime: Double?
    private var isExporting = false
    private var refreshingList = false
    private var endObserver: NSObjectProtocol?
    private let imageFormatPopup = NSPopUpButton()
    private var quality: QualityPreset = .high
    private var canvasMode: VideoCanvasView.Mode = .rectangle
    private var lastListReloadQuantized: Int = -1

    private let exporter = BlurredVideoExporter()
    private var timeObserver: Any?
    private var playerItemStatusObserver: NSKeyValueObservation?
    private var player: AVPlayer!
    private var playAfterSeek = false
    private lazy var seekCoordinator = SeekCoordinator { [weak self] seconds, completion in
        guard let self, self.player.currentItem != nil else { completion(false); return }
        self.liveBlur.currentTime = seconds
        self.liveBlur.invalidateFrame()
        self.player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                         toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            DispatchQueue.main.async { completion(finished) }
        }
    }
    /// 영역 이동 시 키프레임 자동 기록 모드 (▶ 누르면 true, ⏸ 누르면 false).
    /// - true: 영역 drag 중 30Hz로 키프레임 자동 추가 → 시간대별 블러 영역 추적.
    /// - false: 키프레임 추가 안 함 (기존 동작).
    private var recordingKeyframes: Bool = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BlurAction"
        // 윈도우 최소 크기 — 사용자가 더 작게 줄일 수 있게 작게 설정.
        // (이전 960×600은 너무 커서 윈도우 축소 안 됨)
        window.minSize = NSSize(width: 640, height: 480)
        window.contentMinSize = NSSize(width: 640, height: 420)
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        super.init(window: window)
        // init 후 명시적으로 view controller/UI를 모두 구성.
        // NSWindowController의 loadWindow/windowDidLoad는 호출 시점이 미묘해서 직접 호출 흐름을 만든다.
        setupUI()
        window.setContentSize(NSSize(width: 1180, height: 700))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        playerItemStatusObserver?.invalidate()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    /// 모든 UI 구성을 init 시점에 명시적으로 수행.
    /// NSWindowController의 windowDidLoad는 view cycle 의존성 때문에 신뢰성이 떨어짐.
    private func setupUI() {
        // 컨트롤러/뷰 생성
        canvas = VideoCanvasView()
        liveBlur = LiveBlurCompositor()
        mainContainer = MainContainerViewController(canvas: canvas, liveBlur: liveBlur)

        // contentViewController를 mainContainer로 설정.
        window?.contentViewController = mainContainer

        configureContent()
        configureSidebar()
        configureToolbar()
        configureMenu()
        configurePlayer()
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        // setupUI()에서 이미 모든 구성 완료. windowDidLoad는 no-op.
    }

    // MARK: - Layout (root = 수평 stack: [main, divider, sidebar], 그 아래 timeline)

    private func configureContent() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.black.cgColor

        // mainContainer가 contentViewController로 설정되었으므로 mainView = mainContainer.view
        // mainView는 비디오 컨테이너 + timeline 가지고 있음.
        // autoresizingMask = .width/.height로 contentView frame 자동 추종.
        let mainView = mainContainer.view

        // 사이드바 컨테이너 view
        let sidebarView = NSView()
        sidebarView.wantsLayer = true
        sidebarView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        sidebarView.translatesAutoresizingMaskIntoConstraints = false

        sidebarStack.translatesAutoresizingMaskIntoConstraints = false
        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .leading
        sidebarStack.spacing = 10
        sidebarStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        let sidebarScroll = NSScrollView()
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.drawsBackground = false
        sidebarHeader.translatesAutoresizingMaskIntoConstraints = false
        sidebarHeader.orientation = .vertical
        sidebarHeader.alignment = .leading
        sidebarHeader.spacing = 4
        sidebarHeader.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 10, right: 12)
        let sidebarDocument = FlippedDocumentView()
        sidebarDocument.translatesAutoresizingMaskIntoConstraints = false
        sidebarScroll.documentView = sidebarDocument
        sidebarDocument.addSubview(sidebarStack)
        sidebarView.addSubview(sidebarHeader)
        sidebarView.addSubview(sidebarScroll)
        NSLayoutConstraint.activate([
            sidebarHeader.topAnchor.constraint(equalTo: sidebarView.topAnchor),
            sidebarHeader.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor),
            sidebarHeader.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            sidebarScroll.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor),
            sidebarScroll.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            sidebarScroll.topAnchor.constraint(equalTo: sidebarHeader.bottomAnchor),
            sidebarScroll.bottomAnchor.constraint(equalTo: sidebarView.bottomAnchor),
            sidebarDocument.widthAnchor.constraint(equalTo: sidebarScroll.contentView.widthAnchor),
            sidebarStack.leadingAnchor.constraint(equalTo: sidebarDocument.leadingAnchor),
            sidebarStack.trailingAnchor.constraint(equalTo: sidebarDocument.trailingAnchor),
            sidebarStack.topAnchor.constraint(equalTo: sidebarDocument.topAnchor),
            sidebarStack.bottomAnchor.constraint(equalTo: sidebarDocument.bottomAnchor)
        ])

        // divider
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        // mainView에 직접 addSubview (mainView가 이미 비디오 컨테이너+타임라인 가지고 있음)
        // 사이드바/divider를 mainView의 videoContainer 영역 위에 absolute로 배치
        // → 단순화: videoContainer 폭 = mainView 폭 - sidebar 폭 - 1
        // mainView는 videoContainer + timeline으로 구성됨.
        // sidebar/divider는 mainView의 videoContainer frame을 줄이는 방향으로.
        mainView.addSubview(sidebarView)
        mainView.addSubview(divider)

        sidebarView.widthAnchor.constraint(equalToConstant: 300).isActive = true
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true

        NSLayoutConstraint.activate([
            sidebarView.topAnchor.constraint(equalTo: mainView.topAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: mainView.bottomAnchor),
            sidebarView.trailingAnchor.constraint(equalTo: mainView.trailingAnchor),
            sidebarView.widthAnchor.constraint(equalToConstant: 300),

            divider.topAnchor.constraint(equalTo: sidebarView.topAnchor),
            divider.bottomAnchor.constraint(equalTo: sidebarView.bottomAnchor),
            divider.trailingAnchor.constraint(equalTo: sidebarView.leadingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1)
        ])

        // canvas 콜백
        canvas.regionsBinding = { [weak self] in
            guard let self else { return [] }
            return self.pairs.map { RegionEditing.displayed($0, at: self.editTime) }
        }
        canvas.annotationsBinding = { [weak self] in
            guard let self else { return [] }
            return self.annotations.filter { !$0.hidden }.map { $0.displayed(at: self.editTime) }
        }
        canvas.isLocked = { [weak self] id in self?.layerState(id).locked ?? false }
        canvas.annotationStyleBinding = { [weak self] in
            guard let self else { return (.systemYellow, 4, 0) }
            return (self.annotationColorWell.color, CGFloat(self.annotationWidthSlider.doubleValue), self.selectedFillOpacity)
        }
        canvas.annotationAdded = { [weak self] created in self?.addAnnotation(created) }
        canvas.annotationChanged = { [weak self] edited in self?.editAnnotation(edited) }
        canvas.itemsErased = { [weak self] regions, drawings, fromEraser in
            guard let self else { return }
            if fromEraser, self.doc.hasVideo, self.eraseFromNow {
                self.endItems(regions: regions, drawings: drawings, at: self.editTime ?? 0)
            } else {
                self.eraseItems(regions: regions, drawings: drawings)
            }
        }
        canvas.eraserStyleBinding = { [weak self] in
            guard let self else { return (true, 24) }
            return (self.eraserIsBrush, CGFloat(self.eraserSizeSlider.doubleValue.rounded()))
        }
        canvas.eraserStroke = { [weak self] points, width in self?.applyEraserStroke(points, width: width) }
        canvas.textPlacementHandler = { [weak self] point in self?.promptText(at: point) }
        canvas.textEditHandler = { [weak self] id in self?.editText(id) }
        canvas.multiSelectToggle = { [weak self] id in self?.toggleMultiSelection(id) }
        canvas.selectionDecorationsProvider = { [weak self] in self?.selectionDecorations() ?? ([], nil) }
        canvas.annotationSelectionChange = { [weak self] id in
            guard let self else { return }
            if let id, !self.multiSelection.contains(id) { self.multiSelection.removeAll() }
            self.selectedDrawingID = id
            if id != nil { self.selectedID = nil }
            if let id, let drawing = self.annotations.first(where: { $0.id == id }) {
                self.showDrawingStyle(drawing)
                self.showTextStyle(drawing)
            }
            self.refreshTextControls()
            self.refreshSelectedEditor()
            self.refreshRegionList()
        }
        canvas.rightClickOnAnnotation = { [weak self] id, pt in self?.showItemContextMenu(for: id, at: pt) }
        canvas.colorPickCancelled = { [weak self] in self?.workflowHint.stringValue = "색 고르기를 취소했습니다." }
        canvas.shortcutHandler = { [weak self] key in self?.handleShortcut(key) ?? false }
        canvas.motionPathProvider = { [weak self] in self?.selectedMotionPath() ?? [] }
        mainContainer.slider.markerMoved = { [weak self] index, time in self?.retimeKeyframe(index, to: time) }
        mainContainer.slider.rangeEdgeMoved = { [weak self] start, time in self?.moveRangeEdge(start: start, to: time) }
        canvas.editingBegan = { [weak self] in self?.beginGesture() }
        canvas.editingEnded = { [weak self] in self?.endGesture() }
        canvas.regionsUpdate = { [weak self] updated in
            guard let self, !self.isExporting else { return }
            var result = RegionEditing.updating(updated, in: self.pairs, time: self.editTime, recording: self.motionRecording,
                                                anchorTime: self.gestureStartTime, anchorPairs: self.gestureSnapshot,
                                                creationTime: self.canvas.creationStartTime ?? self.playheadTime,
                                                videoDuration: self.doc.hasVideo ? self.doc.duration : nil)
            let existing = Set(self.pairs.map(\.shape.id))
            for index in result.indices where !existing.contains(result[index].shape.id) {
                self.applyDefaultCover(to: &result[index].effect)
            }
            // A grouped region moved or resized as a whole carries the rest of its group along
            // (a polygon vertex edit is not a box change and stays local).
            let moves = updated.compactMap { shape -> (move: GroupChange, source: UUID)? in
                guard let old = self.pairs.first(where: { $0.shape.id == shape.id }) else { return nil }
                let shown = RegionEditing.displayed(old, at: self.editTime)
                guard Self.sameGeometry(shape, shown.replacing(rect: shape.boundingRect)),
                      let move = self.groupMove(from: shown.boundingRect, to: shape.boundingRect,
                                                group: old.effect.groupID) else { return nil }
                return (move, shape.id)
            }
            if !RegionEditing.equal(self.pairs, result) {
                if self.gestureSnapshot == nil { self.checkpoint() }
                self.pairs = result
                for (move, source) in moves { self.moveGroupMembers(move, except: source) }
            }
            self.refreshRegionList()
            self.refreshSelectedEditor()
            self.liveBlur.refresh()
        }
        mainContainer.canvasSizeChanged = { [weak self] old, new in
            guard let self else { return }
            self.pairs = RegionEditing.scaled(self.pairs, from: old, to: new)
            self.annotations = self.annotations.map { $0.scaled(from: old, to: new) }
            self.undoStack = self.undoStack.map { EditorSnapshot(pairs: RegionEditing.scaled($0.pairs, from: old, to: new), annotations: $0.annotations.map { $0.scaled(from: old, to: new) }) }
            self.redoStack = self.redoStack.map { EditorSnapshot(pairs: RegionEditing.scaled($0.pairs, from: old, to: new), annotations: $0.annotations.map { $0.scaled(from: old, to: new) }) }
            if let snapshot = self.gestureSnapshot {
                self.gestureSnapshot = RegionEditing.scaled(snapshot, from: old, to: new)
            }
            self.gestureAnnotations = self.gestureAnnotations?.map { $0.scaled(from: old, to: new) }
        }
        canvas.modeBinding = { [weak self] in self?.canvasMode ?? .rectangle }
        canvas.modeUpdate = { [weak self] m in self?.canvasMode = m }
        canvas.viewSizeBinding = { [weak self] in self?.canvas.bounds.size ?? .zero }
        canvas.videoSizeBinding = { [weak self] in self?.doc.appliedVideoSize ?? .zero }
        canvas.addRegionHandler = { [weak self] in self?.addRegion() }
        canvas.playPauseHandler = { [weak self] in self?.togglePlay() }
        canvas.deleteSelectedHandler = { [weak self] in self?.deleteSelected() }
        canvas.selectionChange = { [weak self] id in
            if let id, self?.multiSelection.contains(id) == false { self?.multiSelection.removeAll() }
            if id != nil { self?.selectedDrawingID = nil }
            self?.selectedID = id
            self?.refreshSelectedEditor()
            self?.refreshRegionList()
        }
        canvas.rightClickOnRegion = { [weak self] id, pt in
            self?.showRegionContextMenu(for: id, at: pt)
        }
        canvas.regionDoubleClickHandler = { [weak self] id in
            self?.selectedID = id
            self?.refreshSelectedEditor()
            self?.window?.makeFirstResponder(self?.blurSlider)
        }
        canvas.effectForID = { [weak self] id in
            self?.pairs.first(where: { $0.shape.id == id })?.effect
        }
        canvas.currentTimeProvider = { [weak self] in self?.canvas.currentVideoTime ?? 0 }
        canvas.creationTimeProvider = { [weak self] in self?.playheadTime }
        canvas.emptyHint = "영상이나 이미지를 끌어다 놓거나 ⌘O로 여세요"
        canvas.hostContainer = mainContainer.aspectFitVideo
        canvas.onFileLoad = { [weak self] url in self?.load(url: url) }
        canvas.liveBlurRefreshCallback = { [weak self] in self?.liveBlur.refresh() }
        liveBlur.regionsProvider = { [weak self] in self?.pairs ?? [] }
        liveBlur.annotationsProvider = { [weak self] in self?.annotations ?? [] }
        liveBlur.videoSize = doc.appliedVideoSize
    }

    private var editTime: Double? { doc.hasVideo ? canvas.currentVideoTime : nil }

    /// During a seek the visible target is authoritative; playback otherwise uses the live clock.
    private var playheadTime: Double? {
        guard doc.hasVideo else { return nil }
        let time = seekCoordinator.suppressesTimeObserver ? canvas.currentVideoTime : player.currentTime().seconds
        return time.isFinite ? min(doc.duration, max(0, time)) : nil
    }

    /// Continuous controls outside a mouse gesture (color panel drags) coalesce per item and key.
    private var coalescedEdit: (key: String, at: Date)?

    private func checkpoint(coalescing key: String? = nil) {
        if let key, let last = coalescedEdit, last.key == key, Date().timeIntervalSince(last.at) < 1 {
            coalescedEdit = (key, Date())
            return
        }
        coalescedEdit = key.map { ($0, Date()) }
        undoStack.append(EditorSnapshot(pairs: pairs, annotations: annotations))
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func beginGesture() {
        guard gestureSnapshot == nil, !isExporting else { return }
        gestureSnapshot = pairs
        gestureAnnotations = annotations
        gestureStartTime = editTime
    }

    private func endGesture() {
        guard let before = gestureSnapshot else { return }
        let beforeAnnotations = gestureAnnotations ?? annotations
        gestureSnapshot = nil
        gestureAnnotations = nil
        gestureStartTime = nil
        if !RegionEditing.equal(before, pairs) || beforeAnnotations != annotations {
            coalescedEdit = nil
            undoStack.append(EditorSnapshot(pairs: before, annotations: beforeAnnotations))
            if undoStack.count > 50 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
    }

    private func configurePlayer() {
        player = AVPlayer()
        mainContainer.playerLayer.player = player
        mainContainer.playPauseButton.target = self
        mainContainer.playPauseButton.action = #selector(togglePlay)
        mainContainer.slider.target = self
        mainContainer.slider.action = #selector(sliderMoved(_:))
        mainContainer.playPauseButton.isEnabled = false
        mainContainer.slider.trackingBegan = { [weak self] in
            guard let self, self.doc.hasVideo, !self.isExporting else { return }
            self.seekCoordinator.beginScrubbing()
            self.stopPlayback()
        }
        mainContainer.slider.trackingEnded = { [weak self] in
            guard let self else { return }
            // Commit the mouse-up value, even if no final continuous action was delivered.
            self.seek(to: self.mainContainer.slider.doubleValue)
            self.seekCoordinator.endScrubbing()
        }
        seekCoordinator.didSettle = { [weak self] finished in
            guard let self, self.doc.hasVideo else { return }
            if !self.seekCoordinator.isScrubbing {
                self.updatePlaybackTime(self.player.currentTime().seconds)
            } else if finished {
                self.liveBlur.refresh()
                self.canvas.refreshOverlay()
            }
            if finished, self.playAfterSeek, !self.seekCoordinator.isScrubbing {
                self.startPlayback()
            } else if !finished {
                self.stopPlayback()
            }
            if finished, !self.seekCoordinator.isScrubbing, self.player.rate == 0 {
                self.liveBlur.requestStillFrame(at: max(0, self.player.currentTime().seconds))
            }
        }

        doc.onLoad = { [weak self] in self?.documentLoaded() }
    }

    private func observePlaybackTime(for item: AVPlayerItem) {
        playerItemStatusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async { [weak self, weak item] in
                guard let self, let item, self.player.currentItem === item else { return }
                if item.status == .failed {
                    self.seekCoordinator.reset(duration: self.doc.duration)
                    self.stopPlayback()
                    self.mainContainer.slider.isEnabled = false
                    self.mainContainer.playPauseButton.isEnabled = false
                    self.updatePlaybackTime(self.player.currentTime().seconds)
                } else {
                    self.seekCoordinator.setReady(item.status == .readyToPlay)
                    if item.status == .readyToPlay, self.player.rate == 0 {
                        self.liveBlur.requestStillFrame(at: max(0, self.player.currentTime().seconds))
                    }
                }
            }
        }
        let interval = CMTime(seconds: 1.0 / 30, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let self, let item, self.player.currentItem === item, self.doc.hasVideo,
                      !self.seekCoordinator.suppressesTimeObserver else { return }
                // Read the current clock, not a callback time queued before the latest seek.
                self.updatePlaybackTime(self.player.currentTime().seconds)
            }
        }
    }

    private func resetPlaybackTime(duration: Double) {
        let duration = duration.isFinite ? max(0, duration) : 0
        seekCoordinator.reset(duration: duration)
        mainContainer.slider.minValue = 0
        mainContainer.slider.maxValue = duration > 0 ? duration : 1
        mainContainer.slider.doubleValue = 0
        mainContainer.timeLabel.stringValue = "00:00.00 / \(format(duration))"
        mainContainer.slider.setAccessibilityValueDescription(mainContainer.timeLabel.stringValue)
        canvas.currentVideoTime = 0
        liveBlur.currentTime = 0
        lastListReloadQuantized = -1
    }

    private func updatePlaybackTime(_ seconds: Double, refreshPreview: Bool = true) {
        guard seconds.isFinite, doc.duration.isFinite else { return }
        let time = min(doc.duration, max(0, seconds))
        if !seekCoordinator.isScrubbing { mainContainer.slider.doubleValue = time }
        mainContainer.timeLabel.stringValue = "\(format(time)) / \(format(doc.duration))"
        mainContainer.slider.setAccessibilityValueDescription(mainContainer.timeLabel.stringValue)
        canvas.currentVideoTime = time
        canvas.recordingKeyframes = recordingKeyframes && trackMotion
        canvas.refreshOverlay()
        if hasSelection, ![positionX, positionY, positionWidth, positionHeight].contains(where: { $0.currentEditor() != nil }) {
            refreshPositionFields()
        }
        if refreshPreview {
            liveBlur.currentTime = time
            liveBlur.refresh()
        }
        let quantized = Int(time * 10)
        if quantized != lastListReloadQuantized {
            refreshRegionList()
            lastListReloadQuantized = quantized
        }
    }

    private func configureSidebar() {
        toolSegment.selectedSegment = 0
        toolSegment.target = self
        toolSegment.action = #selector(toolChanged(_:))
        modeSegment.selectedSegment = 0
        modeSegment.target = self
        modeSegment.action = #selector(modeChanged(_:))
        annotationColorPopup.addItems(withTitles: ["노랑", "빨강", "파랑", "초록", "흰색"])
        annotationColorPopup.target = self
        annotationColorPopup.action = #selector(annotationPresetChosen(_:))
        annotationColorPopup.toolTip = "자주 쓰는 색"
        annotationColorWell.color = .systemYellow
        annotationColorWell.target = self
        annotationColorWell.action = #selector(annotationStyleChanged(_:))
        annotationColorWell.toolTip = "그리기 색 (클릭하면 색상판과 화면 돋보기가 열립니다)"
        annotationPickButton.target = self
        annotationPickButton.action = #selector(pickAnnotationColor)
        annotationPickButton.toolTip = "영상·이미지에서 클릭한 곳의 색을 가져옵니다 (단축키 I)"
        annotationFillPopup.addItems(withTitles: ["채우기 없음", "반투명 채우기", "불투명 채우기"])
        annotationFillPopup.target = self
        annotationFillPopup.action = #selector(annotationStyleChanged(_:))
        annotationFillPopup.toolTip = "사각형·타원·펜 도형 안을 같은 색으로 채웁니다 (선은 채우지 않음)"
        textFontPopup.addItems(withTitles: ["시스템 글꼴"] + DrawingAnnotation.availableFontFamilies)
        textFontPopup.target = self
        textFontPopup.action = #selector(textStyleChanged(_:))
        textFontPopup.toolTip = "글꼴"
        textBoldCheckbox.state = .on
        textBoldCheckbox.target = self
        textBoldCheckbox.action = #selector(textStyleChanged(_:))
        textBackgroundPopup.addItems(withTitles: ["배경 없음", "반투명 검정 배경", "검정 배경", "반투명 흰색 배경", "흰색 배경"])
        textBackgroundPopup.target = self
        textBackgroundPopup.action = #selector(textStyleChanged(_:))
        textBackgroundPopup.toolTip = "글자 뒤에 자막처럼 상자를 깝니다"
        let fontRow = NSStackView(views: [textFontPopup, textBoldCheckbox])
        fontRow.spacing = 8
        textTools.orientation = .vertical
        textTools.alignment = .leading
        textTools.spacing = 6
        for view in [fontRow, textBackgroundPopup] as [NSView] { textTools.addArrangedSubview(view) }
        textTools.isHidden = true
        annotationWidthSlider.minValue = 1
        annotationWidthSlider.maxValue = 20
        annotationWidthSlider.doubleValue = 4
        annotationWidthSlider.isContinuous = true
        annotationWidthSlider.target = self
        annotationWidthSlider.action = #selector(annotationStyleChanged(_:))
        annotationHint.font = .systemFont(ofSize: 11)
        annotationHint.textColor = .secondaryLabelColor
        annotationHint.preferredMaxLayoutWidth = 260
        coverSegment.selectedSegment = 0
        coverSegment.target = self
        coverSegment.action = #selector(coverChanged(_:))
        coverSegment.toolTip = "블러: 흐리게 · 모자이크: 픽셀 블록 · 단색: 색으로 완전히 덮기"
        coverColorWell.color = .black
        coverColorWell.target = self
        coverColorWell.action = #selector(coverColorChanged(_:))
        coverPickButton.target = self
        coverPickButton.action = #selector(pickCoverColor)
        coverPickButton.toolTip = "영상·이미지에서 클릭한 곳의 색으로 덮습니다"
        for view in [coverColorWell, coverPickButton] as [NSView] { coverColorRow.addArrangedSubview(view) }
        coverColorRow.spacing = 6
        trackMotionCheckbox.state = .on
        trackMotionCheckbox.target = self
        trackMotionCheckbox.action = #selector(trackMotionChanged(_:))
        trackMotionCheckbox.toolTip = "영상에서 영역·그림을 옮길 때 그 시점의 위치로 기록합니다"
        trackMotionHint.font = .systemFont(ofSize: 11)
        trackMotionHint.textColor = .secondaryLabelColor
        trackMotionHint.preferredMaxLayoutWidth = 260
        motionTools.orientation = .vertical
        motionTools.alignment = .leading
        motionTools.spacing = 4
        autoTrackButton.bezelStyle = .rounded
        autoTrackButton.target = self
        autoTrackButton.action = #selector(autoTrackTapped)
        autoTrackButton.toolTip = "선택한 영역·그림 안의 대상을 지금부터 끝까지 자동으로 따라가며 위치를 기록합니다 (Vision). ⌘Z로 되돌립니다."
        for view in [trackMotionCheckbox, trackMotionHint, autoTrackButton] as [NSView] { motionTools.addArrangedSubview(view) }
        motionTools.isHidden = true
        eraserHint.font = .systemFont(ofSize: 11)
        eraserHint.textColor = .secondaryLabelColor
        eraserHint.preferredMaxLayoutWidth = 260
        eraserModeSegment.selectedSegment = 0
        eraserModeSegment.target = self
        eraserModeSegment.action = #selector(eraserStyleChanged(_:))
        eraserModeSegment.toolTip = "부분: 그림의 문지른 부분만 지움 · 항목: 닿은 영역·그림을 통째로 지움"
        eraserSizeSlider.target = self
        eraserSizeSlider.action = #selector(eraserStyleChanged(_:))
        eraserSizeSlider.isContinuous = true
        eraserSizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        eraserSizeLabel.textColor = .secondaryLabelColor
        eraseFromNowCheckbox.state = .on
        eraseFromNowCheckbox.target = self
        eraseFromNowCheckbox.action = #selector(eraserStyleChanged(_:))
        eraseFromNowCheckbox.toolTip = "켜면 지금 보고 있는 시점부터 지워지고, 그 전의 모습은 그대로 남습니다."
        eraserTools.orientation = .vertical
        eraserTools.alignment = .leading
        eraserTools.spacing = 6
        let eraserSizeRow = NSStackView(views: [eraserSizeSlider, eraserSizeLabel])
        eraserSizeRow.spacing = 8
        eraserSizeSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        eraserTargetPopup.addItems(withTitles: ["그림과 블러 모두", "그림만", "블러 영역만"])
        eraserTargetPopup.target = self
        eraserTargetPopup.action = #selector(eraserStyleChanged(_:))
        eraserTargetPopup.toolTip = "부분 지우개가 지울 대상"
        for view in [eraserModeSegment, eraserTargetPopup, eraserSizeRow, eraseFromNowCheckbox, eraserHint] as [NSView] { eraserTools.addArrangedSubview(view) }
        for (title, action) in [("선택 항목 지우기", #selector(deleteSelectedTapped)), ("블러 영역 모두 지우기", #selector(clearRegionsTapped)),
                                ("그리기 모두 지우기", #selector(clearDrawingsTapped)), ("모두 지우기", #selector(clearAllTapped))] {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            eraserTools.addArrangedSubview(button)
        }
        let arrangeTitle = NSTextField(labelWithString: "순서·그룹")
        arrangeTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let orderRow = NSStackView()
        let groupRow = NSStackView()
        for (row, items) in [(orderRow, [("맨 뒤", #selector(sendToBackTapped), "맨 뒤로 보내기 (⇧⌘[)"), ("뒤로", #selector(sendBackwardTapped), "뒤로 보내기 (⌘[)"),
                                         ("앞으로", #selector(bringForwardTapped), "앞으로 가져오기 (⌘])"), ("맨 앞", #selector(bringToFrontTapped), "맨 앞으로 가져오기 (⇧⌘])")]),
                             (groupRow, [("그룹 만들기", #selector(groupTapped), "Shift+클릭으로 여러 항목을 고른 뒤 묶습니다 (⌘G)"),
                                         ("그룹 풀기", #selector(ungroupTapped), "선택 항목의 그룹을 풉니다 (⇧⌘G)")])] {
            row.spacing = 4
            for (title, action, tip) in items {
                let button = NSButton(title: title, target: self, action: action)
                button.bezelStyle = .rounded
                button.controlSize = .small
                button.toolTip = tip
                row.addArrangedSubview(button)
            }
        }
        let arrangeHint = NSTextField(wrappingLabelWithString: "Shift+클릭으로 여러 항목(영역·그림)을 고르고 묶으면 하나를 옮길 때 함께 움직입니다. 겹친 것은 앞·뒤 순서로 가립니다.")
        arrangeHint.font = .systemFont(ofSize: 11)
        arrangeHint.textColor = .secondaryLabelColor
        arrangeHint.preferredMaxLayoutWidth = 260
        arrangeTools.orientation = .vertical
        arrangeTools.alignment = .leading
        arrangeTools.spacing = 6
        for view in [arrangeTitle, orderRow, groupRow, arrangeHint] as [NSView] { arrangeTools.addArrangedSubview(view) }
        refreshEraserControls()
        toolSegment.toolTip = "블러(B) · 그리기(D) · 지우개(E)"
        toolChanged(toolSegment)

        blurSlider.minValue = 0
        blurSlider.maxValue = 80
        blurSlider.isContinuous = true
        blurSlider.doubleValue = 25
        blurSlider.target = self
        blurSlider.action = #selector(blurChanged(_:))

        featherSlider.minValue = 0
        featherSlider.maxValue = 50
        featherSlider.isContinuous = true
        featherSlider.doubleValue = 12
        featherSlider.target = self
        featherSlider.action = #selector(featherChanged(_:))
        for slider in [blurSlider, featherSlider, annotationWidthSlider] {
            slider.editingBegan = { [weak self] in self?.beginGesture() }
            slider.editingEnded = { [weak self] in self?.endGesture() }
        }

        qualityPopup.removeAllItems()
        qualityPopup.addItems(withTitles: QualityPreset.allCases.map(\.rawValue))
        qualityPopup.selectItem(withTitle: quality.rawValue)
        qualityPopup.target = self
        qualityPopup.action = #selector(qualityChanged(_:))
        imageFormatPopup.target = self
        imageFormatPopup.action = #selector(imageFormatChanged(_:))

        for label in [sourceInfoLabel, workflowHint, qualityInfoLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = 260
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        }
        sourceInfoLabel.setAccessibilityLabel("원본 파일 사양")
        qualityInfoLabel.setAccessibilityLabel("내보내기 사양")
        featherTitle.toolTip = "값이 클수록 원본 픽셀 기준으로 블러 경계가 넓고 부드러워집니다."
        featherSlider.toolTip = "경계 너비: 0은 선명한 테두리, 50은 넓고 부드러운 테두리"

        exportButton.bezelStyle = .rounded
        exportButton.target = self
        exportButton.action = #selector(exportTapped)
        exportButton.isEnabled = false

        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        cancelButton.isHidden = true

        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.isHidden = true
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        progressLabel.textColor = .secondaryLabelColor

        regionList.headerView = nil
        regionList.rowSizeStyle = .custom
        regionList.rowHeight = 34
        regionList.target = self
        regionList.doubleAction = #selector(layerDoubleClicked)
        regionList.setAccessibilityLabel("레이어 목록")
        regionList.usesAlternatingRowBackgroundColors = false
        regionList.dataSource = self
        regionList.delegate = self
        // NSTableColumn 필수 — view-based table에서도 column 없으면 row 안 그려짐
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("RegionColumn"))
        col.title = "영역"
        col.width = 260
        col.minWidth = 160
        col.resizingMask = .autoresizingMask
        regionList.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        regionList.addTableColumn(col)
        regionList.reloadData()
        regionScroll.documentView = regionList
        regionScroll.hasVerticalScroller = true
        regionScroll.autohidesScrollers = true
        regionScroll.borderType = .noBorder

        // 스타일
        for f in [fileTitle, coverTitle, effectTitle, featherTitle, regionTitle, qualityTitle] {
            f.font = .systemFont(ofSize: 13, weight: .semibold)
        }
        fileLabel.lineBreakMode = .byTruncatingMiddle
        fileLabel.textColor = .secondaryLabelColor
        for l in [blurValueLabel, featherValueLabel] {
            l.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            l.textColor = .secondaryLabelColor
            l.setContentHuggingPriority(.required, for: .horizontal)
        }
        progressIndicator.heightAnchor.constraint(equalToConstant: 4).isActive = true

        // 행 단위 조립
        let blurRow = NSStackView(views: [blurSlider, blurValueLabel])
        blurRow.orientation = .horizontal; blurRow.alignment = .centerY; blurRow.spacing = 8
        let featherRow = NSStackView(views: [featherSlider, featherValueLabel])
        featherRow.orientation = .horizontal; featherRow.alignment = .centerY; featherRow.spacing = 8

        let buttonRow = NSStackView(views: [exportButton, cancelButton])
        buttonRow.orientation = .horizontal; buttonRow.spacing = 8
        exportButton.bezelStyle = .rounded
        cancelButton.bezelStyle = .rounded

        let rangeTitle = NSTextField(labelWithString: "적용 시간 (초)")
        rangeTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        rangeStart.placeholderString = "시작 (초)"
        rangeEnd.placeholderString = "끝 (초)"
        rangeStart.setAccessibilityLabel("블러 시작 시간 (초)")
        rangeEnd.setAccessibilityLabel("블러 끝 시간 (초)")
        for field in [rangeStart, rangeEnd] {
            field.widthAnchor.constraint(equalToConstant: 76).isActive = true
            field.target = self
            field.action = #selector(applyTimeRange)
        }
        rangeApply.target = self; rangeApply.action = #selector(applyTimeRange)
        rangeEntire.target = self; rangeEntire.action = #selector(applyEntireVideo)
        rangeApply.bezelStyle = .rounded; rangeEntire.bezelStyle = .rounded
        rangeHint.font = .systemFont(ofSize: 11)
        rangeHint.textColor = .secondaryLabelColor
        rangeHint.preferredMaxLayoutWidth = 260
        rangeHint.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        let rangeFields = NSStackView(views: [rangeStart, NSTextField(labelWithString: "~"), rangeEnd])
        rangeFields.spacing = 6
        let rangeButtons = NSStackView(views: [rangeApply, rangeEntire])
        rangeButtons.spacing = 6
        timeRangeEditor.orientation = .vertical
        timeRangeEditor.alignment = .leading
        timeRangeEditor.spacing = 6
        for view in [rangeTitle, rangeFields, rangeButtons, rangeHint] { timeRangeEditor.addArrangedSubview(view) }
        timeRangeEditor.isHidden = true

        let precisionTitle = NSTextField(labelWithString: "위치·크기 정밀 조정")
        precisionTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        frameRow.addArrangedSubview(previousFrameButton)
        frameRow.addArrangedSubview(nextFrameButton)
        frameRow.spacing = 6
        previousFrameButton.target = self; previousFrameButton.action = #selector(previousFrame)
        nextFrameButton.target = self; nextFrameButton.action = #selector(nextFrame)
        for button in [previousFrameButton, nextFrameButton] {
            button.toolTip = "원본 평균 FPS를 기준으로 이동합니다. 가변 프레임률 영상에서는 실제 프레임과 차이가 날 수 있습니다."
        }
        recordPositionButton.target = self; recordPositionButton.action = #selector(recordCurrentPosition)
        previousKeyButton.target = self; previousKeyButton.action = #selector(previousKeyframe)
        nextKeyButton.target = self; nextKeyButton.action = #selector(nextKeyframe)
        previousKeyButton.toolTip = "선택 항목의 이전 기록 위치로 이동 (<)"
        nextKeyButton.toolTip = "선택 항목의 다음 기록 위치로 이동 (>)"
        recordPositionButton.toolTip = "선택 영역의 현재 모양을 이 시점의 위치 기록으로 저장합니다."
        for (field, title) in zip([positionX, positionY, positionWidth, positionHeight], ["왼쪽 X", "위쪽 Y", "너비", "높이"]) {
            field.placeholderString = title
            field.setAccessibilityLabel("\(title) (원본 픽셀)")
            field.widthAnchor.constraint(equalToConstant: 76).isActive = true
            field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            field.target = self; field.action = #selector(applyPrecisePosition)
        }
        let positionRow = NSStackView(views: [positionX, positionY])
        positionRow.spacing = 6
        let sizeRow = NSStackView(views: [positionWidth, positionHeight])
        sizeRow.spacing = 6
        applyPositionButton.target = self; applyPositionButton.action = #selector(applyPrecisePosition)
        applyPositionButton.toolTip = "원본 영상·이미지의 왼쪽 위를 (0, 0)으로 한 픽셀 좌표입니다."
        let coordinateHint = NSTextField(wrappingLabelWithString: "원본 왼쪽 위 기준 픽셀 · 영상은 선택한 시간에 기록")
        coordinateHint.font = .systemFont(ofSize: 10)
        coordinateHint.textColor = .secondaryLabelColor
        coordinateHint.preferredMaxLayoutWidth = 260
        preciseTools.orientation = .vertical
        preciseTools.alignment = .leading
        preciseTools.spacing = 6
        let keyRow = NSStackView(views: [previousKeyButton, nextKeyButton])
        keyRow.spacing = 6
        for item in [precisionTitle, frameRow, keyRow, recordPositionButton, positionRow, sizeRow,
                     applyPositionButton, coordinateHint] as [NSView] { preciseTools.addArrangedSubview(item) }

        let scrollContainer = NSView()
        scrollContainer.translatesAutoresizingMaskIntoConstraints = false
        regionScroll.translatesAutoresizingMaskIntoConstraints = false
        scrollContainer.addSubview(regionScroll)
        NSLayoutConstraint.activate([
            regionScroll.topAnchor.constraint(equalTo: scrollContainer.topAnchor),
            regionScroll.bottomAnchor.constraint(equalTo: scrollContainer.bottomAnchor),
            regionScroll.leadingAnchor.constraint(equalTo: scrollContainer.leadingAnchor),
            regionScroll.trailingAnchor.constraint(equalTo: scrollContainer.trailingAnchor),
            scrollContainer.heightAnchor.constraint(equalToConstant: 200)
        ])

        for v in [fileTitle, fileLabel, sourceInfoLabel] { sidebarHeader.addArrangedSubview(v) }
        fileLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        let annotationColorRow = NSStackView(views: [annotationColorWell, annotationPickButton, annotationColorPopup])
        annotationColorRow.spacing = 6
        annotationColorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        coverColorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        self.annotationColorRow = annotationColorRow
        for v in [workflowHint,
                  toolSegment, modeSegment, annotationColorRow, annotationWidthTitle, annotationWidthSlider, annotationFillPopup, textTools,
                  annotationHint, eraserTools,
                  coverTitle, coverSegment, effectTitle, blurRow, featherTitle, featherRow, coverColorRow, arrangeTools, regionTitle,
                  scrollContainer, timeRangeEditor, motionTools, preciseTools,
                  qualityTitle, qualityPopup, qualityInfoLabel, buttonRow, progressIndicator, progressLabel] {
            sidebarStack.addArrangedSubview(v)
        }
        toolChanged(toolSegment)
        imageFormatPopup.addItems(withTitles: ["PNG", "JPEG", "HEIC", "TIFF"])
        imageFormatPopup.isHidden = true
        sidebarStack.insertArrangedSubview(imageFormatPopup, at: sidebarStack.arrangedSubviews.firstIndex(of: qualityPopup) ?? 0)
        imageFormatPopup.toolTip = "이미지 저장 형식"
        regionList.contextMenuHandler = { [weak self] event in
            guard let self else { return }
            _ = self.tableView(self.regionList, menuFor: event)
        }
        // qualityPopup 폭 채우기
        qualityPopup.translatesAutoresizingMaskIntoConstraints = false
        qualityPopup.leadingAnchor.constraint(equalTo: sidebarStack.leadingAnchor, constant: 12).isActive = true
        qualityPopup.trailingAnchor.constraint(equalTo: sidebarStack.trailingAnchor, constant: -12).isActive = true

        // 메인 영역 너비 채우기
        sidebarStack.leadingAnchor.constraint(equalTo: scrollContainer.leadingAnchor).isActive = true
        sidebarStack.trailingAnchor.constraint(equalTo: scrollContainer.trailingAnchor).isActive = true
    }

    private func configureToolbar() {
        let tb = NSToolbar(identifier: "MainToolbar")
        tb.displayMode = .iconAndLabel
        tb.delegate = self
        tb.allowsUserCustomization = false
        window?.toolbar = tb
    }

    private func configureMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "BlurAction 정보…", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "BlurAction 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "파일")
        let openItem = NSMenuItem(title: "열기…", action: #selector(openTapped), keyEquivalent: "o")
        openItem.keyEquivalentModifierMask = [.command]
        openItem.target = self
        fileMenu.addItem(openItem)
        let exportItem = NSMenuItem(title: "내보내기…", action: #selector(exportTapped), keyEquivalent: "e")
        exportItem.keyEquivalentModifierMask = [.command]
        exportItem.target = self
        fileMenu.addItem(exportItem)
        fileMenu.addItem(NSMenuItem.separator())
        for (title, action, key, mask) in [("프로젝트 저장…", #selector(saveProjectTapped), "s", NSEvent.ModifierFlags.command),
                                           ("프로젝트 열기…", #selector(openProjectTapped), "O", [.command, .shift]),
                                           ("다른 영상에 프로젝트 적용…", #selector(applyProjectToOtherMediaTapped), "", []),
                                           ("프로젝트 항목 가져오기…", #selector(importProjectItemsTapped), "I", [.command, .shift])] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mask
            item.target = self
            fileMenu.addItem(item)
        }
        fileItem.submenu = fileMenu
        main.addItem(fileItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "편집")
        let addItem = NSMenuItem(title: "영역 추가", action: #selector(addRegionTapped), keyEquivalent: "A")
        addItem.keyEquivalentModifierMask = [.command, .shift]
        addItem.target = self
        editMenu.addItem(addItem)
        let delItem = NSMenuItem(title: "선택 항목 삭제", action: #selector(deleteSelectedTapped), keyEquivalent: "\u{7F}")
        delItem.keyEquivalentModifierMask = []
        delItem.target = self
        editMenu.addItem(delItem)
        let duplicateItem = NSMenuItem(title: "복제", action: #selector(duplicateSelectedTapped), keyEquivalent: "d")
        duplicateItem.keyEquivalentModifierMask = [.command]
        duplicateItem.target = self
        editMenu.addItem(duplicateItem)
        let clearItem = NSMenuItem(title: "모두 지우기…", action: #selector(clearAllTapped), keyEquivalent: "\u{8}")
        clearItem.keyEquivalentModifierMask = [.command, .option]
        clearItem.target = self
        editMenu.addItem(clearItem)
        editMenu.addItem(NSMenuItem.separator())
        for (title, action, key, mask) in [("앞으로 가져오기", #selector(bringForwardTapped), "]", NSEvent.ModifierFlags.command),
                                           ("뒤로 보내기", #selector(sendBackwardTapped), "[", [.command]),
                                           ("맨 앞으로 가져오기", #selector(bringToFrontTapped), "]", [.command, .shift]),
                                           ("맨 뒤로 보내기", #selector(sendToBackTapped), "[", [.command, .shift]),
                                           ("그룹 만들기", #selector(groupTapped), "g", [.command]),
                                           ("그룹 풀기", #selector(ungroupTapped), "G", [.command, .shift])] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mask
            item.target = self
            editMenu.addItem(item)
        }
        editMenu.addItem(NSMenuItem.separator())
        let undoItem = NSMenuItem(title: "실행취소", action: #selector(undoTapped), keyEquivalent: "z")
        undoItem.keyEquivalentModifierMask = [.command]
        undoItem.target = self
        editMenu.addItem(undoItem)
        let redoItem = NSMenuItem(title: "다시실행", action: #selector(redoTapped), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        redoItem.target = self
        editMenu.addItem(redoItem)
        editMenu.addItem(NSMenuItem.separator())
        let playItem = NSMenuItem(title: "재생/정지 (Space)", action: #selector(togglePlay), keyEquivalent: "")
        playItem.target = self
        editMenu.addItem(playItem)
        let backItem = NSMenuItem(title: "1초 뒤로", action: #selector(stepBackward), keyEquivalent: "\u{f702}")
        backItem.keyEquivalentModifierMask = [.command]
        backItem.target = self
        editMenu.addItem(backItem)
        let fwdItem = NSMenuItem(title: "1초 앞으로", action: #selector(stepForward), keyEquivalent: "\u{f703}")
        fwdItem.keyEquivalentModifierMask = [.command]
        fwdItem.target = self
        editMenu.addItem(fwdItem)
        editItem.submenu = editMenu
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    // MARK: - Actions

    @objc private func openTapped() {
        guard !isExporting else { return }
        let panel = NSOpenPanel()
        // 비디오 + 이미지 확장자 (한 NSOpenPanel에서 자동 분기 — DocumentModel.load(url:)이 확장자로 판정)
        var types: [UTType] = [.movie, .quickTimeMovie, .mpeg4Movie, .video, .audiovisualContent]
        types.append(.image)
        types.append(.jpeg)
        types.append(.png)
        if let heic = UTType("public.heic") { types.append(heic) }
        if let heif = UTType("public.heif") { types.append(heif) }
        if let webp = UTType("org.webmproject.webp") { types.append(webp) }
        types.append(.tiff)
        types.append(.bmp)
        if let gif = UTType("com.compuserve.gif") { types.append(gif) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url { load(url: url) }
    }

    @objc private func addRegionTapped() { addRegion() }

    @objc private func deleteSelectedTapped() { deleteSelected() }

    @objc private func togglePlay() {
        guard doc.hasVideo, !isExporting else { return }
        if player.rate > 0 || recordingKeyframes || playAfterSeek { stopPlayback() }
        else {
            guard !seekCoordinator.isScrubbing else { return }
            playAfterSeek = true
            if canvas.currentVideoTime >= doc.duration - 0.01 { seek(to: 0) }
            if !seekCoordinator.suppressesTimeObserver { startPlayback() }
        }
    }

    private func startPlayback() {
        playAfterSeek = false
        recordingKeyframes = true
        canvas.recordingKeyframes = trackMotion
        player.play()
        mainContainer.playPauseButton.title = "⏸"
    }

    private func stopPlayback() {
        playAfterSeek = false
        player.pause()
        recordingKeyframes = false
        canvas.recordingKeyframes = false
        mainContainer.playPauseButton.title = "▶"
    }

    private func seek(to seconds: Double) {
        guard doc.hasVideo, !isExporting, seconds.isFinite, doc.duration > 0 else { return }
        let t = min(doc.duration, max(0, seconds))
        updatePlaybackTime(t, refreshPreview: false)
        seekCoordinator.request(t)
    }

    @objc private func sliderMoved(_ sender: NSSlider) { stopPlayback(); seek(to: sender.doubleValue) }
    @objc private func stepForward() { stopPlayback(); seek(to: canvas.currentVideoTime + 1) }
    @objc private func stepBackward() { stopPlayback(); seek(to: canvas.currentVideoTime - 1) }
    @objc private func previousFrame() { stepFrame(-1) }
    @objc private func nextFrame() { stepFrame(1) }

    private func stepFrame(_ direction: Double) {
        guard doc.hasVideo, doc.videoFPS.isFinite, doc.videoFPS > 0 else { return }
        stopPlayback()
        seek(to: canvas.currentVideoTime + direction / doc.videoFPS)
    }

    @objc private func recordCurrentPosition() {
        guard doc.hasVideo, !isExporting, let rect = selectedDisplayedRect,
              let time = playheadTime, time < doc.duration else { return }
        stopPlayback()
        endGesture()
        let frame = RegionKeyframe(time: time, rect: rect)
        if let id = selectedID, let index = pairs.firstIndex(where: { $0.shape.id == id }) {
            checkpoint()
            pairs[index].effect.keyframes = RegionEditing.inserting(frame, into: pairs[index].effect.keyframes)
        } else if let id = selectedDrawingID, let index = annotations.firstIndex(where: { $0.id == id }) {
            checkpoint()
            annotations[index].keyframes = MotionTrack.inserting(frame, into: annotations[index].keyframes)
        } else { return }
        refreshAfterEdit()
    }

    @objc private func applyPrecisePosition() {
        guard !isExporting, hasSelection,
              doc.appliedVideoSize.width > 0, doc.appliedVideoSize.height > 0,
              canvas.bounds.width > 0, canvas.bounds.height > 0 else { return }
        let fields = [positionX, positionY, positionWidth, positionHeight]
        let numbers = fields.compactMap { Double($0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let source = doc.appliedVideoSize
        guard numbers.count == 4, numbers.allSatisfy(\.isFinite),
              numbers[0] >= 0, numbers[1] >= 0, numbers[2] > 0, numbers[3] > 0,
              numbers[0] + numbers[2] <= source.width + 0.01,
              numbers[1] + numbers[3] <= source.height + 0.01 else {
            NSSound.beep()
            workflowHint.stringValue = "좌표·크기를 원본 크기 안의 숫자로 입력하세요."
            return
        }
        let sx = canvas.bounds.width / source.width
        let sy = canvas.bounds.height / source.height
        let rect = CGRect(x: numbers[0] * sx,
                          y: canvas.bounds.height - (numbers[1] + numbers[3]) * sy,
                          width: numbers[2] * sx, height: numbers[3] * sy)
        endGesture()
        if doc.hasVideo {
            guard let time = playheadTime, time < doc.duration else { return }
            stopPlayback()
        }
        // Same rules as dragging: with motion recording on, video positions are recorded at this time.
        if let id = selectedID, let index = pairs.firstIndex(where: { $0.shape.id == id }) {
            let shapes = pairs.enumerated().map { offset, pair in
                offset == index ? RegionEditing.displayed(pair, at: editTime).replacing(rect: rect) : RegionEditing.displayed(pair, at: editTime)
            }
            let result = RegionEditing.updating(shapes, in: pairs, time: editTime, recording: motionRecording)
            guard !RegionEditing.equal(result, pairs) else { return }
            checkpoint()
            pairs = result
        } else if let id = selectedDrawingID, let index = annotations.firstIndex(where: { $0.id == id }) {
            let edited = annotations[index].displayed(at: editTime).replacingBounds(rect)
            let updated = annotations[index].applyingEdit(edited, time: editTime, recording: motionRecording)
            guard updated != annotations[index] else { return }
            checkpoint()
            annotations[index] = updated
        }
        workflowHint.stringValue = "정밀 좌표가 적용됐습니다. ⌘Z로 되돌릴 수 있습니다."
        refreshAfterEdit()
    }

    @objc private func exportTapped() {
        guard !isExporting, doc.mediaKind != .none, let input = doc.url else { return }
        guard hasEffectiveEffect else {
            showError("블러 영역을 추가하거나 그리기 도구로 표시할 내용을 추가하세요.")
            return
        }
        endGesture()
        stopPlayback()

        // 이미지 모드: BlurredImageExporter.exportImage 호출
        if doc.mediaKind == .image {
            guard let cg = doc.currentCGImage else {
                BLog("[export] abort: currentCGImage nil")
                return
            }
            exportImage(cgImage: cg)
            return
        }

        let displayRect = canvas.displayRect
        // 매핑은 appliedVideoSize 기준 — exporter가 transform 적용한 size와 일치.
        // (자연 회전된 영상에서 위치 어긋남 방지)
        let videoSize = doc.appliedVideoSize
        guard displayRect.width > 0 else {
            BLog("[export] abort: displayRect.width=0")
            return
        }
        guard videoSize.width > 0 else {
            BLog("[export] abort: videoSize.width=0 (비디오 메타 아직 로딩 안 됨)")
            return
        }
        BLog("[export] videoSize=\(videoSize) (natural=\(doc.videoSize) t=\(doc.preferredTransform)) displayRect=\(displayRect) pairs=\(pairs.count)")
        // pairs는 캔버스 좌표 그대로 전달 — exporter(makeUnionMaskImage)가 canvasBounds → renderSize 변환을 단독 수행.
        // (이전: 여기서도 변환했음 → 이중 변환으로 영역 위치/크기 어긋남)
        let mapped: [(shape: RegionShape, effect: RegionEffect)] = pairs
        let exportCanvasSize = canvas.bounds.size
        setExporting(true)
        progressIndicator.doubleValue = 0
        progressIndicator.isHidden = false
        progressLabel.stringValue = "내보내기 준비 중…"
        cancelButton.isHidden = false
        exportButton.isEnabled = false
        Task {
            await exporter.export(input: input, pairs: mapped, quality: quality, canvasBounds: exportCanvasSize,
                                  annotations: annotations, progressCallback: { p, txt in
                Task { @MainActor in
                    self.progressIndicator.doubleValue = p
                    self.progressLabel.stringValue = txt
                }
            })
            await MainActor.run { self.exportFinished() }
        }
    }

    private func exportFinished() {
        setExporting(false)
        progressIndicator.isHidden = true
        cancelButton.isHidden = true
        if exporter.wasCancelled { progressLabel.stringValue = "내보내기를 취소했습니다."; return }
        if let out = exporter.lastOutputURL {
            let alert = NSAlert()
            alert.messageText = "저장 완료"
            alert.informativeText = "\(out.lastPathComponent)"
            alert.addButton(withTitle: "Finder에서 보기")
            alert.addButton(withTitle: "확인")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([out])
            }
        } else if !exporter.statusText.isEmpty {
            let alert = NSAlert()
            alert.messageText = "내보내기 실패"
            alert.informativeText = exporter.statusText
            alert.addButton(withTitle: "확인")
            alert.runModal()
        }
        progressLabel.stringValue = ""
    }

    @objc private func cancelTapped() {
        if let trackingCancellation { trackingCancellation.cancel() } else { exporter.cancel() }
    }

    // MARK: - Automatic tracking (Vision)

    @objc private func autoTrackTapped() {
        guard doc.hasVideo, !isExporting, let url = doc.url, let id = currentSelectionID, let rect = selectedDisplayedRect,
              let start = playheadTime, canvas.bounds.width > 0, canvas.bounds.height > 0 else {
            NSSound.beep()
            workflowHint.stringValue = "영상에서 따라갈 영역이나 그림을 먼저 선택하세요."
            return
        }
        guard !layerState(id).locked else { NSSound.beep(); workflowHint.stringValue = "잠긴 레이어는 추적할 수 없습니다."; return }
        let end = selectedTiming.map { $0.lowerBound == 0 && $0.upperBound == 0 ? doc.duration : min(doc.duration, $0.upperBound) } ?? doc.duration
        guard end - start > 0.05 else { NSSound.beep(); workflowHint.stringValue = "이 항목은 지금 이후로 표시되는 시간이 없습니다."; return }
        let size = canvas.bounds.size
        let box = CGRect(x: rect.minX / size.width, y: rect.minY / size.height, width: rect.width / size.width, height: rect.height / size.height)
        stopPlayback()
        endGesture()
        let cancellation = ObjectTracker.Cancellation()
        trackingCancellation = cancellation
        setExporting(true)
        progressIndicator.doubleValue = 0
        progressIndicator.isHidden = false
        cancelButton.isHidden = false
        progressLabel.stringValue = "자동 추적 중… (취소하면 여기까지만 기록)"
        let indicator = progressIndicator
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try ObjectTracker.track(url: url, from: start, until: end, box: box, cancellation: cancellation) { value in
                    DispatchQueue.main.async { indicator.doubleValue = value }
                } }
            }.value
            self?.finishTracking(result, itemID: id, start: start, initialBox: box)
        }
    }

    private func finishTracking(_ result: Result<ObjectTracker.Outcome, Error>, itemID id: UUID, start: Double, initialBox: CGRect) {
        trackingCancellation = nil
        setExporting(false)
        progressIndicator.isHidden = true
        cancelButton.isHidden = true
        progressLabel.stringValue = ""
        switch result {
        case .failure(let error):
            showError(error.localizedDescription)
        case .success(let outcome):
            applyTracking(outcome, itemID: id, start: start, initialBox: initialBox)
        }
    }

    /// Writes tracked boxes as recorded positions from `start` on (replacing positions recorded in
    /// that span). Regions take the tracked box; drawings keep their size and follow its movement.
    /// Internal for tests.
    func applyTracking(_ outcome: ObjectTracker.Outcome, itemID id: UUID, start: Double, initialBox: CGRect) {
        let size = canvas.bounds.size
        guard let last = outcome.samples.last?.time, size.width > 0, size.height > 0 else {
            workflowHint.stringValue = outcome.cancelled ? "자동 추적을 취소했습니다." : "대상을 따라가지 못했습니다. 영역을 대상에 딱 맞게 잡고 다시 시도하세요."
            return
        }
        func canvasRect(_ box: CGRect) -> CGRect {
            CGRect(x: box.minX * size.width, y: box.minY * size.height, width: box.width * size.width, height: box.height * size.height)
        }
        func merged(_ frames: [RegionKeyframe], anchor: CGRect, tracked: [RegionKeyframe]) -> [RegionKeyframe] {
            var result = frames.filter { $0.time < start - MotionTrack.sameTime || $0.time > last + MotionTrack.sameTime }
            for frame in [RegionKeyframe(time: start, rect: anchor)] + tracked { result = MotionTrack.inserting(frame, into: result) }
            return result
        }
        if let index = pairs.firstIndex(where: { $0.shape.id == id }) {
            let anchor = RegionEditing.displayed(pairs[index], at: start).boundingRect
            let tracked = outcome.samples.map { RegionKeyframe(time: $0.time, rect: canvasRect($0.box)) }
            checkpoint()
            pairs[index].effect.keyframes = merged(pairs[index].effect.keyframes, anchor: anchor, tracked: tracked)
        } else if let index = annotations.firstIndex(where: { $0.id == id }) {
            let anchor = annotations[index].displayed(at: start).bounds
            let origin = canvasRect(initialBox)
            let tracked = outcome.samples.map { sample -> RegionKeyframe in
                let box = canvasRect(sample.box)
                return RegionKeyframe(time: sample.time, rect: anchor.offsetBy(dx: box.midX - origin.midX, dy: box.midY - origin.midY))
            }
            checkpoint()
            annotations[index].keyframes = merged(annotations[index].keyframes, anchor: anchor, tracked: tracked)
        } else { return }
        var note = "자동 추적: \(outcome.samples.count)개 위치를 \(format(last))까지 기록했습니다."
        if outcome.lostTarget { note += " 대상이 가려지거나 사라져 거기서 멈췄습니다." }
        if outcome.cancelled { note += " (취소한 곳까지)" }
        workflowHint.stringValue = note + " ⌘Z로 되돌립니다."
        refreshAfterEdit()
    }

    private var hasEffectiveBlur: Bool {
        pairs.contains { pair in
            let effect = pair.effect
            let rect = pair.shape.boundingRect
            guard effect.enabled, effect.blurRadius.isFinite, effect.style == .solid || effect.blurRadius > 0,
                  rect.width > 0, rect.height > 0 else { return false }
            guard doc.hasVideo, !effect.appliesToEntireVideo else { return true }
            return effect.timeRange.lowerBound < doc.duration && effect.timeRange.upperBound > 0
                && effect.timeRange.lowerBound < effect.timeRange.upperBound
        }
    }

    private var hasEffectiveEffect: Bool { hasEffectiveBlur || annotations.contains { !$0.hidden } }

    private func setExporting(_ value: Bool) {
        isExporting = value
        canvas.isEditable = !value && doc.mediaKind != .none
        exportButton.isEnabled = !value && doc.mediaKind != .none && hasEffectiveEffect
        for control in [blurSlider, featherSlider, toolSegment, modeSegment, annotationColorPopup, annotationWidthSlider, qualityPopup, imageFormatPopup,
                        annotationColorWell, annotationPickButton, annotationFillPopup, coverSegment, coverColorWell, coverPickButton,
                        trackMotionCheckbox, eraserModeSegment, eraseFromNowCheckbox, eraserTargetPopup,
                        textFontPopup, textBoldCheckbox, textBackgroundPopup] as [NSControl] {
            control.isEnabled = !value
        }
        mainContainer.playPauseButton.isEnabled = !value && doc.hasVideo
        mainContainer.slider.isEnabled = !value && doc.hasVideo
        for control in [rangeStart, rangeEnd, rangeApply, rangeEntire] as [NSControl] {
            control.isEnabled = !value && doc.hasVideo && hasSelection
        }
        refreshSelectedEditor()
    }

    private func showError(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "작업을 완료하지 못했습니다"
        alert.informativeText = text
        alert.addButton(withTitle: "확인")
        if let window { alert.beginSheetModal(for: window) }
    }

    private func exportImage(cgImage: CGImage) {
        guard let original = doc.url else { return }
        let types: [UTType] = [.png, .jpeg, .heic, .tiff]
        let type = types[max(0, imageFormatPopup.indexOfSelectedItem)]
        let panel = ImageSavePanel.make(original: original, type: type)
        guard panel.runModal() == .OK, let output = panel.url else { return }
        do {
            let compression: Double
            switch quality { case .original: compression = 1; case .high: compression = 0.92; case .medium: compression = 0.75; case .low: compression = 0.5 }
            try BlurredImageExporter.export(source: cgImage, pairs: pairs, canvasSize: canvas.bounds.size,
                                            inputURL: original, outputURL: output, type: type, quality: compression,
                                            annotations: annotations)
            progressLabel.stringValue = "저장 완료: \(output.lastPathComponent)"
            let alert = NSAlert()
            alert.messageText = "저장 완료"
            alert.informativeText = output.lastPathComponent
            alert.addButton(withTitle: "확인")
            alert.addButton(withTitle: "Finder에서 보기")
            if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([output]) }
        } catch { showError(error.localizedDescription) }
    }

    @objc private func undoTapped() {
        guard !isExporting else { return }
        endGesture()
        guard let prev = undoStack.popLast() else { BLog("[undo] stack empty"); return }
        coalescedEdit = nil
        redoStack.append(EditorSnapshot(pairs: pairs, annotations: annotations))
        BLog("[undo] restoring \(prev.pairs.count) regions from stack depth=\(undoStack.count)")
        self.pairs = prev.pairs
        self.annotations = prev.annotations
        if let id = selectedDrawingID, !annotations.contains(where: { $0.id == id }) { selectedDrawingID = nil }
        if selectedDrawingID == nil { canvas.clearAnnotationSelection() }
        // 캔버스와 라이브 블러에 새 상태 전달
        self.canvas.setRegionsFromExternal(prev.pairs.map(\.shape))
        self.canvas.refreshOverlay()
        self.refreshRegionList()
        self.refreshSelectedEditor()
        self.liveBlur.refresh()
    }

    @objc private func redoTapped() {
        guard !isExporting else { return }
        endGesture()
        guard let next = redoStack.popLast() else { BLog("[redo] stack empty"); return }
        coalescedEdit = nil
        undoStack.append(EditorSnapshot(pairs: pairs, annotations: annotations))
        BLog("[redo] restoring \(next.pairs.count) regions from stack depth=\(redoStack.count)")
        self.pairs = next.pairs
        self.annotations = next.annotations
        if let id = selectedDrawingID, !annotations.contains(where: { $0.id == id }) { selectedDrawingID = nil }
        if selectedDrawingID == nil { canvas.clearAnnotationSelection() }
        self.canvas.setRegionsFromExternal(next.pairs.map(\.shape))
        self.canvas.refreshOverlay()
        self.refreshRegionList()
        self.refreshSelectedEditor()
        self.liveBlur.refresh()
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        if toolSegment.selectedSegment == 1 {
            switch sender.selectedSegment { case 0: canvasMode = .drawRectangle; case 1: canvasMode = .drawEllipse
            case 2: canvasMode = .drawLine; case 3: canvasMode = .drawFreehand; case 4: canvasMode = .drawArrow
            case 5: canvasMode = .drawText; default: canvasMode = .drawRectangle }
            annotationWidthTitle.stringValue = canvasMode == .drawText ? "글자 크기" : "선 굵기"
            refreshTextControls()
            annotationFillPopup.isEnabled = [.drawRectangle, .drawEllipse, .drawFreehand].contains(canvasMode)
        } else {
            switch sender.selectedSegment { case 0: canvasMode = .rectangle; case 1: canvasMode = .ellipse
            case 2: canvasMode = .polygonClick; case 3: canvasMode = .polygonFree; default: canvasMode = .rectangle }
        }
        canvas.resetInteraction()
    }

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        let drawing = sender.selectedSegment == 1
        let erasing = sender.selectedSegment == 2
        let labels = drawing ? ["사각형", "타원", "선", "펜", "화살표", "글자"] : ["사각형", "원", "점찍기", "자유"]
        modeSegment.segmentCount = labels.count
        for (index, label) in labels.enumerated() {
            modeSegment.setLabel(label, forSegment: index)
            modeSegment.setWidth(0, forSegment: index)
        }
        modeSegment.selectedSegment = 0
        annotationWidthTitle.stringValue = "선 굵기"
        annotationFillPopup.isEnabled = true
        modeSegment.isHidden = erasing
        canvasMode = erasing ? .erase : drawing ? .drawRectangle : .rectangle
        annotationColorRow?.isHidden = !drawing
        annotationWidthTitle.isHidden = !drawing
        annotationWidthSlider.isHidden = !drawing
        annotationFillPopup.isHidden = !drawing
        annotationHint.isHidden = !drawing
        eraserTools.isHidden = !erasing
        canvas.resetInteraction()
        refreshCoverControls()
        refreshTextControls()
    }

    /// Cover controls follow the blur tool and the selected region's (or next region's) style.
    private func refreshCoverControls() {
        let blurTool = toolSegment.selectedSegment == 0
        let selected = selectedID.flatMap { id in pairs.first(where: { $0.shape.id == id }) }
        let style = selected?.effect.style ?? defaultCoverStyle
        coverSegment.selectedSegment = RegionEffect.CoverStyle.allCases.firstIndex(of: style) ?? 0
        if let selected { coverColorWell.color = selected.effect.color.nsColor }
        coverTitle.isHidden = !blurTool
        coverSegment.isHidden = !blurTool
        let showsStrength = blurTool && style != .solid
        effectTitle.stringValue = style == .mosaic ? "모자이크 크기" : "블러 강도"
        effectTitle.isHidden = !showsStrength; blurSlider.isHidden = !showsStrength; blurValueLabel.isHidden = !showsStrength
        featherTitle.isHidden = !blurTool; featherSlider.isHidden = !blurTool; featherValueLabel.isHidden = !blurTool
        coverColorRow.isHidden = !(blurTool && style == .solid)
    }

    private var selectedFillOpacity: CGFloat {
        [0, 0.35, 1][max(0, min(2, annotationFillPopup.indexOfSelectedItem))]
    }

    @objc private func annotationPresetChosen(_ sender: NSPopUpButton) {
        let colors: [NSColor] = [.systemYellow, .systemRed, .systemBlue, .systemGreen, .white]
        annotationColorWell.color = colors[max(0, min(colors.count - 1, sender.indexOfSelectedItem))]
        annotationStyleChanged(sender)
    }

    /// Style controls set the next drawing and restyle the selected one (one undo step per gesture).
    @objc private func annotationStyleChanged(_ sender: Any?) {
        canvas.refreshOverlay()
        guard !isExporting, let id = selectedDrawingID, let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        var drawing = annotations[index]
        drawing.setColor(annotationColorWell.color)
        drawing.lineWidth = CGFloat(annotationWidthSlider.doubleValue).rounded()
        drawing.fillOpacity = selectedFillOpacity
        guard drawing != annotations[index] else { return }
        // Only the color well streams continuous changes; popups and the eyedropper are single edits.
        if gestureSnapshot == nil { checkpoint(coalescing: sender is NSColorWell ? "drawing-color-\(id)" : nil) }
        annotations[index] = drawing
        refreshAfterEdit()
    }

    private func showDrawingStyle(_ drawing: DrawingAnnotation) {
        annotationColorWell.color = drawing.color
        annotationWidthSlider.doubleValue = Double(drawing.lineWidth)
        annotationFillPopup.selectItem(at: drawing.fillOpacity <= 0 ? 0 : drawing.fillOpacity < 1 ? 1 : 2)
    }

    @objc private func coverChanged(_ sender: NSSegmentedControl) {
        let style = RegionEffect.CoverStyle.allCases[max(0, min(2, sender.selectedSegment))]
        defaultCoverStyle = style
        updateSelectedEffect { $0.style = style }
        refreshCoverControls()
        refreshSelectedEditor()
    }

    @objc private func coverColorChanged(_ sender: Any?) {
        let color = RGBAColor(coverColorWell.color)
        updateSelectedEffect(coalescing: sender is NSColorWell ? "cover-color" : nil) { $0.color = color }
    }

    private func applyDefaultCover(to effect: inout RegionEffect) {
        effect.style = defaultCoverStyle
        effect.color = RGBAColor(coverColorWell.color)
    }

    @objc private func trackMotionChanged(_ sender: NSButton) {
        trackMotion = sender.state == .on
        canvas.recordingKeyframes = recordingKeyframes && trackMotion
        workflowHint.stringValue = trackMotion
            ? "움직임 기록 켬: 옮긴 시점의 위치가 기록됩니다."
            : "움직임 기록 끔: 옮기면 기록된 경로 전체가 함께 움직입니다."
        canvas.refreshOverlay()
    }

    // MARK: - Color picking

    private enum ColorTarget { case drawing, cover }

    @objc private func pickAnnotationColor() { startColorPick(.drawing) }
    @objc private func pickCoverColor() { startColorPick(.cover) }

    private func startColorPick(_ target: ColorTarget) {
        guard doc.mediaKind != .none, !isExporting else { return }
        workflowHint.stringValue = "색을 가져올 곳을 캔버스에서 클릭하세요. Esc로 취소합니다."
        window?.makeFirstResponder(canvas)
        canvas.colorPickHandler = { [weak self] point in
            guard let self else { return }
            guard let color = self.liveBlur.color(atCanvasPoint: point) else {
                self.workflowHint.stringValue = "이 위치의 색을 읽지 못했습니다."
                return
            }
            self.applyPickedColor(color, to: target)
        }
    }

    private func applyPickedColor(_ color: NSColor, to target: ColorTarget) {
        switch target {
        case .drawing:
            annotationColorWell.color = color
            annotationStyleChanged(nil)
        case .cover:
            coverColorWell.color = color
            coverColorChanged(nil)
        }
        workflowHint.stringValue = "색을 가져왔습니다."
    }

    // MARK: - Drawings, erasing, duplicating

    private func refreshAfterEdit() {
        canvas.refreshOverlay()
        liveBlur.refresh()
        refreshRegionList()
        refreshSelectedEditor()
    }

    private func addAnnotation(_ created: DrawingAnnotation) {
        guard !isExporting else { return }
        var drawing = created
        if doc.hasVideo {
            // Like regions: a new drawing shows from the time it was started to the end.
            let start = canvas.creationStartTime ?? playheadTime ?? 0
            drawing.timeRange = min(doc.duration, max(0, start))...doc.duration
        }
        if gestureSnapshot == nil { checkpoint() }
        annotations.append(drawing)
        // Select on the canvas too (text is placed from a prompt, not a canvas drag).
        canvas.selectAnnotation(id: drawing.id)
        refreshAfterEdit()
    }

    private func editAnnotation(_ edited: DrawingAnnotation) {
        guard !isExporting, let index = annotations.firstIndex(where: { $0.id == edited.id }) else { return }
        let anchor = gestureStartTime.flatMap { time in
            gestureAnnotations?.first(where: { $0.id == edited.id }).map { (time: time, annotation: $0) }
        }
        let before = annotations[index]
        let updated = before.applyingEdit(edited, time: editTime, recording: motionRecording, anchor: anchor)
        guard updated != before else { return }
        if gestureSnapshot == nil { checkpoint() }
        annotations[index] = updated
        if let move = groupMove(from: before.displayed(at: editTime).bounds, to: edited.bounds, group: before.groupID) {
            moveGroupMembers(move, except: before.id)
        }
        refreshAfterEdit()
    }

    private func eraseItems(regions: Set<UUID>, drawings: Set<UUID>) {
        guard !isExporting else { return }
        let keptPairs = pairs.filter { !regions.contains($0.shape.id) }
        let keptDrawings = annotations.filter { !drawings.contains($0.id) }
        guard keptPairs.count != pairs.count || keptDrawings.count != annotations.count else { return }
        if gestureSnapshot == nil { checkpoint() }
        pairs = keptPairs
        annotations = keptDrawings
        if let id = selectedID, regions.contains(id) { selectedID = nil }
        if let id = selectedDrawingID, drawings.contains(id) { selectedDrawingID = nil }
        canvas.setRegionsFromExternal(pairs.map(\.shape))
        refreshAfterEdit()
    }

    enum ClearScope { case regions, drawings, all }

    @objc private func clearRegionsTapped() { confirmClear(.regions) }
    @objc private func clearDrawingsTapped() { confirmClear(.drawings) }
    @objc private func clearAllTapped() { confirmClear(.all) }

    private func confirmClear(_ scope: ClearScope) {
        guard !isExporting else { return }
        let count = (scope == .drawings ? 0 : pairs.count) + (scope == .regions ? 0 : annotations.count)
        guard count > 0 else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = scope == .regions ? "블러 영역 \(pairs.count)개를 모두 지울까요?"
            : scope == .drawings ? "그림 \(annotations.count)개를 모두 지울까요?" : "영역과 그림 \(count)개를 모두 지울까요?"
        alert.informativeText = "⌘Z로 되돌릴 수 있습니다."
        alert.addButton(withTitle: "지우기")
        alert.addButton(withTitle: "취소")
        guard let window else { clearItems(scope); return }
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.clearItems(scope) }
        }
    }

    /// One undo step. Internal for tests (the confirmation sheet cannot be clicked there).
    func clearItems(_ scope: ClearScope) {
        endGesture()
        // Locked layers are kept.
        eraseItems(regions: scope == .drawings ? [] : Set(pairs.filter { !$0.effect.locked }.map(\.shape.id)),
                   drawings: scope == .regions ? [] : Set(annotations.filter { !$0.locked }.map(\.id)))
    }

    /// ⌘D: copies the selected item, or its whole group (as a new group), 12pt down-right.
    @objc private func duplicateSelectedTapped() {
        guard !isExporting, let selected = currentSelectionID else { NSSound.beep(); return }
        endGesture()
        let dx: CGFloat = 12, dy: CGFloat = -12
        func moved(_ r: CGRect) -> CGRect { r.offsetBy(dx: dx, dy: dy) }
        let group = groupIDOfItem(selected)
        let newGroup: UUID? = group == nil ? nil : UUID()
        func included(_ id: UUID, _ itemGroup: UUID?) -> Bool { id == selected || (group != nil && itemGroup == group) }
        var copiedSelection: UUID?
        var newDrawings: [DrawingAnnotation] = []
        for drawing in annotations where included(drawing.id, drawing.groupID) {
            var copy = drawing
            copy.id = UUID()
            copy.groupID = newGroup
            copy.name = drawing.name.map { $0 + " 사본" }
            copy.points = drawing.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            copy.erasures = drawing.replacingBounds(drawing.bounds.offsetBy(dx: dx, dy: dy)).erasures
            copy.keyframes = drawing.keyframes.map { RegionKeyframe(time: $0.time, rect: moved($0.rect)) }
            if drawing.id == selected { copiedSelection = copy.id }
            newDrawings.append(copy)
        }
        var newPairs: [RegionEditing.Pair] = []
        for pair in pairs where included(pair.shape.id, pair.effect.groupID) {
            let newID = UUID()
            let shape: RegionShape
            switch pair.shape {
            case .rectangle(_, let o, let size): shape = .rectangle(id: newID, origin: CGPoint(x: o.x + dx, y: o.y + dy), size: size)
            case .ellipse(_, let o, let size): shape = .ellipse(id: newID, origin: CGPoint(x: o.x + dx, y: o.y + dy), size: size)
            case .polygon(_, let points): shape = .polygon(id: newID, points: points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) })
            }
            var effect = pair.effect
            effect.groupID = newGroup
            effect.name = pair.effect.name.map { $0 + " 사본" }
            effect.keyframes = effect.keyframes.map { RegionKeyframe(time: $0.time, rect: moved($0.rect)) }
            effect.erasures = effect.erasures.map { $0.mapped(from: pair.shape.boundingRect, to: shape.boundingRect) }
            if pair.shape.id == selected { copiedSelection = newID }
            newPairs.append((shape, effect))
        }
        guard let copiedSelection else { NSSound.beep(); return }
        checkpoint()
        annotations.append(contentsOf: newDrawings)
        pairs.append(contentsOf: newPairs)
        if newPairs.contains(where: { $0.shape.id == copiedSelection }) { canvas.selectRegion(id: copiedSelection) }
        else { canvas.selectAnnotation(id: copiedSelection) }
        if newGroup != nil { workflowHint.stringValue = "그룹 전체(\(newDrawings.count + newPairs.count)개)를 복제했습니다." }
        refreshAfterEdit()
    }

    private func handleShortcut(_ key: Character) -> Bool {
        switch key {
        case "b": selectTool(0)
        case "d": selectTool(1)
        case "e": selectTool(2)
        case "i": startColorPick(toolSegment.selectedSegment == 1 ? .drawing : .cover)
        case ",": previousFrame()
        case ".": nextFrame()
        case "<": previousKeyframe()
        case ">": nextKeyframe()
        default: return false
        }
        return true
    }

    private func selectTool(_ index: Int) {
        guard !isExporting, toolSegment.selectedSegment != index else { return }
        toolSegment.selectedSegment = index
        toolChanged(toolSegment)
    }

    // MARK: - Eraser options

    @objc private func eraserStyleChanged(_ sender: Any?) {
        eraseFromNow = eraseFromNowCheckbox.state == .on
        refreshEraserControls()
        canvas.refreshOverlay()
    }

    private var eraserIsBrush: Bool { eraserModeSegment.selectedSegment == 0 }

    private func refreshEraserControls() {
        let size = Int(eraserSizeSlider.doubleValue.rounded())
        eraserSizeLabel.stringValue = "크기 \(size)pt"
        eraserSizeSlider.isEnabled = eraserIsBrush && !isExporting
        eraserTargetPopup.isHidden = !eraserIsBrush
        eraseFromNowCheckbox.isHidden = !doc.hasVideo
        eraserHint.stringValue = eraserIsBrush
            ? "문지른 부분만 지웁니다(블러 영역을 지우면 그 자리는 가려지지 않습니다). 지운 자리는 항목을 옮기거나 순서를 바꿔도 함께 움직이고, 영상에서는 지운 시점부터 적용됩니다."
            : "영역이나 그림을 클릭하거나 문질러 통째로 지웁니다. 영상에서는 켜 두면 지금 시점부터 사라지고 그 전 모습은 남습니다."
    }

    /// Eraser-tool removal on video ends each item just before the current time instead of
    /// deleting it, so everything shown earlier stays. Items that start now are removed.
    private func endItems(regions: Set<UUID>, drawings: Set<UUID>, at time: Double) {
        let cutoff = time - MotionTrack.sameTime / 2
        func trimmed(_ range: ClosedRange<Double>, entire: Bool) -> ClosedRange<Double>? {
            let start = entire ? 0 : range.lowerBound
            return cutoff - start > MotionTrack.sameTime ? start...cutoff : nil
        }
        var removeRegions = Set<UUID>(), removeDrawings = Set<UUID>()
        var newPairs = pairs, newDrawings = annotations
        for index in newPairs.indices where regions.contains(newPairs[index].shape.id) {
            let effect = newPairs[index].effect
            if let range = trimmed(effect.timeRange, entire: effect.appliesToEntireVideo) { newPairs[index].effect.timeRange = range }
            else { removeRegions.insert(newPairs[index].shape.id) }
        }
        for index in newDrawings.indices where drawings.contains(newDrawings[index].id) {
            let drawing = newDrawings[index]
            if let range = trimmed(drawing.timeRange, entire: drawing.appliesToEntireVideo) { newDrawings[index].timeRange = range }
            else { removeDrawings.insert(drawing.id) }
        }
        guard !RegionEditing.equal(newPairs, pairs) || newDrawings != annotations else { return }
        if gestureSnapshot == nil { checkpoint() }
        pairs = newPairs.filter { !removeRegions.contains($0.shape.id) }
        annotations = newDrawings.filter { !removeDrawings.contains($0.id) }
        if let id = selectedID, regions.contains(id) { selectedID = nil }
        if let id = selectedDrawingID, drawings.contains(id) { selectedDrawingID = nil }
        canvas.setRegionsFromExternal(pairs.map(\.shape))
        refreshAfterEdit()
    }

    /// Brush eraser: rubs out the part of each drawing shown under the stroke. The erasure is stored
    /// in the drawing's own base geometry, so it follows moves, motion, groups and reordering.
    /// Internal for tests.
    func applyEraserStroke(_ points: [CGPoint], width: CGFloat) {
        guard !isExporting, !points.isEmpty, width.isFinite, width > 0 else { return }
        let time = editTime
        let from: Double? = doc.hasVideo && eraseFromNow ? time : nil
        let area = EraseStroke.path(points)
            .copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1).boundingBoxOfPath
        let target = eraserTargetPopup.indexOfSelectedItem // 0 all, 1 drawings, 2 blur regions
        var drawings = annotations, regions = pairs
        var touched = 0
        if target != 2 {
            for index in drawings.indices where drawings[index].isVisible(at: time) && !drawings[index].locked {
                let shown = drawings[index].displayed(at: time)
                let reach = shown.lineWidth / 2 + 2
                guard shown.bounds.insetBy(dx: -reach, dy: -reach).intersects(area) else { continue }
                drawings[index].erasures.append(EraseStroke(points: points, width: width, from: from)
                    .mapped(from: shown.bounds, to: drawings[index].bounds))
                touched += 1
            }
        }
        if target != 1 {
            for index in regions.indices where regions[index].effect.isActive(at: time) && !regions[index].effect.locked {
                let shown = RegionEditing.displayed(regions[index], at: time).boundingRect
                guard shown.intersects(area) else { continue }
                regions[index].effect.erasures.append(EraseStroke(points: points, width: width, from: from)
                    .mapped(from: shown, to: regions[index].shape.boundingRect))
                touched += 1
            }
        }
        guard touched > 0 else {
            workflowHint.stringValue = "문지른 자리에 지울 항목이 없습니다."
            return
        }
        if gestureSnapshot == nil { checkpoint() }
        annotations = drawings
        pairs = regions
        refreshAfterEdit()
    }

    @objc private func restoreErasedFromMenu(_ sender: NSMenuItem) {
        guard !isExporting, let id = sender.representedObject as? UUID else { return }
        endGesture()
        if let index = annotations.firstIndex(where: { $0.id == id }), !annotations[index].erasures.isEmpty {
            checkpoint()
            annotations[index].erasures.removeAll()
        } else if let index = pairs.firstIndex(where: { $0.shape.id == id }), !pairs[index].effect.erasures.isEmpty {
            checkpoint()
            pairs[index].effect.erasures.removeAll()
        } else { return }
        refreshAfterEdit()
    }

    // MARK: - Text

    private func promptText(at point: NSPoint) {
        guard let text = askText(title: "글자 넣기", initial: "") else { return }
        addText(text, at: point)
    }

    /// Multi-line prompt (Return adds a line; the 확인 button confirms).
    private func askText(title: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "여러 줄로 쓸 수 있습니다(Return으로 줄바꿈). 넣은 뒤 끌어서 옮기고 모서리로 크기를 바꿀 수 있습니다."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 280, height: 90))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let view = NSTextView(frame: scroll.bounds)
        view.string = initial
        view.font = .systemFont(ofSize: 13)
        view.isRichText = false
        view.autoresizingMask = [.width]
        view.setAccessibilityLabel("글자 내용")
        scroll.documentView = view
        alert.accessoryView = scroll
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = view
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return Self.cleanedText(view.string)
    }

    /// Trims outer blank space and lines; keeps inner line breaks; caps the length.
    static func cleanedText(_ raw: String) -> String? {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(1000))
    }

    private var selectedTextFont: String? {
        let index = textFontPopup.indexOfSelectedItem
        return index <= 0 ? nil : textFontPopup.titleOfSelectedItem
    }

    private var selectedTextBackground: RGBAColor? {
        switch textBackgroundPopup.indexOfSelectedItem {
        case 1: return RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.55)
        case 2: return RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)
        case 3: return RGBAColor(red: 1, green: 1, blue: 1, alpha: 0.7)
        case 4: return RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
        default: return nil
        }
    }

    /// Places text with its top-left corner at `point`, using the current text settings. Internal for tests.
    func addText(_ string: String, at point: CGPoint) {
        guard !isExporting, let string = Self.cleanedText(string) else { return }
        let size = DrawingAnnotation.fontSize(forLineWidth: CGFloat(annotationWidthSlider.doubleValue))
        var drawing = DrawingAnnotation.text(string, at: .zero, fontSize: size, color: annotationColorWell.color,
                                             fontName: selectedTextFont, bold: textBoldCheckbox.state == .on,
                                             background: selectedTextBackground)
        let box = drawing.bounds
        let origin = CGPoint(x: min(max(0, point.x), max(0, canvas.bounds.width - box.width)),
                             y: min(max(0, point.y - box.height), max(0, canvas.bounds.height - box.height)))
        drawing.points = drawing.points.map { CGPoint(x: $0.x + origin.x, y: $0.y + origin.y) }
        addAnnotation(drawing)
    }

    /// Edits the text, keeping its size and top-left corner. Internal for tests.
    func replaceText(of id: UUID, with string: String) {
        guard !isExporting, let string = Self.cleanedText(string), let index = annotations.firstIndex(where: { $0.id == id }),
              annotations[index].kind == .text, annotations[index].text != string else { return }
        checkpoint()
        annotations[index] = annotations[index].withText(string)
        refreshAfterEdit()
    }

    /// Font, weight and background controls: set the next text and restyle a selected text.
    @objc private func textStyleChanged(_ sender: Any?) {
        guard !isExporting, let id = selectedDrawingID, let index = annotations.firstIndex(where: { $0.id == id }),
              annotations[index].kind == .text else { return }
        var updated = annotations[index].withText(annotations[index].text, fontName: .some(selectedTextFont),
                                                  bold: textBoldCheckbox.state == .on)
        updated.textBackground = selectedTextBackground
        guard updated != annotations[index] else { return }
        checkpoint()
        annotations[index] = updated
        refreshAfterEdit()
    }

    private func showTextStyle(_ drawing: DrawingAnnotation) {
        guard drawing.kind == .text else { return }
        if let font = drawing.fontName, textFontPopup.itemTitles.contains(font) { textFontPopup.selectItem(withTitle: font) }
        else { textFontPopup.selectItem(at: 0) }
        textBoldCheckbox.state = drawing.bold ? .on : .off
        let options: [RGBAColor?] = [nil, RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.55), RGBAColor(red: 0, green: 0, blue: 0, alpha: 1),
                                     RGBAColor(red: 1, green: 1, blue: 1, alpha: 0.7), RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)]
        textBackgroundPopup.selectItem(at: options.firstIndex(where: { $0 == drawing.textBackground }) ?? 0)
    }

    /// Text controls show in text mode or while a text drawing is selected.
    private func refreshTextControls() {
        let selectedText = selectedDrawingID.flatMap { id in annotations.first { $0.id == id } }?.kind == .text
        textTools.isHidden = !(toolSegment.selectedSegment == 1 && (canvasMode == .drawText || selectedText))
    }

    private func editText(_ id: UUID) {
        guard let drawing = annotations.first(where: { $0.id == id }), drawing.kind == .text,
              let text = askText(title: "글자 고치기", initial: drawing.text) else { return }
        replaceText(of: id, with: text)
    }

    // MARK: - Grouping

    private var currentSelectionID: UUID? { selectedID ?? selectedDrawingID }

    private func groupIDOfItem(_ id: UUID) -> UUID? {
        if let pair = pairs.first(where: { $0.shape.id == id }) { return pair.effect.groupID }
        return annotations.first(where: { $0.id == id })?.groupID
    }

    private func displayedBounds(of id: UUID) -> CGRect? {
        if let pair = pairs.first(where: { $0.shape.id == id }) { return RegionEditing.displayed(pair, at: editTime).boundingRect }
        return annotations.first(where: { $0.id == id }).map { $0.displayed(at: editTime).bounds }
    }

    private func toggleMultiSelection(_ id: UUID) {
        if multiSelection.isEmpty, let current = currentSelectionID, current != id { multiSelection.append(current) }
        if let index = multiSelection.firstIndex(of: id) { multiSelection.remove(at: index) } else { multiSelection.append(id) }
        workflowHint.stringValue = multiSelection.count >= 2
            ? "\(multiSelection.count)개 선택됨 · ⌘G 또는 [그룹 만들기]로 묶습니다."
            : "Shift+클릭으로 묶을 항목을 더 고르세요."
        canvas.refreshOverlay()
    }

    private func selectionDecorations() -> (multi: [CGRect], group: CGRect?) {
        let multi = multiSelection.compactMap { displayedBounds(of: $0) }
        guard let current = currentSelectionID, let group = groupIDOfItem(current) else { return (multi, nil) }
        let members = pairs.filter { $0.effect.groupID == group }.map(\.shape.id) + annotations.filter { $0.groupID == group }.map(\.id)
        let union = members.compactMap { displayedBounds(of: $0) }.reduce(CGRect.null) { $0.union($1) }
        return (multi, union.isNull ? nil : union)
    }

    @objc private func groupTapped() {
        guard !isExporting else { return }
        var ids = multiSelection
        if let current = currentSelectionID, !ids.contains(current) { ids.append(current) }
        ids = ids.filter { keyframesOfItem($0) != nil }
        guard ids.count >= 2 else {
            NSSound.beep()
            workflowHint.stringValue = "Shift+클릭으로 두 개 이상 고른 뒤 묶으세요."
            return
        }
        endGesture()
        checkpoint()
        let group = UUID()
        for index in pairs.indices where ids.contains(pairs[index].shape.id) { pairs[index].effect.groupID = group }
        for index in annotations.indices where ids.contains(annotations[index].id) { annotations[index].groupID = group }
        multiSelection.removeAll()
        workflowHint.stringValue = "\(ids.count)개를 그룹으로 묶었습니다. 하나를 옮기면 함께 움직입니다."
        refreshAfterEdit()
    }

    @objc private func ungroupTapped() {
        guard !isExporting else { return }
        let groups = Set((multiSelection + [currentSelectionID].compactMap { $0 }).compactMap { groupIDOfItem($0) })
        guard !groups.isEmpty else { NSSound.beep(); return }
        endGesture()
        checkpoint()
        for index in pairs.indices where pairs[index].effect.groupID.map(groups.contains) == true { pairs[index].effect.groupID = nil }
        for index in annotations.indices where annotations[index].groupID.map(groups.contains) == true { annotations[index].groupID = nil }
        multiSelection.removeAll()
        workflowHint.stringValue = "그룹을 풀었습니다."
        refreshAfterEdit()
    }

    /// Equal up to rounding (a polygon moved by its box is not bit-identical).
    private static func sameGeometry(_ a: RegionShape, _ b: RegionShape) -> Bool {
        func points(_ shape: RegionShape) -> [CGPoint] {
            if case .polygon(_, let pts) = shape { return pts }
            let r = shape.boundingRect
            return [r.origin, CGPoint(x: r.maxX, y: r.maxY)]
        }
        let pa = points(a), pb = points(b)
        return pa.count == pb.count && zip(pa, pb).allSatisfy { abs($0.x - $1.x) < 0.01 && abs($0.y - $1.y) < 0.01 }
    }

    /// A grouped item's box change; the other members get the same change relative to it.
    private struct GroupChange {
        let group: UUID
        let from: CGRect
        let to: CGRect

        /// Maps another member's box: same offset for a move, scaled about the edited box for a resize.
        func apply(_ rect: CGRect) -> CGRect {
            let sx = from.width > 0 ? to.width / from.width : 1
            let sy = from.height > 0 ? to.height / from.height : 1
            return CGRect(x: to.minX + (rect.minX - from.minX) * sx, y: to.minY + (rect.minY - from.minY) * sy,
                          width: rect.width * sx, height: rect.height * sy)
        }
    }

    private func groupMove(from old: CGRect, to new: CGRect, group: UUID?) -> GroupChange? {
        guard let group, old != new else { return nil }
        return GroupChange(group: group, from: old, to: new)
    }

    /// Applies the same box change to the other members of a group, with the same motion rules.
    private func moveGroupMembers(_ move: GroupChange, except source: UUID) {
        let shapes = pairs.map { pair -> RegionShape in
            let shown = RegionEditing.displayed(pair, at: editTime)
            guard pair.effect.groupID == move.group, pair.shape.id != source, !pair.effect.locked else { return shown }
            return shown.replacing(rect: move.apply(shown.boundingRect))
        }
        pairs = RegionEditing.updating(shapes, in: pairs, time: editTime, recording: motionRecording,
                                       anchorTime: gestureStartTime, anchorPairs: gestureSnapshot)
        for index in annotations.indices where annotations[index].groupID == move.group && annotations[index].id != source
            && !annotations[index].locked {
            let shown = annotations[index].displayed(at: editTime)
            let moved = shown.replacingBounds(move.apply(shown.bounds))
            let anchor = gestureStartTime.flatMap { time in
                gestureAnnotations?.first(where: { $0.id == moved.id }).map { (time: time, annotation: $0) }
            }
            annotations[index] = annotations[index].applyingEdit(moved, time: editTime, recording: motionRecording, anchor: anchor)
        }
    }

    // MARK: - Layers: name, visibility, lock

    private func layerState(_ id: UUID) -> (hidden: Bool, locked: Bool) {
        if let pair = pairs.first(where: { $0.shape.id == id }) { return (!pair.effect.enabled, pair.effect.locked) }
        if let drawing = annotations.first(where: { $0.id == id }) { return (drawing.hidden, drawing.locked) }
        return (false, false)
    }

    /// Hidden = left out of preview and export (regions use `enabled`). Internal for tests.
    func setLayerHidden(_ id: UUID, _ hidden: Bool) {
        guard !isExporting else { return }
        endGesture()
        if let index = pairs.firstIndex(where: { $0.shape.id == id }), pairs[index].effect.enabled == hidden {
            checkpoint()
            pairs[index].effect.enabled = !hidden
        } else if let index = annotations.firstIndex(where: { $0.id == id }), annotations[index].hidden != hidden {
            checkpoint()
            annotations[index].hidden = hidden
            if hidden, selectedDrawingID == id { canvas.clearAnnotationSelection() }
        } else { return }
        refreshAfterEdit()
    }

    /// Locked = cannot be picked, moved or erased on the canvas. Internal for tests.
    func setLayerLocked(_ id: UUID, _ locked: Bool) {
        guard !isExporting else { return }
        endGesture()
        if let index = pairs.firstIndex(where: { $0.shape.id == id }), pairs[index].effect.locked != locked {
            checkpoint()
            pairs[index].effect.locked = locked
        } else if let index = annotations.firstIndex(where: { $0.id == id }), annotations[index].locked != locked {
            checkpoint()
            annotations[index].locked = locked
        } else { return }
        refreshAfterEdit()
    }

    /// Empty or whitespace names fall back to the automatic name. Internal for tests.
    func renameLayer(_ id: UUID, to name: String) {
        guard !isExporting else { return }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        let value: String? = trimmed.isEmpty ? nil : trimmed
        endGesture()
        if let index = pairs.firstIndex(where: { $0.shape.id == id }), pairs[index].effect.name != value {
            checkpoint()
            pairs[index].effect.name = value
        } else if let index = annotations.firstIndex(where: { $0.id == id }), annotations[index].name != value {
            checkpoint()
            annotations[index].name = value
        } else { return }
        refreshAfterEdit()
    }

    private func layerID(from sender: Any?) -> UUID? {
        if let item = sender as? NSMenuItem { return item.representedObject as? UUID }
        return (sender as? NSView)?.identifier.flatMap { UUID(uuidString: $0.rawValue) }
    }

    @objc private func toggleLayerVisibility(_ sender: Any?) {
        guard let id = layerID(from: sender) else { return }
        setLayerHidden(id, !layerState(id).hidden)
    }

    @objc private func toggleLayerLock(_ sender: Any?) {
        guard let id = layerID(from: sender) else { return }
        setLayerLocked(id, !layerState(id).locked)
    }

    @objc private func toggleVisibilityFromMenu(_ sender: NSMenuItem) { toggleLayerVisibility(sender) }
    @objc private func toggleLockFromMenu(_ sender: NSMenuItem) { toggleLayerLock(sender) }

    @objc private func renameFromMenu(_ sender: NSMenuItem) {
        guard let id = layerID(from: sender) else { return }
        promptRename(id)
    }

    @objc private func layerDoubleClicked() {
        let rows = layerRows
        let row = regionList.clickedRow
        guard row >= 0, row < rows.count else { return }
        promptRename(rows[row].id)
    }

    private func promptRename(_ id: UUID) {
        let alert = NSAlert()
        alert.messageText = "레이어 이름"
        alert.informativeText = "비워 두면 자동 이름을 씁니다."
        let field = NSTextField(string: layerName(of: id))
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        // Leaving the shown (possibly automatic) name unchanged must not freeze it as a custom name.
        guard alert.runModal() == .alertFirstButtonReturn, field.stringValue != layerName(of: id) else { return }
        renameLayer(id, to: field.stringValue)
    }

    // MARK: - Stacking order

    private enum StackMove { case forward, backward, front, back }

    @objc private func bringForwardTapped() { restack(.forward) }
    @objc private func sendBackwardTapped() { restack(.backward) }
    @objc private func bringToFrontTapped() { restack(.front) }
    @objc private func sendToBackTapped() { restack(.back) }

    private func restacked<T>(_ items: [T], index: Int, _ move: StackMove) -> [T] {
        var result = items
        let item = result.remove(at: index)
        switch move {
        case .forward: result.insert(item, at: min(result.count, index + 1))
        case .backward: result.insert(item, at: max(0, index - 1))
        case .front: result.append(item)
        case .back: result.insert(item, at: 0)
        }
        return result
    }

    /// Later items draw on top: blur regions among regions, drawings among drawings
    /// (drawings always sit above regions).
    private func restack(_ move: StackMove) {
        guard !isExporting else { return }
        endGesture()
        if let id = selectedID, let index = pairs.firstIndex(where: { $0.shape.id == id }) {
            let result = restacked(pairs, index: index, move)
            guard !RegionEditing.equal(result, pairs) else { return }
            checkpoint()
            pairs = result
        } else if let id = selectedDrawingID, let index = annotations.firstIndex(where: { $0.id == id }) {
            let result = restacked(annotations, index: index, move)
            guard result != annotations else { return }
            checkpoint()
            annotations = result
        } else { NSSound.beep(); return }
        refreshAfterEdit()
    }

    // MARK: - Project save / open

    /// The session as a project, geometry normalized to a 1×1 canvas. Internal for tests.
    func projectData(projectURL: URL? = nil) throws -> Data {
        guard let media = doc.url, canvas.bounds.width > 0, canvas.bounds.height > 0 else {
            throw ProjectFile.ProjectError.invalidContent
        }
        let unit = CGSize(width: 1, height: 1)
        let regions = RegionEditing.scaled(pairs, from: canvas.bounds.size, to: unit).map { ProjectFile.Region(shape: $0.shape, effect: $0.effect) }
        let drawings = annotations.map { $0.scaled(from: canvas.bounds.size, to: unit) }
        return try ProjectFile(mediaPath: ProjectFile.mediaReference(for: media, projectURL: projectURL),
                               regions: regions, drawings: drawings).encoded()
    }

    @objc private func saveProjectTapped() {
        guard !isExporting, doc.mediaKind != .none, let media = doc.url else { NSSound.beep(); return }
        endGesture()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ProjectFile.contentType]
        panel.nameFieldStringValue = media.deletingPathExtension().lastPathComponent + "." + ProjectFile.fileExtension
        panel.directoryURL = media.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.standardizedFileURL != media.standardizedFileURL else {
            showError("원본 파일 이름으로는 프로젝트를 저장할 수 없습니다.")
            return
        }
        do {
            try projectData(projectURL: url).write(to: url, options: .atomic)
            workflowHint.stringValue = "프로젝트를 저장했습니다: \(url.lastPathComponent)"
        } catch { showError(error.localizedDescription) }
    }

    /// Asks for a `.bluraction` file and decodes it (validated). Returns the project and its URL.
    private func chooseProject(message: String? = nil) -> (ProjectFile, URL)? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [ProjectFile.contentType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let message { panel.message = message }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { throw ProjectFile.ProjectError.invalidContent }
            guard (values.fileSize ?? 0) <= ProjectFile.maximumBytes else { throw ProjectFile.ProjectError.tooLarge }
            return (try ProjectFile.decode(Data(contentsOf: url)), url)
        } catch {
            showError(error.localizedDescription)
            return nil
        }
    }

    private func chooseMedia(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        var types: [UTType] = [.movie, .quickTimeMovie, .mpeg4Movie, .video, .image]
        for identifier in ["public.heic", "public.heif", "org.webmproject.webp", "com.compuserve.gif"] {
            if let type = UTType(identifier) { types.append(type) }
        }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    @objc private func openProjectTapped() {
        guard !isExporting, let (project, url) = chooseProject() else { return }
        var media = project.mediaURL(relativeTo: url)
        if !VideoCanvasView.isSupportedDropFile(media) {
            // The media moved or was renamed: let the person point to it.
            guard let found = chooseMedia(message: "프로젝트의 원본(\(media.lastPathComponent))을 찾을 수 없습니다. 원본 파일을 선택하세요.") else { return }
            media = found
        }
        openProject(project, media: media)
    }

    /// Template use: the project's items (normalized positions, times, styles) on another video or image.
    @objc private func applyProjectToOtherMediaTapped() {
        guard !isExporting, let (project, _) = chooseProject(message: "적용할 프로젝트(템플릿)를 고르세요."),
              let media = chooseMedia(message: "프로젝트 항목을 적용할 영상이나 이미지를 고르세요.") else { return }
        openProject(project, media: media)
    }

    @objc private func importProjectItemsTapped() {
        guard !isExporting, doc.mediaKind != .none,
              let (project, _) = chooseProject(message: "현재 파일에 항목을 더할 프로젝트를 고르세요.") else { return }
        importProjectItems(project)
    }

    /// Adds a project's items to the current session as new items (new IDs and group IDs, fitted to
    /// the current canvas; times past the end are clipped). One undo step. Internal for tests.
    func importProjectItems(_ project: ProjectFile) {
        guard !isExporting, canvas.bounds.width > 0, canvas.bounds.height > 0 else { return }
        endGesture()
        let unit = CGSize(width: 1, height: 1), size = canvas.bounds.size
        var groups: [UUID: UUID] = [:]
        func newGroup(_ id: UUID?) -> UUID? { id.map { old in groups[old] ?? { let new = UUID(); groups[old] = new; return new }() } }
        func clipped(_ range: ClosedRange<Double>) -> ClosedRange<Double> {
            guard doc.hasVideo, !(range.lowerBound == 0 && range.upperBound == 0), range.upperBound > doc.duration else { return range }
            return min(range.lowerBound, doc.duration)...doc.duration
        }
        let imported = RegionEditing.scaled(project.regions.map { ($0.shape, $0.effect) }, from: unit, to: size).map { pair -> RegionEditing.Pair in
            let id = UUID()
            let shape: RegionShape
            switch pair.shape {
            case .rectangle(_, let o, let s): shape = .rectangle(id: id, origin: o, size: s)
            case .ellipse(_, let o, let s): shape = .ellipse(id: id, origin: o, size: s)
            case .polygon(_, let p): shape = .polygon(id: id, points: p)
            }
            var effect = pair.effect
            effect.groupID = newGroup(effect.groupID)
            effect.timeRange = clipped(effect.timeRange)
            return (shape, effect)
        }
        let drawings = project.drawings.map { drawing -> DrawingAnnotation in
            var copy = drawing.scaled(from: unit, to: size)
            copy.id = UUID()
            copy.groupID = newGroup(drawing.groupID)
            copy.timeRange = clipped(copy.timeRange)
            return copy
        }
        guard !imported.isEmpty || !drawings.isEmpty else { NSSound.beep(); return }
        checkpoint()
        pairs.append(contentsOf: imported)
        annotations.append(contentsOf: drawings)
        workflowHint.stringValue = "프로젝트에서 영역 \(imported.count)개 · 그림 \(drawings.count)개를 가져왔습니다."
        refreshAfterEdit()
    }

    /// Loads `media`, then applies the project's items once the media is laid out. Internal for tests.
    func openProject(_ project: ProjectFile, media: URL) {
        load(url: media, project: project)
    }

    private func applyProject(_ project: ProjectFile) {
        let size = canvas.bounds.size
        guard size.width > 0, size.height > 0 else {
            showError("화면을 준비하지 못해 프로젝트 내용을 적용하지 못했습니다. 창을 키운 뒤 다시 열어 주세요.")
            return
        }
        let unit = CGSize(width: 1, height: 1)
        pairs = RegionEditing.scaled(project.regions.map { ($0.shape, $0.effect) }, from: unit, to: size)
        annotations = project.drawings.map { $0.scaled(from: unit, to: size) }
        undoStack.removeAll()
        redoStack.removeAll()
        canvas.setRegionsFromExternal(pairs.map(\.shape))
        workflowHint.stringValue = "프로젝트를 열었습니다: 영역 \(pairs.count)개 · 그림 \(annotations.count)개"
        refreshAfterEdit()
    }

    // MARK: - Selected item timing (region or drawing)

    private var hasSelection: Bool { selectedID != nil || selectedDrawingID != nil }

    private var selectedKeyframes: [RegionKeyframe] {
        if let id = selectedID, let pair = pairs.first(where: { $0.shape.id == id }) { return pair.effect.keyframes }
        if let id = selectedDrawingID, let drawing = annotations.first(where: { $0.id == id }) { return drawing.keyframes }
        return []
    }

    private var selectedTiming: ClosedRange<Double>? {
        if let id = selectedID, let pair = pairs.first(where: { $0.shape.id == id }) { return pair.effect.timeRange }
        if let id = selectedDrawingID, let drawing = annotations.first(where: { $0.id == id }) { return drawing.timeRange }
        return nil
    }

    @objc private func previousKeyframe() {
        let now = canvas.currentVideoTime
        guard doc.hasVideo, let time = selectedKeyframes.map(\.time).filter({ $0 < now - MotionTrack.sameTime }).max() else { NSSound.beep(); return }
        stopPlayback()
        seek(to: time)
    }

    @objc private func nextKeyframe() {
        let now = canvas.currentVideoTime
        guard doc.hasVideo, let time = selectedKeyframes.map(\.time).filter({ $0 > now + MotionTrack.sameTime }).min() else { NSSound.beep(); return }
        stopPlayback()
        seek(to: time)
    }

    /// Moves recorded position `index` of the selected item to `time`, kept between its neighbours.
    /// Internal for tests (the timeline strip calls it after a drag).
    func retimeKeyframe(_ index: Int, to time: Double) {
        guard doc.hasVideo, !isExporting, time.isFinite else { return }
        func retimed(_ frames: [RegionKeyframe]) -> [RegionKeyframe]? {
            guard frames.indices.contains(index) else { return nil }
            let low = index > 0 ? frames[index - 1].time + MotionTrack.sameTime * 2 : 0
            let high = index < frames.count - 1 ? frames[index + 1].time - MotionTrack.sameTime * 2 : doc.duration
            guard low <= high else { return nil }
            var result = frames
            result[index].time = min(high, max(low, time))
            return result == frames ? nil : result
        }
        endGesture()
        if let id = selectedID, let i = pairs.firstIndex(where: { $0.shape.id == id }), let frames = retimed(pairs[i].effect.keyframes) {
            checkpoint()
            pairs[i].effect.keyframes = frames
        } else if let id = selectedDrawingID, let i = annotations.firstIndex(where: { $0.id == id }), let frames = retimed(annotations[i].keyframes) {
            checkpoint()
            annotations[i].keyframes = frames
        } else { return }
        refreshAfterEdit()
    }

    /// Drags of the timeline band's ends. Internal for tests.
    func moveRangeEdge(start: Bool, to time: Double) {
        guard doc.hasVideo, !isExporting, time.isFinite, let current = selectedTiming else { return }
        let range = current.lowerBound == 0 && current.upperBound == 0 ? 0...doc.duration : current
        let t = min(doc.duration, max(0, time))
        let lower = start ? t : range.lowerBound, upper = start ? range.upperBound : t
        guard upper - lower > MotionTrack.sameTime else { NSSound.beep(); return }
        endGesture()
        setSelectedTimeRange(lower == 0 && abs(upper - doc.duration) < MotionTrack.sameTime ? 0...0 : lower...upper)
    }

    private func selectedMotionPath() -> [CGPoint] {
        guard doc.hasVideo else { return [] }
        return selectedKeyframes.map { CGPoint(x: $0.rect.midX, y: $0.rect.midY) }
    }

    /// Applies to the selected item and, when it is grouped, to every member of its group.
    private func setSelectedTimeRange(_ range: ClosedRange<Double>) {
        guard let id = currentSelectionID else { return }
        let group = groupIDOfItem(id)
        func member(_ itemID: UUID, _ itemGroup: UUID?) -> Bool { itemID == id || (group != nil && itemGroup == group) }
        var newPairs = pairs, newDrawings = annotations
        for index in newPairs.indices where member(newPairs[index].shape.id, newPairs[index].effect.groupID) {
            newPairs[index].effect.timeRange = range
        }
        for index in newDrawings.indices where member(newDrawings[index].id, newDrawings[index].groupID) {
            newDrawings[index].timeRange = range
        }
        guard !RegionEditing.equal(newPairs, pairs) || newDrawings != annotations else { return }
        if gestureSnapshot == nil { checkpoint() }
        pairs = newPairs
        annotations = newDrawings
        refreshAfterEdit()
    }

    @objc private func blurChanged(_ sender: NSSlider) {
        let v = CGFloat(sender.doubleValue).rounded()
        blurValueLabel.stringValue = "\(Int(v))px"
        updateSelectedEffect { $0.blurRadius = v }
    }

    @objc private func featherChanged(_ sender: NSSlider) {
        let v = CGFloat(sender.doubleValue).rounded()
        featherValueLabel.stringValue = "\(Int(v))px"
        updateSelectedEffect { $0.featherRadius = v }
        liveBlur.refresh()
    }

    @objc private func qualityChanged(_ sender: NSPopUpButton) {
        if let title = sender.titleOfSelectedItem, let q = QualityPreset(rawValue: title) {
            quality = q
        }
        refreshQualityInfo()
    }

    @objc private func imageFormatChanged(_ sender: NSPopUpButton) { refreshQualityInfo() }

    private func updateSelectedEffect(coalescing key: String? = nil, _ transform: (inout RegionEffect) -> Void) {
        guard let sel = selectedID,
              let idx = pairs.firstIndex(where: { $0.shape.id == sel }) else { return }
        guard !isExporting else { return }
        var eff = pairs[idx].effect
        transform(&eff)
        guard eff != pairs[idx].effect else { return }
        if gestureSnapshot == nil { checkpoint(coalescing: key.map { "\($0)-\(sel)" }) }
        pairs[idx].effect = eff
        refreshRegionList()
        canvas.refreshOverlay()
        liveBlur.refresh()
    }

    private func refreshSelectedEditor() {
        timeRangeEditor.isHidden = !doc.hasVideo
        motionTools.isHidden = !doc.hasVideo
        let canEditRange = doc.hasVideo && hasSelection && !isExporting
        for control in [rangeStart, rangeEnd, rangeApply, rangeEntire] as [NSControl] { control.isEnabled = canEditRange }
        let canEditPosition = doc.mediaKind != .none && hasSelection && !isExporting
        for control in [positionX, positionY, positionWidth, positionHeight, applyPositionButton] as [NSControl] {
            control.isEnabled = canEditPosition
        }
        recordPositionButton.isEnabled = canEditRange && playheadTime != nil
        autoTrackButton.isEnabled = doc.hasVideo && hasSelection && !isExporting
        let canStep = doc.hasVideo && !isExporting && doc.videoFPS > 0
        previousFrameButton.isEnabled = canStep
        nextFrameButton.isEnabled = canStep
        rangeHint.textColor = .secondaryLabelColor
        mainContainer.slider.markers = doc.hasVideo ? selectedKeyframes.map(\.time) : []
        mainContainer.slider.rangeBand = doc.hasVideo ? selectedTiming.map { $0.lowerBound == 0 && $0.upperBound == 0 ? 0...doc.duration : $0 } : nil
        previousKeyButton.isEnabled = doc.hasVideo && !isExporting && selectedKeyframes.contains { $0.time < canvas.currentVideoTime - MotionTrack.sameTime }
        nextKeyButton.isEnabled = doc.hasVideo && !isExporting && selectedKeyframes.contains { $0.time > canvas.currentVideoTime + MotionTrack.sameTime }
        refreshCoverControls()
        canvas.refreshOverlay()
        let timing: (range: ClosedRange<Double>, entire: Bool)
        if let id = selectedDrawingID, let drawing = annotations.first(where: { $0.id == id }) {
            blurSlider.doubleValue = 0
            featherSlider.doubleValue = 0
            blurValueLabel.stringValue = "—"
            featherValueLabel.stringValue = "—"
            timing = (drawing.timeRange, drawing.appliesToEntireVideo)
        } else if let sel = selectedID, let pair = pairs.first(where: { $0.shape.id == sel }) {
            blurSlider.doubleValue = Double(pair.effect.blurRadius)
            blurValueLabel.stringValue = "\(Int(pair.effect.blurRadius))px"
            featherSlider.doubleValue = Double(pair.effect.featherRadius)
            featherValueLabel.stringValue = "\(Int(pair.effect.featherRadius))px"
            timing = (pair.effect.timeRange, pair.effect.appliesToEntireVideo)
        } else {
            blurSlider.doubleValue = 0
            featherSlider.doubleValue = 0
            blurValueLabel.stringValue = "—"
            featherValueLabel.stringValue = "—"
            rangeHint.stringValue = "영역이나 그림을 선택한 뒤 시간을 지정하세요."
            for field in [positionX, positionY, positionWidth, positionHeight] { field.stringValue = "" }
            return
        }
        refreshPositionFields()
        rangeStart.stringValue = String(format: "%.2f", timing.entire ? 0 : timing.range.lowerBound)
        rangeEnd.stringValue = String(format: "%.2f", timing.entire ? doc.duration : timing.range.upperBound)
        rangeHint.stringValue = timing.entire ? "현재: 영상 전체" : "현재: \(rangeStart.stringValue) ~ \(rangeEnd.stringValue)초"
    }

    /// Displayed bounding box of the selected region or drawing at the playhead.
    private var selectedDisplayedRect: CGRect? {
        if let id = selectedID, let pair = pairs.first(where: { $0.shape.id == id }) {
            return RegionEditing.displayed(pair, at: editTime).boundingRect
        }
        if let id = selectedDrawingID, let drawing = annotations.first(where: { $0.id == id }) {
            return drawing.displayed(at: editTime).bounds
        }
        return nil
    }

    private func refreshPositionFields() {
        guard let displayed = selectedDisplayedRect else { return }
        let source = doc.appliedVideoSize
        guard canvas.bounds.width > 0, canvas.bounds.height > 0, source.width > 0, source.height > 0 else { return }
        let sx = source.width / canvas.bounds.width
        let sy = source.height / canvas.bounds.height
        positionX.stringValue = String(format: "%.1f", displayed.minX * sx)
        positionY.stringValue = String(format: "%.1f", (canvas.bounds.height - displayed.maxY) * sy)
        positionWidth.stringValue = String(format: "%.1f", displayed.width * sx)
        positionHeight.stringValue = String(format: "%.1f", displayed.height * sy)
    }

    @objc private func applyTimeRange() {
        guard doc.hasVideo, hasSelection, !isExporting else { return }
        guard let start = Double(rangeStart.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let end = Double(rangeEnd.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              start.isFinite, end.isFinite, start >= 0, start < doc.duration, start < end, end <= doc.duration + 0.005 else {
            rangeHint.textColor = .systemRed
            rangeHint.stringValue = "0 ~ \(String(format: "%.2f", doc.duration))초 사이에서 시작 < 끝으로 입력하세요."
            return
        }
        endGesture()
        setSelectedTimeRange(start...min(end, doc.duration))
        refreshSelectedEditor()
    }

    @objc private func applyEntireVideo() {
        guard doc.hasVideo, hasSelection, !isExporting else { return }
        endGesture()
        setSelectedTimeRange(0...0)
        refreshSelectedEditor()
    }

    private func addRegion() {
        guard doc.mediaKind != .none, !isExporting else { return }
        checkpoint()
        let rect = canvas.displayRect == .zero ? canvas.bounds : canvas.displayRect
        let def = CGSize(width: max(40, rect.width * 0.25), height: max(40, rect.height * 0.25))
        let origin = CGPoint(x: rect.midX - def.width / 2, y: rect.midY - def.height / 2)
        let shape = RegionShape.rectangle(id: UUID(), origin: origin, size: def)
        var effect = RegionEffect.created(at: playheadTime, videoDuration: doc.hasVideo ? doc.duration : nil)
        applyDefaultCover(to: &effect)
        pairs.append((shape, effect))
        canvas.refreshOverlay()
        selectedID = shape.id
        canvas.selectRegion(id: shape.id)
        refreshRegionList()
        refreshSelectedEditor()
        liveBlur.refresh()
    }

    private func deleteSelected() {
        guard !isExporting else { return }
        if let id = currentSelectionID, layerState(id).locked {
            NSSound.beep()
            workflowHint.stringValue = "잠긴 레이어입니다. 레이어 목록에서 잠금을 풀면 지울 수 있습니다."
            return
        }
        if let id = selectedDrawingID {
            endGesture()
            eraseItems(regions: [], drawings: [id])
            return
        }
        canvas.deleteSelected()
        refreshRegionList()
        refreshSelectedEditor()
        liveBlur.refresh()
    }

    func load(url: URL) { load(url: url, project: nil) }

    private func load(url: URL, project: ProjectFile?) {
        Self.dropLoadLog.notice("load-requested")
        guard !isExporting else {
            Self.dropLoadLog.notice("load-blocked-by-export")
            return
        }
        guard url.isFileURL else {
            Self.dropLoadLog.notice("load-rejected-nonfile")
            showError("이 Mac에 저장된 파일을 선택하세요.")
            return
        }
        stopPlayback()
        resetPlaybackTime(duration: 0)
        mainContainer.slider.isEnabled = false
        mainContainer.playPauseButton.isEnabled = false
        playerItemStatusObserver?.invalidate()
        playerItemStatusObserver = nil
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        player.currentItem?.cancelPendingSeeks()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        pairs.removeAll(); annotations.removeAll(); undoStack.removeAll(); redoStack.removeAll(); gestureSnapshot = nil
        gestureAnnotations = nil
        selectedID = nil
        selectedDrawingID = nil
        multiSelection.removeAll()
        canvas.resetInteraction()
        canvas.isEditable = false
        canvas.currentVideoTime = 0
        player.replaceCurrentItem(with: nil)
        mainContainer.playerLayer.isHidden = true
        liveBlur.detach()
        liveBlur.sourceCGImage = nil
        liveBlur.contents = nil
        fileLabel.stringValue = "불러오는 중…"
        sourceInfoLabel.stringValue = "원본 정보를 읽는 중…"
        qualityInfoLabel.stringValue = "출력 사양을 계산하는 중…"
        progressLabel.stringValue = ""
        exportButton.isEnabled = false
        refreshRegionList(); refreshSelectedEditor()
        pendingProject = project
        doc.load(url: url)
    }

    private func documentLoaded() {
        guard doc.mediaKind != .none else {
            Self.dropLoadLog.notice("load-failed")
            pendingProject = nil
            fileLabel.stringValue = "파일을 열지 못했습니다"
            if let error = doc.errorMessage { showError(error) }
            return
        }
        Self.dropLoadLog.notice("load-succeeded")
        fileLabel.stringValue = doc.displayName
        window?.title = "BlurAction — \(doc.displayName)"
        resetPlaybackTime(duration: doc.duration)
        mainContainer.mediaSize = doc.appliedVideoSize
        fitWindowToMedia(doc.appliedVideoSize)
        frameRow.isHidden = !doc.hasVideo
        recordPositionButton.isHidden = !doc.hasVideo
        previousKeyButton.isHidden = !doc.hasVideo
        nextKeyButton.isHidden = !doc.hasVideo
        workflowHint.stringValue = doc.hasVideo
            ? "① 영역 그리기  ② 블러·시간 조정  ③ 필요하면 위치 기록  ④ 내보내기"
            : "① 영역 그리기  ② 블러·경계 조정  ③ 화질 선택  ④ 내보내기"
        refreshMediaInformation()
        liveBlur.videoSize = doc.appliedVideoSize
        liveBlur.videoTransform = doc.preferredTransform
        liveBlur.currentTime = 0
        canvas.currentVideoTime = 0
        mainContainer.playPauseButton.isHidden = doc.hasImage
        mainContainer.slider.isHidden = doc.hasImage
        mainContainer.timeLabel.stringValue = doc.hasImage ? (doc.url?.pathExtension.lowercased() == "gif" ? "GIF · 첫 프레임만 편집" : "이미지 · 정적 편집") : "00:00.00 / \(format(doc.duration))"
        imageFormatPopup.isHidden = !doc.hasImage
        if doc.hasImage {
            mainContainer.playerLayer.isHidden = true
            liveBlur.sourceCGImage = doc.currentCGImage
        } else if let url = doc.url {
            mainContainer.playerLayer.isHidden = false
            mainContainer.playerLayer.player = player
            let item = AVPlayerItem(asset: VideoAssetPolicy.asset(url: url))
            player.replaceCurrentItem(with: item)
            liveBlur.sourceCGImage = nil
            liveBlur.attach(item: item, player: player)
            observePlaybackTime(for: item)
            seek(to: 0)
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self, weak item] _ in
                MainActor.assumeIsolated {
                    guard let self, let item, self.player.currentItem === item,
                          !self.seekCoordinator.suppressesTimeObserver else { return }
                    self.stopPlayback()
                }
            }
        }
        mainContainer.refreshMediaLayout()
        setExporting(false)
        refreshEraserControls()
        if let project = pendingProject {
            pendingProject = nil
            applyProject(project)
        }
        refreshRegionList(); refreshSelectedEditor()
        canvas.refreshOverlay(); liveBlur.refresh()
    }

    /// Start near the media's pixel size while keeping the whole image on screen.
    /// Subsequent user window resizing still uses the canvas's aspect-fit layout.
    private func fitWindowToMedia(_ size: CGSize) {
        guard let window, let screen = window.screen ?? NSScreen.main,
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return }
        let visible = screen.visibleFrame
        let chrome = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 0, height: 0)).height
        let maxWidth = max(640, visible.width - 48)
        let maxHeight = max(420, visible.height - chrome - 48)
        let mediaWidth = maxWidth - 301
        let mediaHeight = maxHeight - 60
        let scale = min(1, mediaWidth / size.width, mediaHeight / size.height)
        let target = CGSize(width: max(640, ceil(size.width * scale) + 301),
                            height: max(420, ceil(size.height * scale) + 60))
        guard let content = window.contentView,
              abs(content.bounds.width - target.width) > 1 ||
              abs(content.bounds.height - target.height) > 1 else { return }
        window.setContentSize(target)
        window.center()
    }

    private func format(_ t: Double) -> String {
        guard t.isFinite else { return "00:00.00" }
        let m = Int(t) / 60, s = Int(t) % 60, cs = Int((t - floor(t)) * 100)
        return String(format: "%02d:%02d.%02d", m, s, cs)
    }

    private func refreshMediaInformation() {
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(doc.sourceBytes), countStyle: .file)
        let size = doc.appliedVideoSize
        if doc.hasImage {
            sourceInfoLabel.stringValue = "원본: \(Int(size.width)) × \(Int(size.height))px · \(doc.url?.pathExtension.uppercased() ?? "이미지") · \(bytes)"
        } else if doc.hasVideo {
            let fps = doc.videoFPS > 0 ? String(format: "%.2f fps", doc.videoFPS) : "fps 정보 없음"
            let bitRate = doc.videoBitRate > 0 ? String(format: "%.2f Mb/s", doc.videoBitRate / 1_000_000) : "비트레이트 정보 없음"
            sourceInfoLabel.stringValue = "원본: \(Int(size.width)) × \(Int(size.height))px · \(fps) · \(doc.videoCodec)\n\(bitRate) · \(format(doc.duration)) · \(bytes)"
        } else {
            sourceInfoLabel.stringValue = "파일을 열면 원본 정보가 표시됩니다."
        }
        refreshQualityInfo()
    }

    private func refreshQualityInfo() {
        if doc.hasImage {
            let format = imageFormatPopup.titleOfSelectedItem ?? "PNG"
            let detail = ["PNG", "TIFF"].contains(format) ? "무손실" :
                String(format: "압축 품질 %.0f%%", (quality == .original ? 1.0 :
                    quality == .high ? 0.92 : quality == .medium ? 0.75 : 0.5) * 100)
            qualityInfoLabel.stringValue = "출력: \(Int(doc.imageSize.width)) × \(Int(doc.imageSize.height))px · \(format) · \(detail)"
        } else if doc.hasVideo {
            let size = doc.appliedVideoSize
            let fps = max(1, doc.videoFPS)
            let rate = quality == .original ? max(500_000, doc.videoBitRate) :
                max(500_000, size.width * size.height * fps * quality.bitsPerPixelPerSecond)
            let fpsLabel = doc.videoFPS > 0 ? String(format: "%.2f fps", doc.videoFPS) : "원본 프레임 유지"
            qualityInfoLabel.stringValue = "출력: \(Int(size.width)) × \(Int(size.height))px · \(fpsLabel)\nH.264 · 목표 \(String(format: "%.2f", rate / 1_000_000)) Mb/s · MP4/MOV\n원본 화질도 재인코딩\(doc.hasAudio ? " · 오디오 AAC 128 kb/s" : "")"
        } else {
            qualityInfoLabel.stringValue = "파일을 열면 출력 사양이 표시됩니다."
        }
    }

    private func refreshRegionList() {
        guard !refreshingList else { return }
        refreshingList = true
        defer { refreshingList = false }
        regionList.reloadData()
        if let id = currentSelectionID, let row = layerRows.firstIndex(where: { $0.id == id }) {
            regionList.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else { regionList.deselectAll(nil) }
        exportButton.isEnabled = !isExporting && doc.mediaKind != .none && hasEffectiveEffect
    }

    // MARK: - Context menu

    private func showRegionContextMenu(for id: UUID?, at pt: NSPoint) {
        showRegionContextMenu(for: id, at: pt, fromList: false)
    }

    private func showItemContextMenu(for id: UUID, at pt: NSPoint) {
        showRegionContextMenu(for: id, at: pt, fromList: false)
    }

    private func showRegionContextMenu(for id: UUID?, at pt: NSPoint, fromList: Bool) {
        guard !isExporting else { return }
        let menu = makeRegionContextMenu(for: id)
        if fromList {
            // 사이드바 행 우클릭: 행의 우측에 표시
            if let view = regionList.window?.contentView {
                let row = layerRows.firstIndex(where: { $0.id == id }) ?? -1
                if row >= 0 {
                    let rectInWindow = regionList.convert(regionList.rect(ofRow: row), to: nil)
                    let locationInView = view.convert(rectInWindow.origin, from: nil)
                    menu.popUp(positioning: nil, at: NSPoint(x: locationInView.x + 200, y: locationInView.y), in: view)
                }
            }
        } else if let view = canvas.window?.contentView {
            let locationInView = view.convert(pt, from: canvas)
            menu.popUp(positioning: nil, at: locationInView, in: view)
        }
    }

    private static let durationPresets: [Double] = [0.5, 1, 3, 5, 10]
    private struct DurationPreset {
        let regionID: UUID
        let start: Double?
        let seconds: Double
    }

    /// Shared by canvas and list; kept separate from the blocking menu popup for verification.
    func makeRegionContextMenu(for id: UUID?) -> NSMenu {
        let menu = NSMenu(title: "영역")
        menu.autoenablesItems = false
        guard !isExporting, let id, let keyframes = keyframesOfItem(id) else { return menu }
        let isDrawing = !pairs.contains(where: { $0.shape.id == id })
        if doc.hasVideo {
            let start = playheadTime // Freeze the menu-open playhead while playback may continue.
            for (index, seconds) in Self.durationPresets.enumerated() {
                let label = seconds == 0.5 ? "0.5" : String(Int(seconds))
                let item = NSMenuItem(title: "현재 위치부터 \(label)초", action: #selector(applyDurationPreset(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = DurationPreset(regionID: id, start: start, seconds: seconds)
                item.tag = index
                item.isEnabled = start.map {
                    RegionEffect.durationRange(startingAt: $0, seconds: seconds, videoDuration: doc.duration) != nil
                } ?? false
                menu.addItem(item)
            }
            let entire = NSMenuItem(title: "영상 전체", action: #selector(applyEntireVideoFromMenu(_:)), keyEquivalent: "")
            entire.target = self
            entire.representedObject = id
            menu.addItem(entire)
            menu.addItem(NSMenuItem.separator())
        }
        let reset = NSMenuItem(title: "이동 기록 지우기", action: #selector(clearMotion(_:)), keyEquivalent: "")
        reset.target = self; reset.representedObject = id
        reset.isEnabled = !keyframes.isEmpty
        menu.addItem(reset)
        let rename = NSMenuItem(title: "이름 바꾸기…", action: #selector(renameFromMenu(_:)), keyEquivalent: "")
        rename.target = self; rename.representedObject = id
        menu.addItem(rename)
        let state = layerState(id)
        let visibility = NSMenuItem(title: state.hidden ? "보이기" : "숨기기", action: #selector(toggleVisibilityFromMenu(_:)), keyEquivalent: "")
        visibility.target = self; visibility.representedObject = id
        menu.addItem(visibility)
        let lockItem = NSMenuItem(title: state.locked ? "잠금 풀기" : "잠그기", action: #selector(toggleLockFromMenu(_:)), keyEquivalent: "")
        lockItem.target = self; lockItem.representedObject = id
        menu.addItem(lockItem)
        let duplicate = NSMenuItem(title: "복제", action: #selector(duplicateFromMenu(_:)), keyEquivalent: "")
        duplicate.target = self; duplicate.representedObject = id
        menu.addItem(duplicate)
        for (index, title) in ["맨 앞으로", "앞으로", "뒤로", "맨 뒤로"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(restackFromMenu(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = id; item.tag = index
            menu.addItem(item)
        }
        if annotations.first(where: { $0.id == id })?.erasures.isEmpty == false
            || pairs.first(where: { $0.shape.id == id })?.effect.erasures.isEmpty == false {
            let restore = NSMenuItem(title: "지운 부분 되살리기", action: #selector(restoreErasedFromMenu(_:)), keyEquivalent: "")
            restore.target = self; restore.representedObject = id
            menu.addItem(restore)
        }
        if groupIDOfItem(id) != nil {
            let ungroup = NSMenuItem(title: "그룹 풀기", action: #selector(ungroupFromMenu(_:)), keyEquivalent: "")
            ungroup.target = self; ungroup.representedObject = id
            menu.addItem(ungroup)
        }
        menu.addItem(NSMenuItem.separator())
        let delItem = NSMenuItem(title: isDrawing ? "그림 삭제" : "영역 삭제", action: #selector(deleteRegionFromMenu(_:)), keyEquivalent: "")
        delItem.target = self
        delItem.representedObject = id
        menu.addItem(delItem)
        return menu
    }

    private func keyframesOfItem(_ id: UUID) -> [RegionKeyframe]? {
        if let pair = pairs.first(where: { $0.shape.id == id }) { return pair.effect.keyframes }
        return annotations.first(where: { $0.id == id })?.keyframes
    }

    private func selectItem(_ id: UUID) {
        if pairs.contains(where: { $0.shape.id == id }) { canvas.selectRegion(id: id) }
        else if annotations.contains(where: { $0.id == id }) { canvas.selectAnnotation(id: id) }
    }

    @objc private func applyDurationPreset(_ sender: NSMenuItem) {
        guard doc.hasVideo, !isExporting, let preset = sender.representedObject as? DurationPreset,
              keyframesOfItem(preset.regionID) != nil, let time = preset.start,
              let range = RegionEffect.durationRange(startingAt: time, seconds: preset.seconds, videoDuration: doc.duration) else { return }
        endGesture()
        selectItem(preset.regionID)
        setSelectedTimeRange(range)
        refreshSelectedEditor()
    }

    @objc private func applyEntireVideoFromMenu(_ sender: NSMenuItem) {
        guard doc.hasVideo, !isExporting, let id = sender.representedObject as? UUID,
              keyframesOfItem(id) != nil else { return }
        selectItem(id)
        applyEntireVideo()
    }

    @objc private func clearMotion(_ sender: NSMenuItem) {
        guard !isExporting, let id = sender.representedObject as? UUID else { return }
        endGesture()
        if let index = pairs.firstIndex(where: { $0.shape.id == id }) {
            checkpoint()
            let frozen = RegionEditing.displayed(pairs[index], at: editTime)
            pairs[index].effect.erasures = pairs[index].effect.erasures.map {
                $0.mapped(from: pairs[index].shape.boundingRect, to: frozen.boundingRect)
            }
            pairs[index].shape = frozen
            pairs[index].effect.keyframes = []
        } else if let index = annotations.firstIndex(where: { $0.id == id }) {
            checkpoint()
            let frozen = annotations[index].displayed(at: editTime)
            annotations[index].points = frozen.points
            annotations[index].erasures = frozen.erasures
            annotations[index].keyframes = []
        } else { return }
        refreshAfterEdit()
    }

    @objc private func restackFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        selectItem(id)
        restack([StackMove.front, .forward, .backward, .back][max(0, min(3, sender.tag))])
    }

    @objc private func ungroupFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        selectItem(id)
        ungroupTapped()
    }

    @objc private func duplicateFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        selectItem(id)
        duplicateSelectedTapped()
    }

    @objc private func deleteRegionFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        endGesture()
        eraseItems(regions: [id], drawings: [id])
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension NSToolbarItem.Identifier {
    static let open = NSToolbarItem.Identifier("com.bluraction.open")
    static let addRegion = NSToolbarItem.Identifier("com.bluraction.addRegion")
    static let export = NSToolbarItem.Identifier("com.bluraction.export")
}

extension MainWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.open, .addRegion, .flexibleSpace, .export]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case .open:
            item.label = "열기"; item.paletteLabel = "열기"
            item.toolTip = "영상 파일 열기 (⌘O)"
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "열기")
            item.target = self; item.action = #selector(openTapped)
        case .addRegion:
            item.label = "영역 추가"; item.paletteLabel = "영역 추가"
            item.toolTip = "사각형 영역 추가 (⇧⌘A)"
            item.image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: "영역 추가")
            item.target = self; item.action = #selector(addRegionTapped)
        case .export:
            item.label = "내보내기"; item.paletteLabel = "내보내기"
            item.toolTip = "블러 처리해서 저장 (⌘E)"
            item.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "내보내기")
            item.target = self; item.action = #selector(exportTapped)
        default:
            return nil
        }
        return item
    }
}

extension MainWindowController: NSTableViewDataSource, NSTableViewDelegate {
    /// Layer rows, top of the list = drawn on top: drawings (front first), then blur regions.
    var layerRows: [(id: UUID, isDrawing: Bool)] {
        annotations.reversed().map { ($0.id, true) } + pairs.reversed().map { ($0.shape.id, false) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { layerRows.count }

    /// Automatic layer name: kind plus number within its kind (or the text itself).
    func layerName(of id: UUID) -> String {
        if let index = pairs.firstIndex(where: { $0.shape.id == id }) {
            if let name = pairs[index].effect.name, !name.isEmpty { return name }
            let kind: String
            switch pairs[index].shape {
            case .rectangle: kind = "사각형"
            case .ellipse: kind = "원"
            case .polygon: kind = "자유형"
            }
            let cover = ["블러", "모자이크", "단색"][RegionEffect.CoverStyle.allCases.firstIndex(of: pairs[index].effect.style) ?? 0]
            return "\(cover) \(kind) \(index + 1)"
        }
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return "" }
        let drawing = annotations[index]
        if let name = drawing.name, !name.isEmpty { return name }
        switch drawing.kind {
        case .text: return "글자 “\(drawing.text.replacingOccurrences(of: "\n", with: " ").prefix(16))”"
        case .rectangle: return "사각형 그림 \(index + 1)"
        case .ellipse: return "타원 그림 \(index + 1)"
        case .line: return "선 \(index + 1)"
        case .arrow: return "화살표 \(index + 1)"
        case .freehand: return "펜 \(index + 1)"
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let rows = layerRows
        guard row >= 0, row < rows.count else { return nil }
        let item = rows[row]
        let container = NSView()
        container.wantsLayer = true
        let image = NSImageView()
        let text = NSTextField(labelWithString: layerName(of: item.id))
        text.lineBreakMode = .byTruncatingTail
        text.font = .systemFont(ofSize: 12)
        let detail = NSTextField(labelWithString: "")
        detail.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let eye = NSButton(image: NSImage(), target: self, action: #selector(toggleLayerVisibility(_:)))
        let lock = NSButton(image: NSImage(), target: self, action: #selector(toggleLayerLock(_:)))
        for button in [eye, lock] {
            button.isBordered = false
            button.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
            button.imageScaling = .scaleProportionallyDown
        }
        let hidden: Bool, locked: Bool, timing: ClosedRange<Double>, motion: Bool, grouped: Bool, active: Bool
        if item.isDrawing, let drawing = annotations.first(where: { $0.id == item.id }) {
            hidden = drawing.hidden; locked = drawing.locked; timing = drawing.timeRange
            motion = !drawing.keyframes.isEmpty; grouped = drawing.groupID != nil
            active = drawing.isVisible(at: doc.hasVideo ? canvas.currentVideoTime : nil)
            let symbol: String
            switch drawing.kind {
            case .text: symbol = "textformat"
            case .arrow: symbol = "arrow.up.right"
            case .line: symbol = "line.diagonal"
            case .freehand: symbol = "scribble"
            case .ellipse: symbol = "circle"
            case .rectangle: symbol = "rectangle"
            }
            image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "그림")
            image.contentTintColor = drawing.color
        } else if let pair = pairs.first(where: { $0.shape.id == item.id }) {
            hidden = !pair.effect.enabled; locked = pair.effect.locked; timing = pair.effect.timeRange
            motion = !pair.effect.keyframes.isEmpty; grouped = pair.effect.groupID != nil
            active = pair.effect.isActive(at: doc.hasVideo ? canvas.currentVideoTime : nil)
            let symbol: String
            switch pair.shape {
            case .rectangle: symbol = "rectangle.fill"
            case .ellipse: symbol = "circle.fill"
            case .polygon: symbol = "pentagon.fill"
            }
            image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "블러 영역")
            image.contentTintColor = active ? .systemBlue : .systemGray
        } else { return nil }
        var details: [String] = []
        if doc.hasVideo { details.append(timing.lowerBound == 0 && timing.upperBound == 0 ? "전체" : "\(format(timing.lowerBound))~\(format(timing.upperBound))") }
        if motion { details.append("이동") }
        if grouped { details.append("그룹") }
        detail.stringValue = details.joined(separator: " · ")
        text.textColor = hidden ? .tertiaryLabelColor : .labelColor
        eye.image = NSImage(systemSymbolName: hidden ? "eye.slash" : "eye", accessibilityDescription: hidden ? "숨김" : "보임")
        eye.toolTip = hidden ? "보이기 (미리보기와 내보내기에 포함)" : "숨기기 (미리보기와 내보내기에서 빠짐)"
        eye.setAccessibilityLabel(hidden ? "\(text.stringValue) 보이기" : "\(text.stringValue) 숨기기")
        lock.image = NSImage(systemSymbolName: locked ? "lock.fill" : "lock.open", accessibilityDescription: locked ? "잠김" : "풀림")
        lock.toolTip = locked ? "잠금 풀기" : "잠그기 (캔버스에서 선택·이동·지우기 막기)"
        lock.setAccessibilityLabel(locked ? "\(text.stringValue) 잠금 풀기" : "\(text.stringValue) 잠그기")
        lock.contentTintColor = locked ? .systemOrange : .tertiaryLabelColor
        if currentSelectionID == item.id {
            container.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.12).cgColor
        } else if multiSelection.contains(item.id) {
            container.layer?.backgroundColor = NSColor.systemPurple.withAlphaComponent(0.12).cgColor
        }
        for view in [image, text, detail, eye, lock] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            image.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 14), image.heightAnchor.constraint(equalToConstant: 14),
            lock.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            lock.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            lock.widthAnchor.constraint(equalToConstant: 18), lock.heightAnchor.constraint(equalToConstant: 18),
            eye.trailingAnchor.constraint(equalTo: lock.leadingAnchor, constant: -4),
            eye.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            eye.widthAnchor.constraint(equalToConstant: 20), eye.heightAnchor.constraint(equalToConstant: 18),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.topAnchor.constraint(equalTo: container.topAnchor, constant: 3),
            text.trailingAnchor.constraint(lessThanOrEqualTo: eye.leadingAnchor, constant: -4),
            detail.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            detail.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 0),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: eye.leadingAnchor, constant: -4)
        ])
        return container
    }

    private func isEffectActive(_ effect: RegionEffect, at time: Double) -> Bool {
        effect.isActive(at: time)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !refreshingList else { return }
        let rows = layerRows
        let row = regionList.selectedRow
        guard row >= 0, row < rows.count else { return }
        selectItem(rows[row].id)
        refreshSelectedEditor()
        liveBlur.refresh()
    }

    /// 레이어 행 우클릭 — 캔버스 우클릭과 같은 메뉴(+ 이름 바꾸기·숨기기·잠금)
    func tableView(_ tableView: NSTableView, menuFor event: NSEvent) -> NSMenu? {
        let rows = layerRows
        let row = tableView.row(at: tableView.convert(event.locationInWindow, from: nil))
        guard row >= 0, row < rows.count else { return nil }
        let id = rows[row].id
        selectItem(id)
        refreshSelectedEditor()
        showRegionContextMenu(for: id, at: .zero, fromList: true)
        return nil
    }
}

final class RegionTableView: NSTableView {
    var contextMenuHandler: ((NSEvent) -> Void)?
    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenuHandler?(event)
        return nil
    }
}

final class FlippedDocumentView: NSView { override var isFlipped: Bool { true } }
