import AppKit
import AVKit
import AVFoundation
import UniformTypeIdentifiers
import os
import Darwin

final class PageExportCancellation: @unchecked Sendable {
    let lock = NSLock()
    var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// 메인 윈도우 컨트롤러.
///
/// 구조 단순화: NSSplitViewController 없이 NSStackView(Horizontal) + NSDivider로 직접 layout.
final class MainWindowController: NSWindowController {
    static let dropLoadLog = Logger(subsystem: "local.piman.BlurAction", category: "Drop")

    // 컨테이너 뷰
    private let rootStack = NSStackView()
    let sidebarStack = NSStackView()
    let sidebarHeader = NSStackView()
    let sidebarScroll = NSScrollView()
    let taskPanelSelector = NSSegmentedControl(labels: ["찾기", "선택한 영역", "확인"], trackingMode: .selectOne, target: nil, action: nil)
    let findPanel = NSStackView()
    let selectedPanel = NSStackView()
    let reviewPanel = NSStackView()
    let decorationTools = NSStackView()
    let automaticCoverTools = NSStackView()
    let safetyMarginSlider = EditingSlider()
    let safetyMarginValue = NSTextField(labelWithString: "8px")
    let generousCoverButton = NSButton(title: "넉넉하게 가리기", target: nil, action: nil)
    let recommendedCoverButton = NSButton(title: "추천 설정", target: nil, action: nil)
    let automaticCoverHint = NSTextField(wrappingLabelWithString: "검출한 대상에 맞춰 가림을 조절합니다.")
    let reviewTools = NSStackView()
    let pinnedLayers = NSStackView()
    let outputArea = NSStackView()
    let emptyLayersHint = NSTextField(wrappingLabelWithString: "아직 영역이 없습니다.\n찾기 또는 직접 그리기로 추가하세요.")
    let selectedTitle = NSTextField(labelWithString: "가림 설정")
    let selectedHint = NSTextField(wrappingLabelWithString: "영역을 선택하면 해당 설정을 조절할 수 있습니다.")
    let staticReviewHint = NSTextField(wrappingLabelWithString: "전체 이미지·페이지를 확대해 가린 결과를 확인하세요. 레이어에서 숨김·잠금을 조절할 수 있습니다.")
    var advancedSettings: InspectorSection?
    var outputSettings: InspectorSection?
    var blurRow: NSStackView!
    var featherRow: NSStackView!
    var inspectorConfigured = false
    enum InspectorPanel: Int { case find, selected, review }
    private let timelineHost = NSView()

    // 메인 영역 (비디오 + 캔버스 + 블러)
    var mainContainer: MainContainerViewController!
    var canvas: VideoCanvasView!
    var liveBlur: LiveBlurCompositor!

    // 사이드바 컨트롤
    let fileTitle = NSTextField(labelWithString: "파일")
    let fileLabel = NSTextField(labelWithString: "—")
    let sourceInfoLabel = NSTextField(wrappingLabelWithString: "파일을 열면 원본 정보가 표시됩니다.")
    let copyToAllPagesButton = NSButton(title: "현재 페이지 작업을 모든 페이지에 적용…", target: nil, action: nil)
    let workflowHint = NSTextField(wrappingLabelWithString: "① 파일 열기·드롭  ② 영역 그리기  ③ 조정  ④ 내보내기")
    let effectTitle = NSTextField(labelWithString: "블러 강도")
    let blurSlider = EditingSlider()
    let blurValueLabel = NSTextField(labelWithString: "25px")
    let featherTitle = NSTextField(labelWithString: "경계 부드럽게")
    let featherSlider = EditingSlider()
    let featherValueLabel = NSTextField(labelWithString: "12px")
    let toolSegment = NSSegmentedControl(labels: ["블러", "그리기", "지우개"], trackingMode: .selectOne, target: nil, action: nil)
    let modeSegment = NSSegmentedControl(labels: ["사각형", "원", "점찍기", "자유"], trackingMode: .selectOne, target: nil, action: nil)
    let annotationColorPopup = NSPopUpButton()
    let annotationWidthTitle = NSTextField(labelWithString: "선 굵기")
    let annotationWidthSlider = EditingSlider()
    let annotationHint = NSTextField(wrappingLabelWithString: "그린 선을 클릭하면 선택되고, 끌어서 옮기거나 모서리로 크기를 바꿉니다. Delete·더블클릭으로 지웁니다. 영상에서는 그린 시점부터 표시됩니다.")
    let annotationColorWell = NSColorWell()
    let annotationPickButton = NSButton(title: "스포이드", target: nil, action: nil)
    let annotationFillPopup = NSPopUpButton()
    let coverTitle = NSTextField(labelWithString: "가리기 방식")
    let coverSegment = NSSegmentedControl(labels: ["블러", "모자이크", "단색"], trackingMode: .selectOne, target: nil, action: nil)
    let coverColorWell = NSColorWell()
    let coverPickButton = NSButton(title: "스포이드", target: nil, action: nil)
    let coverColorRow = NSStackView()
    let eraserTools = NSStackView()
    let eraserModeSegment = NSSegmentedControl(labels: ["부분 지우개", "항목 지우개"], trackingMode: .selectOne, target: nil, action: nil)
    let eraserTargetPopup = NSPopUpButton()
    let eraserSizeSlider = NSSlider(value: 24, minValue: 4, maxValue: 120, target: nil, action: nil)
    let eraserSizeLabel = NSTextField(labelWithString: "크기 24pt")
    let eraseFromNowCheckbox = NSButton(checkboxWithTitle: "영상: 지금 시점부터 지우기", target: nil, action: nil)
    let eraserHint = NSTextField(wrappingLabelWithString: "")
    let arrangeTools = NSStackView()
    let textTools = NSStackView()
    let textFontPopup = NSPopUpButton()
    let textBoldCheckbox = NSButton(checkboxWithTitle: "굵게", target: nil, action: nil)
    let textBackgroundPopup = NSPopUpButton()
    /// Extra items picked with Shift-click for grouping (may mix regions and drawings).
    /// Several picked items (group, delete, track together). Readable for tests.
    var multiSelection: [UUID] = []
    var eraseFromNow = true
    /// A project waiting for its media to finish loading before its items are applied.
    var pendingProject: ProjectFile?
    var pendingVideoProject: VideoProjectFile?
    var pendingTemplate = false
    var videoProjectBaseline: VideoProjectFile?
    var videoProjectNativeBaseline: ProjectFile?
    var projectSaveTask: Task<Void, Never>?
    var projectImportID: UUID?
    private var imageExportID: UUID?
    var pendingDocument: DocumentModel?
    var pendingWorkspace: PageWorkspace?
    var pendingWorkspaceNavigation = false
    var pendingProgressText = ""
    let videoLoader: DocumentModel.VideoLoader?
    /// Tests capture load failures without presenting an OS sheet.
    private let loadErrorPresenter: ((String) -> Void)?
    let beforeMediaLoad: ((URL) -> Void)?
    let trackMotionCheckbox = NSButton(checkboxWithTitle: "움직임 기록", target: nil, action: nil)
    let trackMotionHint = NSTextField(wrappingLabelWithString: "켜면 옮긴 시점의 위치가 기록되어 영역·그림이 움직임을 따라갑니다. 재생 중 끌어도, 멈춘 채 프레임을 넘기며 옮겨도 됩니다. 끄면 기록된 경로 전체가 함께 옮겨집니다.")
    let motionTools = NSStackView()
    let autoTrackButton = NSButton(title: "선택 항목 자동 추적", target: nil, action: nil)
    let trackDirectionPopup = NSPopUpButton()
    let smoothTrackingCheckbox = NSButton(checkboxWithTitle: "흔들림 줄이기", target: nil, action: nil)
    let reacquireFacesCheckbox = NSButton(checkboxWithTitle: "놓친 얼굴 다시 찾기", target: nil, action: nil)
    let findTools = NSStackView()
    let findFacesButton = NSButton(title: "얼굴 찾기", target: nil, action: nil)
    let findTextButton = NSButton(title: "글자 찾기", target: nil, action: nil)
    let trackAfterFindCheckbox = NSButton(checkboxWithTitle: "영상: 찾은 뒤 앞뒤로 자동 추적", target: nil, action: nil)
    let selectFoundButton = NSButton(title: "찾은 것 고르기", target: nil, action: nil)
    let deleteFoundButton = NSButton(title: "찾은 것 지우기", target: nil, action: nil)
    /// Running finds, the latest find's areas and the detectors (see `+Finding`).
    let finding = FindCoordinator()
    let pickHiddenCheckbox = NSButton(checkboxWithTitle: "숨긴 블러 영역도 캔버스에서 고르기", target: nil, action: nil)
    let phraseField = NSTextField()
    let phraseButton = NSButton(title: "문구 찾아 가리기", target: nil, action: nil)
    let decorationField = NSTextField()
    let decorationScale = NSSlider(value: 80, minValue: 20, maxValue: 100, target: nil, action: nil)
    let decorationApply = NSButton(title: "붙이기", target: nil, action: nil)
    let decorationRemove = NSButton(title: "내용 없애기", target: nil, action: nil)
    let decorationColor = NSColorWell()
    let decorationHint = NSTextField(wrappingLabelWithString: "가림 영역을 고르면 글자·이모지를 붙일 수 있습니다.")
    let reviewPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let reviewGo = NSButton(title: "해당 구간으로", target: nil, action: nil)
    let reviewRetry = NSButton(title: "이 구간 다시 추적", target: nil, action: nil)
    let reviewHold = NSButton(title: "현재 위치로 구간 보정", target: nil, action: nil)
    let reviewHint = NSTextField(wrappingLabelWithString: "추적 후 확인할 구간을 여기에 표시합니다.")
    var decorationSelection: UUID?
    var decorationDisplayed: CoverDecoration?
    var reviewSelection: (region: UUID, review: UUID)?
    let personButton = NSButton(title: "사람 고르기 (역가림)", target: nil, action: nil)
    private var windowCloseObserver: NSObjectProtocol?
    /// The running automatic tracking and the tracker (see `+Tracking`).
    let tracking = TrackingCoordinator()
    var annotationColorRow: NSStackView?
    let regionTitle = NSTextField(labelWithString: "레이어 (위가 앞)")
    let regionScroll = NSScrollView()
    let regionList = RegionTableView()
    let timeRangeEditor = NSStackView()
    let rangeStart = NSTextField(string: "0")
    let rangeEnd = NSTextField(string: "0")
    let rangeApply = NSButton(title: "구간 적용", target: nil, action: nil)
    let rangeEntire = NSButton(title: "영상 전체", target: nil, action: nil)
    let rangeHint = NSTextField(wrappingLabelWithString: "영역을 선택한 뒤 시간을 지정하세요.")
    let preciseTools = NSStackView()
    let frameRow = NSStackView()
    let previousFrameButton = NSButton(title: "◀ 약 1프레임", target: nil, action: nil)
    let nextFrameButton = NSButton(title: "약 1프레임 ▶", target: nil, action: nil)
    let recordPositionButton = NSButton(title: "현재 위치 기록", target: nil, action: nil)
    let previousKeyButton = NSButton(title: "◀ 이전 기록", target: nil, action: nil)
    let nextKeyButton = NSButton(title: "다음 기록 ▶", target: nil, action: nil)
    let positionX = NSTextField(string: "0")
    let positionY = NSTextField(string: "0")
    let positionWidth = NSTextField(string: "0")
    let positionHeight = NSTextField(string: "0")
    let applyPositionButton = NSButton(title: "좌표·크기 적용", target: nil, action: nil)
    let qualityTitle = NSTextField(labelWithString: "내보내기 화질")
    let qualityPopup = NSPopUpButton()
    let qualityInfoLabel = NSTextField(wrappingLabelWithString: "파일을 열면 출력 사양이 표시됩니다.")
    let exportButton = NSButton(title: "내보내기", target: nil, action: nil)
    let cancelButton = NSButton(title: "취소", target: nil, action: nil)
    let progressIndicator = NSProgressIndicator()
    let progressLabel = NSTextField(labelWithString: "")

    // 데이터
    var doc: DocumentModel
    var pageWorkspace: PageWorkspace?
    var workspaceWindowFitted = false
    var pairs: [(shape: RegionShape, effect: RegionEffect)] = []
    typealias EditorSnapshot = EditHistory.Snapshot
    var annotations: [DrawingAnnotation] = []
    /// Undo/redo steps and the mouse gesture in progress.
    var history = EditHistory()
    var gestureSnapshot: [RegionEditing.Pair]? { history.gestureSnapshot }
    var gestureAnnotations: [DrawingAnnotation]? { history.gestureAnnotations }
    var gestureStartTime: Double? { history.gestureStartTime }
    var selectedID: UUID? = nil
    /// Selected drawing (mutually exclusive with `selectedID`).
    var selectedDrawingID: UUID?
    /// Motion recording switch: edits on video become positions at the edit time.
    var trackMotion = true
    var motionRecording: Bool { trackMotion && doc.hasVideo }
    var defaultCoverStyle: RegionEffect.CoverStyle = .blur
    /// Editing is locked while exporting, tracking or finding. Readable for tests.
    private(set) var isExporting = false
    var refreshingList = false
    var endObserver: NSObjectProtocol?
    let imageFormatPopup = NSPopUpButton()
    var quality: QualityPreset = .high
    var canvasMode: VideoCanvasView.Mode = .rectangle
    var lastListReloadQuantized: Int = -1
    var lastTimedLayerActivity: [Bool] = []

    let exporter = BlurredVideoExporter()
    var pageExportCancellation: PageExportCancellation?
    var timeObserver: Any?
    var playerItemStatusObserver: NSKeyValueObservation?
    var player: AVPlayer!
    var playAfterSeek = false
    lazy var seekCoordinator = SeekCoordinator { [weak self] seconds, completion in
        guard let self, self.player.currentItem != nil,
              let target = LiveBlurCompositor.preciseTime(seconds: seconds) else { completion(false); return }
        self.liveBlur.currentTime = seconds
        self.liveBlur.invalidateFrame()
        self.synchronizeCanvasTime(fallback: seconds)
        self.player.seek(to: target,
                         toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            DispatchQueue.main.async { completion(finished) }
        }
    }
    /// 영역 이동 시 키프레임 자동 기록 모드 (▶ 누르면 true, ⏸ 누르면 false).
    /// - true: 영역 drag 중 30Hz로 키프레임 자동 추가 → 시간대별 블러 영역 추적.
    /// - false: 키프레임 추가 안 함 (기존 동작).
    var recordingKeyframes: Bool = false

    init(videoLoader: DocumentModel.VideoLoader? = nil, loadErrorPresenter: ((String) -> Void)? = nil,
         beforeMediaLoad: ((URL) -> Void)? = nil) {
        self.videoLoader = videoLoader
        self.loadErrorPresenter = loadErrorPresenter
        self.beforeMediaLoad = beforeMediaLoad
        doc = DocumentModel(videoLoader: videoLoader)
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
        // Closing the window stops a running tracking task instead of letting it finish unseen.
        windowCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                                     object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.trackingCancellation?.cancel()
                self?.finding.cancelAll()
            }
        }
        window.setContentSize(NSSize(width: 1180, height: 700))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        playerItemStatusObserver?.invalidate()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
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
        mainContainer.previousPageButton.target = self
        mainContainer.previousPageButton.action = #selector(previousPageTapped)
        mainContainer.nextPageButton.target = self
        mainContainer.nextPageButton.action = #selector(nextPageTapped)
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
        let sidebarView = InspectorBackgroundView()
        sidebarView.wantsLayer = true
        sidebarView.backgroundColor = .controlBackgroundColor
        sidebarView.translatesAutoresizingMaskIntoConstraints = false

        sidebarStack.translatesAutoresizingMaskIntoConstraints = false
        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .leading
        sidebarStack.spacing = 14
        sidebarStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
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
        sidebarView.addSubview(taskPanelSelector)
        sidebarView.addSubview(sidebarScroll)
        sidebarView.addSubview(pinnedLayers)
        sidebarView.addSubview(outputArea)
        for stack in [pinnedLayers, outputArea] {
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        }
        taskPanelSelector.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sidebarHeader.topAnchor.constraint(equalTo: sidebarView.topAnchor),
            sidebarHeader.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor),
            sidebarHeader.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            sidebarScroll.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor),
            sidebarScroll.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            taskPanelSelector.topAnchor.constraint(equalTo: sidebarHeader.bottomAnchor, constant: 4),
            taskPanelSelector.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor, constant: 12),
            taskPanelSelector.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor, constant: -12),
            sidebarScroll.topAnchor.constraint(equalTo: taskPanelSelector.bottomAnchor, constant: 6),
            sidebarScroll.bottomAnchor.constraint(equalTo: pinnedLayers.topAnchor),
            sidebarScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            pinnedLayers.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor),
            pinnedLayers.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            pinnedLayers.bottomAnchor.constraint(equalTo: outputArea.topAnchor),
            outputArea.leadingAnchor.constraint(equalTo: sidebarView.leadingAnchor),
            outputArea.trailingAnchor.constraint(equalTo: sidebarView.trailingAnchor),
            outputArea.bottomAnchor.constraint(equalTo: sidebarView.bottomAnchor),
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

        sidebarView.widthAnchor.constraint(equalToConstant: MainContainerViewController.sidebarWidth).isActive = true
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true

        NSLayoutConstraint.activate([
            sidebarView.topAnchor.constraint(equalTo: mainView.topAnchor),
            sidebarView.bottomAnchor.constraint(equalTo: mainView.bottomAnchor),
            sidebarView.trailingAnchor.constraint(equalTo: mainView.trailingAnchor),

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
        canvas.isLocked = { [weak self] id in
            guard let self else { return false }
            let state = self.layerState(id)
            return state.locked || (state.hidden && self.pickHiddenCheckbox.state != .on)
        }
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
                self.showSelectionInspector(drawing: true)
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
            result = self.preservingReviewExterior(result, before: self.pairs)
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
            self.history.rescale(from: old, to: new)
            if var baseline = self.videoProjectNativeBaseline {
                baseline.regions = RegionEditing.scaled(baseline.regions.map { ($0.shape, $0.effect) }, from: old, to: new)
                    .map { ProjectFile.Region(shape: $0.shape, effect: $0.effect) }
                baseline.drawings = baseline.drawings.map { $0.scaled(from: old, to: new) }
                self.videoProjectNativeBaseline = baseline
            }
        }
        canvas.modeBinding = { [weak self] in self?.canvasMode ?? .rectangle }
        canvas.modeUpdate = { [weak self] m in self?.canvasMode = m }
        canvas.viewSizeBinding = { [weak self] in self?.canvas.bounds.size ?? .zero }
        canvas.videoSizeBinding = { [weak self] in self?.doc.appliedVideoSize ?? .zero }
        canvas.isVideoBinding = { [weak self] in self?.doc.hasVideo ?? false }
        // LiveBlurCompositor already paints saved drawings over the source frame.
        canvas.drawsSavedAnnotations = false
        canvas.canLoadFilesBinding = { [weak self] in self?.canLoadFiles ?? false }
        canvas.addRegionHandler = { [weak self] in self?.addRegion() }
        canvas.playPauseHandler = { [weak self] in self?.togglePlay() }
        canvas.deleteSelectedHandler = { [weak self] in self?.deleteSelected() }
        canvas.selectionChange = { [weak self] id in
            if let id, self?.multiSelection.contains(id) == false { self?.multiSelection.removeAll() }
            if id != nil { self?.selectedDrawingID = nil }
            self?.selectedID = id
            if id != nil { self?.showSelectionInspector(drawing: false) }
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
        canvas.currentTimeProvider = { [weak self] in self?.editTime ?? self?.canvas.currentVideoTime ?? 0 }
        canvas.creationTimeProvider = { [weak self] in self?.playheadTime }
        canvas.emptyHint = "영상이나 이미지를 끌어다 놓거나 ⌘O로 여세요"
        canvas.hostContainer = mainContainer.aspectFitVideo
        canvas.onFileLoad = { [weak self] url in self?.load(url: url) }
        canvas.onFilesLoad = { [weak self] urls in self?.load(urls: urls) }
        canvas.liveBlurRefreshCallback = { [weak self] in self?.liveBlur.refresh() }
        liveBlur.regionsProvider = { [weak self] in self?.pairs ?? [] }
        liveBlur.annotationsProvider = { [weak self] in self?.annotations ?? [] }
        liveBlur.onPresentedFrameTime = { [weak self] _ in
            guard let self, self.doc.hasVideo else { return }
            // Contents/PTS are already committed. Update editing UI only; do not seek
            // or rerender from this callback, including when a held frame is repainted.
            self.synchronizeCanvasTime(fallback: self.liveBlur.currentTime)
        }
        liveBlur.videoSize = doc.appliedVideoSize
    }

    var presentedEditTime: Double? {
        guard doc.hasVideo, let time = liveBlur.presentedFrameTime, time.isNumeric,
              time.seconds.isFinite, time.seconds >= 0, time.seconds <= doc.duration else { return nil }
        return time.seconds
    }

    var editTime: Double? { doc.hasVideo ? (presentedEditTime ?? canvas.currentVideoTime) : nil }

    /// Edit the frame actually displayed. With no decoded frame (including injected
    /// loaders and a pending seek), retain the existing target/player-clock fallback.
    var playheadTime: Double? {
        guard doc.hasVideo else { return nil }
        if let presentedEditTime { return presentedEditTime }
        let time = seekCoordinator.suppressesTimeObserver ? canvas.currentVideoTime : player.currentTime().seconds
        return time.isFinite ? min(doc.duration, max(0, time)) : nil
    }

    private var currentSnapshot: EditorSnapshot { EditorSnapshot(pairs: pairs, annotations: annotations) }

    /// Continuous controls outside a mouse gesture (color panel drags) coalesce per item and key.
    func checkpoint(coalescing key: String? = nil) {
        history.checkpoint(currentSnapshot, coalescing: key)
    }

    func beginGesture() {
        guard !isExporting else { return }
        history.beginGesture(currentSnapshot, time: editTime)
    }

    func endGesture() {
        history.endGesture(current: currentSnapshot)
    }

    // MARK: - Actions

    @objc func openTapped() {
        guard !isExporting else { return }
        let panel = NSOpenPanel()
        // 비디오 + 이미지 확장자 (한 NSOpenPanel에서 자동 분기 — DocumentModel.load(url:)이 확장자로 판정)
        var types: [UTType] = [.movie, .quickTimeMovie, .mpeg4Movie, .video, .audiovisualContent]
        types.append(.image)
        types.append(.pdf)
        types.append(.jpeg)
        types.append(.png)
        if let heic = UTType("public.heic") { types.append(heic) }
        if let heif = UTType("public.heif") { types.append(heif) }
        if let webp = UTType("org.webmproject.webp") { types.append(webp) }
        types.append(.tiff)
        types.append(.bmp)
        if let gif = UTType("com.compuserve.gif") { types.append(gif) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { load(urls: panel.urls) }
    }

    @objc func addRegionTapped() { addRegion() }

    @objc func deleteSelectedTapped() { deleteSelected() }

    @objc func cancelTapped() {
        if let projectSaveTask { projectSaveTask.cancel() }
        else if pendingDocument != nil { cancelPendingMediaLoad() }
        else if let pageExportCancellation { pageExportCancellation.cancel() }
        else if let trackingCancellation { trackingCancellation.cancel() }
        else if let findTask { findTask.cancel() }
        else if let phraseTask { phraseTask.cancel() }
        else if let phraseTrackingCancellation { phraseTrackingCancellation.cancel(); phraseTrackingTask?.cancel() }
        else { exporter.cancel() }
    }
    func cancelCurrentOperation() { cancelTapped() }
    var projectSaveInProgress: Bool { projectSaveTask != nil }

    func setExporting(_ value: Bool) {
        isExporting = value
        canvas.isEditable = !value && doc.mediaKind != .none
        exportButton.isEnabled = !value && doc.mediaKind != .none && hasEffectiveEffect
        for control in [blurSlider, featherSlider, toolSegment, modeSegment, annotationColorPopup, annotationWidthSlider, qualityPopup, imageFormatPopup, eraserSizeSlider,
                        annotationColorWell, annotationPickButton, annotationFillPopup, coverSegment, coverColorWell, coverPickButton,
                        trackMotionCheckbox, eraserModeSegment, eraseFromNowCheckbox, eraserTargetPopup,
                        textFontPopup, textBoldCheckbox, textBackgroundPopup, trackDirectionPopup, smoothTrackingCheckbox,
                        reacquireFacesCheckbox, findFacesButton, findTextButton, trackAfterFindCheckbox, pickHiddenCheckbox,
                        selectFoundButton, deleteFoundButton, phraseButton, phraseField, personButton] as [NSControl] {
            control.isEnabled = !value
        }
        mainContainer.playPauseButton.isEnabled = !value && doc.hasVideo
        mainContainer.slider.isEnabled = !value && doc.hasVideo
        mainContainer.previousPageButton.isEnabled = !value && (pageWorkspace?.currentIndex ?? 0) > 0
        mainContainer.nextPageButton.isEnabled = !value && (pageWorkspace.map { $0.currentIndex + 1 < $0.pages.count } ?? false)
        copyToAllPagesButton.isEnabled = !value
        refreshEraserControls()
        for control in [rangeStart, rangeEnd, rangeApply, rangeEntire] as [NSControl] {
            control.isEnabled = !value && doc.hasVideo && hasSelection
        }
        refreshSelectedEditor()
    }

    func showError(_ text: String) {
        if let loadErrorPresenter { loadErrorPresenter(text); return }
        let alert = NSAlert()
        alert.messageText = "작업을 완료하지 못했습니다"
        alert.informativeText = text
        alert.addButton(withTitle: "확인")
        if let window { alert.beginSheetModal(for: window) }
    }

    func exportImage(cgImage: CGImage) {
        guard let original = doc.url else { return }
        let types: [UTType] = [.png, .jpeg, .heic, .tiff]
        let type = types[max(0, imageFormatPopup.indexOfSelectedItem)]
        let panel = ImageSavePanel.make(original: original, type: type)
        guard panel.runModal() == .OK, let output = panel.url else { return }
        let compression: Double
        switch quality { case .original: compression = 1; case .high: compression = 0.92; case .medium: compression = 0.75; case .low: compression = 0.5 }
        do { try exportImageSnapshot(cgImage: cgImage, to: output, type: type, compression: compression) }
        catch { showError(error.localizedDescription) }
    }

    /// Testable worker entrypoint; panels are only the outer destination chooser.
    /// No original decode/hash or CPU helper wait runs on the GUI thread.
    func exportImageSnapshot(cgImage: CGImage, to output: URL, type: UTType, compression: Double,
                             heicCPUHelper: HEICCPUEncoder.Helper? = nil,
                             completion: ((Result<URL, Error>) -> Void)? = nil) throws {
        guard !isExporting, let original = doc.url, let expected = doc.sourceSHA256 else {
            throw ProjectFile.ProjectError.invalidContent
        }
        try VideoProjectFile.requireAvailableFonts(annotations)
        let operating = doc, size = canvas.bounds.size
        let regions = pairs, drawings = annotations
        let id = UUID(); imageExportID = id
        let cancellation = PageExportCancellation(); pageExportCancellation = cancellation
        setExporting(true); progressIndicator.isIndeterminate = true
        progressIndicator.isHidden = false; cancelButton.isHidden = false
        progressLabel.stringValue = "이미지를 새 파일로 만드는 중…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<URL, Error> = Result {
                let captured = try VideoProjectSourceBinding.Source.capture(original) {
                    if cancellation.isCancelled { throw BlurredImageExporter.ExportError.cancelled }
                }
                guard captured.sha256 == expected else { throw PageWorkspace.WorkspaceError.sourceChanged }
                try BlurredImageExporter.export(source: cgImage, pairs: regions, canvasSize: size,
                    inputURL: original, outputURL: output, type: type, quality: compression,
                    annotations: drawings, expectedSourceSHA256: expected,
                    cancel: { cancellation.isCancelled }, heicCPUHelper: heicCPUHelper)
                return output
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.imageExportID == id, self.doc === operating else { return }
                self.imageExportID = nil; self.pageExportCancellation = nil
                self.progressIndicator.isHidden = true; self.progressIndicator.isIndeterminate = false
                self.cancelButton.isHidden = true; self.setExporting(false)
                if let completion { completion(result); return }
                switch result {
                case .success(let saved):
                    self.progressLabel.stringValue = "저장 완료: \(saved.lastPathComponent)"
                    let alert = NSAlert(); alert.messageText = "저장 완료"; alert.informativeText = saved.lastPathComponent
                    alert.addButton(withTitle: "확인"); alert.addButton(withTitle: "Finder에서 보기")
                    if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                case .failure(let error):
                    self.progressLabel.stringValue = ""
                    if cancellation.isCancelled { self.workflowHint.stringValue = "이미지 저장을 취소했습니다. 기존 작업은 유지됩니다." }
                    else { self.showError(error.localizedDescription) }
                }
            }
        }
    }

    @objc func undoTapped() {
        guard !isExporting else { return }
        endGesture()
        guard let prev = history.undo(current: currentSnapshot) else { BLog("[undo] stack empty"); return }
        BLog("[undo] restoring \(prev.pairs.count) regions from stack depth=\(history.undo.count)")
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

    @objc func redoTapped() {
        guard !isExporting else { return }
        endGesture()
        guard let next = history.redo(current: currentSnapshot) else { BLog("[redo] stack empty"); return }
        BLog("[redo] restoring \(next.pairs.count) regions from stack depth=\(history.redo.count)")
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

    func refreshRegionList() {
        guard !refreshingList else { return }
        refreshingList = true
        defer { refreshingList = false }
        regionList.reloadData()
        let rows = layerRows
        emptyLayersHint.isHidden = !rows.isEmpty
        if multiSelection.count > 1 {
            regionList.selectRowIndexes(IndexSet(multiSelection.compactMap { id in rows.firstIndex { $0.id == id } }), byExtendingSelection: false)
        } else if let id = currentSelectionID, let row = rows.firstIndex(where: { $0.id == id }) {
            regionList.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else { regionList.deselectAll(nil) }
        exportButton.isEnabled = !isExporting && doc.mediaKind != .none && hasEffectiveEffect
    }

    let unitPageSize = CGSize(width: 1, height: 1)

}

