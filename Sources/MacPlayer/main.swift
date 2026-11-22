import AppKit
import Foundation

// Entry point. AppKit only; no SwiftUI is used anywhere in MacPlayer.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
