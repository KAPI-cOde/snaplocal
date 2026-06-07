// TempVaultModels.swift
// Data models for TempVault storage tiers

import Foundation
import CoreGraphics

/// Storage tier in TempVault
public enum StorageTier: String, Codable, CaseIterable, Sendable {
    case history = "history"      // 履歴 - Temporary/auto-saves
    case clean = "clean"          // クリーン - Edited/annotated versions
    case formal = "formal"        // 正式保存 - Promoted/permanent storage
}

/// Item stored in TempVault
public struct TempVaultItem: Codable, Sendable, Identifiable {
    public let id: UUID
    public var tier: StorageTier
    public var originalData: Data
    public var metadata: ItemMetadata
    public var createdAt: Date
    public var updatedAt: Date
    public var promotedFrom: UUID?  // ID of item this was promoted from
    
    public init(
        id: UUID = UUID(),
        tier: StorageTier,
        originalData: Data,
        metadata: ItemMetadata,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        promotedFrom: UUID? = nil
    ) {
        self.id = id
        self.tier = tier
        self.originalData = originalData
        self.metadata = metadata
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.promotedFrom = promotedFrom
    }
}

/// Metadata for a TempVault item
public struct ItemMetadata: Codable, Sendable {
    public var title: String
    public var tags: [String]
    public var sourceApplication: String?
    public var windowTitle: String?
    public var screenRect: ScreenRect?
    public var annotations: [AnnotationData]?
    public var customProperties: [String: String]
    
    public init(
        title: String = "",
        tags: [String] = [],
        sourceApplication: String? = nil,
        windowTitle: String? = nil,
        screenRect: ScreenRect? = nil,
        annotations: [AnnotationData]? = nil,
        customProperties: [String: String] = [:]
    ) {
        self.title = title
        self.tags = tags
        self.sourceApplication = sourceApplication
        self.windowTitle = windowTitle
        self.screenRect = screenRect
        self.annotations = annotations
        self.customProperties = customProperties
    }
}

/// Screen rectangle for capture metadata
public struct ScreenRect: Codable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// A simple point type that conforms to Codable
public struct SimplePoint: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
    
    public init(_ point: CGPoint) {
        self.x = point.x
        self.y = point.y
    }
    
    public var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

/// Annotation data for edited items
public struct AnnotationData: Codable, Sendable {
    public var type: AnnotationType
    public var points: [SimplePoint]  // Simplified - in real app would be more specific
    public var color: String      // Hex color string
    public var strokeWidth: Double
    public var text: String?      // For text annotations
    
    public init(
        type: AnnotationType,
        points: [SimplePoint],
        color: String,
        strokeWidth: Double,
        text: String? = nil
    ) {
        self.type = type
        self.points = points
        self.color = color
        self.strokeWidth = strokeWidth
        self.text = text
    }
}

/// Types of annotations
public enum AnnotationType: String, Codable, Sendable {
    case stroke = "stroke"      // Freehand drawing
    case rectangle = "rectangle"
    case ellipse = "ellipse"
    case line = "line"
    case arrow = "arrow"
    case text = "text"
    case mosaic = "mosaic"      // Pixelation/blur
    case highlight = "highlight"
}

/// Result of a promotion operation
public struct PromotionResult: Sendable {
    public let sourceItem: TempVaultItem
    public let promotedItem: TempVaultItem
    public let success: Bool
    public let error: Error?
    
    public init(sourceItem: TempVaultItem, promotedItem: TempVaultItem, success: Bool, error: Error? = nil) {
        self.sourceItem = sourceItem
        self.promotedItem = promotedItem
        self.success = success
        self.error = error
    }
}

/// Configuration for TempVault storage
public struct TempVaultConfiguration: Sendable {
    public let baseURL: URL
    public let historyRetentionDays: Int
    public let cleanRetentionDays: Int
    public let maxHistoryItems: Int
    public let maxCleanItems: Int
    public let autoPromoteOnEdit: Bool
    
    public init(
        baseURL: URL,
        historyRetentionDays: Int = 7,
        cleanRetentionDays: Int = 30,
        maxHistoryItems: Int = 1000,
        maxCleanItems: Int = 500,
        autoPromoteOnEdit: Bool = true
    ) {
        self.baseURL = baseURL
        self.historyRetentionDays = historyRetentionDays
        self.cleanRetentionDays = cleanRetentionDays
        self.maxHistoryItems = maxHistoryItems
        self.maxCleanItems = maxCleanItems
        self.autoPromoteOnEdit = autoPromoteOnEdit
    }
    
    public static let `default` = TempVaultConfiguration(
        baseURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SnapLocal/TempVault", isDirectory: true)
    )
}