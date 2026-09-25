import Foundation

// Diagnostics are opt-in and remain in stderr; no media names/paths are persisted.
func BLog(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["BLURACTION_DEBUG"] == "1" else { return }
    FileHandle.standardError.write(Data((message() + "\n").utf8))
}
func BLogBoth(_ message: @autoclosure () -> String) { BLog(message()) }
