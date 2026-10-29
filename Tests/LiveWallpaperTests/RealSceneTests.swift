import AppKit
import Foundation
import Testing
import WallpaperCore
import WallpaperEngineKit
import WebKit
@testable import LiveWallpaper

/// Real Workshop scenes drawn by the renderer and compared with the project's own preview picture. LW_WE_SAMPLES names
/// the folder of projects; without it these tests do nothing. LW_WE_OUT, if set, receives the drawn frames as PNG
/// (for looking at, never part of the repository).
enum SampleScenes {
    static var samples: URL? {
        guard let path = ProcessInfo.processInfo.environment["LW_WE_SAMPLES"], !path.isEmpty else { return nil }
        return URL(filePath: (path as NSString).expandingTildeInPath)
    }

    /// A scene whose layers are videos with blend modes (1 and 31), if the samples have one.
    static var videoScene: URL? {
        scenes.first { folder in
            guard let item = try? EngineSupport.open(folder), let assets = try? EngineSupport.sceneAssets(item) else { return false }
            return assets.textures.contains { $0.kind == "video" } && assets.document.layers.contains { $0.blendMode != 0 }
        }
    }

    static var scenes: [URL] {
        guard let samples else { return [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: samples.path)) ?? []
        return names.sorted().map { samples.appending(path: $0) }.filter {
            (try? EngineSupport.open($0))?.type == .scene
        }
    }

}

@MainActor
@Suite(.serialized) struct RealSceneTests {
    private func save(_ image: NSImage, as name: String) {
        guard let out = ProcessInfo.processInfo.environment["LW_WE_OUT"], !out.isEmpty,
              let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return }
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try? png.write(to: URL(filePath: out).appending(path: name))
    }

    /// Mean absolute difference per channel (0...255) between the frame and the preview, both at the probe's size.
    private func difference(_ frame: Pixels, _ preview: Pixels) -> Double {
        var total = 0
        for i in stride(from: 0, to: frame.data.count, by: 4) {
            for c in 0..<3 { total += abs(Int(frame.data[i + c]) - Int(preview.data[i + c])) }
        }
        return Double(total) / Double(frame.width * frame.height * 3)
    }

    private func brightness(_ p: Pixels) -> Double {
        var total = 0
        for i in stride(from: 0, to: p.data.count, by: 4) { total += Int(p.data[i]) + Int(p.data[i + 1]) + Int(p.data[i + 2]) }
        return Double(total) / Double(p.width * p.height * 3)
    }

    @Test(arguments: SampleScenes.scenes)
    func sceneIsDrawnAndMatchesItsPreview(folder: URL) async throws {
        let item = try EngineSupport.open(folder)
        let probe = try SceneProbe(folder: folder, size: CGSize(width: 384, height: 216))
        defer { probe.close() }
        try await probe.load()
        let status = try await probe.status()
        print("SCENE", folder.lastPathComponent, status, "skipped:", try EngineSupport.sceneAssets(item).skipped)
        #expect((status["failed"] as? [String]) == [])
        let image = try await probe.webView.takeSnapshot(configuration: nil)
        save(image, as: "\(folder.lastPathComponent).png")
        let frame = try #require(Pixels(image, width: 384, height: 216))
        guard let previewURL = item.previewFile, let preview = NSImage(contentsOf: previewURL).flatMap({ Pixels($0, width: 384, height: 216) }) else { return }
        let diff = difference(frame, preview)
        print("DIFF", folder.lastPathComponent, "mean abs diff", diff, "brightness", brightness(frame), "preview", brightness(preview))
        #expect(brightness(frame) > 5, "кадр чёрный")
        // The preview is a square cut of the scene (zoomed on the moving one): some cut of the frame has to look like it.
        let cut = bestCutDifference(frame: frame, preview: preview)
        print("CUT", folder.lastPathComponent, cut)
        #expect(cut < 30, "кадр непохож на превью: \(cut)")
        #expect(abs(brightness(frame) - brightness(preview)) < 25, "яркость кадра и превью расходится")
    }

    /// The preview of the video scene is a zoomed square cut of the scene, so the frame is searched for the cut that fits it
    /// best (grey values, both at 48x48). Returns the smallest mean difference found.
    private func bestCutDifference(frame: Pixels, preview: Pixels) -> Double {
        func grey(_ p: Pixels, _ x: Double, _ y: Double) -> Double {
            let c = p.at(x, y)
            return Double(c[0] + c[1] + c[2]) / 3
        }
        let n = 32
        let target = (0..<n * n).map { grey(preview, (Double($0 % n) + 0.5) / Double(n), (Double($0 / n) + 0.5) / Double(n)) }
        var best = Double.infinity
        let aspect = Double(frame.width) / Double(frame.height)
        for side in stride(from: 0.30, through: 0.80, by: 0.1) {
            let w = side / aspect
            for cx in stride(from: side / 2 / aspect, through: 1 - side / 2 / aspect, by: 0.08) {
                for cy in stride(from: side / 2, through: 1 - side / 2, by: 0.08) {
                    var total = 0.0
                    for k in 0..<n * n {
                        let x = cx - w / 2 + w * (Double(k % n) + 0.5) / Double(n)
                        let y = cy - side / 2 + side * (Double(k / n) + 0.5) / Double(n)
                        total += abs(grey(frame, x, y) - target[k])
                    }
                    best = min(best, total / Double(n * n))
                }
            }
        }
        return best
    }

    /// Which numbers mean which blend: the frame is compared with the preview under each reading of 1 and 31.
    @Test func blendModeNumbersAgainstThePreview() async throws {
        guard let folder = SampleScenes.videoScene else { return }
        let item = try EngineSupport.open(folder)
        let size = CGSize(width: 768, height: 432)
        let probe = try SceneProbe(folder: folder, size: size)
        defer { probe.close() }
        try await probe.load()
        guard let previewURL = item.previewFile, let source = CGImageSourceCreateWithURL(previewURL as CFURL, nil) else { return }
        // The preview's frames: every one is a moment of the same loop, so the frame that fits best counts.
        let previews: [Pixels] = (0..<CGImageSourceGetCount(source)).filter { $0 % 25 == 0 }.compactMap { index in
            CGImageSourceCreateImageAtIndex(source, index, nil).flatMap { Pixels(NSImage(cgImage: $0, size: NSSize(width: 192, height: 192)), width: 192, height: 192) }
        }
        // 0 normal, 1 multiply, 2 screen, 3 add
        var results: [(String, Double)] = []
        let pairs = (0...3).map { ($0, 2) } + [(1, 0), (1, 1), (1, 3)]
        do {
            for (one, thirtyOne) in pairs {
                _ = try await probe.webView.evaluateJavaScript("window.__lwScene.setModeMap({1: \(one), 31: \(thirtyOne)})")
                let frame = try #require(Pixels(try await probe.webView.takeSnapshot(configuration: nil), width: Int(size.width), height: Int(size.height)))
                results.append(("1→\(one) 31→\(thirtyOne)", previews.map { bestCutDifference(frame: frame, preview: $0) }.min() ?? 255))
            }
        }
        for (name, diff) in results.sorted(by: { $0.1 < $1.1 }) { print("MODEMAP", name, diff) }
        let best = try #require(results.min { $0.1 < $1.1 })
        #expect(best.0 == "1→1 31→2" || best.0 == "1→1 31→3", "лучше всего совпадает \(best.0)")
        let multiply = try #require(results.first { $0.0 == "1→1 31→2" })
        let normal = try #require(results.first { $0.0 == "1→0 31→2" })
        #expect(multiply.1 < normal.1 - 5, "умножение не лучше обычного смешивания: \(multiply.1) и \(normal.1)")
        #expect(multiply.1 < 30, "кадр непохож на превью: \(multiply.1)")
    }

    @Test func dumpPreviewFrames() throws {
        guard let folder = SampleScenes.videoScene,
              let url = try EngineSupport.open(folder).previewFile,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
        let count = CGImageSourceGetCount(source)
        let picks = [0, count / 5, 2 * count / 5, 3 * count / 5, 4 * count / 5]
        let size = 192
        let sheet = NSImage(size: NSSize(width: size * picks.count, height: size))
        sheet.lockFocus()
        for (n, index) in picks.enumerated() {
            if let frame = CGImageSourceCreateImageAtIndex(source, index, nil) {
                NSImage(cgImage: frame, size: NSSize(width: size, height: size)).draw(in: NSRect(x: n * size, y: 0, width: size, height: size))
            }
        }
        sheet.unlockFocus()
        save(sheet, as: "preview-frames.png")
    }
}
