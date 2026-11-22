import AppKit
import CMPV
import Foundation

// MARK: - Rendering choice (read this before changing it)
//
// MacPlayer renders with the `wid` path, NOT with the libmpv Render API
// (`mpv_render_context_create`).
//
// Why: the Render API on macOS needs either OpenGL (deprecated by Apple,
// and `vo=libmpv` instead of `vo=gpu-next`) or a Vulkan/MoltenVK init
// struct (`MPV_RENDER_PARAM_VULKAN_INIT_PARAMS`, `VkInstance`,
// `VkPhysicalDevice`, …) that cannot be built safely from pure Swift under
// `swiftc` without a C/ObjC shim and MoltenVK headers. The `wid` path lets
// libmpv itself own the researched pipeline — `vo=gpu-next` +
// `gpu-api=vulkan` + `gpu-context=moltenvk` + `hwdec=videotoolbox` —
// zero-copy VideoToolbox frames straight into a Metal layer, with
// libplacebo scaling/HDR tone-mapping and libass subtitles rendered inside
// the video output. That is the exact pipeline the research report
// (§2, §5) recommends, and the same embedding mpv-examples shows in
// `libmpv/cocoa/cocoabasic.m`.
// Known caveat (also in the report): mpv-examples warns `wid` can be
// unstable with some frameworks on macOS. Mitigation here: the player is
// created only after the video view is in a visible window, `wid` is set
// once before `mpv_initialize()` and never changed, and the app never
// re-parents the video view. If `wid` ever proves unstable on a future
// macOS, the correct fix is a small C/ObjC Render-API shim — not mixing
// both paths in this file.

/// Events the UI needs from the engine. All callbacks arrive on the main queue.
protocol MPVPlayerDelegate: AnyObject {
    func player(_ player: MPVPlayer, didUpdateTime time: Double, duration: Double)
    func player(_ player: MPVPlayer, didChangePaused paused: Bool)
    func playerDidFinishFile(_ player: MPVPlayer)
    func player(_ player: MPVPlayer, didUpdateHardwareDecode hwdec: String)
}

/// Clean-room libmpv wrapper. No IINA code is used; only the public
/// libmpv C API (`mpv_create`, `mpv_set_option_string`, `mpv_initialize`,
/// `mpv_command`, `mpv_observe_property`, `mpv_wait_event`,
/// `mpv_get_property_string`, `mpv_set_property_string`) is called.
final class MPVPlayer {
    weak var delegate: MPVPlayerDelegate?

    private let videoView: NSView
    private var handle: OpaquePointer?
    private let commandQueue = DispatchQueue(label: "com.macplayer.mpv-command")
    private var eventThreadRunning = false
    private var hwdecFallbackTried = false

    private(set) var currentURL: URL?
    private(set) var time: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPaused: Bool = true
    private(set) var hwdecCurrent: String = "unknown"

    var volume: Double {
        get { getDoubleProperty("volume") ?? 100 }
        set { setDoubleProperty("volume", value: min(100, max(0, newValue))) }
    }

    var speed: Double {
        get { getDoubleProperty("speed") ?? 1 }
        set { setDoubleProperty("speed", value: min(4, max(0.25, newValue))) }
    }

    init(videoView: NSView) {
        self.videoView = videoView
        createHandle()
    }

    deinit {
        stopEventLoop()
        if let handle {
            mpv_terminate_destroy(handle)
        }
    }

    // MARK: - Setup

    private func createHandle() {
        guard let handle = mpv_create() else {
            NSLog("MacPlayer: mpv_create failed")
            return
        }
        self.handle = handle

        // Video output / rendering: gpu-next over MoltenVK (see header note).
        setOption("vo", "gpu-next")
        setOption("gpu-api", "vulkan")
        setOption("gpu-context", "moltenvk")
        setOption("hwdec", "videotoolbox")
        setOption("hwdec-codecs", "all")
        // Audio, sync, cache, subtitles: the low-resource defaults from the
        // research report (§2). `hwdec` is not on by default in mpv.
        setOption("ao", "coreaudio")
        setOption("audio-channels", "auto-safe")
        setOption("video-sync", "display-resample")
        setOption("cache", "yes")
        setOption("demuxer-max-bytes", "1GiB")
        setOption("demuxer-readahead-secs", "20")
        setOption("sub-auto", "fuzzy")
        setOption("sub-file-paths", "sub:subtitles")
        setOption("sub-ass-override", "yes")
        setOption("tone-mapping", "bt.2390")
        setOption("hdr-compute-peak", "yes")
        // No on-screen controller / OSD and no default key bindings: the
        // AppKit UI owns all of that, so mpv must not draw or grab keys.
        setOption("osc", "no")
        setOption("osd-level", "0")
        setOption("input-default-bindings", "no")
        setOption("ytdl", "no")
        setOption("keep-open", "no")

        // Embed into the AppKit video view. Must be set before initialize
        // and never changed afterwards.
        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(videoView).toOpaque()))
        let widResult = withUnsafePointer(to: &wid) { ptr in
            mpv_set_option(handle, "wid", MPV_FORMAT_INT64, UnsafeMutableRawPointer(mutating: ptr))
        }
        if widResult < 0 {
            NSLog("MacPlayer: mpv_set_option wid failed: \(errorString(widResult))")
        }

        let initResult = mpv_initialize(handle)
        if initResult < 0 {
            NSLog("MacPlayer: mpv_initialize failed: \(errorString(initResult))")
            return
        }

        observe("time-pos", format: MPV_FORMAT_DOUBLE)
        observe("duration", format: MPV_FORMAT_DOUBLE)
        observe("pause", format: MPV_FORMAT_FLAG)
        observe("volume", format: MPV_FORMAT_DOUBLE)
        observe("speed", format: MPV_FORMAT_DOUBLE)
        observe("hwdec-current", format: MPV_FORMAT_STRING)
        startEventLoop()
    }

    // MARK: - Playback

    func load(url: URL) {
        currentURL = url
        hwdecFallbackTried = false
        command(["loadfile", url.path, "replace"])
        // Local same-name subtitles are picked up by mpv itself
        // (`sub-auto=fuzzy`); nothing else to do here.
    }

    func play() { setProperty("pause", "no") }
    func pause() { setProperty("pause", "yes") }

    func togglePlayPause() {
        if isPaused { play() } else { pause() }
    }

    func seek(to seconds: Double) {
        guard duration > 0 else { return }
        setDoubleProperty("time-pos", value: min(duration, max(0, seconds)))
    }

    func seekBy(seconds: Double) {
        setDoubleProperty("time-pos", value: max(0, time + seconds))
    }

    func setSpeed(_ value: Double) {
        speed = value
    }

    func setVolume(_ value: Double) {
        volume = value
    }

    /// Add an external subtitle file and select it immediately.
    func addSubtitle(url: URL) {
        command(["sub-add", url.path, "select"])
    }

    func disableSubtitle() {
        setProperty("sid", "no")
    }

    func setSubtitleDelay(_ seconds: Double) {
        setDoubleProperty("sub-delay", value: seconds)
    }

    /// Current-frame screenshot via libmpv. Returns true when mpv accepted
    /// the command; the file itself is written by mpv asynchronously.
    @discardableResult
    func screenshot(to url: URL) -> Bool {
        let result = command(["screenshot-to-file", url.path])
        return result >= 0
    }

    /// Hardware-decode status as reported by libmpv itself
    /// (`hwdec-current`), never guessed from the chip model.
    func checkHardwareDecode() {
        guard let handle else { return }
        let current = getStringProperty("hwdec-current") ?? "no"
        hwdecCurrent = current
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.player(self, didUpdateHardwareDecode: current)
        }
        // `videotoolbox` (zero-copy) failed: fall back to the copying
        // variant once, which works with any video output.
        if (current == "no" || current.isEmpty) && !hwdecFallbackTried {
            hwdecFallbackTried = true
            NSLog("MacPlayer: hwdec=videotoolbox reported no, falling back to videotoolbox-copy")
            setProperty("hwdec", "videotoolbox-copy")
        }
    }

    // MARK: - libmpv helpers (command queue only)

    private func setOption(_ name: String, _ value: String) {
        guard let handle else { return }
        let result = mpv_set_option_string(handle, name, value)
        if result < 0 {
            NSLog("MacPlayer: mpv_set_option_string \(name)=\(value) failed: \(errorString(result))")
        }
    }

    private func observe(_ name: String, format: mpv_format) {
        guard let handle else { return }
        let result = mpv_observe_property(handle, 0, name, format)
        if result < 0 {
            NSLog("MacPlayer: mpv_observe_property \(name) failed: \(errorString(result))")
        }
    }

    @discardableResult
    private func command(_ args: [String]) -> Int32 {
        guard let handle else { return -1 }
        var result: Int32 = -1
        commandQueue.sync {
            result = withCStrings(args) { cArgs in
                mpv_command(handle, cArgs)
            }
        }
        if result < 0 {
            NSLog("MacPlayer: mpv_command \(args.first ?? "") failed: \(errorString(result))")
        }
        return result
    }

    private func setProperty(_ name: String, _ value: String) {
        guard let handle else { return }
        commandQueue.sync {
            let result = mpv_set_property_string(handle, name, value)
            if result < 0 {
                NSLog("MacPlayer: mpv_set_property_string \(name) failed: \(errorString(result))")
            }
        }
    }

    private func setDoubleProperty(_ name: String, value: Double) {
        guard let handle else { return }
        commandQueue.sync {
            var v = value
            let result = mpv_set_property(handle, name, MPV_FORMAT_DOUBLE, &v)
            if result < 0 {
                NSLog("MacPlayer: mpv_set_property \(name) failed: \(errorString(result))")
            }
        }
    }

    private func getDoubleProperty(_ name: String) -> Double? {
        guard let handle else { return nil }
        var value: Double = 0
        var result: Int32 = -1
        commandQueue.sync {
            result = mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &value)
        }
        return result >= 0 ? value : nil
    }

    private func getStringProperty(_ name: String) -> String? {
        guard let handle else { return nil }
        var cString: UnsafeMutablePointer<CChar>?
        var result: Int32 = -1
        commandQueue.sync {
            result = mpv_get_property_string(handle, name, &cString)
        }
        guard result >= 0, let cString else { return nil }
        defer { mpv_free(cString) }
        return String(cString: cString)
    }

    private func errorString(_ code: Int32) -> String {
        guard let cString = mpv_error_string(code) else { return "error \(code)" }
        return String(cString: cString)
    }

    /// Build a null-terminated `const char **` from Swift strings, freeing
    /// every copy afterwards. `strdup` is used so the pointers stay valid
    /// for the whole `mpv_command` call.
    private func withCStrings<T>(_ args: [String], _ body: (UnsafeMutablePointer<UnsafePointer<CChar>?>) -> T) -> T {
        var cStrings: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
        cStrings.append(nil)
        defer { cStrings.forEach { if let p = $0 { free(UnsafeMutablePointer(mutating: p)) } } }
        return cStrings.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }

    // MARK: - Event loop

    private func startEventLoop() {
        guard let handle, !eventThreadRunning else { return }
        eventThreadRunning = true
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self, let handle = self.handle else { return }
            while self.eventThreadRunning {
                guard let event = mpv_wait_event(handle, 0.5) else { continue }
                let eventID = event.pointee.event_id
                if eventID == MPV_EVENT_SHUTDOWN { break }
                if eventID == MPV_EVENT_PROPERTY_CHANGE {
                    self.handlePropertyChange(event)
                } else if eventID == MPV_EVENT_FILE_LOADED {
                    self.checkHardwareDecode()
                } else if eventID == MPV_EVENT_END_FILE {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.delegate?.playerDidFinishFile(self)
                    }
                }
            }
            self.eventThreadRunning = false
        }
    }

    private func stopEventLoop() {
        eventThreadRunning = false
    }

    private func handlePropertyChange(_ event: UnsafeMutablePointer<mpv_event>) {
        guard let raw = event.pointee.data else { return }
        let property = raw.assumingMemoryBound(to: mpv_event_property.self).pointee
        guard let nameCString = property.name else { return }
        let name = String(cString: nameCString)
        switch name {
        case "time-pos":
            if property.format == MPV_FORMAT_DOUBLE {
                let value = property.data.assumingMemoryBound(to: Double.self).pointee
                time = value
                notifyTime()
            }
        case "duration":
            if property.format == MPV_FORMAT_DOUBLE {
                duration = property.data.assumingMemoryBound(to: Double.self).pointee
                notifyTime()
            }
        case "pause":
            if property.format == MPV_FORMAT_FLAG {
                isPaused = property.data.assumingMemoryBound(to: Int32.self).pointee != 0
                let paused = isPaused
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.player(self, didChangePaused: paused)
                }
            }
        case "hwdec-current":
            if property.format == MPV_FORMAT_STRING {
                if let cString = property.data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee {
                    hwdecCurrent = String(cString: cString)
                    let current = hwdecCurrent
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.delegate?.player(self, didUpdateHardwareDecode: current)
                    }
                }
            }
        default:
            break
        }
    }

    private func notifyTime() {
        let t = time
        let d = duration
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.player(self, didUpdateTime: t, duration: d)
        }
    }
}
