import Foundation
import Testing
@testable import WallpaperEngineKit

@Suite struct TexFileTests {
    private func pixels(_ file: TexFile) throws -> (Int, Int, [UInt8]) {
        guard case .pixels(let w, let h, let rgba) = file.payload else { throw TexFile.Failure.damaged("не пиксели") }
        return (w, h, Array(rgba))
    }

    private let rgba2x1: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 128]

    @Test(arguments: [1, 2, 3, 4])
    func rgbaInEveryContainerVersion(container: Int) throws {
        let data = EngineFixtures.tex(container: container, mips: [.init(width: 2, height: 1, bytes: rgba2x1)])
        let file = try TexFile(data: data)
        #expect(file.containerVersion == container)
        let (w, h, bytes) = try pixels(file)
        #expect((w, h) == (2, 1))
        #expect(bytes == rgba2x1)
    }

    @Test func lz4PackedPixelsAreUnpacked() throws {
        let big = (0..<(16 * 16 * 4)).map { UInt8($0 % 7 * 30) }
        let data = EngineFixtures.tex(container: 3, mips: [.init(width: 16, height: 16, bytes: big, lz4: true)])
        #expect(try pixels(TexFile(data: data)).2 == big)
    }

    @Test func onlyTheFirstMipIsReadAndTheOthersAreSkipped() throws {
        let data = EngineFixtures.tex(container: 3, mips: [
            .init(width: 2, height: 1, bytes: rgba2x1), .init(width: 1, height: 1, bytes: [9, 9, 9, 9]),
        ])
        #expect(try pixels(TexFile(data: data)).2 == rgba2x1)
    }

    @Test func redOnlyAndRedGreenTexturesBecomeRGBA() throws {
        let r8 = try TexFile(data: EngineFixtures.tex(format: 9, mips: [.init(width: 2, height: 1, bytes: [10, 200])]))
        #expect(try pixels(r8).2 == [10, 10, 10, 255, 200, 200, 200, 255])
        let rg = try TexFile(data: EngineFixtures.tex(format: 8, mips: [.init(width: 1, height: 1, bytes: [10, 20])]))
        #expect(try pixels(rg).2 == [10, 20, 0, 255])
    }

    @Test func aPaddedTextureIsCutToThePicture() throws {
        // 4x2 texture holding a 3x1 picture in the top-left corner.
        var bytes = [UInt8]()
        for y in 0..<2 { for x in 0..<4 { bytes += [UInt8(x), UInt8(y), 0, 255] } }
        let file = try TexFile(data: EngineFixtures.tex(size: (4, 2), image: (3, 1), mips: [.init(width: 4, height: 2, bytes: bytes)]))
        let (w, h, out) = try pixels(file)
        #expect((w, h) == (3, 1))
        #expect(out == [0, 0, 0, 255, 1, 0, 0, 255, 2, 0, 0, 255])
    }

    @Test func dxt1BlocksDecodeToTheirColours() throws {
        // c0 = red, c1 = blue, every index 0: a red 4x4 block. Then index 1 (blue) for the first pixel.
        let red: UInt16 = 0xF800
        let blue: UInt16 = 0x001F
        var block: [UInt8] = [UInt8(red & 255), UInt8(red >> 8), UInt8(blue & 255), UInt8(blue >> 8), 1, 0, 0, 0]
        let file = try TexFile(data: EngineFixtures.tex(format: 7, mips: [.init(width: 4, height: 4, bytes: block)]))
        let (_, _, out) = try pixels(file)
        #expect(Array(out[0..<4]) == [0, 0, 255, 255])
        #expect(Array(out[4..<8]) == [255, 0, 0, 255])
        block[4] = 2 // two thirds red, one third blue
        let mixed = try pixels(TexFile(data: EngineFixtures.tex(format: 7, mips: [.init(width: 4, height: 4, bytes: block)])))
        #expect(mixed.2[0] == 170 && mixed.2[2] == 85)
    }

    @Test func dxt1WithAlphaWhenTheFirstColourIsNotTheBrighter() throws {
        // c0 <= c1 and index 3: transparent black.
        let data: [UInt8] = [0, 0, 255, 255, 3, 0, 0, 0]
        let out = try pixels(TexFile(data: EngineFixtures.tex(format: 7, mips: [.init(width: 4, height: 4, bytes: data)]))).2
        #expect(Array(out[0..<4]) == [0, 0, 0, 0])
    }

    @Test func dxt3AndDxt5CarryTheirAlpha() throws {
        let colour: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0] // white
        let alpha3: [UInt8] = [0x0F, 0xF0, 0, 0, 0, 0, 0, 0] // low nibble first: pixel 0 = 15, pixel 1 = 0, pixel 2 = 0, pixel 3 = 15
        let dxt3 = try pixels(TexFile(data: EngineFixtures.tex(format: 6, mips: [.init(width: 4, height: 4, bytes: alpha3 + colour)]))).2
        #expect(dxt3[3] == 255 && dxt3[7] == 0 && dxt3[11] == 0 && dxt3[15] == 255)
        // a0 = 200, a1 = 0, all indices 0: alpha 200 everywhere.
        let alpha5: [UInt8] = [200, 0, 0, 0, 0, 0, 0, 0]
        let dxt5 = try pixels(TexFile(data: EngineFixtures.tex(format: 4, mips: [.init(width: 4, height: 4, bytes: alpha5 + colour)]))).2
        #expect(dxt5[3] == 200 && dxt5[63] == 200)
    }

    @Test func imagesInsideAreHandedOnWhole() throws {
        let png = EngineFixtures.png(width: 2, height: 2, rgba: [UInt8](repeating: 255, count: 16))
        let file = try TexFile(data: EngineFixtures.tex(container: 3, fif: 13, mips: [.init(width: 2, height: 2, bytes: [UInt8](png))]))
        guard case .image(let bytes, let mime) = file.payload else { Issue.record("не картинка"); return }
        #expect(mime == "image/png")
        #expect(bytes == png)
        let jpeg = EngineFixtures.png(width: 8, height: 8, rgba: [UInt8](repeating: 200, count: 256), type: .jpeg)
        let j = try TexFile(data: EngineFixtures.tex(container: 3, fif: 2, mips: [.init(width: 8, height: 8, bytes: [UInt8](jpeg))]))
        guard case .image(_, let jm) = j.payload else { Issue.record("не картинка"); return }
        #expect(jm == "image/jpeg")
    }

    @Test(arguments: [0, 1])
    func videoIsToldByItsFtypBoxWhateverTheFieldsSay(mp4Flag: Int) throws {
        let mp4 = [0, 0, 0, 24] + Array("ftypisom".utf8) + [UInt8](repeating: 0, count: 20)
        let file = try TexFile(data: EngineFixtures.tex(container: 4, flags: 35, mp4Flag: mp4Flag, mips: [.init(width: 64, height: 48, bytes: mp4)]))
        guard case .video(let bytes) = file.payload else { Issue.record("не видео"); return }
        #expect(Array(bytes) == mp4)
        #expect(file.isVideo)
    }

    @Test func aVideoFlagWithoutMp4IsRefused() {
        let data = EngineFixtures.tex(flags: 32, mips: [.init(width: 1, height: 1, bytes: [1, 2, 3, 4])])
        #expect(throws: TexFile.Failure.self) { try TexFile(data: data) }
    }

    @Test(arguments: [2, 3])
    func animationFramesAreRead(version: Int) throws {
        let data = EngineFixtures.tex(
            flags: 6, mips: [.init(width: 2, height: 1, bytes: rgba2x1)],
            frames: [(0, 0.1, 0, 0, 1, 1), (0, 0.2, 1, 0, 1, 1)], framesVersion: version
        )
        let file = try TexFile(data: data)
        #expect(file.frames.count == 2)
        #expect(file.frames[1].time == 0.2 && file.frames[1].x == 1 && file.frames[1].width == 1)
    }

    @Test func brokenFilesAreRefusedWithoutACrash() throws {
        let good = EngineFixtures.tex(mips: [.init(width: 2, height: 1, bytes: rgba2x1)])
        #expect(throws: TexFile.Failure.self) { try TexFile(data: Data("hello".utf8)) }
        #expect(throws: TexFile.Failure.self) { try TexFile(data: Data()) }
        for cut in stride(from: 0, to: good.count, by: 5) {
            #expect(throws: TexFile.Failure.self) { try TexFile(data: good.prefix(cut)) }
        }
        // A pixel count that does not fit the bytes.
        #expect(throws: TexFile.Failure.self) { try TexFile(data: EngineFixtures.tex(mips: [.init(width: 100, height: 100, bytes: [1, 2, 3, 4])])) }
        // Too little for the DXT blocks.
        #expect(throws: TexFile.Failure.self) { try TexFile(data: EngineFixtures.tex(format: 7, mips: [.init(width: 8, height: 8, bytes: [0, 0, 0, 0])])) }
        // An unknown pixel format.
        #expect(throws: TexFile.Failure.self) { try TexFile(data: EngineFixtures.tex(format: 77, mips: [.init(width: 1, height: 1, bytes: [0, 0, 0, 0])])) }
    }

    @Test func aTextureInsideAWindowOntoLargerDataIsRead() throws {
        // Package files are slices of one mapped file: indices do not start at zero.
        let good = EngineFixtures.tex(mips: [.init(width: 2, height: 1, bytes: rgba2x1)])
        let wrapped = Data([1, 2, 3]) + good + Data([4, 5])
        let slice = wrapped[3..<(3 + good.count)]
        #expect(try pixels(TexFile(data: slice)).2 == rgba2x1)
    }

    // MARK: Memory limits

    @Test func aLieAboutTheUnpackedSizeIsRefusedBeforeAnythingIsAllocated() {
        // 4 bytes of LZ4 cannot make a gigabyte; the file says it does.
        let bomb = EngineFixtures.tex(mips: [.init(width: 16384, height: 16384, bytes: [1, 2, 3, 4], lz4: true, claimed: 1 << 30)])
        let budget = TexFile.Budget(limit: 64 << 20)
        #expect(throws: TexFile.Failure.self) { try TexFile(data: bomb, budget: budget) }
        #expect(budget.bytesUsed == 0)
    }

    @Test func honestlyPackedDataOverTheBudgetIsRefusedAndGivesTheBytesBack() throws {
        // Zeros pack to almost nothing: a small file, 8 MiB of pixels.
        let zeros = [UInt8](repeating: 0, count: 2048 * 1024 * 4)
        let data = EngineFixtures.tex(mips: [.init(width: 2048, height: 1024, bytes: zeros, lz4: true)])
        #expect(data.count < 200_000)
        let small = TexFile.Budget(limit: 4 << 20)
        #expect(throws: TexFile.Failure.self) { try TexFile(data: data, budget: small) }
        #expect(small.bytesUsed == 0)
        let roomy = TexFile.Budget(limit: 16 << 20)
        _ = try TexFile(data: data, budget: roomy)
        #expect(roomy.bytesUsed == zeros.count)
    }

    @Test func oneBudgetCoversAllTexturesOfAScene() throws {
        let one = [UInt8](repeating: 7, count: 1024 * 256 * 4)
        let data = EngineFixtures.tex(mips: [.init(width: 1024, height: 256, bytes: one, lz4: true)])
        let budget = TexFile.Budget(limit: (3 << 20) / 2)
        _ = try TexFile(data: data, budget: budget)
        #expect(budget.bytesUsed == one.count)
        #expect(throws: TexFile.Failure.self) { try TexFile(data: data, budget: budget) }
        #expect(budget.bytesUsed == one.count)
    }

    @Test func mipsAfterTheFirstAreNotUnpacked() throws {
        let first = [UInt8](repeating: 9, count: 4 * 4 * 4)
        // The second level claims a gigabyte; it is stepped over, so nothing is allocated or refused.
        let data = EngineFixtures.tex(mips: [
            .init(width: 4, height: 4, bytes: first, lz4: true),
            .init(width: 2, height: 2, bytes: [1, 2, 3, 4], lz4: true, claimed: 1 << 30),
        ])
        let budget = TexFile.Budget(limit: 1 << 20)
        let file = try TexFile(data: data, budget: budget)
        guard case .pixels(4, 4, let rgba) = file.payload else { Issue.record("not pixels"); return }
        #expect(Array(rgba) == first)
        #expect(budget.bytesUsed == first.count)
    }

    @Test func aHugePictureIsRefusedWithoutDecoding() {
        let data = EngineFixtures.tex(mips: [.init(width: 16384, height: 16384, bytes: [0, 0, 0, 0])])
        #expect(throws: TexFile.Failure.self) { try TexFile(data: data) }
    }
}
