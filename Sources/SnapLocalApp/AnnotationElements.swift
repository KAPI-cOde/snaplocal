// AnnotationCanvas.swift - Part 2: Concrete Elements
// SnapLocal - Canvas + Shapes + Undo/Redo

import SwiftUI
import CoreGraphics

// MARK: - Line Annotation

struct LineAnnotation: AnnotationElement {
    let id = UUID()
    let type: AnnotationType = .line
    var color: AnnotationColor
    var lineWidth: LineWidth
    var transform: CGAffineTransform = .identity
    var startPoint: CGPoint
    var endPoint: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let start = startPoint.applying(transform)
        let end = endPoint.applying(transform)
        path.move(to: start)
        path.addLine(to: end)
        return path
    }

    func hitTest(_ point: CGPoint, in rect: CGRect) -> Bool {
        let path = self.path(in: rect)
        let strokeStyle = StrokeStyle(lineWidth: lineWidth.rawValue, lineCap: .round, lineJoin: .round)
        return path.strokedPath(strokeStyle).contains(point)
    }

    func bounds(in rect: CGRect) -> CGRect {
        let path = self.path(in: rect)
        return path.boundingRect
    }

    mutating func applyTransform(_ transform: CGAffineTransform) {
        self.transform = transform.concatenating(self.transform)
    }
}

// MARK: - Arrow Annotation

struct ArrowAnnotation: AnnotationElement {
    let id = UUID()
    let type: AnnotationType = .arrow
    var color: AnnotationColor
    var lineWidth: LineWidth
    var transform: CGAffineTransform = .identity
    var startPoint: CGPoint
    var endPoint: CGPoint

    func path(in rect: CGRect) -> Path {
        let start = startPoint.applying(transform)
        let end = endPoint.applying(transform)
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 1 else { return Path() }

        let angle = atan2(dy, dx)
        let headLength: CGFloat = lineWidth.rawValue * 4 + 12
        let headAngle: CGFloat = .pi / 5.5

        var path = Path()
        // Shaft ends at arrowhead base so it doesn't poke through the filled head
        let shaftEnd = length > headLength
            ? CGPoint(x: end.x - headLength * cos(angle), y: end.y - headLength * sin(angle))
            : start
        path.move(to: start)
        path.addLine(to: shaftEnd)

        // Closed triangle arrowhead — filled in canvas draw
        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x - headLength * cos(angle - headAngle),
                                  y: end.y - headLength * sin(angle - headAngle)))
        path.addLine(to: CGPoint(x: end.x - headLength * cos(angle + headAngle),
                                  y: end.y - headLength * sin(angle + headAngle)))
        path.closeSubpath()

        return path
    }

    func hitTest(_ point: CGPoint, in rect: CGRect) -> Bool {
        let p = self.path(in: rect)
        if p.contains(point) { return true }
        let strokeStyle = StrokeStyle(lineWidth: max(lineWidth.rawValue, 10), lineCap: .round, lineJoin: .round)
        return p.strokedPath(strokeStyle).contains(point)
    }

    func bounds(in rect: CGRect) -> CGRect {
        self.path(in: rect).boundingRect
    }

    mutating func applyTransform(_ transform: CGAffineTransform) {
        self.transform = transform.concatenating(self.transform)
    }
}

// MARK: - Rectangle Annotation

struct RectangleAnnotation: AnnotationElement {
    let id = UUID()
    let type: AnnotationType = .rectangle
    var color: AnnotationColor
    var lineWidth: LineWidth
    var transform: CGAffineTransform = .identity
    var rect: CGRect

    func path(in rect: CGRect) -> Path {
        let r = self.rect.applying(transform)
        return Path(r)
    }

    func hitTest(_ point: CGPoint, in rect: CGRect) -> Bool {
        let path = self.path(in: rect)
        let strokeStyle = StrokeStyle(lineWidth: lineWidth.rawValue, lineCap: .round, lineJoin: .round)
        return path.strokedPath(strokeStyle).contains(point)
    }

    func bounds(in rect: CGRect) -> CGRect {
        let path = self.path(in: rect)
        return path.boundingRect
    }

    mutating func applyTransform(_ transform: CGAffineTransform) {
        self.transform = transform.concatenating(self.transform)
    }
}

// MARK: - Ellipse Annotation

struct EllipseAnnotation: AnnotationElement {
    let id = UUID()
    let type: AnnotationType = .ellipse
    var color: AnnotationColor
    var lineWidth: LineWidth
    var transform: CGAffineTransform = .identity
    var rect: CGRect

    func path(in rect: CGRect) -> Path {
        let r = self.rect.applying(transform)
        return Path(ellipseIn: r)
    }

    func hitTest(_ point: CGPoint, in rect: CGRect) -> Bool {
        let path = self.path(in: rect)
        let strokeStyle = StrokeStyle(lineWidth: lineWidth.rawValue, lineCap: .round, lineJoin: .round)
        return path.strokedPath(strokeStyle).contains(point)
    }

    func bounds(in rect: CGRect) -> CGRect {
        let path = self.path(in: rect)
        return path.boundingRect
    }

    mutating func applyTransform(_ transform: CGAffineTransform) {
        self.transform = transform.concatenating(self.transform)
    }
}

// MARK: - Text Annotation

struct TextAnnotation: AnnotationElement {
    let id = UUID()
    let type: AnnotationType = .text
    var color: AnnotationColor
    var lineWidth: LineWidth = .thin
    var transform: CGAffineTransform = .identity
    var rect: CGRect
    var text: String
    var fontSize: CGFloat = 16

    func path(in rect: CGRect) -> Path {
        let r = self.rect.applying(transform)
        return Path(r)
    }

    func hitTest(_ point: CGPoint, in rect: CGRect) -> Bool {
        let r = self.rect.applying(transform)
        return r.contains(point)
    }

    func bounds(in rect: CGRect) -> CGRect {
        let r = self.rect.applying(transform)
        return r
    }

    mutating func applyTransform(_ transform: CGAffineTransform) {
        self.transform = transform.concatenating(self.transform)
    }
}