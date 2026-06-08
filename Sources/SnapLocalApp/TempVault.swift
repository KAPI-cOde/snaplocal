// TempVault.swift - Part 1: Models & Actor
// SnapLocal - L1/L2/L3 Storage
//
// Copyright © 2024 SnapLocal. All rights reserved.

import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Vault Item

struct VaultItem: Identifiable, Codable, @unchecked Sendable {
    let id: UUID
    let createdAt: Date
    let imageData: Data
    let thumbnailData: Data
    let annotations: [AnyAnnotation]
    var level: VaultLevel
    var fileURL: URL?
    
    init(id: UUID = UUID(), createdAt: Date = Date(), imageData: Data, thumbnailData: Data, annotations: [AnyAnnotation] = [], level: VaultLevel = .memory, fileURL: URL? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.imageData = imageData
        self.thumbnailData = thumbnailData
        self.annotations = annotations
        self.level = level
        self.fileURL = fileURL
    }
}

enum VaultLevel: String, Codable, CaseIterable, Sendable {
    case memory = "memory"      // L1: In-memory (session only)
    case cache = "cache"        // L2: ~/Library/Caches/SnapLocal/
    case permanent = "permanent" // L3: ~/Pictures/SnapLocal/
    
    var displayName: String {
        switch self {
        case .memory: return "テンポラリ"
        case .cache: return "キャッシュ"
        case .permanent: return "正式保存"
        }
    }
    
    var systemImage: String {
        switch self {
        case .memory: return "timer"
        case .cache: return "externaldrive.badge.timemachine"
        case .permanent: return "checkmark.seal.fill"
        }
    }
}

// MARK: - TempVault Actor

actor TempVault {
    // L1: In-memory storage (unlimited during session, max 50 items)
    private var memoryItems: [VaultItem] = []
    private let maxMemoryItems = 50
    
    // L2: Cache directory
    private let cacheDirectory: URL
    private let cacheFileManager = FileManager.default
    
    // L3: Permanent directory
    private let permanentDirectory: URL
    
    // Thumbnail size
    private let thumbnailSize = CGSize(width: 200, height: 200)
    
    init() {
        // L2 Cache directory
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.cacheDirectory = cachesDir.appendingPathComponent("SnapLocal", isDirectory: true)
        
        // L3 Permanent directory
        let picturesDir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
        self.permanentDirectory = picturesDir.appendingPathComponent("SnapLocal", isDirectory: true)
        
        // Create directories
        try? cacheFileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? cacheFileManager.createDirectory(at: permanentDirectory, withIntermediateDirectories: true)
        
        // Load existing cache items on init (nonisolated)
        Task { await loadCacheItems() }
    }
    
    // MARK: - Public API
    
    /// Save new screenshot to L1 (memory)
    func saveToMemory(image: CGImage, annotations: [AnyAnnotation] = []) async -> VaultItem {
        let imageData = imageToData(image)
        let thumbnailData = makeThumbnail(from: image)
        
        let item = VaultItem(
            imageData: imageData,
            thumbnailData: thumbnailData,
            annotations: annotations,
            level: .memory
        )
        
        memoryItems.insert(item, at: 0)
        
        // Enforce limit
        if memoryItems.count > maxMemoryItems {
            _ = memoryItems.removeLast()
            // Could promote to cache here if needed
        }
        
        return item
    }
    
    /// Promote item from L1->L2 or L2->L3
    func promote(_ id: UUID, to level: VaultLevel) async -> VaultItem? {
        // Find item in any level
        if let index = memoryItems.firstIndex(where: { $0.id == id }) {
            var item = memoryItems[index]
            item.level = level
            
            if level == .cache {
                await saveToCache(item)
            } else if level == .permanent {
                await saveToPermanent(item)
            }
            
            memoryItems.remove(at: index)
            return item
        }
        
        // Check cache
        if let cacheItem = await loadCacheItem(id: id) {
            if level == .permanent {
                await saveToPermanent(cacheItem)
                await deleteFromCache(id)
            }
            return cacheItem
        }
        
        return nil
    }
    
    /// Delete item from any level
    func delete(_ id: UUID) async {
        memoryItems.removeAll { $0.id == id }
        await deleteFromCache(id)
        await deleteFromPermanent(id)
    }
    
    /// Get all items across all levels (for history UI)
    func allItems() async -> [VaultItem] {
        var items = memoryItems
        items.append(contentsOf: await loadAllCacheItems())
        items.append(contentsOf: await loadAllPermanentItems())
        items.sort { $0.createdAt > $1.createdAt }
        return items
    }
    
    /// Get items by level
    func items(in level: VaultLevel) async -> [VaultItem] {
        switch level {
        case .memory:
            return memoryItems
        case .cache:
            return await loadAllCacheItems()
        case .permanent:
            return await loadAllPermanentItems()
        }
    }
    
    /// Clear L1 memory (on app termination or manual)
    func clearMemory() async {
        memoryItems.removeAll()
    }
    
    /// Get count for each level
    func counts() async -> (memory: Int, cache: Int, permanent: Int) {
        let cacheItems = await loadAllCacheItems()
        let permanentItems = await loadAllPermanentItems()
        return (memoryItems.count, cacheItems.count, permanentItems.count)
    }
    
    // MARK: - Private Helpers
    
    private func imageToData(_ image: CGImage) -> Data {
        let bitmapRep = NSBitmapImageRep(cgImage: image)
        return bitmapRep.representation(using: .png, properties: [:]) ?? Data()
    }
    
    private func makeThumbnail(from image: CGImage) -> Data {
        let width = Int(thumbnailSize.width)
        let height = Int(thumbnailSize.height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Data() }
        
        let scale = min(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
        let drawWidth = CGFloat(image.width) * scale
        let drawHeight = CGFloat(image.height) * scale
        let x = (CGFloat(width) - drawWidth) / 2
        let y = (CGFloat(height) - drawHeight) / 2
        
        context.draw(image, in: CGRect(x: x, y: y, width: drawWidth, height: drawHeight))
        
        guard let thumbnail = context.makeImage() else { return Data() }
        let bitmapRep = NSBitmapImageRep(cgImage: thumbnail)
        guard let data = bitmapRep.representation(using: .png, properties: [:]) else { return Data() }
        return data
    }
    
    private func cacheFileURL(for id: UUID) -> URL {
        cacheDirectory.appendingPathComponent("\(id.uuidString).json")
    }
    
    private func permanentFileURL(for id: UUID) -> URL {
        permanentDirectory.appendingPathComponent("\(id.uuidString).json")
    }
    
    private func saveToCache(_ item: VaultItem) async {
        let url = cacheFileURL(for: item.id)
        do {
            let data = try JSONEncoder().encode(item)
            try data.write(to: url, options: .atomic)
        } catch {
            print("Failed to save to cache: \(error)")
        }
    }
    
    private func saveToPermanent(_ item: VaultItem) async {
        let url = permanentFileURL(for: item.id)
        do {
            var mutableItem = item
            mutableItem.level = .permanent
            mutableItem.fileURL = url
            let data = try JSONEncoder().encode(mutableItem)
            try data.write(to: url, options: .atomic)
        } catch {
            print("Failed to save to permanent: \(error)")
        }
    }
    
    private func loadCacheItem(id: UUID) async -> VaultItem? {
        let url = cacheFileURL(for: id)
        guard let data = try? Data(contentsOf: url),
              let item = try? JSONDecoder().decode(VaultItem.self, from: data) else {
            return nil
        }
        return item
    }
    
    private func loadCacheItems() {
        // Called from init, so not async
        let urls = (try? cacheFileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               (try? JSONDecoder().decode(VaultItem.self, from: data)) != nil {
                // Don't add to memory, just ensure file exists
            }
        }
    }
    
    private func loadAllCacheItems() async -> [VaultItem] {
        let urls = (try? cacheFileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? []
        var items: [VaultItem] = []
        for url in urls where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               let item = try? JSONDecoder().decode(VaultItem.self, from: data) {
                items.append(item)
            }
        }
        items.sort { $0.createdAt > $1.createdAt }
        return items
    }
    
    private func deleteFromCache(_ id: UUID) async {
        let url = cacheFileURL(for: id)
        try? cacheFileManager.removeItem(at: url)
    }
    
    private func loadAllPermanentItems() async -> [VaultItem] {
        let urls = (try? cacheFileManager.contentsOfDirectory(at: permanentDirectory, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? []
        var items: [VaultItem] = []
        for url in urls where url.pathExtension == "json" {
            if let data = try? Data(contentsOf: url),
               let item = try? JSONDecoder().decode(VaultItem.self, from: data) {
                items.append(item)
            }
        }
        items.sort { $0.createdAt > $1.createdAt }
        return items
    }
    
    private func deleteFromPermanent(_ id: UUID) async {
        let url = permanentFileURL(for: id)
        try? cacheFileManager.removeItem(at: url)
    }
}
