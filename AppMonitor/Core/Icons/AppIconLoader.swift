import AppKit
import SwiftUI

/// Lazy icon cache keyed by bundle path. Stores `NSImage?` so failed loads
/// are remembered as `nil` and not retried on every refresh tick.
/// NSWorkspace handles the entire icon-extraction story for us — Info.plist
/// parse, `.icns` decode, Electron-PNG-as-`.icns` quirks, and `Assets.car`
/// extraction all collapse into one call.
actor AppIconLoader {
    private var cache: [String: NSImage?] = [:]
    private let targetSize = NSSize(width: 16, height: 16)

    func icon(forBundle path: String) -> NSImage? {
        if let cached = cache[path] { return cached }
        let workspaceIcon = NSWorkspace.shared.icon(forFile: path)
        workspaceIcon.size = targetSize
        // NSWorkspace always returns an image (falling back to a generic doc
        // icon for non-existent paths) — but if the file system entry is gone
        // entirely we'd rather show nothing. NSImage's `isValid` flag catches
        // that.
        let resolved: NSImage? = workspaceIcon.isValid ? workspaceIcon : nil
        cache[path] = resolved
        return resolved
    }

    func clearCache() {
        cache.removeAll()
    }
}
