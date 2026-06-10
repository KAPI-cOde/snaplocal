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

    @Test("cleanOrphans is a no-op when manifest is empty (corrupt index.json guard)")
    func cleanOrphansNoOpOnEmptyManifest() async throws {
        let (vault, dir) = makeTempVault()
        defer { try? FileManager.default.removeItem(at: dir) }

        // UUID-named PNG present but manifest empty (= index.json unreadable scenario):
        // cleanup must not touch anything.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let strayPNG = dir.appendingPathComponent("\(UUID().uuidString).png")
        try Data([0x89, 0x50]).write(to: strayPNG)

        let trashed = await vault.cleanOrphans()

        #expect(trashed == 0)
        #expect(FileManager.default.fileExists(atPath: strayPNG.path))
    }

    @Test("cleanOrphans never touches non-vault-named files (user files guard)")
    func cleanOrphansIgnoresNonUUIDFiles() async throws {
        let (vault, dir) = makeTempVault()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try #require(await vault.save(image: makeTestImage()))
        let userPNG = dir.appendingPathComponent("my-vacation-photo.png")
        try Data([0x89, 0x50]).write(to: userPNG)

        let trashed = await vault.cleanOrphans()

        #expect(trashed == 0)
        #expect(FileManager.default.fileExists(atPath: userPNG.path))
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

        let trashed = await vault.cleanOrphans(olderThan: 0)

        #expect(trashed == 2)
        #expect(!FileManager.default.fileExists(atPath: orphanPNG.path))
        #expect(!FileManager.default.fileExists(atPath: orphanJPG.path))
        // The indexed item must survive
        let all = await vault.allItems()
        #expect(all.count == 1)
        #expect(FileManager.default.fileExists(atPath: all[0].imageURL.path))
    }

    private func shardURLs(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: dir.appendingPathComponent("index", isDirectory: true),
            includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func makeEntry(createdAt: Date, title: String? = nil) -> VaultManifestEntry {
        let id = UUID()
        return VaultManifestEntry(
            id: id, createdAt: createdAt,
            filename: "\(id.uuidString).png",
            thumbFilename: "thumbnails/\(id.uuidString).jpg",
            ocrText: "", annotationsData: nil,
            width: 10, height: 10, title: title, notes: nil)
    }

    @Test("cleanOrphans keeps recently-modified files (cloud sync grace window)")
    func cleanOrphansKeepsRecentFiles() async throws {
        let (vault, dir) = makeTempVault()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try #require(await vault.save(image: makeTestImage()))

        // 直近に書かれた未登録PNG = 他マシンからの同期で画像が先に届いた状況。
        // シャードJSONが追いつくまで猶予し、ゴミ箱送りにしてはいけない
        let syncing = dir.appendingPathComponent("\(UUID().uuidString).png")
        try Data([0x89, 0x50]).write(to: syncing)

        let trashed = await vault.cleanOrphans()   // 既定の猶予(48h)

        #expect(trashed == 0)
        #expect(FileManager.default.fileExists(atPath: syncing.path))
    }

    @Test("no-op updates do not rewrite the index shard (PLAN.md T5.2)")
    func noOpUpdateDoesNotRewriteManifest() async throws {
        let (vault, dir) = makeTempVault()
        defer { try? FileManager.default.removeItem(at: dir) }

        let saved = try #require(await vault.save(image: makeTestImage()))
        await vault.updateOCR(id: saved.id, text: "hello")

        let shardURL = try #require(shardURLs(in: dir).first)
        let mtimeBefore = try FileManager.default
            .attributesOfItem(atPath: shardURL.path)[.modificationDate] as! Date

        // Same values again — none of these should touch the file
        await vault.updateOCR(id: saved.id, text: "hello")
        await vault.updateTitle(id: saved.id, title: nil)
        await vault.updateNotes(id: saved.id, notes: nil)
        await vault.updateAnnotations(id: saved.id, annotations: [])

        let mtimeAfter = try FileManager.default
            .attributesOfItem(atPath: shardURL.path)[.modificationDate] as! Date
        #expect(mtimeBefore == mtimeAfter, "no-op updates must not rewrite the index shard")

        // A real change must rewrite it
        await vault.updateOCR(id: saved.id, text: "changed")
        let mtimeChanged = try FileManager.default
            .attributesOfItem(atPath: shardURL.path)[.modificationDate] as! Date
        #expect(mtimeBefore != mtimeChanged)
    }

    @Test("legacy index.json migrates to monthly shards with .bak left behind (PLAN.md T6.1)")
    func legacyIndexMigratesToShards() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapLocalTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 旧形式: 異なる月の2エントリを単一 index.json に置く
        let recent = makeEntry(createdAt: Date(), title: "recent")
        let old = makeEntry(createdAt: Date(timeIntervalSinceNow: -40 * 86400), title: "old")
        let legacy = try JSONEncoder().encode([recent, old])
        try legacy.write(to: dir.appendingPathComponent("index.json"))

        let vault = PersistentVault(directory: dir)
        let all = await vault.allItems()

        #expect(all.count == 2, "migrated entries must all load")
        #expect(shardURLs(in: dir).count == 2, "entries from different months go to different shards")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.json").path),
                "legacy index.json should be retired")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("index.json.bak").path),
                "legacy index must be kept as .bak, never deleted")
    }

    @Test("saving touches only the current month's shard (PLAN.md T6.1)")
    func saveWritesOnlyCurrentMonthShard() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapLocalTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let indexDir = dir.appendingPathComponent("index", isDirectory: true)
        try FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)

        // 過去月のシャードを直接seed
        let oldShard = indexDir.appendingPathComponent("2020-01.json")
        let oldEntry = makeEntry(createdAt: Date(timeIntervalSince1970: 1_577_900_000)) // 2020-01
        try JSONEncoder().encode([oldEntry]).write(to: oldShard)
        let oldData = try Data(contentsOf: oldShard)

        let vault = PersistentVault(directory: dir)
        _ = try #require(await vault.save(image: makeTestImage()))

        #expect(shardURLs(in: dir).count == 2, "save creates the current month's shard")
        #expect(try Data(contentsOf: oldShard) == oldData, "past month shard must stay byte-identical")
        #expect(await vault.allItems().count == 2)
    }

    @Test("cloud-sync conflict copies are merged without data loss (PLAN.md T6.1)")
    func conflictCopyShardsAreMerged() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapLocalTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let indexDir = dir.appendingPathComponent("index", isDirectory: true)
        try FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)

        // 正規シャードと、同じ月の競合コピー(Drive風の命名)。
        // shared は両方に存在し title が食い違う → 正規が勝つ。
        // copyOnly は競合コピーにしか無い → 取りこぼさず読み込み、正規シャードへ定着する。
        var shared = makeEntry(createdAt: Date(timeIntervalSince1970: 1_577_900_000), title: "canonical")
        let copyOnly = makeEntry(createdAt: Date(timeIntervalSince1970: 1_577_900_100), title: "copy-only")
        try JSONEncoder().encode([shared]).write(to: indexDir.appendingPathComponent("2020-01.json"))
        shared.title = "conflict-copy"
        try JSONEncoder().encode([shared, copyOnly]).write(to: indexDir.appendingPathComponent("2020-01 (1).json"))

        let vault = PersistentVault(directory: dir)
        let all = await vault.allItems()

        #expect(all.count == 2, "entries that only exist in a conflict copy must not be lost")
        #expect(all.first(where: { $0.id == shared.id })?.title == "canonical",
                "on duplicate IDs the canonical shard wins")
        // 競合コピー由来のエントリは正規シャードに書き戻されている
        let canonical = try JSONDecoder().decode([VaultManifestEntry].self,
            from: Data(contentsOf: indexDir.appendingPathComponent("2020-01.json")))
        #expect(canonical.contains(where: { $0.id == copyOnly.id }))
        // 競合コピー自体は消さない(ユーザーのファイルを勝手に削除しない)
        #expect(FileManager.default.fileExists(atPath: indexDir.appendingPathComponent("2020-01 (1).json").path))
    }

    @Test("search matches annotation text from legacy entries without annotationTexts key (PLAN.md T6.2)")
    func searchMatchesLegacyAnnotationText() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapLocalTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let indexDir = dir.appendingPathComponent("index", isDirectory: true)
        try FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)

        // 旧形式エントリ: annotationsData はあるが annotationTexts キーが無い
        var entry = makeEntry(createdAt: Date(timeIntervalSince1970: 1_577_900_000), title: "no-match")
        let textAnn = AnyAnnotation(TextAnnotation(
            color: .red, rect: CGRect(x: 0, y: 0, width: 100, height: 30), text: "目印テキスト"))
        entry.annotationsData = try JSONEncoder().encode([textAnn])
        entry.annotationTexts = nil
        try JSONEncoder().encode([entry]).write(to: indexDir.appendingPathComponent("2020-01.json"))

        let vault = PersistentVault(directory: dir)

        let hit = await vault.search(query: "目印")
        #expect(hit.count == 1, "annotation text must be searchable without the additive key (backfilled at load)")
        let miss = await vault.search(query: "ヒットしない語")
        #expect(miss.isEmpty)
    }

    @Test("light-path search over 10k entries stays under 100ms (PLAN.md T6.2)")
    func searchPerformanceWith10kEntries() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapLocalTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let indexDir = dir.appendingPathComponent("index", isDirectory: true)
        try FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)

        var entries: [VaultManifestEntry] = []
        entries.reserveCapacity(10_000)
        for i in 0..<10_000 {
            var e = makeEntry(createdAt: Date(timeIntervalSince1970: 1_577_900_000 + Double(i) * 60))
            e.ocrText = "月次レポート ダッシュボード 請求書 entry-\(i) Acme Analytics weekly visitors sign-ups churn rate overview"
            entries.append(e)
        }
        try JSONEncoder().encode(entries).write(to: indexDir.appendingPathComponent("2020-01.json"))

        let vault = PersistentVault(directory: dir)

        let hitStart = Date()
        let hits = await vault.search(query: "entry-4321")
        let hitTime = Date().timeIntervalSince(hitStart)

        let missStart = Date()
        let misses = await vault.search(query: "存在しない検索語")
        let missTime = Date().timeIntervalSince(missStart)

        #expect(hits.count == 1)
        #expect(misses.isEmpty)
        // PLAN.md T6.2 受け入れ条件: 1万件で検索応答 <100ms
        #expect(hitTime < 0.1, "search over 10k entries must respond in <100ms")
        #expect(missTime < 0.1)
        print("[perf] search x10k — hit: \(Int(hitTime * 1000))ms, miss: \(Int(missTime * 1000))ms")
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
