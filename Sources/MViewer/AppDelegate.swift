import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    let viewer = ViewerWindowController()
    private var openedSomething = false
    private lazy var settings = SettingsWindowController()
    private var shortcutMenuItems: [(item: NSMenuItem, action: ShortcutAction, allowsPlainKey: Bool)] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
        applyShortcuts()
        ShortcutStore.shared.notificationCenter.addObserver(
            self, selector: #selector(applyShortcuts),
            name: ShortcutStore.didChange, object: ShortcutStore.shared)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openedSomething = true
        viewer.open(urls: urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        let cliURLs = CommandLine.arguments.dropFirst()
            .filter { !$0.hasPrefix("-") }
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        if !cliURLs.isEmpty {
            openedSomething = true
            viewer.open(urls: cliURLs)
        }

        // Give a launch-time open event a beat to arrive before showing the panel.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, !self.openedSomething else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.openDocument(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie, .folder]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        openedSomething = true
        viewer.open(urls: panel.urls)
    }

    @objc func showSettings(_ sender: Any?) {
        settings.showWindow(sender)
        settings.window?.makeKeyAndOrderFront(sender)
    }

    @objc private func applyShortcuts() {
        for entry in shortcutMenuItems {
            entry.item.applyShortcut(of: entry.action, allowsPlainKey: entry.allowsPlainKey)
        }
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About MViewer",
                        action: #selector(ViewerWindowController.showAbout(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…",
                        action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide MViewer",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.option, .command]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit MViewer",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu, title: "MViewer"))

        let fileMenu = NSMenu(title: "File")
        // Handled by the app delegate, so enabled in every window: no plain keys.
        addItem(to: fileMenu, title: "Open…",
                action: #selector(AppDelegate.openDocument(_:)), shortcut: .openFile, allowsPlainKey: false)
        fileMenu.addItem(.separator())
        addItem(to: fileMenu, title: "Copy Image",
                action: #selector(ViewerWindowController.copyImage(_:)), shortcut: .copyImage)
        addItem(to: fileMenu, title: "Show in Finder",
                action: #selector(ViewerWindowController.showInFinder(_:)), shortcut: .showInFinder)
        addItem(to: fileMenu, title: "Get Info",
                action: #selector(ViewerWindowController.getInfo(_:)), shortcut: .getInfo)
        fileMenu.addItem(.separator())
        addItem(to: fileMenu, title: "Move to Trash",
                action: #selector(ViewerWindowController.moveToTrash(_:)), shortcut: .moveToTrash)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window",
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu(fileMenu, title: "File"))

        let viewMenu = NSMenu(title: "View")
        addItem(to: viewMenu, title: "Zoom In",
                action: #selector(ViewerWindowController.zoomIn(_:)), shortcut: .zoomIn)
        addItem(to: viewMenu, title: "Zoom Out",
                action: #selector(ViewerWindowController.zoomOut(_:)), shortcut: .zoomOut)
        addItem(to: viewMenu, title: "Zoom to Fit",
                action: #selector(ViewerWindowController.zoomToFit(_:)), shortcut: .zoomToFit)
        addItem(to: viewMenu, title: "Actual Size",
                action: #selector(ViewerWindowController.actualSize(_:)), shortcut: .actualSize)
        viewMenu.addItem(.separator())
        addItem(to: viewMenu, title: "Enter Full Screen",
                action: #selector(NSWindow.toggleFullScreen(_:)), shortcut: .toggleFullScreen)
        main.addItem(submenu(viewMenu, title: "View"))

        let goMenu = NSMenu(title: "Go")
        addItem(to: goMenu, title: "Next",
                action: #selector(ViewerWindowController.nextFile(_:)), shortcut: .nextFile)
        addItem(to: goMenu, title: "Previous",
                action: #selector(ViewerWindowController.previousFile(_:)), shortcut: .previousFile)
        main.addItem(submenu(goMenu, title: "Go"))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenu(windowMenu, title: "Window"))
        NSApp.windowsMenu = windowMenu

        let helpMenu = NSMenu(title: "Help")
        addItem(to: helpMenu, title: "Keyboard Shortcuts",
                action: #selector(ViewerWindowController.showShortcuts(_:)), shortcut: .showShortcuts)
        main.addItem(submenu(helpMenu, title: "Help"))
        NSApp.helpMenu = helpMenu

        return main
    }

    /// Adds an item whose key equivalent follows the customizable shortcut.
    private func addItem(to menu: NSMenu, title: String, action: Selector, shortcut: ShortcutAction,
                         allowsPlainKey: Bool = true) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        shortcutMenuItems.append((item, shortcut, allowsPlainKey))
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
