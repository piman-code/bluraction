import Foundation

/// Persisted uncertainty belongs to a cover and survives save, page switching and undo.
/// A correction changes only the selected issue after tracking has actually succeeded.
struct TrackingReview: Codable, Equatable, Identifiable {
    enum Reason: String, Codable { case lostTarget, recognitionGap, cancelled, sampledInterval }
    enum Status: String, Codable { case needsReview, corrected }
    var id: UUID = UUID()
    var start: Double
    var end: Double
    var reason: Reason
    var status: Status = .needsReview

    var isValid: Bool { start.isFinite && end.isFinite && start >= 0 && end >= start }

    init(id: UUID = UUID(), start: Double, end: Double, reason: Reason, status: Status = .needsReview) {
        self.id = id; self.start = start; self.end = end; self.reason = reason; self.status = status
    }
    private enum CodingKeys: String, CodingKey { case id, start, end, reason, status }
    init(from decoder: Decoder) throws {
        try MacEditField.validate(decoder, allowed: ["id", "start", "end", "reason", "status"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        reason = try c.decode(Reason.self, forKey: .reason)
        status = try c.decode(Status.self, forKey: .status)
        guard isValid else { throw ProjectFile.ProjectError.invalidContent }
    }
}
