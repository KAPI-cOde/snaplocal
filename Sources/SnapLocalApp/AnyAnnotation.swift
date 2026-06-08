// AnyAnnotation.swift - Type Erasure
// SnapLocal

import Foundation
import CoreGraphics
import SwiftUI

// MARK: - Type-Erased Annotation

struct AnyAnnotation: AnnotationElement, Codable, @unchecked Sendable {
    var id: UUID
    var type: AnnotationType
    var color: AnnotationColor
    var lineWidth: LineWidth
    var transform: CGAffineTransform
    var textContent: String?

    private let _path: (CGRect) -> Path
    private let _hitTest: (CGPoint, CGRect) -> Bool
    private let _bounds: (CGRect) -> CGRect
    private let _applyTransform: (inout CGAffineTransform) -> Void
    private let _encode: (Encoder) throws -> Void

    init<T: AnnotationElement>(_ annotation: T) {
        self.id = annotation.id
        self.type = annotation.type
        self.color = annotation.color
        self.lineWidth = annotation.lineWidth
        self.transform = annotation.transform
        self.textContent = (annotation as? TextAnnotation)?.text
        self._path = annotation.path
        self._hitTest = annotation.hitTest
        self._bounds = annotation.bounds
        self._applyTransform = { transform in
            var mutable = annotation
            mutable.applyTransform(transform)
        }
        self._encode = { try annotation.encode(to: $0) }
    }

    func path(in rect: CGRect) -> Path { _path(rect) }
    func hitTest(_ point: CGPoint, in rect: CGRect) -> Bool { _hitTest(point, rect) }
    func bounds(in rect: CGRect) -> CGRect { _bounds(rect) }
    mutating func applyTransform(_ transform: CGAffineTransform) { _applyTransform(&self.transform) }
    func encode(to encoder: Encoder) throws { try _encode(encoder) }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try container.decode(UUID.self, forKey: .id)
        let type = try container.decode(AnnotationType.self, forKey: .type)
        let decodedColor = try container.decode(AnnotationColor.self, forKey: .color)
        let decodedLineWidth = try container.decode(LineWidth.self, forKey: .lineWidth)
        let decodedTransform = try container.decode(CGAffineTransform.self, forKey: .transform)

        let annotation: AnyAnnotation
        switch type {
        case .line:
            let a = try LineAnnotation(from: decoder)
            annotation = AnyAnnotation(a)
        case .arrow:
            let a = try ArrowAnnotation(from: decoder)
            annotation = AnyAnnotation(a)
        case .rectangle:
            let a = try RectangleAnnotation(from: decoder)
            annotation = AnyAnnotation(a)
        case .ellipse:
            let a = try EllipseAnnotation(from: decoder)
            annotation = AnyAnnotation(a)
        case .text:
            let a = try TextAnnotation(from: decoder)
            annotation = AnyAnnotation(a)
        case .mosaic:
            let a = try MosaicAnnotation(from: decoder)
            annotation = AnyAnnotation(a)
        case .blur:
            let a = try BlurAnnotation(from: decoder)
            annotation = AnyAnnotation(a)
        }

        self.id = decodedID
        self.type = annotation.type
        self.color = decodedColor
        self.lineWidth = decodedLineWidth
        self.transform = decodedTransform
        self.textContent = annotation.textContent
        self._path = annotation._path
        self._hitTest = annotation._hitTest
        self._bounds = annotation._bounds
        self._applyTransform = annotation._applyTransform
        self._encode = annotation._encode
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, color, lineWidth, transform
    }
}