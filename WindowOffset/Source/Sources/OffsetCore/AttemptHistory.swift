import Foundation
import CoreGraphics

public struct AttemptHistory {
    private var inputs: [[WindowGeometry]] = []
    public private(set) var interactionGeneration = 0
    public init() {}

    public mutating func userInteracted() {
        interactionGeneration &+= 1
        reset()
    }
    public mutating func reset() { inputs.removeAll() }
    public mutating func record(_ geometry: [WindowGeometry]) {
        inputs.append(geometry)
        if inputs.count > 32 { inputs.removeFirst() }
    }
    public func contains(_ geometry: [WindowGeometry]) -> Bool {
        inputs.contains { Self.sameGeometry($0, geometry) }
    }
    public static func sameGeometry(_ a: [WindowGeometry], _ b: [WindowGeometry]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy {
            $0.id == $1.id && abs($0.frame.minX-$1.frame.minX) < 0.1 &&
            abs($0.frame.minY-$1.frame.minY) < 0.1 && abs($0.frame.width-$1.frame.width) < 0.1 &&
            abs($0.frame.height-$1.frame.height) < 0.1 && $0.movable == $1.movable && $0.resizable == $1.resizable
        }
    }
}
