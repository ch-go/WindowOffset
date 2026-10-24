import AppKit
import ApplicationServices
import OffsetCore

final class WindowMonitor {
    var automatic = true { didSet {
        EventLog.shared.write("automatic_changed", ["enabled": automatic])
        if !automatic { trackers.values.forEach { $0.pending?.cancel(); $0.forcePending = false } } else { refresh() }
    } }
    var status: (String) -> Void = { _ in }
    private var trackers: [pid_t: ApplicationTracker] = [:]
    private var timer: Timer?
    private var tokens: [NSObjectProtocol] = []
    private var displayToken: NSObjectProtocol?
    private var wasTrusted = false
    private var mouseMonitor: Any?

    deinit { if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) } }

    func start() {
        EventLog.shared.write("monitor_started", ["trusted": AXIsProcessTrusted(), "automatic": automatic,
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"])
        // Observe real clicks independently of delayed AX notifications. By the
        // time AXResized arrives after a double-click, the buttons are often up.
        // No keyboard, click position, or window content is recorded.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            self?.userInteracted(mouseUp: event.type == .leftMouseUp, clickCount: event.clickCount)
        }
        EventLog.shared.write("mouse_interaction_monitor_started", ["installed": mouseMonitor != nil])
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.didUnhideApplicationNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            tokens.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                EventLog.shared.write("workspace_event", ["notification": notification.name.rawValue])
                self?.refresh()
            })
        }
        displayToken = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                EventLog.shared.write("display_configuration_changed")
                self.trackers.values.forEach { $0.baseline = nil; $0.attemptHistory.reset() }
                self.refresh()
            }
        // Fallback for applications that omit AX notifications. Only changed
        // geometry triggers a pass; rejected geometry isn't retried every tick.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func receivedEvent(observer: AXObserver, notification: String, window: AXUIElement) {
        // Destroyed elements may no longer answer AXUIElementGetPid. Resolve by
        // observer identity so their old creation-order records are still removed.
        if let tracker = trackers.values.first(where: { $0.observer.map { CFEqual($0, observer) } ?? false }) {
            if notification == kAXUIElementDestroyedNotification { tracker.forgetWindow(window) }
            if notification == kAXWindowCreatedNotification,
               AX.value(window, kAXRoleAttribute) as? String == kAXWindowRole {
                tracker.rememberWindow(window)
            }
            guard automatic else { return }
            if NSEvent.pressedMouseButtons != 0 { tracker.attemptHistory.reset() }
            if !tracker.processing { schedule(tracker, reason: notification) }
        }
    }

    private func userInteracted(mouseUp: Bool, clickCount: Int) {
        guard automatic, AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.activationPolicy == .regular,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let tracker = tracker(for: app.processIdentifier)
        tracker.attemptHistory.userInteracted()
        tracker.baseline = nil
        if mouseUp {
            EventLog.shared.write("user_interaction_recheck", ["pid": app.processIdentifier,
                "app": app.localizedName ?? "unknown", "clickCount": clickCount,
                "interactionGeneration": tracker.attemptHistory.interactionGeneration,
                "reason": "clear_old_attempts_after_explicit_mouse_interaction"])
        }
        if tracker.processing { tracker.recheckAfterInteraction = true }
        else { schedule(tracker, reason: mouseUp ? "user_mouse_release" : "user_mouse_down") }
    }

    func refresh() {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            if wasTrusted { EventLog.shared.write("accessibility_permission_changed", ["trusted": false]) }
            trackers.removeAll()
            status("需要辅助功能授权")
            wasTrusted = false
            return
        }
        if !wasTrusted {
            EventLog.shared.write("accessibility_permission_changed", ["trusted": true])
            status(automatic ? "自动处理已开启" : "自动处理已暂停"); wasTrusted = true
        }
        guard automatic else { return }
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        let pids = Set(apps.map(\.processIdentifier))
        for pid in Array(trackers.keys) where !pids.contains(pid) { trackers.removeValue(forKey: pid) }
        for app in apps where !app.isHidden {
            let tracker = tracker(for: app.processIdentifier)
            guard !tracker.processing else { continue }
            let current = tracker.read().map(\.geometry)
            if tracker.changed(current) { schedule(tracker, reason: "geometry_poll_or_workspace_event") }
        }
    }

    func processFrontmost() {
        guard AXIsProcessTrusted() else {
            EventLog.shared.write("manual_process_blocked", ["reason": "accessibility_not_trusted"])
            status("请先授权辅助功能"); return
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            EventLog.shared.write("manual_process_blocked", ["reason": "no_external_frontmost_application"])
            return
        }
        EventLog.shared.write("manual_process_requested", ["pid": app.processIdentifier, "app": app.localizedName ?? "unknown"])
        schedule(tracker(for: app.processIdentifier), force: true, reason: "manual")
    }

    private func tracker(for pid: pid_t) -> ApplicationTracker {
        if let tracker = trackers[pid] { return tracker }
        let tracker = ApplicationTracker(pid: pid, context: Unmanaged.passUnretained(self).toOpaque())
        trackers[pid] = tracker
        return tracker
    }

    private func schedule(_ tracker: ApplicationTracker, force: Bool = false, reason: String = "ax_event") {
        guard !tracker.processing else {
            if force { EventLog.shared.write("manual_process_blocked", ["pid": tracker.pid, "reason": "processing_in_progress"]) }
            return
        }
        tracker.forcePending = tracker.forcePending || force
        if !tracker.forcePending || force { tracker.pendingReason = reason }
        tracker.pending?.cancel()
        let work = DispatchWorkItem { [weak self, weak tracker] in
            guard let self, let tracker else { return }
            // No event tap or input-monitoring permission is required.
            if NSEvent.pressedMouseButtons != 0 {
                if !tracker.waitingForMouse {
                    EventLog.shared.write("waiting_for_mouse_release", ["pid": tracker.pid])
                    tracker.waitingForMouse = true
                }
                tracker.attemptHistory.reset()
                // Mouse-up schedules the next check. Do not busy-poll while held.
                return
            }
            let forced = tracker.forcePending
            tracker.waitingForMouse = false
            tracker.forcePending = false
            guard self.automatic || forced else { return }
            Task { @MainActor in await self.process(tracker, force: forced) }
        }
        tracker.pending = work
        DispatchQueue.main.async(execute: work)
    }

    @MainActor private func process(_ tracker: ApplicationTracker, force: Bool) async {
        guard !tracker.processing else { return }
        tracker.processing = true
        let interactionGeneration = tracker.attemptHistory.interactionGeneration
        defer {
            tracker.processing = false
            if tracker.recheckAfterInteraction {
                tracker.recheckAfterInteraction = false
                tracker.baseline = nil
                if automatic { schedule(tracker, reason: "user_interaction_during_previous_pass") }
            }
        }
        guard AXIsProcessTrusted(), let app = NSRunningApplication(processIdentifier: tracker.pid), !app.isHidden else {
            EventLog.shared.write("process_aborted", ["pid": tracker.pid, "reason": "not_trusted_or_app_exited_or_hidden"])
            return
        }
        let windows = tracker.read()
        let geometry = windows.map(\.geometry)
        guard force || tracker.changed(geometry) else { return }
        let context: [String: Any] = ["passID": UUID().uuidString, "pid": tracker.pid,
            "app": app.localizedName ?? "unknown", "bundleID": app.bundleIdentifier ?? "unknown"]
        func log(_ event: String, _ fields: [String: Any] = [:]) {
            EventLog.shared.write(event, context.merging(fields) { _, new in new })
        }
        log("process_begin", ["manual": force, "trigger": tracker.pendingReason, "sizePolicy": "preserve_original_size",
            "windows": tracker.diagnostics, "eligibleCount": geometry.count])
        tracker.baseline = geometry
        if !force && tracker.attemptHistory.contains(geometry) {
            log("process_skipped", ["reason": "previously_attempted_geometry_anti_loop"])
            return
        }
        let displays = AX.displays
        log("display_geometry", ["displays": displays.map { ["frame": EventLog.rect($0.frame), "usable": EventLog.rect($0.usable)] }])
        let adjustments = Layout.plan(geometry, displays: displays, report: { id, reason in
            log("layout_decision", ["windowID": id, "reason": reason])
        })
        if !adjustments.isEmpty {
            tracker.attemptHistory.record(geometry)
        }
        var moved = 0
        var refused = 0
        var interrupted = false
        for adjustment in adjustments {
            if tracker.attemptHistory.interactionGeneration != interactionGeneration { interrupted = true; break }
            guard NSEvent.pressedMouseButtons == 0,
                  let window = windows.first(where: { $0.id == adjustment.id }),
                  let before = AX.frame(window.element), AX.close(before, window.geometry.frame) else {
                log("adjustment_skipped", ["windowID": adjustment.id, "reason": "mouse_pressed_or_geometry_changed_or_unavailable"])
                continue
            }
            let target = adjustment.frame
            log("adjustment_begin", ["windowID": window.id, "before": EventLog.rect(before), "target": EventLog.rect(target)])
            let shouldInterrupt = {
                NSEvent.pressedMouseButtons != 0 || !self.automatic && !force ||
                tracker.attemptHistory.interactionGeneration != interactionGeneration ||
                !AXIsProcessTrusted() || app.isTerminated || app.isHidden
            }
            func verify(_ phase: String, matches: (CGRect) -> Bool) async -> GeometryVerificationResult {
                let started = Date()
                return await GeometryVerification.wait(read: { AX.frame(window.element) }, interrupted: shouldInterrupt,
                matches: matches, sample: { index, frame in
                    log("geometry_verification_sample", ["windowID": window.id, "phase": phase,
                        "sampleIndex": index, "elapsedMilliseconds": Int(Date().timeIntervalSince(started) * 1000),
                        "actual": frame.map { EventLog.rect($0) } as Any? ?? NSNull()])
                })
            }
            var accepted = true
            if shouldInterrupt() { interrupted = true; accepted = false }
            let matchesFinal: (CGRect) -> Bool = { AX.close($0, target) }
            if accepted {
                let error = AX.writePosition(window.element, target.origin)
                accepted = error == .success
                log("ax_write_position", ["windowID": window.id, "axError": error.rawValue,
                    "readback": AX.frame(window.element).map { EventLog.rect($0) } as Any? ?? NSNull()])
                if accepted {
                    switch await verify("position_preserving_size", matches: matchesFinal) {
                    case .matched: break
                    case .notMatched: accepted = false
                    case .interrupted: interrupted = true; accepted = false
                    }
                }
            }
            if let actual = AX.frame(window.element) { accepted = accepted && matchesFinal(actual) }
            else { accepted = false }
            if accepted { moved += 1 }
            else if interrupted {
                // The user may already be dragging. Never restore over their action.
                log("adjustment_interrupted", ["windowID": window.id, "reason": "user_input_or_monitor_stopped_or_application_unavailable"])
            }
            else {
                // Best-effort rollback, once only; never fight an application's constraints.
                if let actual = AX.frame(window.element), !AX.close(actual, before) {
                    let positionError = AX.writePosition(window.element, before.origin)
                    log("rollback_position", ["windowID": window.id, "axError": positionError.rawValue])
                    if actual.size != before.size { log("size_changed_by_application", ["windowID": window.id]) }
                    if case .interrupted = await verify("rollback", matches: { AX.close($0, before) }) { interrupted = true }
                }
                refused += 1
            }
            let finalFrame = AX.frame(window.element)
            log("adjustment_end", ["windowID": window.id, "accepted": accepted, "sizePolicy": "preserve_original_size",
                "actual": finalFrame.map { EventLog.rect($0) } as Any? ?? NSNull(),
                "overflow": finalFrame.map { WindowPlacement.overflow($0, usable: adjustment.usableBounds) } as Any? ?? NSNull()])
            if interrupted { break }
        }
        tracker.baseline = tracker.read().map(\.geometry)
        log("process_end", ["planned": adjustments.count, "moved": moved, "refused": refused,
            "interrupted": interrupted, "windows": tracker.diagnostics])
        if moved > 0 || refused > 0 || force {
            status("\(app.localizedName ?? "应用")：移动 \(moved) 个，拒绝 \(refused) 个")
        }
    }
}
