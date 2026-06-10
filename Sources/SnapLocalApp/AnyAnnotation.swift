// AnyAnnotation.swift - Type Erasure
// SnapLocal

import Foundation
import CoreGraphics
import SwiftUI
import CoreImage

// MARK: - Type-Erased Annotation

struct AnyAnnotation: AnnotationElement, Codable, @unchecked Sendable {
    var id: UUID
    var type: AnnotationType
    var color: AnnotationColor
    var lineWidth: LineWidth
    var transform: CGAffineTransform
    var textContent: String?
    var textFontSize: CGFloat?
    var textHasBackground: Bool
    var isFilled: Bool
    var stepNumber: Int?
    var arrowDoubleSided: Bool = false
    var hasStrokeRepresentation: Bool
    var opacity: Double = 1.0
    var isLocked: Bool = false
    var lineStyle: LineStyle = .solid
    var customColorHex: String? = nil   // "RRGGBBAA" when set; overrides color
    var calloutTailPoint: CGPoint? = nil  // pre-transform tail point for callout; canvas coords = this.applying(transform)
    var lineStartPoint: CGPoint? = nil   // pre-transform start for line/arrow
    var lineEndPoint: CGPoint? = nil     // pre-transform end for line/arrow

    /// Parses `customColorHex` ("RRGGBBAA") into (r, g, b, a) components in 0...1.
    /// Returns nil when the hex string is absent or malformed.
    private var customColorComponents: (r: Double, g: Double, b: Double, a: Double)? {
        guard let hex = customColorHex, hex.count == 8,
              let rv = UInt8(hex.prefix(2), radix: 16),
              let gv = UInt8(hex.dropFirst(2).prefix(2), radix: 16),
              let bv = UInt8(hex.dropFirst(4).prefix(2), radix: 16),
              let av = UInt8(hex.dropFirst(6).prefix(2), radix: 16)
        else { return nil }
        return (Double(rv)/255, Double(gv)/255, Double(bv)/255, Double(av)/255)
    }

    var resolvedColor: Color {
        guard let c = customColorComponents else { return color.color }
        return Color(red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }

    var resolvedCGColor: CGColor {
        guard let c = customColorComponents else { return color.cgColor }
        return CGColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
    }

    // Captures base path with .identity transform; AnyAnnotation.transform applied on top in path(in:)
    private let _basePath: (CGRect) -> Path
    // Filter closure receives current transform so dragged mosaic/blur tracks correctly
    private let _applyFilter: (CIImage, CGAffineTransform) -> CIImage?
    private let _encode: (Encoder) throws -> Void

    init<T: AnnotationElement>(_ annotation: T) {
        self.id = annotation.id
        self.type = annotation.type
        self.color = annotation.color
        self.lineWidth = annotation.lineWidth
        self.transform = annotation.transform
        self.textContent = (annotation as? TextAnnotation)?.text
        self.textFontSize = (annotation as? TextAnnotation)?.fontSize
        self.textHasBackground = (annotation as? TextAnnotation)?.hasBackground ?? false
        self.isFilled = (annotation as? RectangleAnnotation)?.isFilled
            ?? (annotation as? EllipseAnnotation)?.isFilled
            ?? (annotation as? RoundedRectAnnotation)?.isFilled
            ?? (annotation as? CalloutAnnotation)?.isFilled ?? false
        self.stepNumber = (annotation as? StepAnnotation)?.stepNumber
        self.arrowDoubleSided = (annotation as? ArrowAnnotation)?.doubleSided ?? false
        self.hasStrokeRepresentation = annotation.hasStrokeRepresentation
        self.calloutTailPoint = (annotation as? CalloutAnnotation)?.tailPoint
        self.lineStartPoint = (annotation as? LineAnnotation)?.startPoint ?? (annotation as? ArrowAnnotation)?.startPoint
        self.lineEndPoint = (annotation as? LineAnnotation)?.endPoint ?? (annotation as? ArrowAnnotation)?.endPoint

        var base = annotation
        base.transform = .identity
        self._basePath = base.path

        self._applyFilter = { image, currentTransform in
            var a = annotation
            a.transform = currentTransform
            return a.applyFilter(to: image)
        }
        self._encode = { try annotation.encode(to: $0) }
    }

    func path(in rect: CGRect) -> Path {
        _basePath(rect).applying(transform)
    }

    func hitTest(_ point: CGPoint, in rect: CGRect) -> Bool {
        let p = path(in: rect)
        if !hasStrokeRepresentation || type == .text {
            return p.boundingRect.contains(point)
        }
        if p.contains(point) { return true }
        let tolerance = max(lineWidth.rawValue + 8, 12)
        return p.strokedPath(StrokeStyle(lineWidth: tolerance, lineCap: .round, lineJoin: .round)).contains(point)
    }

    func bounds(in rect: CGRect) -> CGRect {
        path(in: rect).boundingRect
    }

    mutating func applyTransform(_ transform: CGAffineTransform) {
        self.transform = transform.concatenating(self.transform)
    }

    func applyFilter(to image: CIImage) -> CIImage? {
        _applyFilter(image, transform)
    }

    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
        // Write opacity alongside concrete annotation keys (shared keyed container)
        if opacity != 1.0 || isLocked || lineStyle != .solid || customColorHex != nil {
            var container = encoder.container(keyedBy: CodingKeys.self)
            if opacity != 1.0 { try container.encode(opacity, forKey: .opacity) }
            if isLocked { try container.encode(isLocked, forKey: .isLocked) }
            if lineStyle != .solid { try container.encode(lineStyle, forKey: .lineStyle) }
            if let hex = customColorHex { try container.encode(hex, forKey: .customColorHex) }
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try container.decode(UUID.self, forKey: .id)
        let type = try container.decode(AnnotationType.self, forKey: .type)
        let decodedColor = try container.decode(AnnotationColor.self, forKey: .color)
        let decodedLineWidth = try container.decode(LineWidth.self, forKey: .lineWidth)
        let decodedTransform = try container.decode(CGAffineTransform.self, forKey: .transform)

        let wrapped: AnyAnnotation
        switch type {
        case .line:
            wrapped = AnyAnnotation(try LineAnnotation(from: decoder))
        case .arrow:
            wrapped = AnyAnnotation(try ArrowAnnotation(from: decoder))
        case .rectangle:
            wrapped = AnyAnnotation(try RectangleAnnotation(from: decoder))
        case .ellipse:
            wrapped = AnyAnnotation(try EllipseAnnotation(from: decoder))
        case .text:
            wrapped = AnyAnnotation(try TextAnnotation(from: decoder))
        case .mosaic, .blur:
            wrapped = AnyAnnotation(try RedactAnnotation(from: decoder))
        case .step:
            wrapped = AnyAnnotation(try StepAnnotation(from: decoder))
        case .roundedRect:
            wrapped = AnyAnnotation(try RoundedRectAnnotation(from: decoder))
        case .callout:
            wrapped = AnyAnnotation(try CalloutAnnotation(from: decoder))
        case .highlight:
            wrapped = AnyAnnotation(try HighlightAnnotation(from: decoder))
        case .pencil:
            wrapped = AnyAnnotation(try PencilAnnotation(from: decoder))
        case .spotlight:
            wrapped = AnyAnnotation(try SpotlightAnnotation(from: decoder))
        }

        self.id = decodedID
        self.type = wrapped.type
        self.color = decodedColor
        self.lineWidth = decodedLineWidth
        self.transform = decodedTransform
        self.textContent = wrapped.textContent
        self.textFontSize = wrapped.textFontSize
        self.textHasBackground = wrapped.textHasBackground
        self.isFilled = wrapped.isFilled
        self.stepNumber = wrapped.stepNumber
        self.arrowDoubleSided = wrapped.arrowDoubleSided
        self.hasStrokeRepresentation = wrapped.hasStrokeRepresentation
        self.calloutTailPoint = wrapped.calloutTailPoint
        self.lineStartPoint = wrapped.lineStartPoint
        self.lineEndPoint = wrapped.lineEndPoint
        self.opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
        self.isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        self.lineStyle = try container.decodeIfPresent(LineStyle.self, forKey: .lineStyle) ?? .solid
        self.customColorHex = try container.decodeIfPresent(String.self, forKey: .customColorHex)
        self._basePath = wrapped._basePath
        self._applyFilter = wrapped._applyFilter
        self._encode = wrapped._encode
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, color, lineWidth, transform, opacity, isLocked, lineStyle, customColorHex
    }
}
