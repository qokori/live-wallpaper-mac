// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveWallpaper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LiveWallpaper", targets: ["LiveWallpaper"]),
    ],
    targets: [
        // Pure logic: pause policy, video-per-screen choice, loop seam meter. No AppKit or AVFoundation.
        .target(name: "WallpaperCore"),
        // Menu bar app: desktop-level windows, looping players, system events, menu.
        .executableTarget(name: "LiveWallpaper", dependencies: ["WallpaperCore"]),
        .testTarget(name: "WallpaperCoreTests", dependencies: ["WallpaperCore"]),
        // App model and the main window, checked without starting the app: no wallpaper windows, no system changes.
        .testTarget(name: "LiveWallpaperTests", dependencies: ["LiveWallpaper", "WallpaperCore"]),
    ]
)
