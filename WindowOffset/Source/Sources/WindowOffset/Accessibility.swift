import AppKit
import ApplicationServices
import OffsetCore

enum AX {
    static func attribute(_ element: AXUIElement, _ name: String) -> (value: CFTypeRef?, error: AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (value, error)
    }
    static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        let result = attribute(element, name)
        return result.error == .success ? result.value : nil
    }
    static func bool(_ element: AXUIElement, _ name: String) -> Bool {
        (value(element, name) as? NSNumber)?.boolValue ?? false
    }
    static func settable(_ element: AXUIElement, _ name: String) -> Bool {
        capability(element, name).settable
    }
    static func capability(_ element: AXUIElement, _ name: String) -> (settable: Bool, error: AXError) {
        var result = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(element, name as CFString, &result)
        return (error == .success && result.boolValue, error)
    }
    static func point(_ element: AXUIElement) -> CGPoint? {
        guard let raw = value(element, kAXPositionAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var result = CGPoint.zero
        return AXValueGetValue(raw as! AXValue, .cgPoint, &result) ? result : nil
    }
    static func size(_ element: AXUIElement, _ name: String = kAXSizeAttribute) -> CGSize? {
        guard let raw = value(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var result = CGSize.zero
        return AXValueGetValue(raw as! AXValue, .cgSize, &result) ? result : nil
    }
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let point = point(element), let size = size(element), point.x.isFinite, point.y.isFinite,
              size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: point, size: size)
    }
    static func position(_ element: AXUIElement, _ point: CGPoint) -> Bool {
        writePosition(element, point) == .success
    }
    static func writePosition(_ element: AXUIElement, _ point: CGPoint) -> AXError {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return .illegalArgument }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }
    static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX-b.minX) < 0.1 && abs(a.minY-b.minY) < 0.1 &&
        abs(a.width-b.width) < 0.1 && abs(a.height-b.height) < 0.1
    }
    static var displays: [DisplayGeometry] {
        // AX uses a top-left origin in logical points. AppKit uses bottom-left,
        // relative to the primary display, including displays above/left of it.
        guard let primary = NSScreen.screens.first else { return [] }
        let top = primary.frame.maxY
        func convert(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
        }
        return NSScreen.screens.map { DisplayGeometry(frame: convert($0.frame), usable: convert($0.visibleFrame)) }
    }
}

struct TrackedWindow {
    let id: Int
    let element: AXUIElement
    let geometry: WindowGeometry
}

final class ApplicationTracker {
    let pid: pid_t
    let element: AXUIElement
    var observer: AXObserver?
    var windows: [TrackedWindow] = []
    var baseline: [WindowGeometry]?
    // Remember inputs as well as final readback: an app may accept a write then
    // asynchronously snap back. That must not cause a repeated adjustment loop.
    var attemptHistory = AttemptHistory()
    var nextID = 0
    private var knownWindows: [(element: AXUIElement, id: Int)] = []
    var diagnostics: [[String: Any]] = []
    private var lastReadError: AXError?
    var pending: DispatchWorkItem?
    var forcePending = false
    var pendingReason = "unknown"
    var waitingForMouse = false
    var processing = false
    var recheckAfterInteraction = false
    private var watched: [AXUIElement] = []
    private let callbackContext: UnsafeMutableRawPointer

    init(pid: pid_t, context: UnsafeMutableRawPointer) {
        self.pid = pid; self.callbackContext = context
        element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.15)
        var created: AXObserver?
        let observerError = AXObserverCreate(pid, { observer, element, notification, context in
            guard let context else { return }
            let monitor = Unmanaged<WindowMonitor>.fromOpaque(context).takeUnretainedValue()
            // AX observers run on the main run loop.
            monitor.receivedEvent(observer: observer, notification: notification as String, window: element)
        }, &created)
        EventLog.shared.write("observer_created", ["pid": pid, "axError": observerError.rawValue,
            "app": NSRunningApplication(processIdentifier: pid)?.localizedName ?? "unknown"])
        if observerError == .success, let created {
            observer = created
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
            for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification] {
                let error = AXObserverAddNotification(created, element, name as CFString, context)
                if error != .success {
                    EventLog.shared.write("notification_registration_failed", ["pid": pid, "notification": name, "axError": error.rawValue])
                }
            }
        }
    }

    deinit {
        pending?.cancel()
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
    }

    @discardableResult func rememberWindow(_ window: AXUIElement) -> Int {
        if let known = knownWindows.first(where: { CFEqual($0.element, window) }) { return known.id }
        let id = nextID
        nextID += 1
        knownWindows.append((window, id))
        // Keep identity and destruction observation across temporary empty AX lists,
        // Space switches and minimization. Focus/z-order must not reset creation order.
        if let observer {
            let error = AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, callbackContext)
            if error != .success {
                EventLog.shared.write("notification_registration_failed", ["pid": pid, "windowID": id,
                    "notification": kAXUIElementDestroyedNotification, "axError": error.rawValue])
            }
        }
        return id
    }

    func forgetWindow(_ window: AXUIElement) {
        knownWindows.removeAll { CFEqual($0.element, window) }
    }

    func read() -> [TrackedWindow] {
        let result = AX.attribute(element, kAXWindowsAttribute)
        guard result.error == .success, let raw = result.value as? [AXUIElement] else {
            diagnostics = [["reason": "window_list_unavailable", "axError": result.error.rawValue]]
            if lastReadError != result.error {
                EventLog.shared.write("window_list_read_failed", ["pid": pid, "axError": result.error.rawValue])
                lastReadError = result.error
            }
            return windows
        }
        if lastReadError != nil { EventLog.shared.write("window_list_read_recovered", ["pid": pid]); lastReadError = nil }
        diagnostics = []
        var current: [TrackedWindow] = []
        for (index, window) in raw.enumerated() {
            let subroleResult = AX.attribute(window, kAXSubroleAttribute)
            let subrole = subroleResult.value as? String ?? "unknown"
            let minimized = AX.bool(window, kAXMinimizedAttribute)
            let fullScreen = AX.bool(window, "AXFullScreen")
            let frame = AX.frame(window)
            var diagnostic: [String: Any] = ["enumerationIndex": index, "subrole": subrole,
                "subroleAXError": subroleResult.error.rawValue, "minimized": minimized, "fullScreen": fullScreen]
            if let frame { diagnostic["frame"] = EventLog.rect(frame) }
            let reason: String?
            if subrole != kAXStandardWindowSubrole { reason = "non_standard_window" }
            else if minimized { reason = "minimized" }
            else if fullScreen { reason = "native_full_screen" }
            else if frame == nil { reason = "geometry_unavailable" }
            else { reason = nil }
            if let reason {
                diagnostic["reason"] = reason
                if frame == nil {
                    diagnostic["positionAXError"] = AX.attribute(window, kAXPositionAttribute).error.rawValue
                    diagnostic["sizeAXError"] = AX.attribute(window, kAXSizeAttribute).error.rawValue
                }
                diagnostics.append(diagnostic)
                continue
            }
            guard let frame else { continue }
            let id = rememberWindow(window)
            let reportedMinimum = AX.size(window, "AXMinSize")
            let minimum = reportedMinimum ?? CGSize(width: 1, height: 1)
            let movable = AX.capability(window, kAXPositionAttribute)
            let resizable = AX.capability(window, kAXSizeAttribute)
            current.append(TrackedWindow(id: id, element: window, geometry: WindowGeometry(
                id: id, frame: frame, movable: movable.settable,
                resizable: resizable.settable, minimumSize: minimum)))
            diagnostic["windowID"] = id
            diagnostic["reason"] = "eligible"
            diagnostic["movable"] = movable.settable
            diagnostic["resizable"] = resizable.settable
            diagnostic["positionSettableAXError"] = movable.error.rawValue
            diagnostic["sizeSettableAXError"] = resizable.error.rawValue
            diagnostic["minimumSizeReportedByApp"] = reportedMinimum != nil
            diagnostic["minimumSize"] = ["width": minimum.width, "height": minimum.height]
            diagnostics.append(diagnostic)
        }
        if let observer {
            for old in watched where !current.contains(where: { CFEqual($0.element, old) }) {
                for name in [kAXMovedNotification, kAXResizedNotification,
                             kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
                    AXObserverRemoveNotification(observer, old, name as CFString)
                }
            }
            for window in current where !watched.contains(where: { CFEqual($0, window.element) }) {
                for name in [kAXMovedNotification, kAXResizedNotification,
                             kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
                    let error = AXObserverAddNotification(observer, window.element, name as CFString, callbackContext)
                    if error != .success {
                        EventLog.shared.write("notification_registration_failed", ["pid": pid, "windowID": window.id,
                            "notification": name, "axError": error.rawValue])
                    }
                }
            }
            watched = current.map(\.element)
        }
        windows = current.sorted { $0.id < $1.id }
        return windows
    }

    func changed(_ current: [WindowGeometry]) -> Bool {
        guard let baseline else { return true }
        return !Self.sameGeometry(baseline, current)
    }

    static func sameGeometry(_ a: [WindowGeometry], _ b: [WindowGeometry]) -> Bool {
        AttemptHistory.sameGeometry(a, b)
    }
}
