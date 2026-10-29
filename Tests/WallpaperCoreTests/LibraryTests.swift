import Foundation
import Testing
@testable import WallpaperCore

@Suite struct LibraryTests {
    let video = WallpaperSource(kind: .video, location: "/v/a.mov")
    let page = WallpaperSource(kind: .web, location: "/pages/waves")
    let remote = WallpaperSource(kind: .web, location: "https://example.com/w")
    let t0 = Date(timeIntervalSince1970: 1_000)

    private func ids() -> () -> String {
        var n = 0
        return { n += 1; return "id\(n)" }
    }

    @Test func addKeepsOrderAndAssignsIds() {
        var library = WallpaperLibrary()
        let make = ids()
        library.add(video, now: t0, makeID: make)
        library.add(page, now: t0, makeID: make)
        #expect(library.items.map(\.id) == ["id1", "id2"])
        #expect(library.items.map(\.source) == [video, page])
    }

    @Test func sameSourceIsAddedOnce() {
        var library = WallpaperLibrary()
        let make = ids()
        let first = library.add(video, now: t0, makeID: make)
        let again = library.add(video, now: t0, makeID: make)
        #expect(again.id == first.id)
        #expect(library.items.count == 1)
    }

    @Test func sameLocationOfAnotherKindIsAnotherItem() {
        var library = WallpaperLibrary()
        library.add(WallpaperSource(kind: .video, location: "/x"))
        library.add(WallpaperSource(kind: .web, location: "/x"))
        #expect(library.items.count == 2)
    }

    @Test func addingAgainRefreshesTheBookmarkButKeepsTheName() {
        var library = WallpaperLibrary()
        let item = library.add(video)
        library.rename(id: item.id, to: "Дождь")
        library.add(WallpaperSource(kind: .video, location: "/v/a.mov", bookmark: Data([1, 2])))
        #expect(library.items.count == 1)
        #expect(library.items[0].source.bookmark == Data([1, 2]))
        #expect(library.items[0].title == "Дождь")
    }

    @Test func titleFallsBackToTheSourceName() {
        var library = WallpaperLibrary()
        let a = library.add(video)
        let b = library.add(remote)
        #expect(a.title == "a.mov")
        #expect(b.title == "example.com")
        library.rename(id: a.id, to: "   ")
        #expect(library.item(id: a.id)?.title == "a.mov")
    }

    @Test func removeTakesOnlyThatItem() {
        var library = WallpaperLibrary()
        let a = library.add(video)
        let b = library.add(page)
        #expect(library.remove(id: a.id)?.source == video)
        #expect(library.items.map(\.id) == [b.id])
        #expect(library.remove(id: a.id) == nil)
        #expect(library.item(for: video) == nil)
    }

    @Test func adoptTakesTheChosenSourcesOnce() {
        let assignments = WallpaperAssignments(mode: .perScreen, shared: video, perScreen: ["B": page, "A": video])
        var library = WallpaperLibrary()
        library.adopt(assignments)
        library.adopt(assignments)
        #expect(library.items.map(\.source) == [video, page])
        var empty = WallpaperLibrary()
        empty.adopt(WallpaperAssignments())
        #expect(empty.items.isEmpty)
    }

    @Test func storeRoundTripsThroughAFile() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "lw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LibraryStore(fileURL: dir.appending(path: "sub/library.json"))
        var library = WallpaperLibrary()
        let item = library.add(WallpaperSource(kind: .video, location: "/v/a.mov", bookmark: Data([9])), now: t0)
        library.rename(id: item.id, to: "Дождь")
        try store.save(library)
        #expect(store.load() == library)
    }

    @Test func missingOrBrokenFileIsAnEmptyLibrary() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "lw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "library.json")
        let store = LibraryStore(fileURL: file)
        #expect(store.load().items.isEmpty)
        try Data("{ not json".utf8).write(to: file)
        #expect(store.load().items.isEmpty)
    }

    private func decoded(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data)
    }

    private func entries(_ data: Data) throws -> [Any] {
        let root = try #require(try decoded(data) as? [String: Any])
        return try #require(root["items"] as? [Any])
    }

    /// The rollback case: a library written by a newer version has a kind of source this one does not know.
    @Test func entriesOfAnUnknownKindSurviveLoadAndSave() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "lw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "library.json")
        let json = """
        {"items":[
          {"id":"a","added":1000,"source":{"kind":"video","location":"/v/a.mov"}},
          {"id":"b","added":2000,"name":"Новое","source":{"kind":"hologram","location":"/h/b","engine":"scene","extra":[1,2.5,null,true]}},
          "not an item",
          {"id":"c","added":3000,"source":{"kind":"web","location":"/p/c"}}
        ]}
        """
        try Data(json.utf8).write(to: file)
        let store = LibraryStore(fileURL: file)

        var library = store.load()
        #expect(library.items.map(\.id) == ["a", "c"])
        library.rename(id: "a", to: "Дождь")
        library.add(WallpaperSource(kind: .gif, location: "/g/d.gif"), now: t0, makeID: { "d" })
        try store.save(library)

        let all = try entries(try Data(contentsOf: file))
        #expect(all.count == 5)
        let saved = all.compactMap { $0 as? [String: Any] }
        let hologram = try #require(saved.first { $0["id"] as? String == "b" })
        #expect(hologram["name"] as? String == "Новое")
        let source = try #require(hologram["source"] as? [String: Any])
        #expect(source["kind"] as? String == "hologram")
        #expect(source["engine"] as? String == "scene")
        #expect((source["extra"] as? [Any])?.count == 4)
        #expect(saved.contains { $0["id"] as? String == "d" })
        // The entry that was not even an object stays too.
        #expect(all.contains { ($0 as? String) == "not an item" })
        // And the reloaded library is the same one.
        #expect(store.load() == library)
    }

    @Test func aFileThatIsNotALibraryIsSetAsideNotOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "lw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "library.json")
        try Data("{ not json".utf8).write(to: file)
        let store = LibraryStore(fileURL: file)
        #expect(store.load().items.isEmpty)
        let aside = dir.appending(path: "library.unreadable.json")
        #expect(try Data(contentsOf: aside) == Data("{ not json".utf8))
    }
}

@Suite struct ApplyTests {
    let a = WallpaperSource(kind: .video, location: "/v/a.mov")
    let b = WallpaperSource(kind: .web, location: "/p/b")

    @Test func allReplacesEveryChoice() {
        var assignments = WallpaperAssignments(mode: .perScreen, shared: a, perScreen: ["X": a, "Y": b])
        assignments.apply(b, to: .all)
        #expect(assignments.mode == .sameForAll)
        #expect(assignments.shared == b)
        #expect(assignments.perScreen.isEmpty)
        #expect(assignments.source(forDisplay: "X") == b)
        #expect(assignments.source(forDisplay: "new-monitor") == b)
    }

    @Test func oneDisplayLeavesTheOthersOnTheSharedSource() {
        var assignments = WallpaperAssignments(mode: .sameForAll, shared: a)
        assignments.apply(b, to: .display("Y"))
        #expect(assignments.mode == .perScreen)
        #expect(assignments.source(forDisplay: "Y") == b)
        #expect(assignments.source(forDisplay: "X") == a)
    }

    @Test func oneDisplayWithNothingSharedLeavesTheOthersEmpty() {
        var assignments = WallpaperAssignments()
        assignments.apply(a, to: .display("Y"))
        #expect(assignments.source(forDisplay: "Y") == a)
        #expect(assignments.source(forDisplay: "X") == nil)
    }

    @Test func showingListsTheDisplaysThatPlayItIgnoringTheBookmark() {
        let assignments = WallpaperAssignments(mode: .perScreen, shared: a, perScreen: ["Y": b])
        let withBookmark = WallpaperSource(kind: .video, location: "/v/a.mov", bookmark: Data([1]))
        #expect(assignments.displays(showing: withBookmark, among: ["X", "Y", "Z"]) == ["X", "Z"])
        #expect(assignments.displays(showing: b, among: ["X", "Y", "Z"]) == ["Y"])
        #expect(assignments.displays(showing: b, among: []).isEmpty)
    }

    @Test func detectsWhatWasChosen() {
        #expect(WallpaperSource.Kind.detect(path: "/x/clip.MOV", isDirectory: false) == .video)
        #expect(WallpaperSource.Kind.detect(path: "/x/clip.mp4", isDirectory: false) == .video)
        #expect(WallpaperSource.Kind.detect(path: "/x/page.html", isDirectory: false) == .web)
        #expect(WallpaperSource.Kind.detect(path: "/x/page.HTM", isDirectory: false) == .web)
        #expect(WallpaperSource.Kind.detect(path: "/x/folder", isDirectory: true) == .web)
    }
}
