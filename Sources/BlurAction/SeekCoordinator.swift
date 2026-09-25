/// Serializes seeks and keeps only the latest requested time while a seek is in flight.
/// All requests and completions are handled on the main actor.
@MainActor
final class SeekCoordinator {
    typealias Completion = @MainActor (Bool) -> Void
    private let performSeek: (Double, @escaping Completion) -> Void
    var didSettle: ((Bool) -> Void)?

    private(set) var duration: Double = 0
    private(set) var pendingTime: Double?
    private(set) var isSeeking = false
    private(set) var isScrubbing = false
    private var isReady = false
    private var generation = 0

    var suppressesTimeObserver: Bool { isScrubbing || pendingTime != nil || isSeeking }

    init(performSeek: @escaping (Double, @escaping Completion) -> Void) {
        self.performSeek = performSeek
    }

    /// Reset before replacing the player item, so its late completion cannot affect the new item.
    func reset(duration: Double) {
        generation &+= 1
        self.duration = duration.isFinite ? max(0, duration) : 0
        pendingTime = nil
        isSeeking = false
        isScrubbing = false
        isReady = false
    }

    func setReady(_ ready: Bool) {
        isReady = ready
        seekIfNeeded()
    }

    func beginScrubbing() { isScrubbing = true }
    func endScrubbing() { isScrubbing = false }

    func request(_ seconds: Double) {
        guard seconds.isFinite, duration > 0 else { return }
        pendingTime = min(duration, max(0, seconds))
        seekIfNeeded()
    }

    private func seekIfNeeded() {
        guard isReady, !isSeeking, let target = pendingTime else { return }
        isSeeking = true
        let requestGeneration = generation
        performSeek(target) { [weak self] finished in
            guard let self, self.generation == requestGeneration else { return }
            self.isSeeking = false
            if self.pendingTime != target {
                self.seekIfNeeded()
            } else {
                self.pendingTime = nil
                self.didSettle?(finished)
            }
        }
    }
}
