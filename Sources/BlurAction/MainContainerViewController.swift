import AppKit
import AVKit

/// 좌측 메인 영역. NSViewController 기반 — contentViewController로 직접 호스팅.
final class MainContainerViewController: NSViewController {
    let videoContainer = NSView()
    let aspectFitVideo = NSView()
    let playerLayer = AVPlayerLayer()
    let liveBlur: LiveBlurCompositor
    let canvas: VideoCanvasView

    let controlsView = NSView()
    let playPauseButton = NSButton(title: "▶", target: nil, action: nil)
    let timeLabel = NSTextField(labelWithString: "00:00.00 / 00:00.00")
    let slider = TrackingSlider()

    var mediaSize: CGSize = .zero {
        didSet { if isViewLoaded { view.needsLayout = true } }
    }
    var canvasSizeChanged: ((CGSize, CGSize) -> Void)?

    init(canvas: VideoCanvasView, liveBlur: LiveBlurCompositor) {
        self.canvas = canvas
        self.liveBlur = liveBlur
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1180, height: 700))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        // Let NSWindow size its content view. An autoresizing-mask constraint here
        // pins the initial dimensions and silently undoes subsequent window resizing.
        root.autoresizingMask = [.width, .height]
        root.translatesAutoresizingMaskIntoConstraints = false

        videoContainer.wantsLayer = true
        videoContainer.layer?.backgroundColor = NSColor.black.cgColor
        videoContainer.translatesAutoresizingMaskIntoConstraints = false

        aspectFitVideo.wantsLayer = true
        aspectFitVideo.layer?.backgroundColor = NSColor.black.cgColor
        aspectFitVideo.translatesAutoresizingMaskIntoConstraints = true

        // playerLayer: 비디오 직접 렌더링 (liveBlur보다 아래)
        playerLayer.videoGravity = .resizeAspect
        aspectFitVideo.layer?.addSublayer(playerLayer)
        playerLayer.zPosition = 0

        // liveBlur: playerLayer와 같은 frame, 위에 덮음
        aspectFitVideo.layer?.addSublayer(liveBlur)
        liveBlur.zPosition = 1

        // canvas: 영역 편집 오버레이 (마우스)
        canvas.translatesAutoresizingMaskIntoConstraints = true
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.clear.cgColor
        canvas.hostContainer = aspectFitVideo
        aspectFitVideo.addSubview(canvas)
        // 캔버스는 liveBlur 위에 와야 마우스 이벤트를 받음
        canvas.layer?.zPosition = 2

        videoContainer.addSubview(aspectFitVideo)
        root.addSubview(videoContainer)

        // 컨트롤 (타임라인)
        controlsView.wantsLayer = true
        controlsView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        controlsView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(controlsView)

        playPauseButton.bezelStyle = .rounded
        playPauseButton.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        slider.minValue = 0
        slider.maxValue = 1
        slider.isContinuous = true
        slider.isEnabled = false
        slider.identifier = NSUserInterfaceItemIdentifier("videoTimeline")
        slider.setAccessibilityLabel("영상 재생 위치")
        slider.setAccessibilityHelp("드래그하거나 방향키로 영상의 재생 위치를 이동합니다. 단위는 초입니다.")
        slider.toolTip = "영상 재생 위치 (초). 아래 띠의 주황 점(기록 위치)과 파란 끝(적용 구간)은 끌어서 옮깁니다."
        slider.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true

        let stack = NSStackView(views: [playPauseButton, timeLabel, slider])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        controlsView.addSubview(stack)

        NSLayoutConstraint.activate([
            videoContainer.topAnchor.constraint(equalTo: root.topAnchor),
            videoContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            videoContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -301),
            videoContainer.bottomAnchor.constraint(equalTo: controlsView.topAnchor),

            controlsView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            controlsView.trailingAnchor.constraint(equalTo: videoContainer.trailingAnchor),
            controlsView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            controlsView.heightAnchor.constraint(equalToConstant: 60),

            stack.leadingAnchor.constraint(equalTo: controlsView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: controlsView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: controlsView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: controlsView.bottomAnchor)
        ])

        self.view = root
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutMedia()
    }

    /// Media can change while the window stays the same size (notably on a drop).
    /// Updating these manual layer frames explicitly avoids waiting for a resize event.
    func refreshMediaLayout() {
        guard isViewLoaded else { return }
        view.layoutSubtreeIfNeeded()
        videoContainer.layoutSubtreeIfNeeded()
        layoutMedia()
    }

    private func layoutMedia() {
        updateAspectFitConstraints()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = aspectFitVideo.bounds
        liveBlur.frame = aspectFitVideo.bounds
        // canvas의 frame을 aspectFitVideo와 정확히 일치 — 짤림 방지.
        // (canvas는 Auto Layout 제약 없으므로 layoutSubtreeIfNeeded 후 frame이 300×200 default일 수 있음)
        let oldSize = canvas.bounds.size
        canvas.frame = aspectFitVideo.bounds
        if oldSize != canvas.bounds.size { canvasSizeChanged?(oldSize, canvas.bounds.size) }
        CATransaction.commit()
        // 캔버스 좌표 = aspectFitVideo.bounds와 동일
        canvas.displayRect = NSRect(origin: .zero, size: aspectFitVideo.bounds.size)
        liveBlur.videoDisplayRect = canvas.displayRect
        // layout 변경 시마다 즉시 refresh — 이미지/비디오 frame이 새 size에 정확히 매핑.
        liveBlur.refresh()
        canvas.refreshOverlay()
        BLog("[layout] videoContainer=\(videoContainer.frame) aspectFit=\(aspectFitVideo.frame) canvas=\(canvas.frame)")
    }

    /// The editor covers only media pixels, never the letterbox bars.
    private func updateAspectFitConstraints() {
        let available = videoContainer.bounds
        guard available.width > 0, available.height > 0 else { return }
        let scale = mediaSize.width > 0 && mediaSize.height > 0
            ? min(available.width / mediaSize.width, available.height / mediaSize.height) : 0
        let size = scale > 0 ? CGSize(width: mediaSize.width * scale, height: mediaSize.height * scale) : available.size
        aspectFitVideo.frame = CGRect(x: available.midX - size.width / 2,
                                     y: available.midY - size.height / 2, width: size.width, height: size.height)
    }
}
