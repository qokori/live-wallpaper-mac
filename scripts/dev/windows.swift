// Lists desktop-level windows (wallpaper, our windows, Finder icons) with layer and bounds. No permissions needed.
import CoreGraphics
import Foundation

let desktop = Int(CGWindowLevelForKey(.desktopWindow))
let icons = Int(CGWindowLevelForKey(.desktopIconWindow))
print("levels: desktop=\(desktop) desktopIcons=\(icons)")
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for window in list {
    let layer = window[kCGWindowLayer as String] as? Int ?? 0
    guard layer <= icons + 1 else { continue }
    let owner = window[kCGWindowOwnerName as String] as? String ?? "?"
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let b = ["X", "Y", "Width", "Height"].map { "\(bounds[$0] ?? "?")" }.joined(separator: ",")
    print("layer \(layer - desktop >= 0 ? "desktop+\(layer - desktop)" : "\(layer)")\t\(owner)\t[\(b)]\tid=\(window[kCGWindowNumber as String] ?? "?")")
}
