import AppKit
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private let monitor = WindowMonitor()
    private let statusItem = NSMenuItem(title: "准备就绪", action: nil, keyEquivalent: "")
    private var automaticItem: NSMenuItem!
    private var permissionItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var loginSettingsItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if UserDefaults.standard.object(forKey: "automatic") != nil {
            monitor.automatic = UserDefaults.standard.bool(forKey: "automatic")
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "窗口微错位")
        item.button?.toolTip = "窗口微错位 · 保留系统 App Exposé"
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "窗口微错位 · 1 逻辑点", action: nil, keyEquivalent: ""))
        menu.addItem(statusItem)
        menu.addItem(.separator())
        automaticItem = add("自动处理", action: #selector(toggleAutomatic), to: menu)
        automaticItem.state = monitor.automatic ? .on : .off
        add("立即处理当前应用", action: #selector(processCurrent), to: menu)
        loginItem = add("登录时自动启动", action: #selector(toggleLoginItem), to: menu)
        loginSettingsItem = add("在系统设置中允许自动启动…", action: #selector(openLoginSettings), to: menu)
        updateLoginMenu()
        EventLog.shared.write("login_item_status", ["status": String(describing: SMAppService.mainApp.status)])
        menu.addItem(.separator())
        permissionItem = add("辅助功能授权…", action: #selector(permissions), to: menu)
        add("打开日志文件夹…", action: #selector(openLogs), to: menu)
        add("使用说明…", action: #selector(help), to: menu)
        menu.addItem(.separator())
        add("退出", action: #selector(quit), to: menu, key: "q")
        item.menu = menu
        monitor.status = { [weak self] message in self?.statusItem.title = message }
        monitor.start()
        if !AXIsProcessTrusted() { permissions() }
    }

    @discardableResult private func add(_ title: String, action: Selector, to menu: NSMenu, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        menu.addItem(entry)
        return entry
    }
    func menuWillOpen(_ menu: NSMenu) {
        permissionItem.title = AXIsProcessTrusted() ? "辅助功能已授权 · 打开设置…" : "辅助功能授权…"
        updateLoginMenu()
    }
    private func updateLoginMenu() {
        let status = SMAppService.mainApp.status
        loginItem.isEnabled = Bundle.main.bundleURL.pathExtension == "app"
        loginItem.state = status == .enabled ? .on : (status == .requiresApproval ? .mixed : .off)
        loginItem.title = status == .requiresApproval ? "登录时自动启动（待系统允许）" : "登录时自动启动"
        loginSettingsItem.isHidden = status != .requiresApproval
    }
    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        let shouldEnable = service.status != .enabled && service.status != .requiresApproval
        do {
            if shouldEnable { try service.register() }
            else { try service.unregister() }
            updateLoginMenu()
            EventLog.shared.write("login_item_changed", ["requestedEnabled": shouldEnable,
                "status": String(describing: service.status)])
            if service.status == .requiresApproval {
                let alert = NSAlert()
                alert.messageText = "自动启动需要在系统设置中允许"
                alert.informativeText = "请在“系统设置 → 通用 → 登录项”中允许 WindowOffset。允许后，下次登录会自动启动。"
                alert.addButton(withTitle: "打开登录项设置")
                alert.addButton(withTitle: "稍后")
                if alert.runModal() == .alertFirstButtonReturn { openLoginSettings() }
            }
        } catch {
            updateLoginMenu()
            let detail = error as NSError
            EventLog.shared.write("login_item_change_failed", ["requestedEnabled": shouldEnable,
                "errorDomain": detail.domain, "errorCode": detail.code, "description": detail.localizedDescription])
            let alert = NSAlert()
            alert.messageText = "无法更改登录时自动启动"
            alert.informativeText = "\(detail.localizedDescription)\n\n请先将应用放在固定位置（建议“应用程序”文件夹），再打开该位置的应用设置。"
            alert.runModal()
        }
    }
    @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    @objc private func toggleAutomatic() {
        monitor.automatic.toggle()
        UserDefaults.standard.set(monitor.automatic, forKey: "automatic")
        automaticItem.state = monitor.automatic ? .on : .off
        statusItem.title = monitor.automatic ? "自动处理已开启" : "自动处理已暂停"
    }
    @objc private func processCurrent() { monitor.processFrontmost() }
    @objc private func permissions() {
        let alert = NSAlert()
        alert.messageText = "允许“窗口微错位”调整窗口"
        alert.informativeText = "请在“系统设置 → 隐私与安全性 → 辅助功能”中添加并开启 WindowOffset.app。授权后自动检测生效，无需授予屏幕录制或输入监控。\n\n本工具仅读取普通窗口的位置、大小及能力，并在横坐标或纵坐标相同时仅调整位置，保留原始大小。"
        alert.addButton(withTitle: "打开辅助功能设置")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
    @objc private func help() {
        let alert = NSAlert()
        alert.messageText = "保留系统 App Exposé"
        alert.informativeText = "同一应用中，横坐标或纵坐标相同的普通窗口会逐一向右下偏移 1 逻辑点，直到横、纵坐标分别都不重复（同一坐标相差小于 1 点视为相同，正好相差 1 点视为不同）。只修改位置，始终保留窗口大小，允许右边或下边因偏移而少量越界。新增窗口与已有窗口任一坐标相同时，按跟踪到的创建顺序寻找下一个空位。\n\n支持保留菜单栏的铺满窗口；跳过原生独立 Space 全屏、最小化窗口及面板。鼠标释放后立即检查，没有固定防抖或延迟读回等待；不激活窗口、不修改叠放顺序。\n\n可在菜单开启“登录时自动启动”，下次登录自动运行。\n\n窗口微错位可能影响原生 App Exposé 排列，但系统如何排列并无保证。第三方应用可拒绝窗口调整，此时仅尝试一次并尽力恢复。"
        alert.runModal()
    }
    @objc private func openLogs() {
        EventLog.shared.write("log_folder_opened")
        EventLog.shared.flush()
        NSWorkspace.shared.activateFileViewerSelecting([EventLog.shared.fileURL])
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        EventLog.shared.write("application_stopped")
        EventLog.shared.flush()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
