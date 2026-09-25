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
    private let trackMotionCheckbox = NSButton(checkboxWithTitle: "움직임 기록", target: nil, action: nil)
    private let trackMotionHint = NSTextField(wrappingLabelWithString: "켜면 옮긴 시점의 위치가 기록되어 영역·그림이 움직임을 따라갑니다. 재생 중 끌어도, 멈춘 채 프레임을 넘기며 옮겨도 됩니다. 끄면 기록된 경로 전체가 함께 옮겨집니다.")
    private let motionTools = NSStackView()
    private var annotationColorRow: NSStackView?
    private let regionTitle = NSTextField(labelWithString: "영역")
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
            return self.annotations.map { $0.displayed(at: self.editTime) }
        }
        canvas.annotationStyleBinding = { [weak self] in
            guard let self else { return (.systemYellow, 4, 0) }
            return (self.annotationColorWell.color, CGFloat(self.annotationWidthSlider.doubleValue), self.selectedFillOpacity)
        }
        canvas.annotationAdded = { [weak self] created in self?.addAnnotation(created) }
        canvas.annotationChanged = { [weak self] edited in self?.editAnnotation(edited) }
        canvas.itemsErased = { [weak self] regions, drawings in self?.eraseItems(regions: regions, drawings: drawings) }
        canvas.annotationSelectionChange = { [weak self] id in
            guard let self else { return }
            self.selectedDrawingID = id
            if id != nil { self.selectedID = nil }
            if let id, let drawing = self.annotations.first(where: { $0.id == id }) { self.showDrawingStyle(drawing) }
            self.refreshSelectedEditor()
            self.refreshRegionList()
        }
        canvas.rightClickOnAnnotation = { [weak self] id, pt in self?.showItemContextMenu(for: id, at: pt) }
        canvas.colorPickCancelled = { [weak self] in self?.workflowHint.stringValue = "색 고르기를 취소했습니다." }
        canvas.shortcutHandler = { [weak self] key in self?.handleShortcut(key) ?? false }
        canvas.motionPathProvider = { [weak self] in self?.selectedMotionPath() ?? [] }
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
            if !RegionEditing.equal(self.pairs, result) {
                if self.gestureSnapshot == nil { self.checkpoint() }
                self.pairs = result
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

    private func checkpoint() {
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
        for view in [trackMotionCheckbox, trackMotionHint] { motionTools.addArrangedSubview(view) }
        motionTools.isHidden = true
        let eraserHint = NSTextField(wrappingLabelWithString: "캔버스에서 지울 영역이나 그림을 클릭하거나 문질러 지웁니다. 모든 지우기는 ⌘Z로 되돌릴 수 있습니다.")
        eraserHint.font = .systemFont(ofSize: 11)
        eraserHint.textColor = .secondaryLabelColor
        eraserHint.preferredMaxLayoutWidth = 260
        eraserTools.orientation = .vertical
        eraserTools.alignment = .leading
        eraserTools.spacing = 6
        eraserTools.addArrangedSubview(eraserHint)
        for (title, action) in [("선택 항목 지우기", #selector(deleteSelectedTapped)), ("블러 영역 모두 지우기", #selector(clearRegionsTapped)),
                                ("그리기 모두 지우기", #selector(clearDrawingsTapped)), ("모두 지우기", #selector(clearAllTapped))] {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            eraserTools.addArrangedSubview(button)
        }
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
        for slider in [blurSlider, featherSlider] {
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
        regionList.rowHeight = 26
        regionList.usesAlternatingRowBackgroundColors = false
        regionList.dataSource = self
        regionList.delegate = self
        // NSTableColumn 필수 — view-based table에서도 column 없으면 row 안 그려짐
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("RegionColumn"))
        col.title = "영역"
        col.width = 300
        col.minWidth = 200
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
        for item in [precisionTitle, frameRow, recordPositionButton, positionRow, sizeRow,
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
            scrollContainer.heightAnchor.constraint(equalToConstant: 160)
        ])

        for v in [fileTitle, fileLabel, sourceInfoLabel] { sidebarHeader.addArrangedSubview(v) }
        fileLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 260).isActive = true
        let annotationColorRow = NSStackView(views: [annotationColorWell, annotationPickButton, annotationColorPopup])
        annotationColorRow.spacing = 6
        annotationColorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        coverColorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        self.annotationColorRow = annotationColorRow
        for v in [workflowHint,
                  toolSegment, modeSegment, annotationColorRow, annotationWidthTitle, annotationWidthSlider, annotationFillPopup,
                  annotationHint, eraserTools,
                  coverTitle, coverSegment, effectTitle, blurRow, featherTitle, featherRow, coverColorRow, regionTitle,
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

    @objc private func cancelTapped() { exporter.cancel() }

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

    private var hasEffectiveEffect: Bool { hasEffectiveBlur || !annotations.isEmpty }

    private func setExporting(_ value: Bool) {
        isExporting = value
        canvas.isEditable = !value && doc.mediaKind != .none
        exportButton.isEnabled = !value && doc.mediaKind != .none && hasEffectiveEffect
        for control in [blurSlider, featherSlider, toolSegment, modeSegment, annotationColorPopup, annotationWidthSlider, qualityPopup, imageFormatPopup,
                        annotationColorWell, annotationPickButton, annotationFillPopup, coverSegment, coverColorWell, coverPickButton,
                        trackMotionCheckbox] as [NSControl] {
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
        redoStack.append(EditorSnapshot(pairs: pairs, annotations: annotations))
        BLog("[undo] restoring \(prev.pairs.count) regions from stack depth=\(undoStack.count)")
        self.pairs = prev.pairs
        self.annotations = prev.annotations
        if let id = selectedDrawingID, !annotations.contains(where: { $0.id == id }) { selectedDrawingID = nil }
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
        undoStack.append(EditorSnapshot(pairs: pairs, annotations: annotations))
        BLog("[redo] restoring \(next.pairs.count) regions from stack depth=\(redoStack.count)")
        self.pairs = next.pairs
        self.annotations = next.annotations
        if let id = selectedDrawingID, !annotations.contains(where: { $0.id == id }) { selectedDrawingID = nil }
        self.canvas.setRegionsFromExternal(next.pairs.map(\.shape))
        self.canvas.refreshOverlay()
        self.refreshRegionList()
        self.refreshSelectedEditor()
        self.liveBlur.refresh()
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        if toolSegment.selectedSegment == 1 {
            switch sender.selectedSegment { case 0: canvasMode = .drawRectangle; case 1: canvasMode = .drawEllipse
            case 2: canvasMode = .drawLine; case 3: canvasMode = .drawFreehand; default: canvasMode = .drawRectangle }
        } else {
            switch sender.selectedSegment { case 0: canvasMode = .rectangle; case 1: canvasMode = .ellipse
            case 2: canvasMode = .polygonClick; case 3: canvasMode = .polygonFree; default: canvasMode = .rectangle }
        }
        canvas.resetInteraction()
    }

    @objc private func toolChanged(_ sender: NSSegmentedControl) {
        let drawing = sender.selectedSegment == 1
        let erasing = sender.selectedSegment == 2
        let labels = drawing ? ["사각형", "타원", "선", "펜"] : ["사각형", "원", "점찍기", "자유"]
        for (index, label) in labels.enumerated() { modeSegment.setLabel(label, forSegment: index) }
        modeSegment.selectedSegment = 0
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
        if gestureSnapshot == nil { checkpoint() }
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
        updateSelectedEffect { $0.color = color }
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
        selectedID = nil
        selectedDrawingID = drawing.id
        refreshAfterEdit()
    }

    private func editAnnotation(_ edited: DrawingAnnotation) {
        guard !isExporting, let index = annotations.firstIndex(where: { $0.id == edited.id }) else { return }
        let anchor = gestureStartTime.flatMap { time in
            gestureAnnotations?.first(where: { $0.id == edited.id }).map { (time: time, annotation: $0) }
        }
        let updated = annotations[index].applyingEdit(edited, time: editTime, recording: motionRecording, anchor: anchor)
        guard updated != annotations[index] else { return }
        if gestureSnapshot == nil { checkpoint() }
        annotations[index] = updated
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
        eraseItems(regions: scope == .drawings ? [] : Set(pairs.map(\.shape.id)),
                   drawings: scope == .regions ? [] : Set(annotations.map(\.id)))
    }

    @objc private func duplicateSelectedTapped() {
        guard !isExporting else { return }
        endGesture()
        let dx: CGFloat = 12, dy: CGFloat = -12
        func moved(_ r: CGRect) -> CGRect { r.offsetBy(dx: dx, dy: dy) }
        if let id = selectedDrawingID, let drawing = annotations.first(where: { $0.id == id }) {
            var copy = drawing
            copy.id = UUID()
            copy.points = drawing.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            copy.keyframes = drawing.keyframes.map { RegionKeyframe(time: $0.time, rect: moved($0.rect)) }
            checkpoint()
            annotations.append(copy)
            canvas.selectAnnotation(id: copy.id)
        } else if let id = selectedID, let pair = pairs.first(where: { $0.shape.id == id }) {
            let newID = UUID()
            let shape: RegionShape
            switch pair.shape {
            case .rectangle(_, let o, let size): shape = .rectangle(id: newID, origin: CGPoint(x: o.x + dx, y: o.y + dy), size: size)
            case .ellipse(_, let o, let size): shape = .ellipse(id: newID, origin: CGPoint(x: o.x + dx, y: o.y + dy), size: size)
            case .polygon(_, let points): shape = .polygon(id: newID, points: points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) })
            }
            var effect = pair.effect
            effect.keyframes = effect.keyframes.map { RegionKeyframe(time: $0.time, rect: moved($0.rect)) }
            checkpoint()
            pairs.append((shape, effect))
            canvas.selectRegion(id: newID)
        } else { NSSound.beep(); return }
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
        default: return false
        }
        return true
    }

    private func selectTool(_ index: Int) {
        guard !isExporting, toolSegment.selectedSegment != index else { return }
        toolSegment.selectedSegment = index
        toolChanged(toolSegment)
    }

    // MARK: - Selected item timing (region or drawing)

    private var hasSelection: Bool { selectedID != nil || selectedDrawingID != nil }

    private var selectedKeyframes: [RegionKeyframe] {
        if let id = selectedID, let pair = pairs.first(where: { $0.shape.id == id }) { return pair.effect.keyframes }
        if let id = selectedDrawingID, let drawing = annotations.first(where: { $0.id == id }) { return drawing.keyframes }
        return []
    }

    private func selectedMotionPath() -> [CGPoint] {
        guard doc.hasVideo else { return [] }
        return selectedKeyframes.map { CGPoint(x: $0.rect.midX, y: $0.rect.midY) }
    }

    private func setSelectedTimeRange(_ range: ClosedRange<Double>) {
        if selectedID != nil { updateSelectedEffect { $0.timeRange = range }; return }
        guard let id = selectedDrawingID, let index = annotations.firstIndex(where: { $0.id == id }),
              annotations[index].timeRange != range else { return }
        if gestureSnapshot == nil { checkpoint() }
        annotations[index].timeRange = range
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

    private func updateSelectedEffect(_ transform: (inout RegionEffect) -> Void) {
        guard let sel = selectedID,
              let idx = pairs.firstIndex(where: { $0.shape.id == sel }) else { return }
        guard !isExporting else { return }
        var eff = pairs[idx].effect
        transform(&eff)
        guard eff != pairs[idx].effect else { return }
        if gestureSnapshot == nil { checkpoint() }
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
        let canStep = doc.hasVideo && !isExporting && doc.videoFPS > 0
        previousFrameButton.isEnabled = canStep
        nextFrameButton.isEnabled = canStep
        rangeHint.textColor = .secondaryLabelColor
        mainContainer.slider.markers = doc.hasVideo ? selectedKeyframes.map(\.time) : []
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

    func load(url: URL) {
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
        doc.load(url: url)
    }

    private func documentLoaded() {
        guard doc.mediaKind != .none else {
            Self.dropLoadLog.notice("load-failed")
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
        if let id = selectedID, let row = pairs.firstIndex(where: { $0.shape.id == id }) {
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
            if let view = regionList.window?.contentView, let scroll = regionList.enclosingScrollView {
                let row = pairs.firstIndex(where: { $0.shape.id == id }) ?? -1
                if row >= 0 {
                    let rectInScroll = regionList.rect(ofRow: row)
                    let rectInWindow = scroll.convert(rectInScroll, to: nil)
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
        let duplicate = NSMenuItem(title: "복제", action: #selector(duplicateFromMenu(_:)), keyEquivalent: "")
        duplicate.target = self; duplicate.representedObject = id
        menu.addItem(duplicate)
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
            pairs[index].shape = RegionEditing.displayed(pairs[index], at: editTime)
            pairs[index].effect.keyframes = []
        } else if let index = annotations.firstIndex(where: { $0.id == id }) {
            checkpoint()
            annotations[index].points = annotations[index].displayed(at: editTime).points
            annotations[index].keyframes = []
        } else { return }
        refreshAfterEdit()
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
    func numberOfRows(in tableView: NSTableView) -> Int { pairs.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        // 매번 새 container 생성 (NSTableColumn이 있으므로 row가 그려짐)
        let container = NSView()
        container.wantsLayer = true
        let image = NSImageView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        container.addSubview(image)
        container.addSubview(text)
        image.translatesAutoresizingMaskIntoConstraints = false
        text.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            image.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 14),
            image.heightAnchor.constraint(equalToConstant: 14),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            text.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        let pair = pairs[row]
        let isActive = isEffectActive(pair.effect, at: canvas.currentVideoTime)
        let isSelected = selectedID == pair.shape.id
        // 선택된 행은 연한 파란 배경
        if isSelected {
            container.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.10).cgColor
        } else {
            container.layer?.backgroundColor = nil
        }
        switch pair.shape {
        case .rectangle:
            text.stringValue = "사각형"
            image.image = NSImage(systemSymbolName: "rectangle.fill", accessibilityDescription: "사각형")
            image.contentTintColor = isActive ? .systemBlue : .systemGray
        case .ellipse:
            text.stringValue = "원/타원"
            image.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "원형")
            image.contentTintColor = isActive ? .systemTeal : .systemGray
        case .polygon(_, let pts):
            text.stringValue = "자유형 (\(pts.count)점)"
            image.image = NSImage(systemSymbolName: "pentagon.fill", accessibilityDescription: "자유형")
            image.contentTintColor = isActive ? .systemPurple : .systemGray
        }
        switch pair.effect.style {
        case .blur: break
        case .mosaic: text.stringValue += " · 모자이크"
        case .solid: text.stringValue += " · 단색"
        }
        if !pair.effect.keyframes.isEmpty { text.stringValue += " · 이동" }
        let r = pair.effect.timeRange
        if r.lowerBound != 0 || r.upperBound != 0 {
            text.stringValue = (text.stringValue) + "  [\(format(r.lowerBound))~\(format(r.upperBound))]"
        }
        return container
    }

    private func isEffectActive(_ effect: RegionEffect, at time: Double) -> Bool {
        effect.isActive(at: time)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !refreshingList else { return }
        let row = regionList.selectedRow
        guard row >= 0, row < pairs.count else { return }
        let id = pairs[row].shape.id
        selectedID = id
        canvas.selectRegion(id: id)
        canvas.refreshOverlay()
        refreshSelectedEditor()
        // 사이드바 선택이 캔버스 영역 외곽선도 강조
        canvas.liveBlurRefreshCallback?()
        liveBlur.refresh()
    }

    /// 사이드바 행 우클릭 — 영역 우클릭과 동일한 메뉴
    func tableView(_ tableView: NSTableView, menuFor event: NSEvent) -> NSMenu? {
        let pt = event.locationInWindow
        // 행 찾기
        let row = tableView.row(at: tableView.convert(pt, from: nil))
        if row >= 0, row < pairs.count {
            let id = pairs[row].shape.id
            selectedID = id
            canvas.selectRegion(id: id)
            canvas.refreshOverlay()
            refreshSelectedEditor()
            tableView.reloadData()
            // 동일 메뉴 표시 (우상단 점)
            let dummyPt = NSPoint(x: 0, y: 0)
            showRegionContextMenu(for: id, at: dummyPt, fromList: true)
            return nil  // showRegionContextMenu가 popUp으로 처리
        }
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
