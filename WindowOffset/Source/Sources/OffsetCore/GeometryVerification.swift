import Foundation
import CoreGraphics

public enum GeometryVerificationResult {
    case matched(CGRect)
    case notMatched(CGRect?)
    case interrupted
}

public enum GeometryVerification {
    /// Read-only confirmation: never repeat a write to persuade an application.
    /// Yield the main actor between samples so UI and AX callbacks stay responsive.
    @MainActor public static func wait(
        delays: [UInt64] = [0],
        read: () -> CGRect?, interrupted: () -> Bool,
        matches: (CGRect) -> Bool, sample: (Int, CGRect?) -> Void
    ) async -> GeometryVerificationResult {
        var last: CGRect?
        for (index, delay) in delays.enumerated() {
            if delay > 0 {
                do { try await Task.sleep(nanoseconds: delay) }
                catch { return .interrupted }
            }
            guard !Task.isCancelled, !interrupted() else { return .interrupted }
            last = read()
            sample(index, last)
            if let last, matches(last) { return .matched(last) }
        }
        return .notMatched(last)
    }
}
