import AppKit

/// Keep playback observation from moving the thumb during AppKit's mouse tracking loop.
final class TrackingSlider: NSSlider {
    var trackingBegan: (() -> Void)?
    var trackingEnded: (() -> Void)?
    private var trackingPointer = false
    /// Times (in slider units) of the selected item's recorded positions, drawn as ticks.
    var markers: [Double] = [] {
        didSet { if markers != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !markers.isEmpty, maxValue > minValue, let sliderCell = cell as? NSSliderCell else { return }
        let knob = sliderCell.knobRect(flipped: isFlipped)
        let left = bounds.minX + knob.width / 2, right = bounds.maxX - knob.width / 2
        guard right > left else { return }
        NSColor.systemOrange.setFill()
        for time in markers where time.isFinite {
            let x = left + CGFloat((min(maxValue, max(minValue, time)) - minValue) / (maxValue - minValue)) * (right - left)
            NSBezierPath(rect: NSRect(x: x - 1, y: bounds.minY, width: 2, height: 5)).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        trackingPointer = true
        trackingBegan?()
        updateFromPointer(event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard trackingPointer, isEnabled else { return }
        updateFromPointer(event)
    }

    override func mouseUp(with event: NSEvent) {
        guard trackingPointer else { return }
        if isEnabled { updateFromPointer(event) }
        trackingPointer = false
        trackingEnded?()
    }

    private func updateFromPointer(_ event: NSEvent) {
        guard let sliderCell = cell as? NSSliderCell else { return }
        let bar = sliderCell.barRect(flipped: isFlipped)
        let knob = sliderCell.knobRect(flipped: isFlipped)
        let point = convert(event.locationInWindow, from: nil)
        let left = bounds.minX + knob.width / 2
        let right = bounds.maxX - knob.width / 2
        guard bar.width > 0, right > left else { return }
        let fraction = min(1, max(0, (point.x - left) / (right - left)))
        doubleValue = minValue + Double(fraction) * (maxValue - minValue)
        needsDisplay = true
        _ = sendAction(action, to: target)
    }
}
