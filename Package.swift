// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiveWallpaper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LiveWallpaper", targets: ["LiveWallpaper"]),
    ],
    dependencies: [
        // Updates from GitHub releases (EdDSA-signed appcast). Pinned to an exact stable release.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        // Pure logic: pause policy, video-per-screen choice, loop seam meter. No AppKit or AVFoundation.
        .target(name: "WallpaperCore"),
        // Wallpaper Engine projects: project.json, the .pkg container, the web page shim. Foundation only.
        .target(name: "WallpaperEngineKit"),
        // Menu bar app: desktop-level windows, looping players, system events, menu.
        .executableTarget(name: "LiveWallpaper", dependencies: ["WallpaperCore", "WallpaperEngineKit", .product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "WallpaperCoreTests", dependencies: ["WallpaperCore"]),
        .testTarget(name: "WallpaperEngineKitTests", dependencies: ["WallpaperEngineKit"]),
        // App model and the main window, checked without starting the app: no wallpaper windows, no system changes.
        .testTarget(name: "LiveWallpaperTests", dependencies: ["LiveWallpaper", "WallpaperCore", "WallpaperEngineKit"]),
    ]
)
