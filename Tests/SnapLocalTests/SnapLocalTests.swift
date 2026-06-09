import Testing
import Foundation
import CoreGraphics
@testable import SnapLocalApp

// SnapLocalApp uses ScreenCaptureKit and Vision framework APIs that require
// a running macOS app context, so unit tests are limited to data-layer logic
// (PersistentVault). Integration testing is done by running the app manually.
//
// NOTE: `swift test` requires a full Xcode toolchain (swift-testing is not
// bundled with Command Line Tools). On CLT-only machines, rely on CI.

@Suite("PersistentVault", .serialized)
struct PersistentVaultTests {

    private func makeTempVault() -> (PersistentVault, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapLocalTests-\(UUID().uuidString)", isDirectory: true)
        return (PersistentVault(directory: dir), dir)
    }

    private func makeTestImage(width: Int = 64, height: Int = 64) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    @Test("save → allItems roundtrip")
    func saveAndLoadRoundtrip() async throws {
        let (vault, dir) = makeTempVault()
        defer { try? FileManager.default.removeItem(at: dir) }

        let saved = try #require(await vault.save(image: makeTestImage()))
        let all = await vault.allItems()

        #expect(all.count == 1)
        #expect(all.first?.id == saved.id)
        #expect(all.first?.width == 64)
        #expect(FileManager.default.fileExists(atPath: saved.imageURL.path))
        #expect(!(all.first!.thumbnailData.isEmpty), "thumbnail should be generated")
    }

    @Test("delete removes files and index entry")
    func deleteRemovesFiles() async throws {
        let (vault, dir) = makeTempVault()
        defer { try? FileManager.default.removeItem(at: dir) }

        let saved = try #require(await vault.save(image: makeTestImage()))
        await vault.delete(id: saved.id)

        #expect(await vault.allItems().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: saved.imageURL.path))
    }

    @Test("cleanOrphans trashes unindexed files, keeps indexed ones (PLAN.md T5.2)")
    func cleanOrphansTrashesUnindexedFiles() async throws {
        let (vault, dir) = makeTempVault()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try #require(await vault.save(image: makeTestImage()))

        // Plant orphans: a PNG and a thumbnail JPEG not present in index.json
        let orphanPNG = dir.appendingPathComponent("\(UUID().uuidString).png")
        let orphanJPG = dir.appendingPathComponent("thumbnails/\(UUID().uuidString).jpg")
        try Data([0x89, 0x50]).write(to: orphanPNG)
        try Data([0xFF, 0xD8]).write(to: orphanJPG)

        let trashed = await vault.cleanOrphans()

        #expect(trashed == 2)
        #expect(!FileManager.default.fileExists(atPath: orphanPNG.path))
        #expect(!FileManager.default.fileExists(atPath: orphanJPG.path))
        // The indexed item must survive
        let all = await vault.allItems()
        #expect(all.count == 1)
        #expect(FileManager.default.fileExists(atPath: all[0].imageURL.path))
    }

    @Test("no-op updates do not rewrite index.json (PLAN.md T5.2)")
    func noOpUpdateDoesNotRewriteManifest() async throws {
        let (vault, dir) = makeTempVault()
        defer { try? FileManager.default.removeItem(at: dir) }

        let saved = try #require(await vault.save(image: makeTestImage()))
        await vault.updateOCR(id: saved.id, text: "hello")

        let indexURL = dir.appendingPathComponent("index.json")
        let mtimeBefore = try FileManager.default
            .attributesOfItem(atPath: indexURL.path)[.modificationDate] as! Date

        // Same values again — none of these should touch the file
        await vault.updateOCR(id: saved.id, text: "hello")
        await vault.updateTitle(id: saved.id, title: nil)
        await vault.updateNotes(id: saved.id, notes: nil)
        await vault.updateAnnotations(id: saved.id, annotations: [])

        let mtimeAfter = try FileManager.default
            .attributesOfItem(atPath: indexURL.path)[.modificationDate] as! Date
        #expect(mtimeBefore == mtimeAfter, "no-op updates must not rewrite index.json")

        // A real change must rewrite it
        await vault.updateOCR(id: saved.id, text: "changed")
        let mtimeChanged = try FileManager.default
            .attributesOfItem(atPath: indexURL.path)[.modificationDate] as! Date
        #expect(mtimeBefore != mtimeChanged)
    }

    @Test("allItems with 200 items — warm cache is fast (PLAN.md T5.3/T4.2)")
    func allItemsPerformanceWith200Items() async throws {
        let (vault, dir) = makeTempVault()
        defer { try? FileManager.default.removeItem(at: dir) }

        let image = makeTestImage(width: 50, height: 50)
        for _ in 0..<200 {
            _ = await vault.save(image: image)
        }

        // Cold: first read hits disk for every thumbnail
        let coldStart = Date()
        let cold = await vault.allItems()
        let coldTime = Date().timeIntervalSince(coldStart)

        // Warm: thumbnails served from NSCache (T4.2)
        let warmStart = Date()
        let warm = await vault.allItems()
        let warmTime = Date().timeIntervalSince(warmStart)

        #expect(cold.count == 200)
        #expect(warm.count == 200)
        // 閾値はPLAN.md T5.3の「操作応答>100ms」に余裕を持たせた値
        #expect(warmTime < 0.5, "warm allItems() for 200 items should be served from cache")
        print("[perf] allItems x200 — cold: \(Int(coldTime * 1000))ms, warm: \(Int(warmTime * 1000))ms")
    }
}
