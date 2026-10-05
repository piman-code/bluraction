import AppKit
import CoreImage
import CoreText
import CryptoKit
import Foundation
import Testing
@testable import BlurAction

/// Native font, renderer and controller objects only; no OS input or file-panel automation.
@Suite(.serialized)
@MainActor
struct FontCompatibilityTests {
    private let oldPresetFamilies: Set<String> = [
        "Apple SD Gothic Neo", "AppleMyungjo", "Helvetica Neue", "Georgia", "Menlo", "Noteworthy"
    ]

    private func installedNonPresetFamily() throws -> String {
        try #require(NSFontManager.shared.availableFontFamilies.sorted().first { family in
            !oldPresetFamilies.contains(family) && NSFontManager.shared.font(withFamily: family,
                traits: [], weight: 5, size: 20) != nil
        }, "This native host must supply an installed family outside the old six choices")
    }

    /// AppKit's documented native choices are the independent references, not the product resolver.
    private func nativeReference(_ name: String?, bold: Bool, size: CGFloat) throws -> NSFont {
        let weight: NSFont.Weight = bold ? .semibold : .regular
        switch (name ?? "").lowercased() {
        case "", "system", "sans serif", "sans-serif":
            return NSFont.systemFont(ofSize: size, weight: weight)
        case "monospace":
            return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        case "serif":
            let descriptor = try #require(NSFont.systemFont(ofSize: size, weight: weight)
                .fontDescriptor.withDesign(.serif))
            return try #require(NSFont(descriptor: descriptor, size: size))
        case "cursive", "fantasy":
            let families = name?.lowercased() == "cursive"
                ? ["Apple Chancery", "Snell Roundhand", "Zapfino"]
                : ["Papyrus", "Herculanum", "Copperplate"]
            for family in families {
                if let font = NSFontManager.shared.font(withFamily: family,
                    traits: bold ? .boldFontMask : [], weight: 5, size: size)
                    ?? NSFont(name: family, size: size) { return font }
            }
            throw FontReferenceError.noInstalledCategoryFamily
        default: throw FontReferenceError.unexpectedAlias
        }
    }

    private enum FontReferenceError: Error { case noInstalledCategoryFamily, unexpectedAlias }

    private func controls(_ session: ImageSession) throws -> (font: NSPopUpButton, bold: NSButton, background: NSPopUpButton) {
        let font = try #require(session.descendants.compactMap { $0 as? NSPopUpButton }
            .first { $0.itemTitles.first == "시스템 글꼴" })
        let bold = try #require(session.descendants.compactMap { $0 as? NSButton }.first { $0.title == "굵게" })
        let background = try #require(session.descendants.compactMap { $0 as? NSPopUpButton }
            .first { $0.itemTitles.contains("검정 배경") })
        return (font, bold, background)
    }

    private func storedDrawing(_ session: ImageSession, id: UUID) throws -> DrawingAnnotation {
        try #require(session.canvas.annotationsBinding?().first { $0.id == id })
    }

    private func send(_ control: NSControl) {
        _ = control.sendAction(control.action, to: control.target)
    }

    /// Draw the independently obtained native NSFont object directly. System design fonts may
    /// expose private PostScript names that cannot be recreated through NSFont(name:size:).
    private func nativeRaster(text: String, font: NSFont, source: CIImage, canvasSize: CGSize) throws -> CIImage {
        let context = try #require(CGContext(data: nil, width: Int(canvasSize.width), height: Int(canvasSize.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        context.clear(canvasRect)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        ]))
        var descent: CGFloat = 0
        let advance = CTLineGetTypographicBounds(line, nil, &descent, nil)
        try #require(advance > 0 && advance.isFinite)
        // Independently authored resized box: corners (8, 16) and (78, 41), 70 × 25 pt.
        // Neither position, width nor baseline is obtained from the product annotation.
        let lineHeight: CGFloat = 25
        let baseline = CGFloat(16) + descent + (lineHeight - CGFloat(20) * 1.2) / 2
        context.translateBy(x: 8, y: baseline)
        context.scaleBy(x: CGFloat(70) / CGFloat(advance), y: 1)
        context.textMatrix = .identity
        context.textPosition = .zero
        CTLineDraw(line, context)
        let overlay = try #require(context.makeImage())
        return CIImage(cgImage: overlay).composited(over: source).cropped(to: canvasRect)
    }

    @Test
    func genericAliasesUseNativeFontsForMetricsAndCompleteRaster() throws {
        let aliases: [String?] = [nil, "", "System", "Sans Serif", "sans-serif", "Monospace", "Serif", "Cursive", "Fantasy",
                                  "SYSTEM", "MONOSPACE", "sErIf", "CURSIVE", "FANTASY"]
        let helper = RenderingCoreTests()
        let source = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: CGRect(origin: .zero, size: helper.size))
        let sourcePixels = helper.pixels(source)
        for alias in aliases {
            for bold in [false, true] {
                let expected = try nativeReference(alias, bold: bold, size: 20)
                let actual = DrawingAnnotation.font(size: 20, family: alias, bold: bold)
                #expect(actual.fontName == expected.fontName)
                #expect(actual.pointSize == expected.pointSize)
                if alias?.lowercased() == "monospace" {
                    let narrow = CTLineCreateWithAttributedString(NSAttributedString(string: "iiii", attributes: [.font: actual]))
                    let wide = CTLineCreateWithAttributedString(NSAttributedString(string: "WWWW", attributes: [.font: actual]))
                    let narrowAdvance = CTLineGetTypographicBounds(narrow, nil, nil, nil)
                    let wideAdvance = CTLineGetTypographicBounds(wide, nil, nil, nil)
                    #expect(narrowAdvance > 0 && wideAdvance > 0)
                    #expect(abs(narrowAdvance - wideAdvance) < 0.001,
                            "ASCII advances must be fixed; Korean fallback is not assumed to have identical advances")
                }
                let text = "Wi 17"
                var drawing = DrawingAnnotation.text(text, at: CGPoint(x: 8, y: 16), fontSize: 20,
                    color: .black, fontName: alias, bold: bold)
                let width = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(
                    NSAttributedString(string: text, attributes: [.font: expected])), nil, nil, nil)
                #expect(abs(drawing.bounds.width - CGFloat(width)) < 0.001)
                // Keep natural-size validation above separate from fitted-box raster validation.
                // A system font's first measured advance can differ from later native measurements;
                // the rendering contract fits the current line to these independently authored corners.
                drawing.points = [CGPoint(x: 8, y: 16), CGPoint(x: 78, y: 41)]
                try VideoProjectFile.requireAvailableFonts([drawing])
                let encoded = try JSONEncoder().encode(drawing)
                let decoded = try JSONDecoder().decode(DrawingAnnotation.self, from: encoded)
                #expect(decoded.fontName == alias && decoded == drawing)

                let rendered = try BlurRenderer.render(image: source, pairs: [], canvasSize: helper.size,
                    time: nil, annotations: [drawing])
                let referenceRaster = try nativeRaster(text: text, font: expected, source: source, canvasSize: helper.size)
                let actualPixels = helper.pixels(rendered)
                let referencePixels = helper.pixels(referenceRaster)
                let rasterEqual = actualPixels == referencePixels
                let nonblank = actualPixels != sourcePixels
                let actualCount = actualPixels.count, referenceCount = referencePixels.count
                let actualHash = SHA256.hash(data: Data(actualPixels)).description
                let referenceHash = SHA256.hash(data: Data(referencePixels)).description
                print("FontRaster authoredBox=70x25 alias=\(alias ?? "<nil>") bold=\(bold) font=\(expected.fontName) bytes=\(actualCount) actual=\(actualHash) reference=\(referenceHash)")
                #expect(actualCount == referenceCount)
                #expect(rasterEqual, "Every RGBA byte must match the independently drawn native font")
                #expect(actualHash == referenceHash)
                #expect(nonblank, "A matching blank canvas is not a text-rendering pass")
                drawing.hidden = true
                #expect(drawing.fontName == alias)
            }
        }
    }

    @Test
    func installedFamilyOutsideSixSurvivesSelectionBackgroundWeightAndUndo() async throws {
        let family = try installedNonPresetFamily()
        let session = try await ImageSession.open()
        defer { session.close() }
        session.tool(1); session.mode(5)
        let drawing = DrawingAnnotation.text("기존 글꼴\n둘째 줄", at: CGPoint(x: 12, y: 40), fontSize: 20,
            color: .black, fontName: family, bold: false)
        session.canvas.annotationAdded?(drawing)
        session.canvas.selectAnnotation(id: drawing.id)
        let ui = try controls(session)
        #expect(ui.font.titleOfSelectedItem == family, "Selecting imported text must not display system font")
        #expect(try storedDrawing(session, id: drawing.id) == drawing)

        ui.background.selectItem(withTitle: "검정 배경"); send(ui.background)
        let withBackground = try storedDrawing(session, id: drawing.id)
        #expect(withBackground.fontName == family && !withBackground.bold)
        #expect(withBackground.textBackground == RGBAColor(red: 0, green: 0, blue: 0, alpha: 1))
        ui.bold.state = .on; send(ui.bold)
        let weighted = try storedDrawing(session, id: drawing.id)
        #expect(weighted.fontName == family && weighted.bold && weighted.textBackground == withBackground.textBackground)
        #expect(abs(weighted.bounds.maxY - drawing.bounds.maxY) < 0.001)
        #expect(abs(weighted.textFontSize - drawing.textFontSize) < 0.001)
        session.controller.perform(NSSelectorFromString("undoTapped"))
        #expect(try storedDrawing(session, id: drawing.id) == withBackground)
        session.controller.perform(NSSelectorFromString("undoTapped"))
        #expect(try storedDrawing(session, id: drawing.id) == drawing)
        #expect(ui.font.titleOfSelectedItem == family)
        session.controller.perform(NSSelectorFromString("redoTapped"))
        #expect(try storedDrawing(session, id: drawing.id) == withBackground)
        session.controller.perform(NSSelectorFromString("redoTapped"))
        #expect(try storedDrawing(session, id: drawing.id) == weighted)
    }

    @Test
    func namedPostScriptFamilyAndCustomBackgroundAreNotRewrittenByOtherControls() async throws {
        let family = try installedNonPresetFamily()
        let native = try #require(NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 20))
        let name = native.fontName
        let custom = RGBAColor(red: 0.13, green: 0.27, blue: 0.41, alpha: 0.63)
        let session = try await ImageSession.open()
        defer { session.close() }
        session.tool(1); session.mode(5)
        let drawing = DrawingAnnotation.text("Custom background", at: CGPoint(x: 12, y: 40), fontSize: 20,
            color: .black, fontName: name, bold: false, background: custom)
        session.canvas.annotationAdded?(drawing)
        let ui = try controls(session)
        #expect(ui.font.titleOfSelectedItem == name)
        ui.bold.state = .on; send(ui.bold)
        let weighted = try storedDrawing(session, id: drawing.id)
        #expect(weighted.fontName == name && weighted.textBackground == custom && weighted.bold)
        session.controller.perform(NSSelectorFromString("undoTapped"))
        #expect(try storedDrawing(session, id: drawing.id) == drawing)

        ui.font.selectItem(at: 0); send(ui.font)
        let explicitSystem = try storedDrawing(session, id: drawing.id)
        #expect(explicitSystem.fontName == nil && explicitSystem.textBackground == custom && !explicitSystem.bold)
        session.controller.perform(NSSelectorFromString("undoTapped"))
        #expect(try storedDrawing(session, id: drawing.id) == drawing)
        #expect(ui.font.titleOfSelectedItem == name)
        let decoded = try JSONDecoder().decode(DrawingAnnotation.self,
            from: JSONEncoder().encode(try storedDrawing(session, id: drawing.id)))
        #expect(decoded.fontName == name && decoded.textBackground == custom)
    }

    @Test
    func storedGenericAliasesRemainExactDuringControllerRestyling() async throws {
        let session = try await ImageSession.open()
        defer { session.close() }
        session.tool(1); session.mode(5)
        let ui = try controls(session)
        for alias in ["", "System", "Monospace", "Sans Serif", "sans-serif", "Serif", "Cursive", "Fantasy", "sErIf"] {
            let drawing = DrawingAnnotation.text("Saved alias", at: CGPoint(x: 10, y: 40), fontSize: 18,
                color: .black, fontName: alias, bold: false)
            session.canvas.annotationAdded?(drawing)
            #expect(ui.font.titleOfSelectedItem == (alias.isEmpty ? "시스템 글꼴" : alias))
            ui.bold.state = .on; send(ui.bold)
            #expect(try storedDrawing(session, id: drawing.id).fontName == alias)
            ui.background.selectItem(withTitle: "검정 배경"); send(ui.background)
            #expect(try storedDrawing(session, id: drawing.id).fontName == alias)
            session.controller.perform(NSSelectorFromString("undoTapped"))
            session.controller.perform(NSSelectorFromString("undoTapped"))
            #expect(try storedDrawing(session, id: drawing.id) == drawing)
            try session.controller.validateExportFonts()
        }
    }

    @Test
    func missingNamedFontAndNearAliasArePreservedAndVisibleLockedTextIsHeld() throws {
        let names = ["BlurActionMissingNamedFont-" + UUID().uuidString, "Monospace-not-a-generic", " System "]
        for name in names {
            var drawing = DrawingAnnotation(kind: .text, points: [.zero, CGPoint(x: 0.5, y: 0.3)], lineWidth: 0.01)
            drawing.text = "원래 지정 글꼴"; drawing.fontName = name
            let original = drawing
            #expect(throws: VideoProjectFile.Review.self) { try VideoProjectFile.requireAvailableFonts([drawing]) }
            #expect(drawing == original)
            drawing.locked = true
            #expect(throws: VideoProjectFile.Review.self) { try VideoProjectFile.requireAvailableFonts([drawing]) }
            drawing.hidden = true
            try VideoProjectFile.requireAvailableFonts([drawing])
            #expect(drawing.fontName == name && drawing.locked)
            let reopened = try JSONDecoder().decode(DrawingAnnotation.self, from: JSONEncoder().encode(drawing))
            #expect(reopened == drawing && reopened.fontName == name)
            drawing.kind = .rectangle; drawing.hidden = false
            try VideoProjectFile.requireAvailableFonts([drawing])
        }
    }

    @Test
    func missingNamedFontIsShownExactlyUntilTheUserExplicitlyChangesIt() async throws {
        let name = "BlurActionMissingNamedFont-" + UUID().uuidString
        let session = try await ImageSession.open()
        defer { session.close() }
        session.tool(1); session.mode(5)
        let drawing = DrawingAnnotation.text("원래 지정 글꼴", at: CGPoint(x: 12, y: 40), fontSize: 20,
            color: .black, fontName: name, bold: false)
        session.canvas.annotationAdded?(drawing)
        let ui = try controls(session)
        #expect(ui.font.titleOfSelectedItem == name && ui.font.toolTip?.contains(name) == true)
        #expect(throws: VideoProjectFile.Review.self) { try session.controller.validateExportFonts() }
        ui.bold.state = .on; send(ui.bold)
        #expect(try storedDrawing(session, id: drawing.id).fontName == name)
        #expect(throws: VideoProjectFile.Review.self) { try session.controller.validateExportFonts() }
        session.controller.perform(NSSelectorFromString("undoTapped"))
        #expect(try storedDrawing(session, id: drawing.id) == drawing)
        ui.font.selectItem(at: 0); send(ui.font)
        #expect(try storedDrawing(session, id: drawing.id).fontName == nil)
        try session.controller.validateExportFonts()
        session.controller.perform(NSSelectorFromString("undoTapped"))
        #expect(try storedDrawing(session, id: drawing.id) == drawing)
        #expect(ui.font.titleOfSelectedItem == name && ui.font.toolTip?.contains(name) == true)
        #expect(throws: VideoProjectFile.Review.self) { try session.controller.validateExportFonts() }
    }

    @Test
    func lockedSelectedTextCannotBeRestyledOrCreateAnUndoStep() async throws {
        let family = try installedNonPresetFamily()
        let session = try await ImageSession.open()
        defer { session.close() }
        session.tool(1); session.mode(5)
        let drawing = DrawingAnnotation.text("Locked original", at: CGPoint(x: 12, y: 40), fontSize: 20,
            color: .black, fontName: family, bold: false)
        session.canvas.annotationAdded?(drawing)
        session.controller.setLayerLocked(drawing.id, true)
        session.canvas.selectAnnotation(id: drawing.id)
        let locked = try storedDrawing(session, id: drawing.id)
        let ui = try controls(session)
        #expect(ui.font.titleOfSelectedItem == family)
        ui.bold.state = .on; send(ui.bold)
        ui.background.selectItem(withTitle: "검정 배경"); send(ui.background)
        ui.font.selectItem(at: 0); send(ui.font)
        #expect(try storedDrawing(session, id: drawing.id) == locked)
        session.controller.perform(NSSelectorFromString("undoTapped"))
        #expect(try storedDrawing(session, id: drawing.id) == drawing,
            "First undo must remove the original lock, not an attempted style edit")
        session.controller.perform(NSSelectorFromString("redoTapped"))
        #expect(try storedDrawing(session, id: drawing.id) == locked)
    }
}
