// PersistentVault.swift
// Disk-first screenshot storage. Every capture is saved as a PNG file.
// The save directory can point to any folder including Google Drive.

import Foundation
import AppKit
import Vision

// MARK: - Manifest Entry (lightweight, stored in index.json)

struct VaultManifestEntry: Codable, Sendable {
    var id: UUID
    var createdAt: Date
    var filename: String        // {uuid}.png
    var thumbFilename: String   // thumbnails/{uuid}.jpg
    var ocrText: String
    var annotationsData: Data?  // JSON-encoded [AnyAnnotation]
    /// テキストアノテーションの平文(検索用)。annotationsDataのデコードなしに検索できるようにする
    /// 追加キー(T6.2)— 旧エントリでは nil で、読み込み時に一度だけ補完される
    var annotationTexts: String? = nil
    /// annotationsData の座標が表現されている基準キャンバスサイズ(保存時の表示サイズ)。
    /// 追加キー(T9.5)— nil = 旧データ(基準不明、ロード時は換算なしで現サイズを採用)
    var annotationsBasis: CGSize? = nil
    var width: Int
    var height: Int
    var title: String?
    var notes: String?
    var isStarred: Bool = false
}

// MARK: - VaultItem (in-memory representation for UI)

struct VaultItem: Identifiable, Sendable {
    let id: UUID
    let createdAt: Date
    let imageURL: URL
    let thumbnailData: Data
    var ocrText: String
    var annotations: [AnyAnnotation]
    /// annotations の基準キャンバスサイズ(T9.5)。nil = 旧データ
    var annotationsBasis: CGSize? = nil
    var title: String?
    var notes: String?
    var width: Int = 0
    var height: Int = 0
    var isStarred: Bool = false

    var dimensionLabel: String {
        guard width > 0, height > 0 else { return "" }
        return "\(width)×\(height)"
    }

    // Load full image on demand (triggers disk read, call from background)
    var imageData: Data { (try? Data(contentsOf: imageURL)) ?? Data() }
}

// MARK: - PersistentVault

actor PersistentVault {
    private var baseDirectory: URL
    private var thumbDirectory: URL
    /// 月別シャード(index/YYYY-MM.json)の置き場所。PLAN.md T6.1
    /// 書き込みは変更があったシャードだけ → 過去月は不変になり、クラウド同期が差分だけで済む
    private var indexDirectory: URL
    private var legacyIndexURL: URL             // 旧形式の単一 index.json(移行後は index.json.bak)
    private var manifest: [UUID: VaultManifestEntry] = [:]
    private var orderedIDs: [UUID] = []         // newest first
    private var shardOf: [UUID: String] = [:]   // entry id → "YYYY-MM"(エントリが属するシャード)
    /// 検索用テキスト(OCR+タイトル+ノート+注釈平文)のメモリキャッシュ。
    /// 検索のたびに annotationsData をデコードしない(T6.2)
    private var searchText: [UUID: String] = [:]
    private let thumbnailSize = CGSize(width: 200, height: 130)
    /// サムネイルJPEGのメモリキャッシュ。allItems()/search()が呼ばれるたびに
    /// 全件をディスクから読み直すのを防ぐ。コスト=バイト数、上限50MB。
    private let thumbDataCache = NSCache<NSString, NSData>()

    init(directory: URL? = nil) {
        let dir = directory ?? {
            let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
            return pictures.appendingPathComponent("SnapLocal", isDirectory: true)
        }()
        self.baseDirectory = dir
        self.thumbDirectory = dir.appendingPathComponent("thumbnails", isDirectory: true)
        self.indexDirectory = dir.appendingPathComponent("index", isDirectory: true)
        self.legacyIndexURL = dir.appendingPathComponent("index.json")
        thumbDataCache.totalCostLimit = 50 * 1024 * 1024
        // Setup inline (can't call isolated methods from actor init in Swift 6)
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: dir.appendingPathComponent("thumbnails"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: indexDirectory, withIntermediateDirectories: true)

        // 1. シャード読み込み(クラウド同期の競合コピーも吸収する — 重複IDは正規ファイルが勝つ)
        var loaded = Self.loadShards(from: indexDirectory)

        // 2. 旧形式 index.json からの自動移行(シャードに無いエントリだけ取り込む)
        var dirtyShards = loaded.dirtyShards
        let legacyExists = fm.fileExists(atPath: legacyIndexURL.path)
        if legacyExists,
           let data = try? Data(contentsOf: legacyIndexURL),
           let entries = try? JSONDecoder().decode([VaultManifestEntry].self, from: data) {
            for entry in entries where loaded.manifest[entry.id] == nil {
                let key = Self.monthKey(for: entry.createdAt)
                loaded.manifest[entry.id] = entry
                loaded.shardOf[entry.id] = key
                dirtyShards.insert(key)
            }
        }

        self.manifest = loaded.manifest
        self.shardOf = loaded.shardOf
        self.orderedIDs = loaded.manifest.values.sorted { $0.createdAt > $1.createdAt }.map(\.id)

        // T6.2: 検索用テキストキャッシュを構築。annotationTexts 未保存の旧エントリは
        // ここで一度だけアノテーションをデコードして補完する(メモリ内のみ。
        // 次にそのエントリが変更された時に追加キーとして永続化される)
        for (id, entry) in self.manifest {
            var entry = entry
            if entry.annotationTexts == nil, let data = entry.annotationsData,
               let anns = try? JSONDecoder().decode([AnyAnnotation].self, from: data) {
                entry.annotationTexts = anns.compactMap { $0.textContent }.joined(separator: " ")
                self.manifest[id] = entry
            }
            self.searchText[id] = Self.searchText(for: entry)
        }

        // 3. 移行・競合吸収分をディスクへ反映し、旧 index.json は index.json.bak として退役
        //    (削除はしない — 既存ユーザーの履歴を壊す経路を残さないため)
        var allWritten = true
        for key in dirtyShards {
            let entries = self.orderedIDs.compactMap { loaded.manifest[$0] }.filter { loaded.shardOf[$0.id] == key }
            if !Self.writeShardFile(entries: entries, key: key, indexDirectory: indexDirectory) { allWritten = false }
        }
        if legacyExists && allWritten {
            let bak = dir.appendingPathComponent("index.json.bak")
            if !fm.fileExists(atPath: bak.path) {
                try? fm.moveItem(at: legacyIndexURL, to: bak)
            }
            // bak が既にある場合は index.json を残す(次回起動でも同じ結果になるだけで無害)
        }
    }

    // MARK: - Public API

    /// Save a new screenshot. Returns the VaultItem immediately (OCR runs separately).
    /// annotationsBasis: 注釈座標の基準キャンバスサイズ(T9.5)。注釈ありなら必ず渡す
    func save(image: CGImage, annotations: [AnyAnnotation] = [],
              annotationsBasis: CGSize? = nil) async -> VaultItem? {
        let id = UUID()
        let filename = "\(id.uuidString).png"
        let thumbFilename = "thumbnails/\(id.uuidString).jpg"
        let imageURL = baseDirectory.appendingPathComponent(filename)
        let thumbURL = baseDirectory.appendingPathComponent(thumbFilename)

        guard let pngData = image.pngData() else { return nil }
        let thumbData = jpegThumbnail(from: image) ?? Data()

        do {
            try pngData.write(to: imageURL, options: .atomic)
            try thumbData.write(to: thumbURL, options: .atomic)
        } catch {
            return nil
        }
        thumbDataCache.setObject(thumbData as NSData,
                                 forKey: thumbFilename as NSString,
                                 cost: thumbData.count)

        let annotationsData = try? JSONEncoder().encode(annotations)
        let entry = VaultManifestEntry(
            id: id,
            createdAt: Date(),
            filename: filename,
            thumbFilename: thumbFilename,
            ocrText: "",
            annotationsData: annotationsData,
            annotationTexts: annotations.compactMap { $0.textContent }.joined(separator: " "),
            annotationsBasis: annotations.isEmpty ? nil : annotationsBasis,
            width: image.width,
            height: image.height
        )
        manifest[id] = entry
        orderedIDs.insert(id, at: 0)
        persist(id)

        return VaultItem(
            id: id,
            createdAt: entry.createdAt,
            imageURL: imageURL,
            thumbnailData: thumbData,
            ocrText: "",
            annotations: annotations,
            annotationsBasis: entry.annotationsBasis,
            title: nil,
            notes: nil,
            width: image.width,
            height: image.height
        )
    }

    /// Update OCR text for an item (called after async OCR finishes)
    func updateOCR(id: UUID, text: String) {
        guard let entry = manifest[id], entry.ocrText != text else { return }
        manifest[id]!.ocrText = text
        persist(id)
    }

    /// Update title/label for an item
    func updateTitle(id: UUID, title: String?) {
        let normalized = title?.isEmpty == true ? nil : title
        guard let entry = manifest[id], entry.title != normalized else { return }
        manifest[id]!.title = normalized
        persist(id)
    }

    /// Update freeform notes for an item
    func updateNotes(id: UUID, notes: String?) {
        let normalized = notes?.isEmpty == true ? nil : notes
        guard let entry = manifest[id], entry.notes != normalized else { return }
        manifest[id]!.notes = normalized
        persist(id)
    }

    /// Toggle star (favorite) status for an item
    func toggleStar(id: UUID) {
        guard manifest[id] != nil else { return }
        manifest[id]!.isStarred.toggle()
        persist(id)
    }

    /// 最新の注釈+基準サイズをディスク(manifest)から読む(T9.5)。
    /// UI の history 配列はロード時のスナップショットで、項目切替の persist を反映しない。
    /// 古い注釈を resetAndLoad → オートセーブで保存し直すと直前の編集が巻き戻るため、
    /// キャンバスへのロードは必ずこちらを使う
    func currentAnnotations(id: UUID) -> ([AnyAnnotation], CGSize?)? {
        guard let entry = manifest[id] else { return nil }
        let anns = entry.annotationsData
            .flatMap { try? JSONDecoder().decode([AnyAnnotation].self, from: $0) } ?? []
        return (anns, entry.annotationsBasis)
    }

    /// Update annotations for an item
    /// basis: 注釈座標の基準キャンバスサイズ(T9.5)。注釈とセットで常に更新する
    func updateAnnotations(id: UUID, annotations: [AnyAnnotation], basis: CGSize?) {
        guard let entry = manifest[id] else { return }
        let newData = try? JSONEncoder().encode(annotations)
        let newBasis = annotations.isEmpty ? nil : basis
        // 内容が同じならシャードを書き直さない(クラウド同期フォルダでの無駄な同期防止)
        guard entry.annotationsData != newData || entry.annotationsBasis != newBasis else { return }
        manifest[id]!.annotationsData = newData
        manifest[id]!.annotationTexts = annotations.compactMap { $0.textContent }.joined(separator: " ")
        manifest[id]!.annotationsBasis = newBasis
        persist(id)
    }

    /// Overwrite the thumbnail file with an annotated image (call after baking annotations).
    func updateThumbnail(id: UUID, annotatedImage: CGImage) {
        guard let entry = manifest[id] else { return }
        let thumbURL = baseDirectory.appendingPathComponent(entry.thumbFilename)
        if let thumbData = jpegThumbnail(from: annotatedImage) {
            try? thumbData.write(to: thumbURL, options: .atomic)
            thumbDataCache.setObject(thumbData as NSData,
                                     forKey: entry.thumbFilename as NSString,
                                     cost: thumbData.count)
        }
    }

    /// 背景編集(クロップ・回転・結合等)を既存アイテムへ上書き保存する(T7.2)。
    /// ファイル名・IDは変えない(同一セッション内でフォーク済みのアイテムの続き編集用)。
    /// 寸法を更新し、サムネイルも再生成する
    func updateImage(id: UUID, image: CGImage) -> Bool {
        guard let entry = manifest[id], let png = image.pngData() else { return false }
        let imageURL = baseDirectory.appendingPathComponent(entry.filename)
        do { try png.write(to: imageURL, options: .atomic) } catch { return false }
        manifest[id]!.width = image.width
        manifest[id]!.height = image.height
        if let thumbData = jpegThumbnail(from: image) {
            try? thumbData.write(to: baseDirectory.appendingPathComponent(entry.thumbFilename), options: .atomic)
            thumbDataCache.setObject(thumbData as NSData,
                                     forKey: entry.thumbFilename as NSString,
                                     cost: thumbData.count)
        }
        persist(id)
        return true
    }

    /// インデックスに載っていない画像/サムネイルをゴミ箱へ移動する(復元可能)。
    /// 「消したはずの画像がディスクに残る」事故を防ぐ起動時クリーンアップ(PLAN.md T5.2)。
    ///
    /// データ安全ガード:
    /// - manifestが空なら何もしない(インデックスがクラウド同期競合等で読めなかった場合に
    ///   全ファイルを孤児と誤認して履歴全体をゴミ箱送りにする事故を防ぐ)
    /// - vault自身の命名規則 `{UUID}.png/jpg` に一致するファイルだけを対象にする
    ///   (保存先にユーザー自身のPNGがあるフォルダを指定しているケースを保護)
    /// - 更新が `olderThan`(既定48時間)以内のファイルは残す。クラウド同期vaultを
    ///   複数マシンで使うと、他マシンの画像PNGが先に届きシャードJSONが遅れることがある —
    ///   その瞬間に起動しても正規の画像を孤児と誤認しない(同期猶予)
    func cleanOrphans(olderThan grace: TimeInterval = 48 * 3600) -> Int {
        guard !manifest.isEmpty else { return 0 }
        let fm = FileManager.default
        let cutoff = Date(timeIntervalSinceNow: -grace)
        let validImages = Set(manifest.values.map { $0.filename })
        let validThumbs = Set(manifest.values.map { ($0.thumbFilename as NSString).lastPathComponent })
        func isVaultNamed(_ url: URL) -> Bool {
            UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
        }
        func isPastGrace(_ url: URL) -> Bool {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return (mtime ?? .distantPast) <= cutoff
        }
        var trashed = 0
        if let files = try? fm.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for url in files
            where url.pathExtension.lowercased() == "png"
                && isVaultNamed(url)
                && !validImages.contains(url.lastPathComponent)
                && isPastGrace(url) {
                if (try? fm.trashItem(at: url, resultingItemURL: nil)) != nil { trashed += 1 }
            }
        }
        if let files = try? fm.contentsOfDirectory(at: thumbDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for url in files
            where url.pathExtension.lowercased() == "jpg"
                && isVaultNamed(url)
                && !validThumbs.contains(url.lastPathComponent)
                && isPastGrace(url) {
                if (try? fm.trashItem(at: url, resultingItemURL: nil)) != nil { trashed += 1 }
            }
        }
        return trashed
    }

    /// Delete an item and its files
    func delete(id: UUID) {
        guard let entry = manifest[id] else { return }
        try? FileManager.default.removeItem(at: baseDirectory.appendingPathComponent(entry.filename))
        try? FileManager.default.removeItem(at: baseDirectory.appendingPathComponent(entry.thumbFilename))
        thumbDataCache.removeObject(forKey: entry.thumbFilename as NSString)
        manifest.removeValue(forKey: id)
        orderedIDs.removeAll { $0 == id }
        persist(id)
    }

    /// Duplicate an item (copy files, new UUID, current timestamp)
    func duplicate(id: UUID) -> VaultItem? {
        guard let src = manifest[id] else { return nil }
        let newID = UUID()
        let newFilename = "\(newID.uuidString).png"
        let newThumb = "thumbnails/\(newID.uuidString).jpg"
        let srcURL = baseDirectory.appendingPathComponent(src.filename)
        let dstURL = baseDirectory.appendingPathComponent(newFilename)
        let srcThumb = baseDirectory.appendingPathComponent(src.thumbFilename)
        let dstThumb = baseDirectory.appendingPathComponent(newThumb)
        do {
            try FileManager.default.copyItem(at: srcURL, to: dstURL)
            try FileManager.default.copyItem(at: srcThumb, to: dstThumb)
        } catch { return nil }
        var entry = src
        entry.id = newID
        entry.createdAt = Date()
        entry.filename = newFilename
        entry.thumbFilename = newThumb
        manifest[newID] = entry
        orderedIDs.insert(newID, at: 0)
        persist(newID)
        let thumbData = cachedThumbnailData(for: entry)
        let annotations = entry.annotationsData
            .flatMap { try? JSONDecoder().decode([AnyAnnotation].self, from: $0) } ?? []
        return VaultItem(id: newID, createdAt: entry.createdAt, imageURL: dstURL,
                         thumbnailData: thumbData, ocrText: entry.ocrText,
                         annotations: annotations, annotationsBasis: entry.annotationsBasis,
                         title: entry.title,
                         notes: entry.notes, width: entry.width, height: entry.height)
    }

    /// All items, newest first
    func allItems() -> [VaultItem] {
        orderedIDs.compactMap { item(for: $0) }
    }

    /// Search items by OCR text / title / notes / annotation text.
    /// 軽量パス(T6.2): テキストだけを先にスキャンし、VaultItem(サムネイル読み・
    /// アノテーションのJSONデコード)はヒットした分だけ組み立てる
    func search(query: String) -> [VaultItem] {
        guard !query.isEmpty else { return allItems() }
        return orderedIDs
            .filter { searchText[$0]?.localizedCaseInsensitiveContains(query) ?? false }
            .compactMap { item(for: $0) }
    }

    /// manifest エントリから UI 用の VaultItem を組み立てる(サムネイル読み+アノテーションデコード)
    private func item(for id: UUID) -> VaultItem? {
        guard let entry = manifest[id] else { return nil }
        let imageURL = baseDirectory.appendingPathComponent(entry.filename)
        let thumbData = cachedThumbnailData(for: entry)
        let annotations = entry.annotationsData
            .flatMap { try? JSONDecoder().decode([AnyAnnotation].self, from: $0) } ?? []
        return VaultItem(
            id: entry.id,
            createdAt: entry.createdAt,
            imageURL: imageURL,
            thumbnailData: thumbData,
            ocrText: entry.ocrText,
            annotations: annotations,
            annotationsBasis: entry.annotationsBasis,
            title: entry.title,
            notes: entry.notes,
            width: entry.width,
            height: entry.height,
            isStarred: entry.isStarred
        )
    }

    // MARK: - Private

    /// キャッシュ経由でサムネイルJPEGを読む。キーは thumbFilename(UUID入り)。
    private func cachedThumbnailData(for entry: VaultManifestEntry) -> Data {
        let key = entry.thumbFilename as NSString
        if let cached = thumbDataCache.object(forKey: key) { return cached as Data }
        guard let data = try? Data(contentsOf: baseDirectory.appendingPathComponent(entry.thumbFilename)) else {
            return Data()
        }
        thumbDataCache.setObject(data as NSData, forKey: key, cost: data.count)
        return data
    }

    // MARK: - Shard persistence (PLAN.md T6.1)

    /// 変更されたエントリが属するシャードだけを書き出す(他の月のファイルは触らない)。
    /// 検索用テキストキャッシュの更新もここで一元化する
    private func persist(_ id: UUID) {
        searchText[id] = manifest[id].map { Self.searchText(for: $0) }
        let key = shardOf[id]
            ?? manifest[id].map { Self.monthKey(for: $0.createdAt) }
            ?? Self.monthKey(for: Date())
        shardOf[id] = manifest[id] != nil ? key : nil   // 削除済みならマッピングも消す
        writeShard(key)
    }

    private static func searchText(for entry: VaultManifestEntry) -> String {
        [entry.ocrText, entry.title ?? "", entry.notes ?? "", entry.annotationTexts ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func writeShard(_ key: String) {
        let entries = orderedIDs.compactMap { manifest[$0] }.filter { shardOf[$0.id] == key }
        Self.writeShardFile(entries: entries, key: key, indexDirectory: indexDirectory)
    }

    private struct LoadedShards {
        var manifest: [UUID: VaultManifestEntry] = [:]
        var shardOf: [UUID: String] = [:]
        var dirtyShards: Set<String> = []
    }

    /// index/ 内の全 .json を読む。正規名(YYYY-MM.json)以外のファイル(クラウド同期の
    /// 競合コピー等)も読んでエントリの取りこぼしを防ぐ。重複IDは正規ファイルが勝つ。
    private static func loadShards(from indexDirectory: URL) -> LoadedShards {
        var result = LoadedShards()
        guard let files = try? FileManager.default.contentsOfDirectory(at: indexDirectory, includingPropertiesForKeys: nil) else {
            return result
        }
        let jsons = files.filter { $0.pathExtension.lowercased() == "json" }
        // 競合コピー → 正規 の順で読む(後勝ちなので正規が優先される)
        let ordered = jsons.filter { canonicalShardKey(of: $0) == nil } + jsons.filter { canonicalShardKey(of: $0) != nil }
        for url in ordered {
            guard let data = try? Data(contentsOf: url),
                  let entries = try? JSONDecoder().decode([VaultManifestEntry].self, from: data) else { continue }
            let canonical = canonicalShardKey(of: url)
            for entry in entries {
                let key = canonical ?? shardKeyPrefix(of: url) ?? monthKey(for: entry.createdAt)
                result.manifest[entry.id] = entry
                result.shardOf[entry.id] = key
                // 競合コピー由来のエントリは正規シャードへ書き戻して定着させる
                if canonical == nil { result.dirtyShards.insert(key) }
            }
        }
        return result
    }

    /// "2026-06.json" → "2026-06"。正規シャード名でなければ nil
    private static func canonicalShardKey(of url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        return isMonthKey(stem) ? stem : nil
    }

    /// "2026-06 (1).json" のような競合コピー名から先頭の月キーを拾う
    private static func shardKeyPrefix(of url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.count > 7 else { return nil }
        let prefix = String(stem.prefix(7))
        return isMonthKey(prefix) ? prefix : nil
    }

    private static func isMonthKey(_ s: String) -> Bool {
        guard s.count == 7 else { return false }
        let parts = s.split(separator: "-")
        return parts.count == 2 && parts[0].count == 4 && parts[1].count == 2
            && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    private static func monthKey(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    @discardableResult
    private static func writeShardFile(entries: [VaultManifestEntry], key: String, indexDirectory: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(entries) else { return false }
        let url = indexDirectory.appendingPathComponent("\(key).json")
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    private func jpegThumbnail(from image: CGImage) -> Data? {
        let w = Int(thumbnailSize.width)
        let h = Int(thumbnailSize.height)
        let scale = min(CGFloat(w) / CGFloat(image.width), CGFloat(h) / CGFloat(image.height))
        let dw = CGFloat(image.width) * scale
        let dh = CGFloat(image.height) * scale
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: (CGFloat(w) - dw) / 2, y: (CGFloat(h) - dh) / 2, width: dw, height: dh))
        guard let thumb = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: thumb).representation(using: .jpeg, properties: [.compressionFactor: 0.75])
    }
}

// MARK: - OCR Service

enum OCRService {
    static func recognizeText(in image: CGImage) async -> String {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { req, _ in
                let obs = req.results as? [VNRecognizedTextObservation] ?? []
                let text = obs.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                continuation.resume(returning: text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([request])
        }
    }
}
