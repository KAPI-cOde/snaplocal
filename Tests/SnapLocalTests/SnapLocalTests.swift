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

    @Test("updateImage overwrites pixels, dimensions and thumbnail in place (PLAN.md T7.2)")
    func updateImageOverwritesInPlace() async throws {
        let (vault, dir) = makeTempVault()
        defer { try? FileManager.default.removeItem(at: dir) }

        let saved = try #require(await vault.save(image: makeTestImage(width: 64, height: 64)))
        let originalBytes = try Data(contentsOf: saved.imageURL)

        let ok = await vault.updateImage(id: saved.id, image: makeTestImage(width: 32, height: 16))
        #expect(ok)

        let item = try #require(await vault.allItems().first)
        #expect(item.id == saved.id, "ID・ファイル名は変わらない")
        #expect(item.width == 32 && item.height == 16, "寸法が更新される")
        #expect(try Data(contentsOf: saved.imageURL) != originalBytes, "画像ファイルが上書きされる")
        #expect(await vault.allItems().count == 1, "新規アイテムは作られない")
    }

    @Test("updateImage on unknown id is a safe no-op")
    func updateImageUnknownID() async throws {
        let (vault, dir) = makeTempVault()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ok = await vault.updateImage(id: UUID(), image: makeTestImage())
        #expect(!ok)
        #expect(await vault.allItems().isEmpty)
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

    @Test("VaultManifestEntry decodes legacy JSON without ocrTextPolished key")
    func manifestEntryDecodesWithoutPolishedOCRKey() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "createdAt": 0,
          "filename": "\(id.uuidString).png",
          "thumbFilename": "thumbnails/\(id.uuidString).jpg",
          "ocrText": "raw",
          "annotationsData": null,
          "width": 10,
          "height": 10,
          "title": null,
          "notes": null,
          "isStarred": false
        }
        """

        let entry = try JSONDecoder().decode(VaultManifestEntry.self, from: Data(json.utf8))

        #expect(entry.ocrText == "raw")
        #expect(entry.ocrTextPolished == nil)
    }

    @Test("VaultManifestEntry round-trips ocrTextPolished")
    func manifestEntryRoundTripsPolishedOCR() throws {
        var entry = makeEntry(createdAt: Date(timeIntervalSince1970: 0))
        entry.ocrText = "raw"
        entry.ocrTextPolished = "foo"

        let decoded = try JSONDecoder().decode(
            VaultManifestEntry.self,
            from: JSONEncoder().encode(entry)
        )

        #expect(decoded.ocrText == "raw")
        #expect(decoded.ocrTextPolished == "foo")
    }

    @Test("stripMarkdownDecoration removes common wrappers but preserves dash bullets")
    func stripMarkdownDecoration() {
        let input = """
        ```text
        # 見出し
        **太字**の行
        * 箇条書き
        - 残す行
        ```
        """

        let stripped = OCRPolishService.stripMarkdownDecoration(input)

        #expect(!stripped.contains("```"))
        #expect(!stripped.contains("**"))
        #expect(stripped.contains("見出し"))
        #expect(stripped.contains("箇条書き"))
        #expect(stripped.contains("- 残す行"))
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
        await vault.updateAnnotations(id: saved.id, annotations: [], basis: nil)

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

// MARK: - R4.1 RedactAnnotation persistence compatibility

/// PLAN.md R4.1: MosaicAnnotation/BlurAnnotation を RedactAnnotation に統合。
/// 旧structが書いた on-disk JSON(キー: id/type/color/lineWidth/transform/rect/intensity)を
/// 新コードがそのままデコードできることを固定フィクスチャで証明する。
/// フィクスチャは統合前のコードの JSONEncoder 出力をそのまま貼り付けたもの(形式変更厳禁)。
struct RedactAnnotationCompatTests {

    // 統合前の MosaicAnnotation がエンコードした実出力(transform は translate(5,-3)+rotate(0.3))
    private let legacyMosaicJSON = """
    {"type":"mosaic","id":"B46B7EC4-1D15-4310-9933-99004E4DA7B4","color":"blue","lineWidth":{"thick":{}},"transform":[0.955336489125606,0.29552020666133955,-0.29552020666133955,0.955336489125606,5,-3],"rect":[[10,20],[100,50]],"intensity":14}
    """

    // 統合前の BlurAnnotation がエンコードした実出力(+AnyAnnotation の追加キー opacity/customColorHex)
    private let legacyBlurJSON = """
    {"type":"blur","id":"71F46ED2-E2AF-47F2-945C-6BB520EEA956","color":"red","lineWidth":{"thin":{}},"transform":[1,0,0,1,0,0],"rect":[[-4.5,0],[33.25,7]],"intensity":27.5,"opacity":0.5,"customColorHex":"FF8800FF"}
    """

    @Test("legacy mosaic/blur JSON decodes via AnyAnnotation with fields intact (PLAN.md R4.1)")
    func legacyRedactAnnotationsDecode() throws {
        let data = "[\(legacyMosaicJSON),\(legacyBlurJSON)]".data(using: .utf8)!
        let decoded = try JSONDecoder().decode([AnyAnnotation].self, from: data)
        #expect(decoded.count == 2)

        let mosaic = decoded[0]
        #expect(mosaic.type == .mosaic)
        #expect(mosaic.id == UUID(uuidString: "B46B7EC4-1D15-4310-9933-99004E4DA7B4"))
        #expect(mosaic.color == .blue)
        #expect(mosaic.lineWidth == .thick)
        // bounds は rect.applying(transform) — 回転込みで保存時と同一に再現されること
        let expectedRect = CGRect(x: 10, y: 20, width: 100, height: 50)
            .applying(CGAffineTransform(a: 0.955336489125606, b: 0.29552020666133955,
                                        c: -0.29552020666133955, d: 0.955336489125606, tx: 5, ty: -3))
        let bounds = mosaic.bounds(in: .zero)
        #expect(abs(bounds.minX - expectedRect.minX) < 0.001 && abs(bounds.width - expectedRect.width) < 0.001)

        let blur = decoded[1]
        #expect(blur.type == .blur)
        #expect(blur.bounds(in: .zero) == CGRect(x: -4.5, y: 0, width: 33.25, height: 7))
        #expect(blur.opacity == 0.5)
        #expect(blur.customColorHex == "FF8800FF")
    }

    @Test("re-encoded redact annotations keep the legacy key set (downgrade-safe) (PLAN.md R4.1)")
    func reEncodeKeepsLegacyKeySet() throws {
        let data = "[\(legacyMosaicJSON),\(legacyBlurJSON)]".data(using: .utf8)!
        let decoded = try JSONDecoder().decode([AnyAnnotation].self, from: data)
        for (annotation, fixture) in zip(decoded, [legacyMosaicJSON, legacyBlurJSON]) {
            let reEncoded = try JSONEncoder().encode(annotation)
            let newKeys = Set((try JSONSerialization.jsonObject(with: reEncoded) as! [String: Any]).keys)
            let oldKeys = Set((try JSONSerialization.jsonObject(with: fixture.data(using: .utf8)!) as! [String: Any]).keys)
            #expect(newKeys == oldKeys, "encoded key set must not drift from legacy format")
        }
        // 再エンコード→再デコードも同値(ロスレス)
        let roundTripped = try JSONDecoder().decode([AnyAnnotation].self, from: JSONEncoder().encode(decoded))
        #expect(roundTripped[0].bounds(in: .zero) == decoded[0].bounds(in: .zero))
        #expect(roundTripped[1].bounds(in: .zero) == decoded[1].bounds(in: .zero))
    }
}
