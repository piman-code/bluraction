import AppKit

/// Keep playback observation from moving the thumb during AppKit's mouse tracking loop.
/// The strip along the bottom edge shows the selected item's recorded positions (ticks) and
/// time range (band); both can be dragged there, while the rest of the slider scrubs.
final class TrackingSlider: NSSlider {
    var trackingBegan: (() -> Void)?
    var trackingEnded: (() -> Void)?
    private var trackingPointer = false
    /// Times (in slider units) of the selected item's recorded positions, drawn as ticks.
    var markers: [Double] = [] {
        didSet { if markers != oldValue { needsDisplay = true } }
    }
    /// The selected item's time range, drawn as a band with draggable ends.
    var rangeBand: ClosedRange<Double>? {
        didSet { if rangeBand != oldValue { needsDisplay = true } }
    }
    /// Called on mouse-up after dragging marker `index` to a new time.
    var markerMoved: ((Int, Double) -> Void)?
    /// Called on mouse-up after dragging the band's start (true) or end (false).
    var rangeEdgeMoved: ((Bool, Double) -> Void)?

    private enum Grab: Equatable { case scrub, marker(Int), start, end }
    private var grab: Grab = .scrub
    private var dragTime: Double?

    static let stripHeight: CGFloat = 9

    private var strip: CGRect {
        isFlipped ? CGRect(x: bounds.minX, y: bounds.maxY - Self.stripHeight, width: bounds.width, height: Self.stripHeight)
                  : CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: Self.stripHeight)
    }

    private var trackSpan: (left: CGFloat, right: CGFloat)? {
        guard let sliderCell = cell as? NSSliderCell, maxValue > minValue else { return nil }
        let knob = sliderCell.knobRect(flipped: isFlipped)
        let left = bounds.minX + knob.width / 2, right = bounds.maxX - knob.width / 2
        return right > left ? (left, right) : nil
    }

    func x(forTime time: Double) -> CGFloat? {
        guard let span = trackSpan, time.isFinite else { return nil }
        return span.left + CGFloat((min(maxValue, max(minValue, time)) - minValue) / (maxValue - minValue)) * (span.right - span.left)
    }

    private func time(forX x: CGFloat) -> Double? {
        guard let span = trackSpan else { return nil }
        let fraction = min(1, max(0, (x - span.left) / (span.right - span.left)))
        return minValue + Double(fraction) * (maxValue - minValue)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let strip = self.strip
        if let band = rangeBand, let a = x(forTime: displayed(.start, band.lowerBound)), let b = x(forTime: displayed(.end, band.upperBound)) {
            NSColor.systemBlue.withAlphaComponent(0.25).setFill()
            NSBezierPath(rect: NSRect(x: min(a, b), y: strip.minY + 2, width: abs(b - a), height: strip.height - 4)).fill()
            NSColor.systemBlue.setFill()
            for edge in [a, b] { NSBezierPath(rect: NSRect(x: edge - 1.5, y: strip.minY, width: 3, height: strip.height)).fill() }
        }
        NSColor.systemOrange.setFill()
        for (index, time) in markers.enumerated() {
            guard let x = x(forTime: grab == .marker(index) ? (dragTime ?? time) : time) else { continue }
            let diamond = NSBezierPath()
            let mid = strip.midY
            diamond.move(to: NSPoint(x: x, y: mid - 4)); diamond.line(to: NSPoint(x: x + 3.5, y: mid))
            diamond.line(to: NSPoint(x: x, y: mid + 4)); diamond.line(to: NSPoint(x: x - 3.5, y: mid)); diamond.close()
            diamond.fill()
        }
    }

    private func displayed(_ edge: Grab, _ value: Double) -> Double { grab == edge ? (dragTime ?? value) : value }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        grab = .scrub
        if strip.insetBy(dx: 0, dy: -3).contains(point) {
            if let index = markers.indices.min(by: { abs((x(forTime: markers[$0]) ?? .infinity) - point.x) < abs((x(forTime: markers[$1]) ?? .infinity) - point.x) }),
               let mx = x(forTime: markers[index]), abs(mx - point.x) <= 5 {
                grab = .marker(index)
            } else if let band = rangeBand, let a = x(forTime: band.lowerBound), abs(a - point.x) <= 5 {
                grab = .start
            } else if let band = rangeBand, let b = x(forTime: band.upperBound), abs(b - point.x) <= 5 {
                grab = .end
            }
        }
        if grab != .scrub {
            dragTime = time(forX: point.x)
            NSCursor.resizeLeftRight.set()
            needsDisplay = true
            return
        }
        trackingPointer = true
        trackingBegan?()
        updateFromPointer(event)
    }

    override func mouseDragged(with event: NSEvent) {
        if grab != .scrub {
            dragTime = time(forX: convert(event.locationInWindow, from: nil).x)
            needsDisplay = true
            return
        }
        guard trackingPointer, isEnabled else { return }
        updateFromPointer(event)
    }

    override func mouseUp(with event: NSEvent) {
        if grab != .scrub {
            let time = self.time(forX: convert(event.locationInWindow, from: nil).x)
            let finished = grab
            grab = .scrub
            dragTime = nil
            NSCursor.arrow.set()
            needsDisplay = true
            guard let time else { return }
            switch finished {
            case .marker(let index): markerMoved?(index, time)
            case .start: rangeEdgeMoved?(true, time)
            case .end: rangeEdgeMoved?(false, time)
            case .scrub: break
            }
            return
        }
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
