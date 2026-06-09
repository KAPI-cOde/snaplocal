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
    var isFilled: Bool
    var stepNumber: Int?
    var hasStrokeRepresentation: Bool

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
        self.isFilled = (annotation as? RectangleAnnotation)?.isFilled
            ?? (annotation as? EllipseAnnotation)?.isFilled
            ?? (annotation as? RoundedRectAnnotation)?.isFilled
            ?? (annotation as? CalloutAnnotation)?.isFilled ?? false
        self.stepNumber = (annotation as? StepAnnotation)?.stepNumber
        self.hasStrokeRepresentation = annotation.hasStrokeRepresentation

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

    func encode(to encoder: Encoder) throws { try _encode(encoder) }

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
        case .mosaic:
            wrapped = AnyAnnotation(try MosaicAnnotation(from: decoder))
        case .blur:
            wrapped = AnyAnnotation(try BlurAnnotation(from: decoder))
        case .step:
            wrapped = AnyAnnotation(try StepAnnotation(from: decoder))
        case .roundedRect:
            wrapped = AnyAnnotation(try RoundedRectAnnotation(from: decoder))
        case .callout:
            wrapped = AnyAnnotation(try CalloutAnnotation(from: decoder))
        case .highlight:
            wrapped = AnyAnnotation(try HighlightAnnotation(from: decoder))
        }

        self.id = decodedID
        self.type = wrapped.type
        self.color = decodedColor
        self.lineWidth = decodedLineWidth
        self.transform = decodedTransform
        self.textContent = wrapped.textContent
        self.textFontSize = wrapped.textFontSize
        self.isFilled = wrapped.isFilled
        self.stepNumber = wrapped.stepNumber
        self.hasStrokeRepresentation = wrapped.hasStrokeRepresentation
        self._basePath = wrapped._basePath
        self._applyFilter = wrapped._applyFilter
        self._encode = wrapped._encode
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, color, lineWidth, transform
    }
}
