import Testing
// Shared assertion adapters keep the pixel/media checks readable on CLT's Swift Testing.
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(a == b, Comment(rawValue: message), sourceLocation: sourceLocation)
}
func XCTAssertNotEqual<T: Equatable>(_ a: T, _ b: T, sourceLocation: SourceLocation = #_sourceLocation) { #expect(a != b, sourceLocation: sourceLocation) }
func XCTAssertEqual(_ a: Double, _ b: Double, accuracy: Double, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(abs(a - b) <= accuracy, "actual: \(a), expected: \(b)", sourceLocation: sourceLocation)
}
func XCTAssertGreaterThan<T: Comparable>(_ a: T, _ b: T, sourceLocation: SourceLocation = #_sourceLocation) { #expect(a > b, sourceLocation: sourceLocation) }
func XCTAssertLessThan<T: Comparable>(_ a: T, _ b: T, sourceLocation: SourceLocation = #_sourceLocation) { #expect(a < b, sourceLocation: sourceLocation) }
func XCTAssertTrue(_ value: Bool, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) { #expect(value, Comment(rawValue: message), sourceLocation: sourceLocation) }
func XCTAssertFalse(_ value: Bool, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) { #expect(!value, Comment(rawValue: message), sourceLocation: sourceLocation) }
func XCTAssertNil(_ value: Any?, sourceLocation: SourceLocation = #_sourceLocation) { #expect(value == nil, sourceLocation: sourceLocation) }
func XCTAssertNotNil(_ value: Any?, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) { #expect(value != nil, Comment(rawValue: message), sourceLocation: sourceLocation) }
func XCTUnwrap<T>(_ value: T?, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) throws -> T {
    try #require(value, Comment(rawValue: message), sourceLocation: sourceLocation)
}
func XCTAssertThrowsError<T>(_ value: @autoclosure () throws -> T, sourceLocation: SourceLocation = #_sourceLocation) {
    do { _ = try value(); Issue.record("Expected error", sourceLocation: sourceLocation) } catch {}
}
