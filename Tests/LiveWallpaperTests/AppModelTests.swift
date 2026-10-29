import Foundation
import Testing
import WallpaperCore
@testable import LiveWallpaper

/// A model on a scratch defaults suite and library file. `start()` is never called, so no wallpaper window opens.
@MainActor
struct Sandbox {
    let directory: URL
    let suite: String
    let defaults: UserDefaults
    let store: LibraryStore

    init() {
        directory = FileManager.default.temporaryDirectory.appending(path: "lw-test-\(UUID().uuidString)")
        suite = "lw-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        store = LibraryStore(fileURL: directory.appending(path: "library.json"))
    }

    /// Never reads or writes the real Application Support: the converted videos go under `directory`, and the screen size is fixed.
    func model(screenSide: Int = 2000) -> AppModel {
        AppModel(defaults: defaults, libraryStore: store, convertedDirectory: directory.appending(path: "Converted"), screenSide: { screenSide })
    }

    func file(_ name: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try Data().write(to: url)
        return url
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
@Suite struct AppModelTests {
    let video = WallpaperSource(kind: .video, location: "/v/a.mov")
    let page = WallpaperSource(kind: .web, location: "https://example.com/w")

    @Test func applyingToAllPutsTheSourceInTheLibraryAndOnEveryScreen() {
        let box = Sandbox()
        defer { box.cleanup() }
        let model = box.model()
        model.apply(video, to: .all)
        #expect(model.assignments.source(forDisplay: "any") == video)
        #expect(model.library.items.map(\.source) == [video])
        model.apply(video, to: .all)
        #expect(model.library.items.count == 1)
    }

    @Test func applyingToOneScreenKeepsTheOthers() {
        let box = Sandbox()
        defer { box.cleanup() }
        let model = box.model()
        model.apply(video, to: .all)
        model.apply(page, to: .display("B"))
        #expect(model.assignments.source(forDisplay: "A") == video)
        #expect(model.assignments.source(forDisplay: "B") == page)
        #expect(model.library.items.count == 2)
    }

    @Test func frameRateAndQualityStartAt30AndTheScreen() {
        let box = Sandbox()
        defer { box.cleanup() }
        let model = box.model()
        #expect(model.webFrameRate == 30 && model.renderQuality == .screen)
    }

    @Test func frameRatesOnOfferAndQualityAreRemembered() {
        let box = Sandbox()
        defer { box.cleanup() }
        let first = box.model()
        first.webFrameRate = 60
        first.renderQuality = .maximum
        let second = box.model()
        #expect(second.webFrameRate == 60 && second.renderQuality == .maximum)
        second.webFrameRate = 15
        second.renderQuality = .economy
        let third = box.model()
        #expect(third.webFrameRate == 15 && third.renderQuality == .economy)
    }

    @Test func aFrameRateNotOnOfferFallsBackTo30() {
        let box = Sandbox()
        defer { box.cleanup() }
        let model = box.model()
        model.webFrameRate = 45
        #expect(model.webFrameRate == 30)
        #expect(box.model().webFrameRate == 30)
        // The 0.5.0 settings held 30 or 60 as a number: they read back unchanged.
        box.defaults.set(60, forKey: "webFrameRate")
        #expect(box.model().webFrameRate == 60)
    }

    @Test func libraryAndChoicesSurviveARestart() {
        let box = Sandbox()
        defer { box.cleanup() }
        let first = box.model()
        first.apply(video, to: .all)
        first.apply(page, to: .display("B"))
        let second = box.model()
        #expect(second.library.items.map(\.source) == [video, page])
        #expect(second.assignments == first.assignments)
    }

    @Test func choicesFromBeforeTheLibraryExistedAreAdopted() throws {
        let box = Sandbox()
        defer { box.cleanup() }
        let old = WallpaperAssignments(mode: .perScreen, shared: video, perScreen: ["B": page])
        box.defaults.set(try JSONEncoder().encode(old), forKey: "assignments")
        let model = box.model()
        #expect(Set(model.library.items.map(\.source.location)) == [video.location, page.location])
        #expect(box.store.load().items.map(\.id) == model.library.items.map(\.id))
    }

    @Test func removingFromTheLibraryKeepsTheWallpaperOnScreen() throws {
        let box = Sandbox()
        defer { box.cleanup() }
        let model = box.model()
        model.apply(video, to: .all)
        let item = try #require(model.library.item(for: video))
        model.removeFromLibrary(item)
        #expect(model.library.items.isEmpty)
        #expect(model.assignments.shared == video)
        #expect(box.model().library.items.isEmpty) // not adopted a second time
    }

    @Test func aBadAddressIsRefusedWithANotice() async {
        let box = Sandbox()
        defer { box.cleanup() }
        let model = box.model()
        let added = await model.addWebAddress("not an address")
        #expect(!added)
        #expect(model.notice?.title == "Неверный адрес")
        #expect(model.library.items.isEmpty)
    }

    @Test func aTypedAddressIsNormalisedAndAdded() async {
        let box = Sandbox()
        defer { box.cleanup() }
        let model = box.model()
        #expect(await model.addWebAddress("example.com/w"))
        #expect(model.library.items.first?.source.location == "https://example.com/w")
        #expect(model.notice == nil)
    }

    @Test func aFolderWithoutIndexIsRefusedAndNotAdded() async throws {
        let box = Sandbox()
        defer { box.cleanup() }
        let model = box.model()
        try FileManager.default.createDirectory(at: box.directory, withIntermediateDirectories: true)
        let added = await model.addToLibrary(WallpaperSource(kind: .web, location: box.directory.path))
        #expect(!added)
        #expect(model.notice?.text == SourceError.noIndexPage.localizedDescription)
        #expect(model.library.items.isEmpty)
    }

    @Test func aFolderWithAnIndexIsAdded() async throws {
        let box = Sandbox()
        defer { box.cleanup() }
        let model = box.model()
        _ = try box.file("index.html")
        #expect(await model.addToLibrary(WallpaperSource(kind: .web, location: box.directory.path)))
        #expect(model.library.items.count == 1)
    }

    @Test func screensShowingAnItemAreNamed() throws {
        let box = Sandbox()
        defer { box.cleanup() }
        let model = box.model()
        model.screens = [
            ScreenStatus(id: "A", name: "Встроенный", source: nil, playing: false, reasons: []),
            ScreenStatus(id: "B", name: "Dell", source: nil, playing: false, reasons: []),
        ]
        model.apply(video, to: .all)
        model.apply(page, to: .display("B"))
        let item = try #require(model.library.item(for: video))
        #expect(model.screenNames(showing: item) == ["Встроенный"])
    }
}
