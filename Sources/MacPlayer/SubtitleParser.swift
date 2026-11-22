import Foundation

/// One subtitle cue: a numbered time span and the text to show in it.
struct SubtitleCue {
    var index: Int
    var start: TimeInterval
    var end: TimeInterval
    var text: String

    func contains(_ time: TimeInterval) -> Bool {
        time >= start && time <= end
    }
}

/// A parsed external subtitle file: its display name, source file (nil for
/// embedded tracks) and its cues in time order.
struct SubtitleTrack {
    var name: String
    var url: URL?
    var cues: [SubtitleCue]

    /// The cue visible at a given playback time, if any.
    func cue(at time: TimeInterval) -> SubtitleCue? {
        cues.first { $0.contains(time) }
    }
}

/// Parses SRT and VTT subtitle files. Handles both timestamp spellings
/// (`00:01:23,456` in SRT and `00:01:23.456` in VTT), the shorter
/// `MM:SS.mmm` form, the `WEBVTT` header, cue identifiers and multi-line
/// cue text. Malformed lines are skipped instead of failing the whole file.
enum SubtitleParser {

    /// Parse a file from disk, choosing SRT or VTT by extension.
    /// Returns nil when the file cannot be read or has no usable cues.
    static func parse(url: URL) -> SubtitleTrack? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            // Retry as Latin-1 for files saved in a legacy encoding.
            guard let latin = try? String(contentsOf: url, encoding: .isoLatin1) else { return nil }
            return parse(contents: latin, name: url.lastPathComponent, url: url)
        }
        return parse(contents: contents, name: url.lastPathComponent, url: url)
    }

    static func parse(contents raw: String, name: String, url: URL? = nil) -> SubtitleTrack? {
        let isVTT = raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("WEBVTT")
        let cues = isVTT ? parseVTT(raw) : parseSRT(raw)
        guard !cues.isEmpty else { return nil }
        return SubtitleTrack(name: name, url: url, cues: cues)
    }

    // MARK: - SRT

    static func parseSRT(_ contents: String) -> [SubtitleCue] {
        let blocks = contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n\n")
        var cues: [SubtitleCue] = []
        var fallbackIndex = 0
        for block in blocks {
            let lines = block.components(separatedBy: "\n").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            guard !lines.isEmpty else { continue }
            var lineOffset = 0
            var index = fallbackIndex
            if let first = Int(lines[0]) {
                index = first
                lineOffset = 1
            }
            guard lines.count > lineOffset else { continue }
            let timingLine = lines[lineOffset]
            guard let (start, end) = parseTimingLine(timingLine) else { continue }
            let textLines = Array(lines.dropFirst(lineOffset + 1))
            guard !textLines.isEmpty else { continue }
            let text = stripFormatting(textLines.joined(separator: "\n"))
            cues.append(SubtitleCue(index: index, start: start, end: end, text: text))
            fallbackIndex += 1
        }
        return cues.sorted { $0.start < $1.start }
    }

    // MARK: - VTT

    static func parseVTT(_ contents: String) -> [SubtitleCue] {
        let normalized = contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        var cues: [SubtitleCue] = []
        var index = 0
        for block in blocks {
            let lines = block.components(separatedBy: "\n").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            guard !lines.isEmpty else { continue }
            // Skip the WEBVTT header, NOTE comments and STYLE/REGION blocks.
            if lines[0].hasPrefix("WEBVTT") || lines[0].hasPrefix("NOTE") { continue }
            if lines[0] == "STYLE" || lines[0] == "REGION" { continue }
            var lineOffset = 0
            // A VTT cue may start with an identifier line before the timing line.
            if !lines[0].contains("-->") {
                lineOffset = 1
                guard lines.count > 1 else { continue }
            }
            guard lines.count > lineOffset else { continue }
            let timingLine = lines[lineOffset]
            guard timingLine.contains("-->") else { continue }
            guard let (start, end) = parseTimingLine(timingLine) else { continue }
            let textLines = Array(lines.dropFirst(lineOffset + 1))
            guard !textLines.isEmpty else { continue }
            let text = stripFormatting(textLines.joined(separator: "\n"))
            cues.append(SubtitleCue(index: index, start: start, end: end, text: text))
            index += 1
        }
        return cues.sorted { $0.start < $1.start }
    }

    // MARK: - Timing

    /// Parse one timing line such as `00:01:23,456 --> 00:01:26,789` or
    /// `01:23.456 --> 01:26.789`. Trailing VTT settings after the end time
    /// (for example ` line:90%`) are ignored.
    static func parseTimingLine(_ line: String) -> (TimeInterval, TimeInterval)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        let startText = parts[0].trimmingCharacters(in: .whitespaces)
        let endToken = parts[1].trimmingCharacters(in: .whitespaces)
        let endText = endToken.components(separatedBy: .whitespaces).first ?? endToken
        guard let start = parseTimestamp(startText), let end = parseTimestamp(endText) else { return nil }
        guard end > start else { return nil }
        return (start, end)
    }

    /// Parse `HH:MM:SS,mmm`, `HH:MM:SS.mmm` or `MM:SS.mmm` into seconds.
    static func parseTimestamp(_ text: String) -> TimeInterval? {
        let normalized = text.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.components(separatedBy: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var values: [Double] = []
        for part in parts {
            guard let value = Double(part) else { return nil }
            values.append(value)
        }
        if values.count == 3 {
            return values[0] * 3600 + values[1] * 60 + values[2]
        }
        return values[0] * 60 + values[1]
    }

    // MARK: - Text cleanup

    /// Remove HTML-style tags (`<i>`, `<b>`, `<font ...>`, `{...}`) and
    /// VTT voice spans (`<v Speaker>`) so only readable text remains.
    static func stripFormatting(_ text: String) -> String {
        var result = text
        while let open = result.range(of: "<") {
            guard let close = result[open.lowerBound...].range(of: ">") else { break }
            result.removeSubrange(open.lowerBound...close.upperBound)
        }
        while let open = result.range(of: "{") {
            guard let close = result[open.lowerBound...].range(of: "}") else { break }
            result.removeSubrange(open.lowerBound...close.upperBound)
        }
        return result
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
