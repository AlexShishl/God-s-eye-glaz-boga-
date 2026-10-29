import AppKit
import ServiceManagement

@main
enum NotchDrawerMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ClipboardStore.shared.start()
        ScreenshotStore.shared.start()
        HotKeyCenter.shared.register()
        controller = NotchController()
        setupStatusItem()
        if CommandLine.arguments.contains("--permissions") { Permissions.requestAll() }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "eye.fill", accessibilityDescription: "Глаз Бога")

        let menu = NSMenu()
        let open = NSMenuItem(title: "Открыть Глаз Бога", action: #selector(openDrawer), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let login = NSMenuItem(title: "Запускать при входе", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let perms = NSMenuItem(title: "Выдать разрешения…", action: #selector(requestPermissions), keyEquivalent: "")
        perms.target = self
        menu.addItem(perms)

        let update = NSMenuItem(title: "Обновить…", action: #selector(runUpdate), keyEquivalent: "")
        update.target = self
        menu.addItem(update)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    /// Повторный запуск уже работающего приложения (из «Программ», Spotlight, Launchpad)
    /// раньше ничего не делал — теперь пересобирает окно и открывает шторку.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.rebuildPanel()
        controller?.open(pinned: true)
        return false
    }

    @objc private func openDrawer() {
        controller?.open(pinned: true)
    }

    @objc private func requestPermissions() {
        Permissions.requestAll()
    }

    @objc private func runUpdate() {
        Updater.run()
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Login item error: \(error)")
        }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}
