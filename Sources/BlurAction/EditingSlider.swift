import AppKit

/// AppKit tracks a continuous slider inside mouseDown; group its actions into one edit.
final class EditingSlider: NSSlider {
    var editingBegan: (() -> Void)?
    var editingEnded: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        editingBegan?()
        defer { editingEnded?() }
        super.mouseDown(with: event)
    }
}
