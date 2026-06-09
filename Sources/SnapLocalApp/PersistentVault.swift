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
    var level: VaultLevel
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

enum VaultLevel: String, Codable, CaseIterable, Sendable {
    case memory    = "memory"
    case cache     = "cache"
    case permanent = "permanent"

    var systemImage: String {
        switch self {
        case .memory:    return "timer"
        case .cache:     return "externaldrive.badge.timemachine"
        case .permanent: return "checkmark.seal.fill"
        }
    }
}

// MARK: - PersistentVault

actor PersistentVault {
    private var baseDirectory: URL
    private var thumbDirectory: URL
    private var indexURL: URL
    private var manifest: [UUID: VaultManifestEntry] = [:]
    private var orderedIDs: [UUID] = []         // newest first
    private let thumbnailSize = CGSize(width: 200, height: 130)

    init(directory: URL? = nil) {
        let dir = directory ?? {
            let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
            return pictures.appendingPathComponent("SnapLocal", isDirectory: true)
        }()
        self.baseDirectory = dir
        self.thumbDirectory = dir.appendingPathComponent("thumbnails", isDirectory: true)
        self.indexURL = dir.appendingPathComponent("index.json")
        // Setup inline (can't call isolated methods from actor init in Swift 6)
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: dir.appendingPathComponent("thumbnails"), withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: dir.appendingPathComponent("index.json")),
           let entries = try? JSONDecoder().decode([VaultManifestEntry].self, from: data) {
            self.manifest = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
            self.orderedIDs = entries.sorted { $0.createdAt > $1.createdAt }.map { $0.id }
        }
    }

    // MARK: - Public API

    /// Save a new screenshot. Returns the VaultItem immediately (OCR runs separately).
    func save(image: CGImage, annotations: [AnyAnnotation] = []) async -> VaultItem? {
        let id = UUID()
        let filename = "\(id.uuidString).png"
        let thumbFilename = "thumbnails/\(id.uuidString).jpg"
        let imageURL = baseDirectory.appendingPathComponent(filename)
        let thumbURL = baseDirectory.appendingPathComponent(thumbFilename)

        guard let pngData = pngData(from: image) else { return nil }
        let thumbData = jpegThumbnail(from: image) ?? Data()

        do {
            try pngData.write(to: imageURL, options: .atomic)
            try thumbData.write(to: thumbURL, options: .atomic)
        } catch {
            return nil
        }

        let annotationsData = try? JSONEncoder().encode(annotations)
        let entry = VaultManifestEntry(
            id: id,
            createdAt: Date(),
            filename: filename,
            thumbFilename: thumbFilename,
            ocrText: "",
            annotationsData: annotationsData,
            width: image.width,
            height: image.height
        )
        manifest[id] = entry
        orderedIDs.insert(id, at: 0)
        saveManifest()

        return VaultItem(
            id: id,
            createdAt: entry.createdAt,
            imageURL: imageURL,
            thumbnailData: thumbData,
            ocrText: "",
            annotations: annotations,
            level: .permanent,
            title: nil,
            notes: nil,
            width: image.width,
            height: image.height
        )
    }

    /// Update OCR text for an item (called after async OCR finishes)
    func updateOCR(id: UUID, text: String) {
        guard manifest[id] != nil else { return }
        manifest[id]!.ocrText = text
        saveManifest()
    }

    /// Update title/label for an item
    func updateTitle(id: UUID, title: String?) {
        guard manifest[id] != nil else { return }
        manifest[id]!.title = title?.isEmpty == true ? nil : title
        saveManifest()
    }

    /// Update freeform notes for an item
    func updateNotes(id: UUID, notes: String?) {
        guard manifest[id] != nil else { return }
        manifest[id]!.notes = notes?.isEmpty == true ? nil : notes
        saveManifest()
    }

    /// Toggle star (favorite) status for an item
    func toggleStar(id: UUID) {
        guard manifest[id] != nil else { return }
        manifest[id]!.isStarred.toggle()
        saveManifest()
    }

    /// Update annotations for an item
    func updateAnnotations(id: UUID, annotations: [AnyAnnotation]) {
        guard manifest[id] != nil else { return }
        manifest[id]!.annotationsData = try? JSONEncoder().encode(annotations)
        saveManifest()
    }

    /// Overwrite the thumbnail file with an annotated image (call after baking annotations).
    func updateThumbnail(id: UUID, annotatedImage: CGImage) {
        guard let entry = manifest[id] else { return }
        let thumbURL = baseDirectory.appendingPathComponent(entry.thumbFilename)
        if let thumbData = jpegThumbnail(from: annotatedImage) {
            try? thumbData.write(to: thumbURL, options: .atomic)
        }
    }

    /// Delete an item and its files
    func delete(id: UUID) {
        guard let entry = manifest[id] else { return }
        try? FileManager.default.removeItem(at: baseDirectory.appendingPathComponent(entry.filename))
        try? FileManager.default.removeItem(at: baseDirectory.appendingPathComponent(entry.thumbFilename))
        manifest.removeValue(forKey: id)
        orderedIDs.removeAll { $0 == id }
        saveManifest()
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
        saveManifest()
        let thumbData = (try? Data(contentsOf: dstThumb)) ?? Data()
        let annotations = entry.annotationsData
            .flatMap { try? JSONDecoder().decode([AnyAnnotation].self, from: $0) } ?? []
        return VaultItem(id: newID, createdAt: entry.createdAt, imageURL: dstURL,
                         thumbnailData: thumbData, ocrText: entry.ocrText,
                         annotations: annotations, level: .permanent, title: entry.title,
                         notes: entry.notes, width: entry.width, height: entry.height)
    }

    /// All items, newest first
    func allItems() -> [VaultItem] {
        orderedIDs.compactMap { id -> VaultItem? in
            guard let entry = manifest[id] else { return nil }
            let imageURL = baseDirectory.appendingPathComponent(entry.filename)
            let thumbURL = baseDirectory.appendingPathComponent(entry.thumbFilename)
            let thumbData = (try? Data(contentsOf: thumbURL)) ?? Data()
            let annotations = entry.annotationsData
                .flatMap { try? JSONDecoder().decode([AnyAnnotation].self, from: $0) } ?? []
            return VaultItem(
                id: entry.id,
                createdAt: entry.createdAt,
                imageURL: imageURL,
                thumbnailData: thumbData,
                ocrText: entry.ocrText,
                annotations: annotations,
                level: .permanent,
                title: entry.title,
                notes: entry.notes,
                width: entry.width,
                height: entry.height,
                isStarred: entry.isStarred
            )
        }
    }

    /// Search items by OCR text
    func search(query: String) -> [VaultItem] {
        guard !query.isEmpty else { return allItems() }
        return allItems().filter { item in
            if item.ocrText.localizedCaseInsensitiveContains(query) { return true }
            if let title = item.title, title.localizedCaseInsensitiveContains(query) { return true }
            if let notes = item.notes, notes.localizedCaseInsensitiveContains(query) { return true }
            let annotationText = item.annotations.compactMap { $0.textContent }.joined(separator: " ")
            return annotationText.localizedCaseInsensitiveContains(query)
        }
    }

    // MARK: - Private

    private func setupDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: thumbDirectory, withIntermediateDirectories: true)
    }

    private func loadManifest() {
        guard let data = try? Data(contentsOf: indexURL),
              let entries = try? JSONDecoder().decode([VaultManifestEntry].self, from: data) else {
            return
        }
        manifest = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        orderedIDs = entries.sorted { $0.createdAt > $1.createdAt }.map { $0.id }
    }

    private func saveManifest() {
        let entries = orderedIDs.compactMap { manifest[$0] }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func pngData(from image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
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
                let text = obs.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
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
