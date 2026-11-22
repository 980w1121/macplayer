import Foundation

/// Captures the current video frame as a PNG file via libmpv
/// (`screenshot-to-file`). AVFoundation is NOT used here: it cannot play
/// MKV/WebM/AVI, so an `AVAssetImageGenerator` screenshot would fail on
/// exactly the files MacPlayer exists to play. libmpv renders the frame
/// (including subtitles) and writes the file itself.
enum Screenshot {

    /// Folder screenshots are saved to: ~/Pictures/MacPlayer
    static var saveDirectory: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
        return pictures.appendingPathComponent("MacPlayer", isDirectory: true)
    }

    /// File name for a screenshot taken now.
    static func fileURLForNow() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "MacPlayer-\(formatter.string(from: Date())).png"
        return saveDirectory.appendingPathComponent(name)
    }

    /// Ask the player to capture the current frame to a new file in
    /// `saveDirectory`. Returns the target URL when mpv accepted the
    /// command, nil when there is no player or mpv rejected it. The file
    /// is written by mpv asynchronously, so callers should check for its
    /// existence before announcing success.
    static func capture(from player: MPVPlayer?) -> URL? {
        guard let player else { return nil }
        let url = fileURLForNow()
        do {
            try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
        } catch {
            NSLog("MacPlayer: failed to create screenshot folder: \(error)")
            return nil
        }
        return player.screenshot(to: url) ? url : nil
    }
}
