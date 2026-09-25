import AppKit

/// 우측 사이드바 컨트롤러.
final class SidebarViewController: NSViewController {
    private let stack: NSStackView
    private let fileTitle: NSTextField, fileLabel: NSTextField
    private let effectTitle: NSTextField
    private let blurSlider: NSSlider, blurValueLabel: NSTextField
    private let featherTitle: NSTextField, featherSlider: NSSlider, featherValueLabel: NSTextField
    private let modeSegment: NSSegmentedControl
    private let regionTitle: NSTextField
    private let regionScroll: NSScrollView, regionList: NSTableView
    private let timeRangeTitle: NSTextField
    private let timeStartField: NSTextField, timeEndField: NSTextField, timeApplyAllButton: NSButton
    private let qualityTitle: NSTextField, qualityPopup: NSPopUpButton
    private let exportButton: NSButton, cancelButton: NSButton
    private let progressIndicator: NSProgressIndicator
    private let progressLabel: NSTextField

    init(stack: NSStackView,
         fileTitle: NSTextField, fileLabel: NSTextField,
         effectTitle: NSTextField, blurSlider: NSSlider, blurValueLabel: NSTextField,
         featherTitle: NSTextField, featherSlider: NSSlider, featherValueLabel: NSTextField,
         modeSegment: NSSegmentedControl,
         regionTitle: NSTextField, regionScroll: NSScrollView, regionList: NSTableView,
         timeRangeTitle: NSTextField, timeStartField: NSTextField, timeEndField: NSTextField, timeApplyAllButton: NSButton,
         qualityTitle: NSTextField, qualityPopup: NSPopUpButton,
         exportButton: NSButton, cancelButton: NSButton, progressIndicator: NSProgressIndicator, progressLabel: NSTextField) {
        self.stack = stack
        self.fileTitle = fileTitle
        self.fileLabel = fileLabel
        self.effectTitle = effectTitle
        self.blurSlider = blurSlider
        self.blurValueLabel = blurValueLabel
        self.featherTitle = featherTitle
        self.featherSlider = featherSlider
        self.featherValueLabel = featherValueLabel
        self.modeSegment = modeSegment
        self.regionTitle = regionTitle
        self.regionScroll = regionScroll
        self.regionList = regionList
        self.timeRangeTitle = timeRangeTitle
        self.timeStartField = timeStartField
        self.timeEndField = timeEndField
        self.timeApplyAllButton = timeApplyAllButton
        self.qualityTitle = qualityTitle
        self.qualityPopup = qualityPopup
        self.exportButton = exportButton
        self.cancelButton = cancelButton
        self.progressIndicator = progressIndicator
        self.progressLabel = progressLabel
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        for f in [fileTitle, effectTitle, featherTitle, regionTitle, timeRangeTitle, qualityTitle] {
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
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        progressLabel.textColor = .secondaryLabelColor

        let blurRow = NSStackView(views: [blurSlider, blurValueLabel])
        blurRow.orientation = .horizontal
        blurRow.alignment = .centerY
        blurRow.spacing = 8
        let featherRow = NSStackView(views: [featherSlider, featherValueLabel])
        featherRow.orientation = .horizontal
        featherRow.alignment = .centerY
        featherRow.spacing = 8

        let timeRow = NSStackView(views: [timeStartField, NSTextField(labelWithString: "~"), timeEndField, timeApplyAllButton])
        timeRow.orientation = .horizontal
        timeRow.alignment = .centerY
        timeRow.spacing = 6
        for f in [timeStartField, timeEndField] {
            f.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        }
        timeStartField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        timeEndField.widthAnchor.constraint(equalToConstant: 60).isActive = true

        let scrollContainer = NSView()
        scrollContainer.addSubview(regionScroll)
        regionScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            regionScroll.topAnchor.constraint(equalTo: scrollContainer.topAnchor),
            regionScroll.bottomAnchor.constraint(equalTo: scrollContainer.bottomAnchor),
            regionScroll.leadingAnchor.constraint(equalTo: scrollContainer.leadingAnchor),
            regionScroll.trailingAnchor.constraint(equalTo: scrollContainer.trailingAnchor),
            scrollContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])

        let buttonRow = NSStackView(views: [exportButton, cancelButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        exportButton.bezelStyle = .rounded
        cancelButton.bezelStyle = .rounded
        exportButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        cancelButton.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let qualityRow = NSStackView(views: [qualityPopup])
        qualityRow.orientation = .horizontal
        qualityPopup.translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        for v in [fileTitle, fileLabel, effectTitle, blurRow, featherTitle, featherRow, modeSegment, regionTitle, scrollContainer, timeRangeTitle, timeRow, qualityTitle, qualityRow, buttonRow, progressIndicator, progressLabel] {
            stack.addArrangedSubview(v)
        }

        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollContainer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24)
        ])

        self.view = root
    }
}