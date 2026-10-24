import CoreGraphics
import OffsetCore

// A standalone runner also works with Command Line Tools, which lack XCTest.
func XCTAssertEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #file, line: UInt = #line) {
    precondition(actual == expected, "Expected \(expected), got \(actual)", file: file, line: line)
}
func XCTAssertTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(value, "Expected true", file: file, line: line)
}

final class LayoutTests {
    let display = DisplayGeometry(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                  usable: CGRect(x: 0, y: 25, width: 1440, height: 850))
    func window(_ id: Int, _ x: CGFloat = 100, _ y: CGFloat = 100,
                _ width: CGFloat = 600, _ height: CGFloat = 400,
                movable: Bool = true, resizable: Bool = true,
                minimum: CGSize = CGSize(width: 1, height: 1)) -> WindowGeometry {
        WindowGeometry(id: id, frame: CGRect(x: x, y: y, width: width, height: height),
                       movable: movable, resizable: resizable, minimumSize: minimum)
    }
    func testDifferentSizeSameOriginMovesOnlyDuplicate() {
        let result = Layout.plan([window(0), window(1, 100, 100, 500, 300)], displays: [display])
        XCTAssertEqual(result.map(\.id), [1])
        XCTAssertEqual(result.first?.frame, CGRect(x: 101, y: 101, width: 500, height: 300))
    }
    func testExistingOffsetsReservedAndUntouched() {
        let result = Layout.plan([window(0), window(1), window(2, 101, 101), window(3)], displays: [display])
        XCTAssertEqual(result.map(\.id), [1, 3])
        XCTAssertEqual(result.map(\.frame.origin), [CGPoint(x: 102, y: 102), CGPoint(x: 103, y: 103)])
    }
    func testMaximizedWindowsKeepOriginalSize() {
        let full = [window(0, 0, 25, 1440, 850), window(1, 0, 25, 1440, 850), window(2, 0, 25, 1440, 850)]
        let result = Layout.plan(full, displays: [display])
        XCTAssertEqual(result.map(\.frame), [CGRect(x: 1, y: 26, width: 1440, height: 850),
                                            CGRect(x: 2, y: 27, width: 1440, height: 850)])
    }
    func testUniqueWindowsNeverResizeEvenOutsideUsableBounds() {
        XCTAssertTrue(Layout.plan([window(0, 0, 0, 2000, 1000), window(1, 99)], displays: [display]).isEmpty)
    }
    func testImmovableAnchorAndUnresizableWindows() {
        let result = Layout.plan([window(0), window(1, movable: false)], displays: [display])
        XCTAssertEqual(result.map(\.id), [0])
        XCTAssertEqual(Layout.plan([window(0, 0, 25, 1440, 850),
                                  window(1, 0, 25, 1440, 850, resizable: false)], displays: [display]).first?.frame,
                       CGRect(x: 1, y: 26, width: 1440, height: 850))
        XCTAssertEqual(Layout.plan([window(0), window(1, resizable: false)], displays: [display]).count, 1)
    }
    func testMinimumSizeDoesNotPreventPositionOnlyMove() {
        let result = Layout.plan([window(0, 840), window(1, 840, minimum: CGSize(width: 600, height: 300)),
                                  window(2, 841, 101)], displays: [display])
        XCTAssertEqual(result.first?.frame, CGRect(x: 842, y: 102, width: 600, height: 400))
    }
    func testNegativeAndAboveDisplayCoordinatesRemainLogicalPoints() {
        let left = DisplayGeometry(frame: CGRect(x: -1920, y: -300, width: 1920, height: 1080),
                                   usable: CGRect(x: -1920, y: -275, width: 1920, height: 1055))
        let result = Layout.plan([window(0, -1800, -200), window(1, -1800, -200)], displays: [display, left])
        XCTAssertEqual(result.first?.frame.origin, CGPoint(x: -1799, y: -199))
    }
    func testIdempotentAndLargeCollisionGroup() {
        var windows = (0..<100).map { window($0) }
        let result = Layout.plan(windows, displays: [display])
        XCTAssertEqual(result.count, 99)
        for change in result {
            windows[change.id] = WindowGeometry(id: change.id, frame: change.frame)
        }
        XCTAssertTrue(Layout.plan(windows, displays: [display]).isEmpty)
        XCTAssertEqual(Set(windows.map { "\($0.frame.minX),\($0.frame.minY)" }).count, 100)
    }
    func testFractionalCoordinatesAndNoDisplay() {
        let result = Layout.plan([window(0, 100.5, 100.5), window(1, 100.5, 100.5), window(2, 100.6, 100.6)], displays: [display])
        XCTAssertEqual(result.map(\.id), [1])
        XCTAssertEqual(result.first?.frame.minX, 101.5)
        XCTAssertTrue(Layout.plan([window(0), window(1)], displays: []).isEmpty)
    }
    func testEveryWindowHasDiagnosticDecision() {
        var decisions: [Int: String] = [:]
        let windows = [window(0, 0, 25, 1440, 850),
                       window(1, 0, 25, 1440, 850, resizable: false),
                       window(2, 0, 25, 1440, 850, minimum: CGSize(width: 1440, height: 850)),
                       window(3, 0, 25, 1440, 850, movable: false)]
        let result = Layout.plan(windows, displays: [display], report: { id, reason in
            XCTAssertTrue(decisions[id] == nil)
            decisions[id] = reason
        })
        XCTAssertEqual(result.map(\.id), [0, 1, 2])
        XCTAssertEqual(decisions, [0: "adjustment_planned", 1: "adjustment_planned",
                                   2: "adjustment_planned", 3: "anchor_or_unique"])
    }
    func testSequentialAdditionPreservesExistingWindows() {
        var existing = [window(0, 0, 25, 1440, 850)]
        for id in 1...8 {
            let before = existing.map(\.frame)
            existing.append(window(id, 0, 25, 1440, 850))
            let result = Layout.plan(existing.reversed(), displays: [display])
            XCTAssertEqual(result.map(\.id), [id])
            XCTAssertEqual(result.first?.frame, CGRect(x: id, y: 25 + id, width: 1440, height: 850))
            existing[id] = WindowGeometry(id: id, frame: result.first!.frame)
            XCTAssertEqual(Array(existing.dropLast()).map(\.frame), before)
        }
    }
    func testCreationOrderDoesNotFollowStackOrder() {
        let result = Layout.plan([window(2), window(0), window(1)], displays: [display])
        XCTAssertEqual(result.map(\.id), [1, 2])
        XCTAssertEqual(result.map(\.frame.origin), [CGPoint(x: 101, y: 101), CGPoint(x: 102, y: 102)])
    }
    func testOverflowMeasuredWithoutShrinking() {
        let full = [window(0, 0, 25, 1440, 850), window(1, 0, 25, 1440, 850)]
        let result = Layout.plan(full, displays: [display])
        XCTAssertEqual(WindowPlacement.overflow(result.first!.frame, usable: display.usable),
                       ["right": 1, "bottom": 1])
        XCTAssertEqual(result.first?.frame.size, full[1].frame.size)
    }
    func testUserInteractionRearmsPreviouslyAttemptedLayout() {
        var history = AttemptHistory()
        let maximized = [window(0, 0, 25, 1440, 850), window(1, 0, 25, 1440, 850)]
        history.record(maximized)
        XCTAssertTrue(history.contains(maximized))
        let generation = history.interactionGeneration
        history.userInteracted()
        XCTAssertTrue(!history.contains(maximized))
        XCTAssertTrue(history.interactionGeneration != generation)
        history.record(maximized)
        XCTAssertTrue(history.contains(maximized))
    }
    func testAXFeedbackRetainsLoopProtectionUntilUserInteraction() {
        var history = AttemptHistory()
        let original = [window(0), window(1)]
        let adjusted = [window(0), window(1, 101, 101)]
        history.record(original)
        // Notification delivery and application snapback alone do not clear history.
        XCTAssertTrue(!history.contains(adjusted))
        XCTAssertTrue(history.contains(original))
        history.userInteracted()
        XCTAssertTrue(!history.contains(original))
    }
}

@main
enum LayoutChecks {
    @MainActor static func main() async {
        let suite = LayoutTests()
        let checks: [(String, () -> Void)] = [
            ("different sizes, same origin", suite.testDifferentSizeSameOriginMovesOnlyDuplicate),
            ("reserve existing offsets", suite.testExistingOffsetsReservedAndUntouched),
            ("maximized windows keep their full size", suite.testMaximizedWindowsKeepOriginalSize),
            ("unique windows unchanged", suite.testUniqueWindowsNeverResizeEvenOutsideUsableBounds),
            ("unresizable windows can still move", suite.testImmovableAnchorAndUnresizableWindows),
            ("minimum size does not block position-only movement", suite.testMinimumSizeDoesNotPreventPositionOnlyMove),
            ("negative monitor coordinates", suite.testNegativeAndAboveDisplayCoordinatesRemainLogicalPoints),
            ("100 windows and idempotency", suite.testIdempotentAndLargeCollisionGroup),
            ("fractional points and missing display", suite.testFractionalCoordinatesAndNoDisplay),
            ("diagnostic decision coverage", suite.testEveryWindowHasDiagnosticDecision),
            ("sequential additions leave old windows untouched", suite.testSequentialAdditionPreservesExistingWindows),
            ("creation order independent of stack enumeration", suite.testCreationOrderDoesNotFollowStackOrder),
            ("overflow measured without resizing", suite.testOverflowMeasuredWithoutShrinking),
            ("explicit user click rearms identical maximized layout", suite.testUserInteractionRearmsPreviouslyAttemptedLayout),
            ("AX-only feedback retains anti-loop protection", suite.testAXFeedbackRetainsLoopProtectionUntilUserInteraction)
        ]
        for (name, check) in checks { check(); print("PASS: \(name)") }
        let original = CGRect(x: 0, y: 33, width: 1511, height: 945)
        let target = CGRect(x: 1, y: 34, width: 1511, height: 945)
        var reads = 0
        let delayed = await GeometryVerification.wait(delays: [0, 0, 0, 0], read: {
            reads += 1
            return reads < 3 ? original : target
        }, interrupted: { false }, matches: { $0 == target }, sample: { _, _ in })
        if case .matched(let frame) = delayed { XCTAssertEqual(frame, target) }
        else { preconditionFailure("Delayed application of a position must succeed") }
        XCTAssertEqual(reads, 3)
        print("PASS: delayed position confirmation")

        reads = 0
        let ignored = await GeometryVerification.wait(delays: [0, 0, 0], read: {
            reads += 1; return original
        }, interrupted: { false }, matches: { $0 == target }, sample: { _, _ in })
        if case .notMatched(let frame) = ignored { XCTAssertEqual(frame, original) }
        else { preconditionFailure("Ignored position must remain a failure") }
        XCTAssertEqual(reads, 3)
        print("PASS: ignored position has bounded reads")

        reads = 0
        let stopped = await GeometryVerification.wait(delays: [0, 0, 0], read: {
            reads += 1; return original
        }, interrupted: { reads == 1 }, matches: { $0 == target }, sample: { _, _ in })
        if case .interrupted = stopped {} else { preconditionFailure("User interaction must stop verification") }
        XCTAssertEqual(reads, 1)
        print("PASS: user interference interrupts verification")

        var mainActorRan = false
        Task { @MainActor in mainActorRan = true }
        let yielded = await GeometryVerification.wait(delays: [0, 80_000_000],
            read: { mainActorRan ? target : original }, interrupted: { false },
            matches: { $0 == target }, sample: { _, _ in })
        if case .matched = yielded {} else { preconditionFailure("Waiting must yield the UI actor") }
        XCTAssertTrue(mainActorRan)
        print("PASS: verification yields the main actor")

        var history = AttemptHistory()
        let generation = history.interactionGeneration
        reads = 0
        let quickClick = await GeometryVerification.wait(delays: [0, 0, 0], read: {
            reads += 1; return original
        }, interrupted: { history.interactionGeneration != generation }, matches: { $0 == target }, sample: { _, _ in
            // A full click can begin and end between two geometry samples.
            history.userInteracted()
        })
        if case .interrupted = quickClick {} else { preconditionFailure("Released click must still interrupt the old pass") }
        XCTAssertEqual(reads, 1)
        print("PASS: quick released click invalidates in-flight verification")

        reads = 0
        let immediate = await GeometryVerification.wait(read: {
            reads += 1
            return reads == 1 ? original : target
        }, interrupted: { false }, matches: { $0 == target }, sample: { _, _ in })
        if case .notMatched = immediate {} else { preconditionFailure("Default verification must not wait for another read") }
        XCTAssertEqual(reads, 1)
        print("PASS: production default performs one immediate read without delay")
        print("All \(checks.count) layout and 6 verification checks passed. No desktop windows were accessed.")
    }
}
