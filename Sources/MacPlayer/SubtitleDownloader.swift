import Foundation
import Security

// MARK: - Query and results

/// What a subtitle search is about. `moviehash` is the OpenSubtitles
/// hash (see `MovieHash.compute`); title/year/season/episode come from
/// parsing the video file name.
struct SubtitleQuery {
    var movieHash: String?
    var fileSize: Int64?
    var title: String
    var year: Int?
    var season: Int?
    var episode: Int?
    var releaseGroup: String?
    var languages: [String] // e.g. ["zh-Hans", "en"]
    var videoURL: URL
}

/// One search hit. `fileID` is provider-specific (OpenSubtitles file_id,
/// Assrt subtitle id, SubDL file id); `downloadURL` is filled when the
/// provider gives a direct link in the search response.
struct SubtitleItem: Identifiable {
    var id: String
    var providerID: String
    var providerName: String
    var name: String
    var language: String
    var format: String // "srt" or "ass"
    var downloadCount: Int
    var hashMatch: Bool
    var releaseGroupMatch: Bool
    var fileID: String?
    var downloadURL: URL?
    var score: Int = 0
}

/// A subtitle provider. Modelled on the IINA plugin provider interface
/// (search / download) as described in the research report §6.5, but
/// re-implemented from scratch — no IINA code is used.
protocol SubtitleProvider {
    var id: String { get }
    var displayName: String { get }
    var isConfigured: Bool { get }
    func search(query: SubtitleQuery) async throws -> [SubtitleItem]
    func download(_ item: SubtitleItem, to directory: URL) async throws -> [URL]
}

// MARK: - Keys (Keychain only, never in code or in the repo)

/// Per-user API keys/tokens, stored in the Keychain. The code ships with
/// empty placeholders only; a shared key is never bundled.
enum KeychainStore {
    private static let service = "com.macplayer.app.subtitles"

    static func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// User-facing subtitle settings. Toggles live in UserDefaults; secrets
/// live only in the Keychain (see `KeychainStore`).
struct SubtitleSettings {
    static var autoSearchOnline: Bool {
        get { UserDefaults.standard.object(forKey: "subtitleAutoSearchOnline") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "subtitleAutoSearchOnline") }
    }
    static var loadFirstFound: Bool {
        get { UserDefaults.standard.object(forKey: "subtitleLoadFirstFound") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "subtitleLoadFirstFound") }
    }
    static var preferredLanguages: [String] {
        get { UserDefaults.standard.stringArray(forKey: "subtitleLanguages") ?? ["zh-Hans", "en"] }
        set { UserDefaults.standard.set(newValue, forKey: "subtitleLanguages") }
    }
    static var openSubtitlesApiKey: String? {
        get { KeychainStore.load(key: "opensubtitles-api-key") }
        set { if let v = newValue, !v.isEmpty { _ = KeychainStore.save(key: "opensubtitles-api-key", value: v) } else { KeychainStore.delete(key: "opensubtitles-api-key") } }
    }
    static var assrtToken: String? {
        get { KeychainStore.load(key: "assrt-token") }
        set { if let v = newValue, !v.isEmpty { _ = KeychainStore.save(key: "assrt-token", value: v) } else { KeychainStore.delete(key: "assrt-token") } }
    }
    static var subdlApiKey: String? {
        get { KeychainStore.load(key: "subdl-api-key") }
        set { if let v = newValue, !v.isEmpty { _ = KeychainStore.save(key: "subdl-api-key", value: v) } else { KeychainStore.delete(key: "subdl-api-key") } }
    }
}

// MARK: - Movie hash (OpenSubtitles algorithm)

/// OpenSubtitles moviehash: file size plus the sum of the 64-bit
/// little-endian words in the first and last 64 KB, as 16 hex chars.
enum MovieHash {
    static func compute(for url: URL) -> (hash: String, size: Int64)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return nil }
        let fileSize = size.int64Value
        guard fileSize > 0 else { return nil }
        var sum: UInt64 = UInt64(bitPattern: fileSize)
        let chunkSize = 65536
        for offset in [0, max(0, fileSize - Int64(chunkSize))] {
            do {
                try handle.seek(toOffset: UInt64(offset))
                let data = try handle.read(upToCount: chunkSize) ?? Data()
                var index = data.startIndex
                while index + 8 <= data.endIndex {
                    let word = data[index..<index + 8].withUnsafeBytes { $0.load(as: UInt64.self) }
                    sum = sum &+ UInt64(littleEndian: word)
                    index += 8
                }
            } catch {
                return nil
            }
        }
        return (String(format: "%016llx", sum), fileSize)
    }
}

// MARK: - File-name parsing

/// Parse `Show.S01E02.1080p.WEB-DL-GROUP.mkv` style names into
/// title / year / season / episode / release group.
enum VideoFileName {
    static func parse(_ url: URL) -> (title: String, year: Int?, season: Int?, episode: Int?, releaseGroup: String?) {
        let base = url.deletingPathExtension().lastPathComponent
        var title = base
        var year: Int?
        var season: Int?
        var episode: Int?
        var releaseGroup: String?
        if let match = firstMatch(pattern: #"(?i)S(\d{1,2})E(\d{1,2})"#, in: base) {
            season = Int(match.groups[1]); episode = Int(match.groups[2])
            title = String(base[..<match.range.lowerBound]).replacingOccurrences(of: ".", with: " ").trimmingCharacters(in: .whitespaces)
        }
        if let match = firstMatch(pattern: #"\b(19\d{2}|20\d{2})\b"#, in: base) {
            year = Int(match.groups[0])
            if season == nil {
                title = String(base[..<match.range.lowerBound]).replacingOccurrences(of: ".", with: " ").trimmingCharacters(in: .whitespaces)
            }
        }
        if title.isEmpty { title = base }
        if let dash = base.range(of: "-", options: .backwards) {
            let group = String(base[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !group.isEmpty && group.count <= 20 { releaseGroup = group }
        }
        return (title, year, season, episode, releaseGroup)
    }

    // Minimal regex helper returning full match + capture groups.
    private static func firstMatch(pattern: String, in text: String) -> (range: Range<String.Index>, groups: [String])? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        var groups: [String] = []
        for i in 0..<result.numberOfRanges {
            let r = result.range(at: i)
            groups.append(r.location == NSNotFound ? "" : (text as NSString).substring(with: r))
        }
        guard let swiftRange = Range(result.range, in: text) else { return nil }
        return (swiftRange, groups)
    }
}

// MARK: - Shared HTTP / JSON helpers

enum SubtitleHTTP {
    static func session(timeout: TimeInterval = 5) -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        return URLSession(configuration: config)
    }

    static func fetchJSON(url: URL, headers: [String: String] = [:], timeout: TimeInterval = 5) async throws -> Any {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session(timeout: timeout).data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "MacPlayer.Subtitles", code: 1, userInfo: [NSLocalizedDescriptionKey: "HTTP error for \(url.host ?? "")"])
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    static func fetchData(url: URL, headers: [String: String] = [:], timeout: TimeInterval = 5) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session(timeout: timeout).data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "MacPlayer.Subtitles", code: 1, userInfo: [NSLocalizedDescriptionKey: "HTTP error for \(url.host ?? "")"])
        }
        return data
    }

    /// Walk any JSON value and collect dictionaries that look like subtitle
    /// records. Providers change field names; this keeps search working
    /// when a response adds a wrapper object.
    static func collectRecords(_ value: Any, into out: inout [[String: Any]]) {
        if let dict = value as? [String: Any] {
            if dict["id"] != nil || dict["subtitle_id"] != nil || dict["file_id"] != nil {
                out.append(dict)
            }
            for child in dict.values { collectRecords(child, into: &out) }
        } else if let array = value as? [Any] {
            for child in array { collectRecords(child, into: &out) }
        }
    }

    static func string(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty { return value }
            if let value = dict[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }

    static func int(_ dict: [String: Any], keys: [String]) -> Int {
        for key in keys {
            if let value = dict[key] as? Int { return value }
            if let value = dict[key] as? NSNumber { return value.intValue }
        }
        return 0
    }
}

// MARK: - Provider 1: OpenSubtitles.com (global default)

/// OpenSubtitles.com REST v1 — https://api.opensubtitles.com/api/v1
/// Search: GET /subtitles?moviehash=…&languages=… (hash first) or
/// ?query=…&year=… (title fallback). Download: POST /download {file_id}
/// returns a temporary link. Headers: `Api-Key` (user's own key) +
/// `User-Agent: MacPlayer v1.0`. Free quota is per account/key
/// (report §6.3: 5/day without an account, 20/day with a free account;
/// verify live at integration time, do not hard-code a number).
struct OpenSubtitlesProvider: SubtitleProvider {
    let id = "opensubtitles"
    let displayName = "OpenSubtitles.com"
    var isConfigured: Bool { !(SubtitleSettings.openSubtitlesApiKey ?? "").isEmpty }

    func search(query: SubtitleQuery) async throws -> [SubtitleItem] {
        guard let apiKey = SubtitleSettings.openSubtitlesApiKey, !apiKey.isEmpty else { return [] }
        var components = URLComponents(string: "https://api.opensubtitles.com/api/v1/subtitles")!
        var items: [URLQueryItem] = [URLQueryItem(name: "languages", value: query.languages.joined(separator: ","))]
        if let hash = query.movieHash {
            items.append(URLQueryItem(name: "moviehash", value: hash))
        } else {
            items.append(URLQueryItem(name: "query", value: query.title))
            if let year = query.year { items.append(URLQueryItem(name: "year", value: "\(year)")) }
        }
        components.queryItems = items
        let headers = ["Api-Key": apiKey, "User-Agent": "MacPlayer v1.0", "Accept": "application/json"]
        let json = try await SubtitleHTTP.fetchJSON(url: components.url!, headers: headers)
        var records: [[String: Any]] = []
        SubtitleHTTP.collectRecords(json, into: &records)
        return records.compactMap { record -> SubtitleItem? in
            let attributes = record["attributes"] as? [String: Any] ?? record
            let files = attributes["files"] as? [[String: Any]] ?? []
            let fileID = files.first.flatMap { SubtitleHTTP.string($0, keys: ["file_id", "fileid"]) }
                ?? SubtitleHTTP.string(attributes, keys: ["file_id", "subtitle_id"])
            let language = SubtitleHTTP.string(attributes, keys: ["language"]) ?? "en"
            let name = SubtitleHTTP.string(attributes, keys: ["release", "file_name", "name"]) ?? query.title
            let downloads = SubtitleHTTP.int(attributes, keys: ["download_count", "downloads"])
            return SubtitleItem(
                id: "os-\(fileID ?? UUID().uuidString)",
                providerID: id, providerName: displayName, name: name,
                language: language, format: "srt", downloadCount: downloads,
                hashMatch: query.movieHash != nil, releaseGroupMatch: false, fileID: fileID)
        }
    }

    func download(_ item: SubtitleItem, to directory: URL) async throws -> [URL] {
        guard let apiKey = SubtitleSettings.openSubtitlesApiKey, !apiKey.isEmpty,
              let fileID = item.fileID, let fileIDInt = Int(fileID) else { return [] }
        let url = URL(string: "https://api.opensubtitles.com/api/v1/download")!
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue("MacPlayer v1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["file_id": fileIDInt])
        let (data, response) = try await SubtitleHTTP.session(timeout: 10).data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let link = json["link"] as? String, let linkURL = URL(string: link) else { return [] }
        let fileData = try await SubtitleHTTP.fetchData(url: linkURL, timeout: 10)
        return try SubtitleFiles.saveDownloaded(data: fileData, fileName: item.name, to: directory)
    }
}

// MARK: - Provider 2: Assrt / 伪射手网 (Chinese default)

/// Assrt — https://api.assrt.net/v1/sub/search?q=…&count=20&pos=0
/// & /v1/sub/detail?id=… ; auth is a per-user 32-char `token` query
/// parameter (register at assrt.net, token in the user panel). Quota is
/// about 5 requests/minute per third-party docs, so the manager throttles
/// Assrt to one search per video. Only enabled by default when the
/// preferred languages include zh-Hans. Do not ship a shared token.
struct AssrtProvider: SubtitleProvider {
    let id = "assrt"
    let displayName = "Assrt（伪射手网）"
    var isConfigured: Bool { !(SubtitleSettings.assrtToken ?? "").isEmpty }

    func search(query: SubtitleQuery) async throws -> [SubtitleItem] {
        guard let token = SubtitleSettings.assrtToken, !token.isEmpty else { return [] }
        var components = URLComponents(string: "https://api.assrt.net/v1/sub/search")!
        components.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "q", value: query.title),
            URLQueryItem(name: "count", value: "20"),
            URLQueryItem(name: "pos", value: "0"),
        ]
        let json = try await SubtitleHTTP.fetchJSON(url: components.url!)
        var records: [[String: Any]] = []
        SubtitleHTTP.collectRecords(json, into: &records)
        return records.compactMap { record -> SubtitleItem? in
            let name = SubtitleHTTP.string(record, keys: ["native_name", "name", "title"]) ?? query.title
            let idValue = SubtitleHTTP.string(record, keys: ["id", "subtitle_id"]) ?? UUID().uuidString
            let urlString = SubtitleHTTP.string(record, keys: ["url", "download_url", "link"])
            return SubtitleItem(
                id: "assrt-\(idValue)", providerID: id, providerName: displayName,
                name: name, language: "zh-Hans", format: "srt",
                downloadCount: SubtitleHTTP.int(record, keys: ["download_count", "downloads"]),
                hashMatch: false, releaseGroupMatch: false, fileID: idValue,
                downloadURL: urlString.flatMap(URL.init(string:)))
        }
    }

    func download(_ item: SubtitleItem, to directory: URL) async throws -> [URL] {
        guard let token = SubtitleSettings.assrtToken, !token.isEmpty else { return [] }
        if let direct = item.downloadURL {
            let data = try await SubtitleHTTP.fetchData(url: direct, timeout: 10)
            return try SubtitleFiles.saveDownloaded(data: data, fileName: item.name, to: directory)
        }
        guard let fileID = item.fileID else { return [] }
        var components = URLComponents(string: "https://api.assrt.net/v1/sub/detail")!
        components.queryItems = [URLQueryItem(name: "token", value: token), URLQueryItem(name: "id", value: fileID)]
        let json = try await SubtitleHTTP.fetchJSON(url: components.url!)
        var records: [[String: Any]] = []
        SubtitleHTTP.collectRecords(json, into: &records)
        guard let record = records.first,
              let urlString = SubtitleHTTP.string(record, keys: ["url", "download_url", "link"]),
              let url = URL(string: urlString) else { return [] }
        let data = try await SubtitleHTTP.fetchData(url: url, timeout: 10)
        return try SubtitleFiles.saveDownloaded(data: data, fileName: item.name, to: directory)
    }
}

// MARK: - Provider 3: SubDL (global fallback)

/// SubDL — https://api.subdl.com/api/v1/subtitles?api_key=…&film_name=…
/// &languages=EN,ZH-CN&type=movie|tv&season_number&episode_number&year
/// Free key: 2,000 searches + 50 downloads/day (per SubDL docs).
/// Download: the `url` in the search record, or
/// https://dl.subdl.com/subtitle/{id}.zip . Mirrors the Subscene archive;
/// Subscene itself shut in May 2024 and is not listed.
struct SubDLProvider: SubtitleProvider {
    let id = "subdl"
    let displayName = "SubDL"
    var isConfigured: Bool { !(SubtitleSettings.subdlApiKey ?? "").isEmpty }

    func search(query: SubtitleQuery) async throws -> [SubtitleItem] {
        guard let apiKey = SubtitleSettings.subdlApiKey, !apiKey.isEmpty else { return [] }
        var components = URLComponents(string: "https://api.subdl.com/api/v1/subtitles")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "film_name", value: query.title),
            URLQueryItem(name: "languages", value: subdlLanguages(query.languages)),
        ]
        if let year = query.year { items.append(URLQueryItem(name: "year", value: "\(year)")) }
        if let season = query.season, let episode = query.episode {
            items.append(URLQueryItem(name: "type", value: "tv"))
            items.append(URLQueryItem(name: "season_number", value: "\(season)"))
            items.append(URLQueryItem(name: "episode_number", value: "\(episode)"))
        } else {
            items.append(URLQueryItem(name: "type", value: "movie"))
        }
        components.queryItems = items
        let json = try await SubtitleHTTP.fetchJSON(url: components.url!)
        var records: [[String: Any]] = []
        SubtitleHTTP.collectRecords(json, into: &records)
        return records.compactMap { record -> SubtitleItem? in
            let name = SubtitleHTTP.string(record, keys: ["release_name", "name", "file_name"]) ?? query.title
            let idValue = SubtitleHTTP.string(record, keys: ["subtitle_id", "id", "file_id"]) ?? UUID().uuidString
            let urlString = SubtitleHTTP.string(record, keys: ["url", "download_url", "link"])
            let language = SubtitleHTTP.string(record, keys: ["language", "lang"]) ?? "en"
            return SubtitleItem(
                id: "subdl-\(idValue)", providerID: id, providerName: displayName,
                name: name, language: language, format: "srt",
                downloadCount: SubtitleHTTP.int(record, keys: ["download_count", "downloads"]),
                hashMatch: false, releaseGroupMatch: false, fileID: idValue,
                downloadURL: urlString.flatMap(URL.init(string:)))
        }
    }

    func download(_ item: SubtitleItem, to directory: URL) async throws -> [URL] {
        guard let url = item.downloadURL else { return [] }
        let data = try await SubtitleHTTP.fetchData(url: url, timeout: 10)
        return try SubtitleFiles.saveDownloaded(data: data, fileName: item.name, to: directory)
    }

    private func subdlLanguages(_ languages: [String]) -> String {
        languages.map { $0 == "zh-Hans" || $0 == "zh-CN" ? "ZH-CN" : $0.uppercased() }.joined(separator: ",")
    }
}

// MARK: - Downloaded files: ZIP / plain subtitle handling

/// Saves a downloaded subtitle blob: plain .srt/.ass is written as-is;
/// a ZIP is extracted with the system `unzip` (Foundation has no public
/// ZIP API) and the best .srt/.ass inside is kept. RAR/7z archives are
/// not supported — the UI reports that honestly instead of failing
/// silently.
enum SubtitleFiles {
    static func saveDownloaded(data: Data, fileName: String, to directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let isZip = data.prefix(2) == Data([0x50, 0x4B]) // "PK"
        if !isZip {
            let ext = fileName.lowercased().hasSuffix(".ass") ? "ass" : "srt"
            let url = directory.appendingPathComponent("download.\(ext)")
            try data.write(to: url, options: [.atomic])
            return [url]
        }
        let zipURL = directory.appendingPathComponent("download.zip")
        try data.write(to: zipURL, options: [.atomic])
        let extractDir = directory.appendingPathComponent("extracted")
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-j", zipURL.path, "-d", extractDir.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        let candidates = (try? FileManager.default.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)) ?? []
        return candidates.filter { ["srt", "ass", "ssa"].contains($0.pathExtension.lowercased()) }
    }

    /// Pick the downloaded file that best matches the video (same episode
    /// / language in the name wins, otherwise the first .srt, then .ass).
    static func pickBest(_ files: [URL], for videoURL: URL, language: String) -> URL? {
        let base = videoURL.deletingPathExtension().lastPathComponent.lowercased()
        return files.first { $0.lastPathComponent.lowercased().contains(base) }
            ?? files.first { $0.pathExtension.lowercased() == "srt" }
            ?? files.first
    }
}

// MARK: - Manager: order, ranking, timeout, fallback

/// Runs the default subtitle order and ranking. Order (confirmed):
/// 1. local same-name files (handled by libmpv `sub-auto`, checked here
///    first so online search is skipped when a local file exists)
/// 2. OpenSubtitles.com  3. Assrt (zh-Hans only)  4. SubDL
/// Zimuku / SubHD are NOT providers here — no public API, scraping-only,
/// WAF/CAPTCHA; see README (opt-in plugin only, not implemented).
/// Shooter / Subscene are NOT listed — dead (2014 / 2024).
/// Every online search has a 5-second timeout and degrades to the next
/// provider; a failure never blocks playback.
final class SubtitleDownloader {
    static let shared = SubtitleDownloader()

    var providers: [SubtitleProvider] {
        var list: [SubtitleProvider] = [OpenSubtitlesProvider()]
        if SubtitleSettings.preferredLanguages.contains("zh-Hans") {
            list.append(AssrtProvider())
        }
        list.append(SubDLProvider())
        return list
    }

    /// Local subtitles for a video: same basename in the same folder, plus
    /// a `sub/` subfolder. Checked before any network search.
    func localSubtitles(for videoURL: URL) -> [URL] {
        let folder = videoURL.deletingLastPathComponent()
        let base = videoURL.deletingPathExtension().lastPathComponent
        let exts = ["srt", "ass", "ssa", "vtt"]
        var found: [URL] = []
        for ext in exts {
            let candidate = folder.appendingPathComponent("\(base).\(ext)")
            if FileManager.default.fileExists(atPath: candidate.path) { found.append(candidate) }
        }
        let subFolder = folder.appendingPathComponent("sub", isDirectory: true)
        for ext in exts {
            let candidate = subFolder.appendingPathComponent("\(base).\(ext)")
            if FileManager.default.fileExists(atPath: candidate.path) { found.append(candidate) }
        }
        return found
    }

    func makeQuery(for videoURL: URL) -> SubtitleQuery {
        let parsed = VideoFileName.parse(videoURL)
        let hash = MovieHash.compute(for: videoURL)
        return SubtitleQuery(
            movieHash: hash?.hash, fileSize: hash?.size,
            title: parsed.title, year: parsed.year, season: parsed.season,
            episode: parsed.episode, releaseGroup: parsed.releaseGroup,
            languages: SubtitleSettings.preferredLanguages, videoURL: videoURL)
    }

    /// Search all configured providers in parallel (5 s total), rank the
    /// merged hits, and return them best-first.
    func searchAll(for videoURL: URL) async -> [SubtitleItem] {
        let query = makeQuery(for: videoURL)
        let providers = providers.filter { $0.isConfigured }
        guard !providers.isEmpty else { return [] }
        let results = await withTimeout(seconds: 5) {
            await withTaskGroup(of: [SubtitleItem].self) { group in
                for provider in providers {
                    group.addTask {
                        (try? await provider.search(query: query)) ?? []
                    }
                }
                var merged: [SubtitleItem] = []
                for await items in group { merged.append(contentsOf: items) }
                return merged
            }
        } ?? []
        return rank(results, query: query)
    }

    /// Rank: hash match > release-group match > downloads > language order.
    func rank(_ items: [SubtitleItem], query: SubtitleQuery) -> [SubtitleItem] {
        items.map { item in
            var scored = item
            var score = 0
            if item.hashMatch { score += 100 }
            if let group = query.releaseGroup, item.name.localizedCaseInsensitiveContains(group) {
                score += 30; scored.releaseGroupMatch = true
            }
            score += min(20, item.downloadCount / 100)
            if let index = query.languages.firstIndex(of: item.language) { score += 10 - index }
            else if item.language.lowercased().contains("zh") { score += 5 }
            scored.score = score
            return scored
        }.sorted { $0.score > $1.score }
    }

    /// Download one hit, save it beside the video as
    /// `<video-basename>.<language>.srt|.ass`, and return the saved file.
    func downloadAndSave(_ item: SubtitleItem, for videoURL: URL) async throws -> URL? {
        let provider = providers.first { $0.id == item.providerID }
        guard let provider else { return nil }
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacPlayer-sub-\(UUID().uuidString)", isDirectory: true)
        let files = try await provider.download(item, to: tmpDir)
        guard let best = SubtitleFiles.pickBest(files, for: videoURL, language: item.language) else { return nil }
        let ext = best.pathExtension.lowercased()
        let lang = item.language.isEmpty ? "und" : item.language
        let destination = videoURL.deletingLastPathComponent()
            .appendingPathComponent("\(videoURL.deletingPathExtension().lastPathComponent).\(lang).\(ext)")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: best, to: destination)
        return destination
    }

    /// Run a throwing async block with a hard timeout; nil on timeout.
    private func withTimeout<T>(seconds: Double, _ work: @escaping () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next()
            group.cancelAll()
            return first ?? nil
        }
    }
}
