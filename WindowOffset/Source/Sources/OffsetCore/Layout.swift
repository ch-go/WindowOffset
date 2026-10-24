import Foundation
import CoreGraphics

public struct WindowGeometry {
    public let id: Int
    public let frame: CGRect
    public let movable: Bool
    public let resizable: Bool
    public let minimumSize: CGSize
    public init(id: Int, frame: CGRect, movable: Bool = true, resizable: Bool = true,
                minimumSize: CGSize = CGSize(width: 1, height: 1)) {
        self.id = id; self.frame = frame; self.movable = movable
        self.resizable = resizable; self.minimumSize = minimumSize
    }
}

public struct DisplayGeometry {
    public let frame: CGRect
    public let usable: CGRect
    public init(frame: CGRect, usable: CGRect) { self.frame = frame; self.usable = usable }
}

public struct Adjustment {
    public let id: Int
    public let frame: CGRect
    public let usableBounds: CGRect
}

public enum Layout {
    // Coordinates less than one logical point apart count as equal.
    public static func sameOrigin(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) < 1 && abs(a.y - b.y) < 1
    }

    private static func sharesCoordinate(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) < 1 || abs(a.y - b.y) < 1
    }

    public static func plan(_ windows: [WindowGeometry], displays: [DisplayGeometry],
                            step: CGFloat = 1, report: ((Int, String) -> Void)? = nil) -> [Adjustment] {
        guard step.isFinite, step > 0 else { return [] }
        var anchors: [WindowGeometry] = []
        var duplicates: [WindowGeometry] = []
        // Keep an immovable member as the anchor where possible.
        let byCreation = windows.sorted { $0.id < $1.id }
        let ordered = byCreation.filter { !$0.movable } + byCreation.filter { $0.movable }
        for window in ordered {
            if anchors.contains(where: { sharesCoordinate($0.frame.origin, window.frame.origin) }) {
                duplicates.append(window)
            } else { anchors.append(window); report?(window.id, "anchor_or_unique") }
        }
        // Reserve even duplicate originals: a failed move must not create a new collision.
        var occupied = windows.map(\.frame.origin)
        var result: [Adjustment] = []
        for window in duplicates {
            guard window.movable else { report?(window.id, "position_not_settable"); continue }
            guard let display = displays.max(by: {
                area(window.frame.intersection($0.frame)) < area(window.frame.intersection($1.frame))
            }), area(window.frame.intersection(display.frame)) > 0 else { report?(window.id, "no_intersecting_display"); continue }
            var point = window.frame.origin
            // With fractional origins, each axis can block two one-point candidates.
            for _ in 0...(4 * windows.count) {
                point.x += step; point.y += step
                if !occupied.contains(where: { sharesCoordinate($0, point) }) { break }
            }
            let usable = display.usable
            guard point.x >= usable.minX, point.y >= usable.minY else { report?(window.id, "outside_usable_top_or_left"); continue }
            result.append(Adjustment(id: window.id, frame: CGRect(origin: point, size: window.frame.size), usableBounds: usable))
            report?(window.id, "adjustment_planned")
            occupied.append(point)
        }
        return result
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull || rect.isInfinite ? 0 : max(0, rect.width) * max(0, rect.height)
    }
}
