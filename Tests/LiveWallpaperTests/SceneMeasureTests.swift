import AppKit
import Darwin
import Foundation
import Testing
import WallpaperEngineKit
import WebKit
@testable import LiveWallpaper

/// The measurement from the plan (section 2.1, "revisit condition"): memory and CPU of the scene page with three 4K
/// video layers at 30 frames a second, against a 4K video wallpaper. Off screen, in the test process. Runs only with
/// LW_WE_MEASURE=1 and LW_WE_SAMPLES; the numbers are printed, not asserted.
@MainActor
@Suite(.serialized) struct SceneMeasureTests {
    private struct Usage {
        var cpu: Double
        var footprint: Int

        static func of(_ pid: Int32) -> Usage? {
            var info = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            guard result == 0 else { return nil }
            var base = mach_timebase_info_data_t()
            mach_timebase_info(&base)
            let nanos = Double(info.ri_user_time + info.ri_system_time) * Double(base.numer) / Double(base.denom)
            return Usage(cpu: nanos / 1e9, footprint: Int(info.ri_phys_footprint))
        }
    }

    private static var enabled: Bool {
        ProcessInfo.processInfo.environment["LW_WE_MEASURE"] == "1"
    }

    /// Pids of processes whose command contains `name`.
    private func pids(named name: String) -> Set<Int32> {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return Set(text.split(separator: "\n").compactMap { line in
            guard line.contains(name) else { return nil }
            return Int32(line.split(separator: " ").first ?? "")
        })
    }

    private struct Sample {
        var seconds: Double
        var cpu: [String: Double]
        var memory: [String: Int]
    }

    /// Samples the named processes for `seconds`, after a warm-up, calling `tick` 30 times a second.
    private func measure(_ processes: @escaping () -> [String: Int32], warmup: Double = 6, seconds: Double = 20, tick: @escaping @MainActor @Sendable () -> Void) async -> Sample {
        let start = Date()
        var timer: Timer? = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
        try? await Task.sleep(for: .seconds(warmup))
        let before = processes().compactMapValues { Usage.of($0) }
        let t0 = Date()
        var peak: [String: Int] = [:]
        while Date().timeIntervalSince(t0) < seconds {
            try? await Task.sleep(for: .milliseconds(500))
            for (name, usage) in processes().compactMapValues({ Usage.of($0) }) { peak[name] = max(peak[name] ?? 0, usage.footprint) }
        }
        let after = processes().compactMapValues { Usage.of($0) }
        let elapsed = Date().timeIntervalSince(t0)
        timer?.invalidate()
        timer = nil
        _ = start
        var cpu: [String: Double] = [:]
        for (name, usage) in after { cpu[name] = (usage.cpu - (before[name]?.cpu ?? usage.cpu)) / elapsed * 100 }
        return Sample(seconds: elapsed, cpu: cpu, memory: peak)
    }

    private func describe(_ title: String, _ sample: Sample) {
        var lines = ["MEASURE \(title): \(String(format: "%.1f", sample.seconds)) с"]
        for name in sample.cpu.keys.sorted() {
            lines.append("  \(name): CPU \(String(format: "%.1f", sample.cpu[name] ?? 0)) % одного ядра, память (пик) \((sample.memory[name] ?? 0) / 1_048_576) МБ")
        }
        let totalCPU = sample.cpu.values.reduce(0, +)
        let totalMem = sample.memory.values.reduce(0, +) / 1_048_576
        lines.append("  ИТОГО: CPU \(String(format: "%.1f", totalCPU)) %, память \(totalMem) МБ")
        print(lines.joined(separator: "\n"))
    }

    @Test func sceneAgainstAVideoWallpaper() async throws {
        guard Self.enabled, let folder = SampleScenes.videoScene else { return }
        let item = try EngineSupport.open(folder)
        let assets = try EngineSupport.sceneAssets(item)

        // The same 4K clip the scene's first layer plays, as a file for the video wallpaper.
        let clipTexture = try #require(assets.textures.first { $0.kind == "video" })
        let archive = try PKGArchive(contentsOf: try #require(item.package))
        let texture = try TexFile(data: try #require(archive.slice(of: clipTexture.path)))
        guard case .video(let mp4) = texture.payload else { Issue.record("не видео"); return }
        let clip = FileManager.default.temporaryDirectory.appending(path: "lw-measure-\(UUID().uuidString).mp4")
        try mp4.write(to: clip)
        defer { try? FileManager.default.removeItem(at: clip) }
        print("MEASURE клип \(texture.imageWidth)×\(texture.imageHeight), \(mp4.count / 1_048_576) МБ, слоёв-видео в сцене: \(assets.textures.filter { $0.kind == "video" }.count)")

        // 1. The scene.
        let gpuBefore = pids(named: "com.apple.WebKit.GPU")
        let probe = try SceneProbe(folder: folder, size: CGSize(width: 1920, height: 1080), frameRate: 30)
        try await probe.load()
        let webPid = try #require(probe.webView.value(forKey: "_webProcessIdentifier") as? Int32)
        let gpuPids = pids(named: "com.apple.WebKit.GPU").subtracting(gpuBefore)
        let appPid = getpid()
        let scene = await measure({
            var map: [String: Int32] = ["WebContent": webPid, "приложение": appPid]
            for pid in gpuPids { map["GPU \(pid)"] = pid }
            return map
        }) {
            probe.webView.evaluateJavaScript("window.__lwScene.step(1/30)")
        }
        describe("сцена, 3 видеослоя 4K, 30 к/с", scene)
        let status = try await probe.status()
        print("MEASURE сцена: отрисовано кадров \(status["drawn"] ?? "?"), загрузка видео \(status["videoState"] ?? "?")")
        probe.close()
        try await Task.sleep(for: .seconds(2))

        // 2. One 4K video wallpaper.
        let video = VideoContent(url: clip, label: "measure")
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1920, height: 1080), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = video.view
        video.view.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        var ready = false
        video.start(ready: { ready = true }, failed: { _ in })
        for _ in 0..<200 where !ready { try await Task.sleep(for: .milliseconds(50)) }
        video.setPlaying(true)
        let videoSample = await measure({ ["приложение": appPid] }) {}
        describe("видео-обои 4K (одно видео)", videoSample)
        video.setPlaying(false)
        video.stop()
        window.orderOut(nil)
    }

    /// What a paused scene still costs: the same scene playing and then paused (covered by windows, display asleep).
    @Test func sceneWhilePaused() async throws {
        guard Self.enabled, let folder = SampleScenes.videoScene else { return }
        let gpuBefore = pids(named: "com.apple.WebKit.GPU")
        let probe = try SceneProbe(folder: folder, size: CGSize(width: 1920, height: 1080), frameRate: 30)
        defer { probe.close() }
        try await probe.load()
        let webPid = try #require(probe.webView.value(forKey: "_webProcessIdentifier") as? Int32)
        let gpuPids = pids(named: "com.apple.WebKit.GPU").subtracting(gpuBefore)
        let appPid = getpid()
        let processes: () -> [String: Int32] = {
            var map: [String: Int32] = ["WebContent": webPid, "приложение": appPid]
            for pid in gpuPids { map["GPU \(pid)"] = pid }
            return map
        }
        let playing = await measure(processes, warmup: 6, seconds: 15) {
            probe.webView.evaluateJavaScript("window.__lwScene.step(1/30)")
        }
        describe("сцена играет", playing)
        probe.web.setPlaying(false)
        // After the pause the loop is not driven at all, as the page's own loop stops when paused.
        let paused = await measure(processes, warmup: 4, seconds: 15) {}
        describe("сцена на паузе", paused)
        probe.web.setPlaying(true)
        let resumed = await measure(processes, warmup: 4, seconds: 10) {
            probe.webView.evaluateJavaScript("window.__lwScene.step(1/30)")
        }
        describe("сцена снова играет", resumed)
    }
}
