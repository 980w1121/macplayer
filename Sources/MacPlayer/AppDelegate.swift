import AppKit
import Foundation

/// Application delegate: owns the main window and the menu bar.
/// No document model, no SwiftUI scene, no network work at launch.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: PlayerWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = PlayerWindowController()
        self.windowController = controller
        controller.showWindow(nil)
        buildMenu()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // v1.0.8 crash: the plural openFiles: [String] force-casts the
    // NSArray AppKit delivers to [String], but on macOS 13 AppKit
    // passes NSURL objects, so the cast aborts in
    // _unconditionallyBridgeFromObjectiveC before any of our code
    // runs. IINA uses the singular openFile: instead, and the modern
    // openURLs: [URL] bridges safely because NSURL bridges to URL.
    // Never re-add the plural openFiles: [String] form — the CI
    // guard in build.sh fails the build if it reappears.
    func application(_ sender: NSApplication, openURLs urls: [URL]) {
        windowController?.open(urls: urls)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        windowController?.open(urls: [URL(fileURLWithPath: filename)])
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
