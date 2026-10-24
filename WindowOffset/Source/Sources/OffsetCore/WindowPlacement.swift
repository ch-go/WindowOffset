import Foundation
import CoreGraphics

public enum WindowPlacement {
    public static func overflow(_ actual: CGRect, usable: CGRect) -> [String: Double] {
        ["right": Double(max(0, actual.maxX-usable.maxX)),
         "bottom": Double(max(0, actual.maxY-usable.maxY))]
    }
}
