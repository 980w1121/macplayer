import AppKit
import Foundation

// MARK: - Video view (drag & drop target for libmpv `wid`)

/// Plain layer-backed view that libmpv renders into via `wid`, and that
/// accepts dropped media files. It draws nothing itself.
final class VideoView: NSView {
    var onDropURLs: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else { return false }
        onDropURLs?(urls)
        return true
    }
}

// MARK: - Main window

/// Main window: video area, left playlist, bottom control bar, status line.
/// AppKit only. Playback, subtitles and screenshots all go through
/// `MPVPlayer`; this class owns no decoding.
final class PlayerWindowController: NSWindowController, MPVPlayerDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let videoView = VideoView(frame: .zero)
    private let playlistTable = NSTableView()
    private let playPauseButton = NSButton(title: "▶", target: nil, action: nil)
    private let prevButton = NSButton(title: "⏮", target: nil, action: nil)
    private let nextButton = NSButton(title: "⏭", target: nil, action: nil)
    private let seekSlider = NSSlider(value: 0, minValue: 0, maxValue: 1000, target: nil, action: nil)
    private let timeLabel = NSTextField(labelWithString: "00:00 / 00:00")
    private let volumeSlider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let speedPopup = NSPopUpButton()
    private let subtitleButton = NSButton(title: "字幕", target: nil, action: nil)
    private let screenshotButton = NSButton(title: "截图", target: nil, action: nil)
    private let fullscreenButton = NSButton(title: "全屏", target: nil, action: nil)
    private let openButton = NSButton(title: "打开", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "就绪")
    private let subtitleDelayLabel = NSTextField(labelWithString: "字幕延迟 0.0s")

    private var player: MPVPlayer?
    private var currentIndex: Int?
    private var isSeeking = false
    private var subtitleDelay: Double = 0
    private var settingsController: SettingsWindowController?
    private var subtitleSearchController: SubtitleSearchController?
    private var keyMonitor: Any?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 960, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "MacPlayer"
        window.minSize = NSSize(width: 960, height: 600)
        window.backgroundColor = NSColor(white: 0.08, alpha: 1)
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        ensurePlayer()
        installKeyMonitor()
    }

    // MARK: - UI

    private func buildUI() {
        guard let window, let content = window.contentView else { return }
        content.wantsLayer = true

        // Playlist sidebar (left).
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = playlistTable
        playlistTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title")))
        playlistTable.headerView = nil
        playlistTable.dataSource = self
        playlistTable.delegate = self
        playlistTable.target = self
        playlistTable.doubleAction = #selector(playlistDoubleClicked(_:))
        playlistTable.backgroundColor = NSColor(white: 0.12, alpha: 1)

        videoView.onDropURLs = { [weak self] urls in self?.open(urls: urls) }

        // Controls.
        playPauseButton.target = self; playPauseButton.action = #selector(togglePlayPause(_:))
        prevButton.target = self; prevButton.action = #selector(playPrevious(_:))
        nextButton.target = self; nextButton.action = #selector(playNext(_:))
        seekSlider.target = self; seekSlider.action = #selector(seekSliderChanged(_:))
        volumeSlider.target = self; volumeSlider.action = #selector(volumeChanged(_:))
        speedPopup.addItems(withTitles: ["0.25x", "0.5x", "0.75x", "1x", "1.25x", "1.5x", "1.75x", "2x"])
        speedPopup.selectItem(withTitle: "1x")
        speedPopup.target = self; speedPopup.action = #selector(speedChanged(_:))
        subtitleButton.target = self; subtitleButton.action = #selector(searchSubtitlesOnline(_:))
        screenshotButton.target = self; screenshotButton.action = #selector(takeScreenshot(_:))
        fullscreenButton.target = self; fullscreenButton.action = #selector(toggleFullscreen(_:))
        openButton.target = self; openButton.action = #selector(openFile(_:))

        for label in [timeLabel, statusLabel, subtitleDelayLabel] {
            label.textColor = .lightGray
            label.font = .systemFont(ofSize: 12)
        }
        timeLabel.alignment = .right

        let controls = NSStackView(views: [playPauseButton, prevButton, nextButton, seekSlider, timeLabel, volumeSlider, speedPopup, subtitleButton, screenshotButton, fullscreenButton, openButton])
        controls.orientation = .horizontal
        controls.spacing = 8
        controls.alignment = .centerY
        seekSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let statusRow = NSStackView(views: [statusLabel, subtitleDelayLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = 16

        let rightColumn = NSStackView(views: [videoView, controls, statusRow])
        rightColumn.orientation = .vertical
        rightColumn.spacing = 8
        rightColumn.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        let split = NSSplitView()
        split.isVertical = true
        split.addArrangedSubview(scroll)
        split.addArrangedSubview(rightColumn)
        split.setPosition(220, ofDividerAt: 0)
        split.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.topAnchor.constraint(equalTo: content.topAnchor),
            split.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        videoView.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, window.isKeyWindow else { return event }
            if self.window?.firstResponder is NSTextField { return event }
            switch event.keyCode {
            case 49: // Space
                self.togglePlayPause(nil); return nil
            case 123: // Left arrow
                self.player?.seekBy(seconds: -5); return nil
            case 124: // Right arrow
                self.player?.seekBy(seconds: 5); return nil
            case 126: // Up arrow
                self.player?.setVolume((self.player?.volume ?? 100) + 5); self.volumeSlider.doubleValue = self.player?.volume ?? 100; return nil
            case 125: // Down arrow
                self.player?.setVolume((self.player?.volume ?? 100) - 5); self.volumeSlider.doubleValue = self.player?.volume ?? 100; return nil
            default:
                break
            }
            if let chars = event.charactersIgnoringModifiers?.lowercased() {
                switch chars {
                case "f": self.toggleFullscreen(nil); return nil
                case "s": self.takeScreenshot(nil); return nil
                case "n": self.playNext(nil); return nil
                case "p": self.playPrevious(nil); return nil
                default: break
                }
            }
            return event
        }
    }

    // MARK: - Player

    private func ensurePlayer() {
        guard player == nil else { return }
        let mpv = MPVPlayer(videoView: videoView)
        mpv.delegate = self
        player = mpv
    }

    func open(urls: [URL]) {
        guard !urls.isEmpty else { return }
        ensurePlayer()
        let added = PlaylistStore.shared.add(urls: urls)
        playlistTable.reloadData()
        let first = added.first ?? urls.first
        if let first { play(url: first) }
    }

    private func play(url: URL) {
        ensurePlayer()
        currentIndex = PlaylistStore.shared.index(of: PlaylistItem(url: url))
        player?.load(url: url)
        player?.play()
        window?.title = "MacPlayer — \(url.lastPathComponent)"
        statusLabel.stringValue = "正在播放：\(url.lastPathComponent)"
        maybeAutoSearchSubtitles(for: url)
    }

    private func maybeAutoSearchSubtitles(for url: URL) {
        guard SubtitleSettings.autoSearchOnline else { return }
        guard SubtitleDownloader.shared.localSubtitles(for: url).isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            let results = await SubtitleDownloader.shared.searchAll(for: url)
            guard let first = results.first, SubtitleSettings.loadFirstFound else {
                if !results.isEmpty {
                    await MainActor.run { self.statusLabel.stringValue = "找到 \(results.count) 个在线字幕，点击“字幕”查看" }
                }
                return
            }
            if let saved = try? await SubtitleDownloader.shared.downloadAndSave(first, for: url) {
                await MainActor.run {
                    self.player?.addSubtitle(url: saved)
                    self.statusLabel.stringValue = "已自动加载字幕：\(saved.lastPathComponent)"
                }
            }
        }
    }

    // MARK: - MPVPlayerDelegate

    func player(_ player: MPVPlayer, didUpdateTime time: Double, duration: Double) {
        guard !isSeeking else { return }
        if duration > 0 {
            seekSlider.doubleValue = time / duration * 1000
        }
        timeLabel.stringValue = "\(formatTime(time)) / \(formatTime(duration))"
    }

    func player(_ player: MPVPlayer, didChangePaused paused: Bool) {
        playPauseButton.title = paused ? "▶" : "⏸"
    }

    func playerDidFinishFile(_ player: MPVPlayer) {
        playNext(nil)
    }

    func player(_ player: MPVPlayer, didUpdateHardwareDecode hwdec: String) {
        statusLabel.stringValue = "硬解：\(hwdec)"
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - Actions

    @objc func togglePlayPause(_ sender: Any?) { ensurePlayer(); player?.togglePlayPause() }

    @objc func playPrevious(_ sender: Any?) {
        guard let index = currentIndex, let prev = PlaylistStore.shared.previousIndex(before: index),
              let item = PlaylistStore.shared.item(at: prev) else { return }
        play(url: item.url)
    }

    @objc func playNext(_ sender: Any?) {
        guard let index = currentIndex, let next = PlaylistStore.shared.nextIndex(after: index),
              let item = PlaylistStore.shared.item(at: next) else { return }
        play(url: item.url)
    }

    @objc func seekSliderChanged(_ sender: Any?) {
        guard let player else { return }
        // mpv reports duration via the delegate; read it from the slider
        // position relative to the last known duration is not possible
        // here, so seek by fraction using the player's duration property.
        // `MPVPlayer.duration` is kept in sync by time-pos events.
        isSeeking = true
        player.seek(to: player.duration * seekSlider.doubleValue / 1000)
        isSeeking = false
    }

    @objc func volumeChanged(_ sender: Any?) {
        player?.setVolume(volumeSlider.doubleValue)
    }

    @objc func speedChanged(_ sender: Any?) {
        guard let title = speedPopup.selectedItem?.title else { return }
        player?.setSpeed(Double(title.dropLast()) ?? 1)
    }

    @objc func toggleFullscreen(_ sender: Any?) {
        window?.toggleFullScreen(sender)
    }

    @objc func takeScreenshot(_ sender: Any?) {
        guard let url = Screenshot.capture(from: player) else {
            statusLabel.stringValue = "截图失败：没有正在播放的视频"
            return
        }
        statusLabel.stringValue = "截图已保存：\(url.path)"
    }

    @objc func openFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedFileTypes = Array(MediaTypes.allExtensions)
        if panel.runModal() == .OK { open(urls: panel.urls) }
    }

    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { open(urls: panel.urls) }
    }

    @objc func searchSubtitlesOnline(_ sender: Any?) {
        guard let url = player?.currentURL else {
            statusLabel.stringValue = "先打开一个视频再搜索字幕"
            return
        }
        let controller = SubtitleSearchController(videoURL: url, player: player)
        subtitleSearchController = controller
        controller.showWindow(nil)
    }

    @objc func loadLocalSubtitle(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedFileTypes = ["srt", "ass", "ssa", "vtt"]
        if panel.runModal() == .OK, let url = panel.urls.first {
            player?.addSubtitle(url: url)
            statusLabel.stringValue = "已加载字幕：\(url.lastPathComponent)"
        }
    }

    @objc func disableSubtitle(_ sender: Any?) {
        player?.disableSubtitle()
        statusLabel.stringValue = "字幕已关闭"
    }

    func showSettings() {
        let controller = SettingsWindowController()
        settingsController = controller
        controller.showWindow(nil)
    }

    // MARK: - Playlist table

    func numberOfRows(in tableView: NSTableView) -> Int {
        PlaylistStore.shared.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = PlaylistStore.shared.item(at: row)
        let cell = NSTextField(labelWithString: item?.title ?? "")
        cell.textColor = row == currentIndex ? .systemBlue : .labelColor
        return cell
    }

    @objc func playlistDoubleClicked(_ sender: Any?) {
        let row = playlistTable.clickedRow
        guard let item = PlaylistStore.shared.item(at: row) else { return }
        play(url: item.url)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }
}
