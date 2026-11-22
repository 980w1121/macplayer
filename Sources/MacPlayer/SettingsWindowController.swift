import AppKit
import Foundation

/// Settings window: subtitle API keys (Keychain) and subtitle behaviour.
/// Keys are per-user; the app ships with empty fields only and never
/// bundles a shared key. Registration pages are named by domain only.
final class SettingsWindowController: NSWindowController {
    private let openSubtitlesField = NSSecureTextField()
    private let assrtField = NSSecureTextField()
    private let subdlField = NSSecureTextField()
    private let autoSearchCheckbox = NSButton(checkboxWithTitle: "打开视频时自动在线搜索字幕（无本地字幕时）", target: nil, action: nil)
    private let loadFirstCheckbox = NSButton(checkboxWithTitle: "找到唯一精确匹配时自动加载第一个", target: nil, action: nil)

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 560, height: 340),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "MacPlayer 设置"
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { nil }

    private func labeledRow(label: String, field: NSTextField, hint: String) -> NSStackView {
        let title = NSTextField(labelWithString: label)
        title.font = .boldSystemFont(ofSize: 12)
        let help = NSTextField(labelWithString: hint)
        help.textColor = .secondaryLabelColor
        help.font = .systemFont(ofSize: 11)
        let stack = NSStackView(views: [title, field, help])
        stack.orientation = .vertical
        stack.spacing = 4
        return stack
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        openSubtitlesField.stringValue = SubtitleSettings.openSubtitlesApiKey ?? ""
        assrtField.stringValue = SubtitleSettings.assrtToken ?? ""
        subdlField.stringValue = SubtitleSettings.subdlApiKey ?? ""
        autoSearchCheckbox.state = SubtitleSettings.autoSearchOnline ? .on : .off
        loadFirstCheckbox.state = SubtitleSettings.loadFirstFound ? .on : .off

        let saveButton = NSButton(title: "保存", target: self, action: #selector(save(_:)))
        saveButton.bezelStyle = .rounded
        let note = NSTextField(labelWithString: "字幕源顺序：本地同名 → OpenSubtitles.com → Assrt（仅中文）→ SubDL。\nZimuku / SubHD 没有公开接口，不在默认源里；射手网、Subscene 已停运，不列入。\n密钥只存在本机钥匙串，不会写入仓库或上传。")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)

        let stack = NSStackView(views: [
            labeledRow(label: "OpenSubtitles.com API Key", field: openSubtitlesField, hint: "在 opensubtitles.com 注册为 API 消费者后获取"),
            labeledRow(label: "Assrt（伪射手网）Token", field: assrtField, hint: "在 assrt.net 注册后，在用户中心获取 32 位 token"),
            labeledRow(label: "SubDL API Key", field: subdlField, hint: "在 subdl.com 账号面板获取免费 key"),
            autoSearchCheckbox, loadFirstCheckbox, note, saveButton,
        ])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    @objc private func save(_ sender: Any?) {
        SubtitleSettings.openSubtitlesApiKey = openSubtitlesField.stringValue.isEmpty ? nil : openSubtitlesField.stringValue
        SubtitleSettings.assrtToken = assrtField.stringValue.isEmpty ? nil : assrtField.stringValue
        SubtitleSettings.subdlApiKey = subdlField.stringValue.isEmpty ? nil : subdlField.stringValue
        SubtitleSettings.autoSearchOnline = autoSearchCheckbox.state == .on
        SubtitleSettings.loadFirstFound = loadFirstCheckbox.state == .on
        window?.close()
    }
}

// MARK: - Online subtitle search window

/// Ranked online-subtitle results for the current video. The user picks
/// one; it is downloaded, saved beside the video, and loaded via libmpv.
/// Nothing is auto-downloaded without a pick, unless the user enabled
/// "load first found" in Settings (handled in the main window).
final class SubtitleSearchController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let videoURL: URL
    private weak var player: MPVPlayer?
    private let table = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "点击“搜索”开始")
    private var results: [SubtitleItem] = []

    init(videoURL: URL, player: MPVPlayer?) {
        self.videoURL = videoURL
        self.player = player
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 200, width: 640, height: 400),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "在线搜索字幕 — \(videoURL.lastPathComponent)"
        super.init(window: window)
        buildUI()
    }

    required init?(coder: NSCoder) { nil }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let searchButton = NSButton(title: "搜索", target: self, action: #selector(search(_:)))
        let loadButton = NSButton(title: "下载并加载所选", target: self, action: #selector(loadSelected(_:)))
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "字幕"
        nameColumn.width = 380
        let providerColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("provider"))
        providerColumn.title = "来源"
        providerColumn.width = 140
        let langColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("language"))
        langColumn.title = "语言"
        langColumn.width = 80
        table.addTableColumn(nameColumn)
        table.addTableColumn(providerColumn)
        table.addTableColumn(langColumn)
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(loadSelected(_:))

        let buttons = NSStackView(views: [searchButton, loadButton, statusLabel])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        let stack = NSStackView(views: [scroll, buttons])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    @objc private func search(_ sender: Any?) {
        statusLabel.stringValue = "搜索中（5 秒超时，失败自动降级）…"
        Task { [weak self] in
            guard let self else { return }
            let found = await SubtitleDownloader.shared.searchAll(for: self.videoURL)
            await MainActor.run {
                self.results = found
                self.table.reloadData()
                self.statusLabel.stringValue = found.isEmpty
                    ? "没有找到字幕：请检查各源的 key 是否已在设置里填写，或换一个片名再试"
                    : "找到 \(found.count) 个，按匹配度排序"
            }
        }
    }

    @objc private func loadSelected(_ sender: Any?) {
        let row = table.selectedRow
        guard results.indices.contains(row) else { return }
        let item = results[row]
        statusLabel.stringValue = "下载中…"
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let saved = try await SubtitleDownloader.shared.downloadAndSave(item, for: self.videoURL) else {
                    await MainActor.run { self.statusLabel.stringValue = "下载失败：该源未返回可用文件" }
                    return
                }
                await MainActor.run {
                    self.player?.addSubtitle(url: saved)
                    self.statusLabel.stringValue = "已加载：\(saved.lastPathComponent)"
                }
            } catch {
                await MainActor.run { self.statusLabel.stringValue = "下载失败：\(error.localizedDescription)" }
            }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = results[row]
        switch tableColumn?.identifier.rawValue {
        case "provider": return NSTextField(labelWithString: item.providerName)
        case "language": return NSTextField(labelWithString: item.language)
        default: return NSTextField(labelWithString: item.name)
        }
    }
}
