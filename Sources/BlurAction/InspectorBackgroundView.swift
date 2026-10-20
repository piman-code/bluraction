import AppKit

/// CGColor snapshots must be refreshed when the window's appearance changes.
private func refreshInspectorBackground(_ view: NSView, color: NSColor) {
    view.wantsLayer = true
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        view.layer?.backgroundColor = color.cgColor
    }
}

final class InspectorBackgroundView: NSView {
    var backgroundColor: NSColor = .controlBackgroundColor {
        didSet { refreshInspectorBackground(self, color: backgroundColor) }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshInspectorBackground(self, color: backgroundColor)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshInspectorBackground(self, color: backgroundColor)
    }
}

final class InspectorBackgroundStackView: NSStackView {
    var backgroundColor: NSColor = .windowBackgroundColor {
        didSet { refreshInspectorBackground(self, color: backgroundColor) }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshInspectorBackground(self, color: backgroundColor)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshInspectorBackground(self, color: backgroundColor)
    }
}
