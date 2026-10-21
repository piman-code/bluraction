import AppKit
import AVKit
import AVFoundation
import UniformTypeIdentifiers
import os
import Darwin

// MainWindowController: 사이드바·도구막대·메뉴 구성.

extension MainWindowController {
    func configureSidebar() {
        taskPanelSelector.identifier = NSUserInterfaceItemIdentifier("taskPanelSelector")
        taskPanelSelector.setAccessibilityLabel("작업 패널")
        taskPanelSelector.selectedSegment = InspectorPanel.selected.rawValue
        taskPanelSelector.target = self
        taskPanelSelector.action = #selector(inspectorPanelChanged(_:))
        taskPanelSelector.segmentDistribution = .fillEqually
        for (panel, name) in [(findPanel, "findPanel"), (selectedPanel, "selectedPanel"), (reviewPanel, "reviewPanel"),
                              (decorationTools, "decorationTools"), (reviewTools, "reviewTools"),
                              (pinnedLayers, "pinnedLayers"), (outputArea, "outputArea")] {
            panel.identifier = NSUserInterfaceItemIdentifier(name)
            panel.orientation = .vertical
            panel.alignment = .leading
            panel.spacing = 12
        }
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
        annotationHint.font = .systemFont(ofSize: 12)
        annotationHint.textColor = .secondaryLabelColor
        annotationHint.preferredMaxLayoutWidth = 290
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
        trackMotionHint.font = .systemFont(ofSize: 12)
        trackMotionHint.textColor = .secondaryLabelColor
        trackMotionHint.preferredMaxLayoutWidth = 290
        motionTools.orientation = .vertical
        motionTools.alignment = .leading
        motionTools.spacing = 4
        autoTrackButton.bezelStyle = .rounded
        autoTrackButton.target = self
        autoTrackButton.action = #selector(autoTrackTapped)
        autoTrackButton.toolTip = "선택한 영역·그림 안의 대상을 지금부터 끝까지 자동으로 따라가며 위치를 기록합니다 (Vision). ⌘Z로 되돌립니다."
        trackDirectionPopup.addItems(withTitles: ["앞으로 추적", "뒤로 추적", "앞뒤로 추적"])
        trackDirectionPopup.toolTip = "지금부터 항목 끝까지(앞으로), 영상 처음 쪽으로(뒤로), 또는 양쪽으로 따라갑니다. 여러 항목을 고르면 함께 추적합니다."
        smoothTrackingCheckbox.state = .on
        smoothTrackingCheckbox.toolTip = "추적 위치의 잔떨림을 앞뒤 몇 프레임 평균으로 줄입니다. 가림은 그 프레임의 추적 위치를 항상 다 덮습니다."
        reacquireFacesCheckbox.state = .on
        reacquireFacesCheckbox.toolTip = "얼굴이 든 영역을 놓치면 1.5초 동안 그 근처에서 얼굴을 다시 찾아 이어서 따라갑니다. 크기가 크게 다르거나 다른 영역이 덮고 있거나 비슷한 거리에 얼굴이 여럿이면 고르지 않습니다. 번호판·글자 같은 다른 대상에는 쓰지 않습니다."
        let trackRow = NSStackView(views: [trackDirectionPopup, autoTrackButton])
        trackRow.spacing = 6
        autoTrackButton.title = "자동 추적"
        let trackOptions = NSStackView(views: [smoothTrackingCheckbox, reacquireFacesCheckbox])
        trackOptions.spacing = 8
        for view in [trackMotionCheckbox, trackMotionHint, trackRow, trackOptions] as [NSView] { motionTools.addArrangedSubview(view) }
        let findTitle = NSTextField(labelWithString: "자동 찾기")
        findTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        for (button, action, tip) in [(findFacesButton, #selector(findFacesTapped), "지금 화면에서 얼굴을 찾아 모두 가립니다 (Vision)."),
                                      (findTextButton, #selector(findTextTapped), "지금 화면에서 글자(번호판·명찰·간판 등)를 찾아 가립니다 (Vision).")] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
            button.toolTip = tip
        }
        trackAfterFindCheckbox.state = .on
        trackAfterFindCheckbox.toolTip = "영상에서 찾은 영역을 바로 앞뒤로 자동 추적해 움직임을 따라가게 합니다."
        let findHint = NSTextField(wrappingLabelWithString: "찾은 곳마다 새 영역이 생깁니다. 이미 가린 곳은 건너뛰고, 잘못 찾은 것은 지우면 됩니다.")
        findHint.font = .systemFont(ofSize: 12)
        findHint.textColor = .secondaryLabelColor
        findHint.preferredMaxLayoutWidth = 290
        let findRow = NSStackView(views: [findFacesButton, findTextButton])
        findRow.spacing = 6
        for (button, action, tip) in [(selectFoundButton, #selector(selectFoundTapped), "방금 찾은 영역들을 다시 함께 고릅니다(그룹·추적·삭제에 씀)."),
                                      (deleteFoundButton, #selector(deleteFoundTapped), "방금 찾은 영역들을 한꺼번에 지웁니다(잠긴 것은 남김, ⌘Z로 되돌림).")] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
            button.action = action
            button.toolTip = tip
        }
        let foundRow = NSStackView(views: [selectFoundButton, deleteFoundButton])
        foundRow.spacing = 6
        findTools.orientation = .vertical
        findTools.alignment = .leading
        findTools.spacing = 10
        phraseField.placeholderString = "가릴 문구 (쉼표로 여러 개)"
        phraseField.controlSize = .regular
        phraseField.toolTip = "화면에 나오는 이 글자를 읽어 그 자리를 가립니다. 두 글자 이상, 공백과 기호는 무시합니다."
        phraseField.widthAnchor.constraint(equalToConstant: 290).isActive = true
        phraseButton.bezelStyle = .rounded
        phraseButton.controlSize = .small
        phraseButton.target = self
        phraseButton.action = #selector(findPhrasesTapped)
        phraseButton.title = "문구 찾아 추적"
        phraseButton.toolTip = "문구를 읽고 그 줄을 추적합니다. 인식이 끊긴 구간은 확인 목록에 남깁니다."
        let phraseRow = NSStackView(views: [phraseField, phraseButton])
        phraseRow.orientation = .vertical
        phraseRow.alignment = .leading
        phraseRow.spacing = 6
        let phraseHint = NSTextField(wrappingLabelWithString: "입력한 문구가 포함된 줄을 찾아 추적합니다. 짧거나 흐린 글자는 놓칠 수 있어 결과를 확인하세요. 긴 영상은 실제 검사 간격을 표시합니다.")
        phraseHint.font = .systemFont(ofSize: 12)
        phraseHint.textColor = .secondaryLabelColor
        phraseHint.preferredMaxLayoutWidth = 290
        personButton.bezelStyle = .rounded
        personButton.controlSize = .small
        personButton.target = self
        personButton.action = #selector(pickPersonTapped)
        personButton.toolTip = "영상에서 남길 사람을 캔버스에서 클릭하면, 그 사람만 남기고 나머지 화면을 가립니다. 같은 사람을 자동 추적으로 따라갑니다."
        for view in [findTitle, findRow, foundRow, trackAfterFindCheckbox, findHint, inspectorDivider(), phraseRow, phraseHint, personButton] as [NSView] { findTools.addArrangedSubview(view) }
        configureCoverAttachments()
        pickHiddenCheckbox.state = .off
        pickHiddenCheckbox.target = self
        pickHiddenCheckbox.action = #selector(pickHiddenChanged(_:))
        pickHiddenCheckbox.toolTip = "끄면 숨긴 블러 영역은 캔버스에서 눌러도 잡히지 않습니다(레이어 목록에서는 고를 수 있음)."
        motionTools.isHidden = true
        eraserHint.font = .systemFont(ofSize: 12)
        eraserHint.textColor = .secondaryLabelColor
        eraserHint.preferredMaxLayoutWidth = 290
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
        arrangeTitle.font = .systemFont(ofSize: 14, weight: .semibold)
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
        arrangeHint.font = .systemFont(ofSize: 12)
        arrangeHint.textColor = .secondaryLabelColor
        arrangeHint.preferredMaxLayoutWidth = 290
        arrangeTools.orientation = .vertical
        arrangeTools.alignment = .leading
        arrangeTools.spacing = 6
        for view in [arrangeTitle, orderRow, groupRow, arrangeHint, pickHiddenCheckbox] as [NSView] { arrangeTools.addArrangedSubview(view) }
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
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = 290
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 290).isActive = true
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
        regionList.rowHeight = 44
        regionList.intercellSpacing = NSSize(width: 0, height: 4)
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
        regionList.allowsMultipleSelection = true
        regionList.registerForDraggedTypes([.blurActionLayerRow])
        regionList.setDraggingSourceOperationMask(.move, forLocal: true)
        regionList.addTableColumn(col)
        regionList.reloadData()
        regionScroll.documentView = regionList
        regionScroll.hasVerticalScroller = true
        regionScroll.autohidesScrollers = true
        regionScroll.borderType = .noBorder

        // 스타일
        for f in [fileTitle, coverTitle, effectTitle, featherTitle, regionTitle, qualityTitle] {
            f.font = .systemFont(ofSize: 14, weight: .semibold)
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
        blurRow = NSStackView(views: [blurSlider, blurValueLabel])
        blurRow.orientation = .horizontal; blurRow.alignment = .centerY; blurRow.spacing = 8
        featherRow = NSStackView(views: [featherSlider, featherValueLabel])
        featherRow.orientation = .horizontal; featherRow.alignment = .centerY; featherRow.spacing = 8

        let buttonRow = NSStackView(views: [exportButton, cancelButton])
        buttonRow.orientation = .horizontal; buttonRow.spacing = 8
        exportButton.bezelStyle = .rounded
        cancelButton.bezelStyle = .rounded

        let rangeTitle = NSTextField(labelWithString: "적용 시간 (초)")
        rangeTitle.font = .systemFont(ofSize: 14, weight: .semibold)
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
        rangeHint.font = .systemFont(ofSize: 12)
        rangeHint.textColor = .secondaryLabelColor
        rangeHint.preferredMaxLayoutWidth = 290
        rangeHint.widthAnchor.constraint(lessThanOrEqualToConstant: 290).isActive = true
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
        precisionTitle.font = .systemFont(ofSize: 14, weight: .semibold)
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
        coordinateHint.preferredMaxLayoutWidth = 290
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
        emptyLayersHint.identifier = NSUserInterfaceItemIdentifier("emptyLayersHint")
        emptyLayersHint.font = .systemFont(ofSize: 12)
        emptyLayersHint.textColor = .secondaryLabelColor
        emptyLayersHint.alignment = .center
        emptyLayersHint.translatesAutoresizingMaskIntoConstraints = false
        scrollContainer.addSubview(emptyLayersHint)
        NSLayoutConstraint.activate([
            regionScroll.topAnchor.constraint(equalTo: scrollContainer.topAnchor),
            regionScroll.bottomAnchor.constraint(equalTo: scrollContainer.bottomAnchor),
            regionScroll.leadingAnchor.constraint(equalTo: scrollContainer.leadingAnchor),
            regionScroll.trailingAnchor.constraint(equalTo: scrollContainer.trailingAnchor),
            scrollContainer.heightAnchor.constraint(equalToConstant: 90),
            emptyLayersHint.centerYAnchor.constraint(equalTo: scrollContainer.centerYAnchor),
            emptyLayersHint.leadingAnchor.constraint(equalTo: scrollContainer.leadingAnchor, constant: 8),
            emptyLayersHint.trailingAnchor.constraint(equalTo: scrollContainer.trailingAnchor, constant: -8)
        ])

        for v in [fileTitle, fileLabel, sourceInfoLabel, copyToAllPagesButton] { sidebarHeader.addArrangedSubview(v) }
        copyToAllPagesButton.target = self
        copyToAllPagesButton.action = #selector(copyCurrentPageToAll)
        copyToAllPagesButton.isHidden = true
        fileLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 290).isActive = true
        let annotationColorRow = NSStackView(views: [annotationColorWell, annotationPickButton, annotationColorPopup])
        annotationColorRow.spacing = 6
        annotationColorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        coverColorWell.widthAnchor.constraint(equalToConstant: 44).isActive = true
        self.annotationColorRow = annotationColorRow
        imageFormatPopup.addItems(withTitles: ["PNG", "JPEG", "HEIC", "TIFF"])
        imageFormatPopup.isHidden = true
        imageFormatPopup.toolTip = "이미지 저장 형식"
        selectedTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        for label in [selectedHint, staticReviewHint] {
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = 290
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 290).isActive = true
        }
        findPanel.addArrangedSubview(findTools)
        for view in [selectedTitle, selectedHint, modeSegment, annotationColorRow, annotationWidthTitle,
                     annotationWidthSlider, annotationFillPopup, textTools, annotationHint, eraserTools,
                     coverTitle, coverSegment, effectTitle, blurRow!, coverColorRow, automaticCoverTools, decorationTools] {
            selectedPanel.addArrangedSubview(view)
        }
        setupAutomaticCoverControls()
        let advanced = InspectorSection(title: "고급 설정", identifier: "advancedSettings",
            views: [featherTitle, featherRow, timeRangeEditor, motionTools, preciseTools, arrangeTools])
        advancedSettings = advanced
        selectedPanel.addArrangedSubview(advanced)
        reviewPanel.addArrangedSubview(reviewTools)
        reviewPanel.addArrangedSubview(staticReviewHint)
        for panel in [findPanel, selectedPanel, reviewPanel] {
            sidebarStack.addArrangedSubview(panel)
            panel.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor, constant: -24).isActive = true
        }
        for view in [regionTitle, scrollContainer] { pinnedLayers.addArrangedSubview(view) }
        scrollContainer.widthAnchor.constraint(equalTo: pinnedLayers.widthAnchor, constant: -24).isActive = true
        let output = InspectorSection(title: "출력 설정", identifier: "outputSettings",
            views: [qualityTitle, imageFormatPopup, qualityPopup, qualityInfoLabel])
        outputSettings = output
        selectedPanel.addArrangedSubview(output)
        let outputShortcut = NSButton(title: "출력 설정…", target: self, action: #selector(showOutputSettings))
        outputShortcut.identifier = NSUserInterfaceItemIdentifier("outputSettingsShortcut")
        outputShortcut.bezelStyle = .rounded
        outputShortcut.controlSize = .small
        let outputRow = NSStackView(views: [buttonRow, outputShortcut]); outputRow.spacing = 8
        for view in [outputRow, progressIndicator, progressLabel, workflowHint] { outputArea.addArrangedSubview(view) }
        toolSegment.setLabel("가리기", forSegment: 0)
        toolSegment.setAccessibilityLabel("편집 도구")
        mainContainer.editorToolBar.addArrangedSubview(toolSegment)
        applyInspectorPolish(outputShortcut: outputShortcut)
        inspectorConfigured = true
        showInspectorPanel(.selected)
        toolChanged(toolSegment)
        regionList.contextMenuHandler = { [weak self] event in
            guard let self else { return }
            _ = self.tableView(self.regionList, menuFor: event)
        }
        // qualityPopup 폭 채우기
        qualityPopup.translatesAutoresizingMaskIntoConstraints = false
        qualityPopup.widthAnchor.constraint(equalTo: output.content.widthAnchor).isActive = true
        for section in [advanced, output] {
            section.widthAnchor.constraint(equalTo: selectedPanel.widthAnchor).isActive = true
        }
    }

    /// Use the existing native controls with the prototype's readable scale and grouping.
    /// Only the scrolling inspector grows; the pinned layers and output stay compact.
    private func applyInspectorPolish(outputShortcut: NSButton) {
        func styleControls(in view: NSView) {
            if let button = view as? NSButton {
                button.font = .systemFont(ofSize: button.identifier?.rawValue.hasSuffix("SettingsToggle") == true ? 13 : 12)
            } else if let field = view as? NSTextField, field.isEditable {
                field.font = .systemFont(ofSize: 13)
            }
            for child in view.subviews { styleControls(in: child) }
        }
        for view in [sidebarHeader, sidebarStack, pinnedLayers, outputArea] { styleControls(in: view) }
        for segment in [taskPanelSelector, toolSegment, modeSegment, coverSegment, eraserModeSegment] {
            segment.controlSize = .regular
            segment.font = .systemFont(ofSize: 13, weight: .medium)
            segment.selectedSegmentBezelColor = .systemBlue
            segment.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        }
        for segment in [modeSegment, coverSegment, eraserModeSegment] {
            segment.segmentDistribution = .fillEqually
            segment.widthAnchor.constraint(equalTo: selectedPanel.widthAnchor).isActive = true
        }
        for button in [findFacesButton, findTextButton, phraseButton, personButton,
                       decorationApply, reviewGo, reviewRetry, reviewHold, exportButton, cancelButton] {
            button.controlSize = .regular
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        }
        phraseField.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        decorationField.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        fileLabel.font = .systemFont(ofSize: 13, weight: .medium)
        pinnedLayers.spacing = 6
        outputArea.spacing = 6
        outputShortcut.font = .systemFont(ofSize: 12)
        exportButton.bezelColor = .systemBlue
        exportButton.contentTintColor = .white
        regionScroll.drawsBackground = false
        regionList.backgroundColor = .clear
        for stack in [pinnedLayers, outputArea] {
            let line = inspectorDivider()
            stack.addSubview(line)
            NSLayoutConstraint.activate([
                line.topAnchor.constraint(equalTo: stack.topAnchor),
                line.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 12),
                line.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -12)
            ])
        }
    }

    func inspectorDivider() -> NSBox {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        line.widthAnchor.constraint(equalToConstant: MainContainerViewController.sidebarWidth - 24).isActive = true
        return line
    }

    @objc private func inspectorPanelChanged(_ sender: NSSegmentedControl) {
        showInspectorPanel(InspectorPanel(rawValue: sender.selectedSegment) ?? .selected)
    }

    func showInspectorPanel(_ panel: InspectorPanel) {
        guard inspectorConfigured else { return }
        taskPanelSelector.selectedSegment = panel.rawValue
        findPanel.isHidden = panel != .find
        selectedPanel.isHidden = panel != .selected
        reviewPanel.isHidden = panel != .review
        sidebarScroll.contentView.scroll(to: .zero)
        sidebarScroll.reflectScrolledClipView(sidebarScroll.contentView)
    }

    @objc private func showOutputSettings() {
        showInspectorPanel(.selected)
        outputSettings?.isExpanded = true
        sidebarStack.layoutSubtreeIfNeeded()
        outputSettings?.scrollToVisible(outputSettings?.bounds ?? .zero)
    }

    func configureToolbar() {
        let tb = NSToolbar(identifier: "MainToolbar")
        tb.displayMode = .iconAndLabel
        tb.delegate = self
        tb.allowsUserCustomization = false
        window?.toolbar = tb
    }

    func configureMenu() {
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
}
