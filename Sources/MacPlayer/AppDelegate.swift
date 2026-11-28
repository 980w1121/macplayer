import AppKit
import Foundation

/// Application delegate: owns the main window and the menu bar.
/// No document model, no SwiftUI scene, no network work at launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: PlayerWindowController?
    // v1.0.10: AppKit can deliver the open-documents event before
    // applicationDidFinishLaunching runs (double-clicking a video
    // launches the app to open it), when windowController is still
    // nil. Queue those URLs and open them once the window exists
    // instead of silently dropping them.
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("MacPlayer: applicationDidFinishLaunching")
        let controller = PlayerWindowController()
        self.windowController = controller
        controller.showWindow(nil)
        NSLog("MacPlayer: window shown")
        buildMenu()
        if !pendingURLs.isEmpty {
            let urls = pendingURLs
            pendingURLs.removeAll()
            controller.open(urls: urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // v1.0.8 crash: the plural openFiles: [String] force-casts the
    // NSArray AppKit delivers to [String], but on macOS 13 AppKit
    // passes NSURL objects, so the cast aborts in
    // _unconditionallyBridgeFromObjectiveC before any of our code
    // runs. IINA uses the singular openFile: instead, and the modern
    // application(_:open:) bridges safely because NSURL bridges to
    // URL. (Spelled `open urls:` in Swift — `openURLs:` was renamed
    // in Swift 3; using the old spelling is a compile error.)
    // Never re-add the plural openFiles: [String] form — the CI
    // guard in build.sh fails the build if it reappears.
    func application(_ sender: NSApplication, open urls: [URL]) {
        guard let controller = windowController else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        controller.open(urls: urls)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        guard let controller = windowController else {
            pendingURLs.append(url)
            return true
        }
        controller.open(urls: [url])
        return true
    }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "关于 MacPlayer", action: #selector(showAbout), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "退出 MacPlayer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(NSMenuItem(title: "打开文件…", action: #selector(PlayerWindowController.openFile(_:)), keyEquivalent: "o"))
        fileMenu.addItem(NSMenuItem(title: "打开文件夹…", action: #selector(PlayerWindowController.openFolder(_:)), keyEquivalent: "O"))
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let subtitleMenuItem = NSMenuItem()
        let subtitleMenu = NSMenu(title: "字幕")
        subtitleMenu.addItem(NSMenuItem(title: "在线搜索字幕…", action: #selector(PlayerWindowController.searchSubtitlesOnline(_:)), keyEquivalent: ""))
        subtitleMenu.addItem(NSMenuItem(title: "加载本地字幕…", action: #selector(PlayerWindowController.loadLocalSubtitle(_:)), keyEquivalent: ""))
        subtitleMenu.addItem(NSMenuItem(title: "关闭字幕", action: #selector(PlayerWindowController.disableSubtitle(_:)), keyEquivalent: ""))
        subtitleMenuItem.submenu = subtitleMenu
        mainMenu.addItem(subtitleMenuItem)

        NSApplication.shared.mainMenu = mainMenu
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "MacPlayer 1.0.0"
        alert.informativeText = "基于 LGPL 构建的 libmpv 的开源播放器（Apple Silicon arm64）。\n与 PotPlayer / Kakao 无任何关联。"
        alert.runModal()
    }

    @objc private func showSettings() {
        windowController?.showSettings()
    }
}
