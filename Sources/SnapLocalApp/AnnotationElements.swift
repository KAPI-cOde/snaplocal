// AnnotationCanvas.swift - Part 2: Concrete Elements
// SnapLocal - Canvas + Shapes + Undo/Redo

import SwiftUI
import CoreGraphics

// MARK: - Line Annotation

struct LineAnnotation: AnnotationElement {
    var id = UUID()
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
        let tolerance = max(lineWidth.rawValue + 8, 12)
        return path.strokedPath(StrokeStyle(lineWidth: tolerance, lineCap: .round, lineJoin: .round)).contains(point)
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
    var id = UUID()
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
        let tolerance = max(lineWidth.rawValue + 8, 12)
        return p.strokedPath(StrokeStyle(lineWidth: tolerance, lineCap: .round, lineJoin: .round)).contains(point)
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
    var id = UUID()
    let type: AnnotationType = .rectangle
    var color: AnnotationColor
    var lineWidth: LineWidth
    var transform: CGAffineTransform = .identity
    var rect: CGRect
    var isFilled: Bool = false

    func path(in rect: CGRect) -> Path {
        let r = self.rect.applying(transform)
        return Path(r)
    }

    func hitTest(_ point: CGPoint, in rect: CGRect) -> Bool {
        let path = self.path(in: rect)
        if isFilled && path.contains(point) { return true }
        let tolerance = max(lineWidth.rawValue + 8, 12)
        return path.strokedPath(StrokeStyle(lineWidth: tolerance, lineCap: .round, lineJoin: .round)).contains(point)
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
    var id = UUID()
    let type: AnnotationType = .ellipse
    var color: AnnotationColor
    var lineWidth: LineWidth
    var transform: CGAffineTransform = .identity
    var rect: CGRect
    var isFilled: Bool = false

    func path(in rect: CGRect) -> Path {
        let r = self.rect.applying(transform)
        return Path(ellipseIn: r)
    }

    func hitTest(_ point: CGPoint, in rect: CGRect) -> Bool {
        let path = self.path(in: rect)
        if isFilled && path.contains(point) { return true }
        let tolerance = max(lineWidth.rawValue + 8, 12)
        return path.strokedPath(StrokeStyle(lineWidth: tolerance, lineCap: .round, lineJoin: .round)).contains(point)
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
    var id = UUID()
    let type: AnnotationType = .text
    var color: AnnotationColor
    var lineWidth: LineWidth = .thin
    var transform: CGAffineTransform = .identity
    var rect: CGRect
    var text: String
    var fontSize: CGFloat = 18
    var hasBackground: Bool = false

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

// MARK: - Rounded Rectangle Annotation

struct RoundedRectAnnotation: AnnotationElement {
    var id = UUID()
    let type: AnnotationType = .roundedRect
    var color: AnnotationColor
    var lineWidth: LineWidth
    var transform: CGAffineTransform = .identity
    var rect: CGRect
    var isFilled: Bool = false

    func path(in rect: CGRect) -> Path {
        let r = self.rect.applying(transform)
        let radius = min(r.width, r.height) * 0.15
        return Path(roundedRect: r, cornerRadius: radius)
    }

    func hitTest(_ point: CGPoint, in rect: CGRect) -> Bool {
        let path = self.path(in: rect)
        if isFilled && path.contains(point) { return true }
        let tolerance = max(lineWidth.rawValue + 8, 12)
        return path.strokedPath(StrokeStyle(lineWidth: tolerance, lineCap: .round, lineJoin: .round)).contains(point)
    }

    func bounds(in rect: CGRect) -> CGRect {
        self.rect.applying(transform)
    }

    mutating func applyTransform(_ transform: CGAffineTransform) {
        self.transform = transform.concatenating(self.transform)
    }
}

// MARK: - Step Annotation (numbered circle for tutorials)

struct StepAnnotation: AnnotationElement {
    var id = UUID()
    let type: AnnotationType = .step
    var color: AnnotationColor
    var lineWidth: LineWidth = .medium
    var transform: CGAffineTransform = .identity
    var rect: CGRect
    var stepNumber: Int

    func path(in rect: CGRect) -> Path {
        let r = self.rect.applying(transform)
        return Path(ellipseIn: r)
    }

    func hitTest(_ point: CGPoint, in rect: CGRect) -> Bool {
        let path = self.path(in: rect)
        return path.contains(point)
    }

    func bounds(in rect: CGRect) -> CGRect {
        self.rect.applying(transform)
    }

    mutating func applyTransform(_ transform: CGAffineTransform) {
        self.transform = transform.concatenating(self.transform)
    }
}

// MARK: - Callout Annotation (speech bubble)

struct CalloutAnnotation: AnnotationElement {
    var id = UUID()
    let type: AnnotationType = .callout
    var color: AnnotationColor
    var lineWidth: LineWidth
    var transform: CGAffineTransform = .identity
    var rect: CGRect
    var isFilled: Bool = false

    func path(in rect: CGRect) -> Path {
        let r = self.rect.applying(transform)
        let cr: CGFloat = min(r.width, r.height) * 0.15
        let tailW: CGFloat = max(12, min(r.width * 0.2, 24))
        let tailH: CGFloat = max(10, min(r.height * 0.25, 20))
        let tailCX = r.minX + r.width * 0.28

        var p = Path()
        p.move(to: CGPoint(x: r.minX + cr, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - cr, y: r.minY))
        p.addArc(center: CGPoint(x: r.maxX - cr, y: r.minY + cr), radius: cr,
                 startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - cr))
        p.addArc(center: CGPoint(x: r.maxX - cr, y: r.maxY - cr), radius: cr,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        // Bottom edge: right part, then tail, then left part
        p.addLine(to: CGPoint(x: tailCX + tailW / 2, y: r.maxY))
        p.addLine(to: CGPoint(x: tailCX, y: r.maxY + tailH))
        p.addLine(to: CGPoint(x: tailCX - tailW / 2, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + cr, y: r.maxY))
        p.addArc(center: CGPoint(x: r.minX + cr, y: r.maxY - cr), radius: cr,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + cr))
        p.addArc(center: CGPoint(x: r.minX + cr, y: r.minY + cr), radius: cr,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }

    func hitTest(_ point: CGPoint, in rect: CGRect) -> Bool {
        let p = self.path(in: rect)
        if isFilled && p.contains(point) { return true }
        let tol = max(lineWidth.rawValue + 8, 12)
        return p.strokedPath(StrokeStyle(lineWidth: tol)).contains(point)
    }

    func bounds(in rect: CGRect) -> CGRect {
        let r = self.rect.applying(transform)
        let tailH: CGFloat = max(10, min(r.height * 0.25, 20))
        return r.insetBy(dx: 0, dy: 0).union(CGRect(x: r.minX, y: r.maxY, width: r.width * 0.28 + 12, height: tailH))
    }

    mutating func applyTransform(_ transform: CGAffineTransform) {
        self.transform = transform.concatenating(self.transform)
    }
}

// MARK: - Pencil Annotation (freehand stroke)

struct PencilAnnotation: AnnotationElement {
    var id = UUID()
    let type: AnnotationType = .pencil
    var color: AnnotationColor
    var lineWidth: LineWidth
    var transform: CGAffineTransform = .identity
    var points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        guard points.count >= 2 else { return Path() }
        let pts = points.map { $0.applying(transform) }
        var p = Path()
        p.move(to: pts[0])
        for i in 1..<pts.count {
            let prev = pts[i - 1], curr = pts[i]
            let mid = CGPoint(x: (prev.x + curr.x) / 2, y: (prev.y + curr.y) / 2)
            p.addQuadCurve(to: mid, control: prev)
        }
        p.addLine(to: pts.last!)
        return p
    }

    func hitTest(_ point: CGPoint, in rect: CGRect) -> Bool {
        let path = self.path(in: rect)
        let tolerance = max(lineWidth.rawValue + 8, 12)
        return path.strokedPath(StrokeStyle(lineWidth: tolerance, lineCap: .round, lineJoin: .round)).contains(point)
    }

    func bounds(in rect: CGRect) -> CGRect {
        path(in: rect).boundingRect.insetBy(dx: -lineWidth.rawValue, dy: -lineWidth.rawValue)
    }

    mutating func applyTransform(_ transform: CGAffineTransform) {
        self.transform = transform.concatenating(self.transform)
    }
}

// MARK: - Highlight Annotation (semi-transparent fill, no stroke)

struct HighlightAnnotation: AnnotationElement {
    var id = UUID()
    let type: AnnotationType = .highlight
    var color: AnnotationColor
    var lineWidth: LineWidth = .medium
    var transform: CGAffineTransform = .identity
    var rect: CGRect
    var isFilled: Bool { true }

    func path(in rect: CGRect) -> Path {
        Path(self.rect.applying(transform))
    }

    func hitTest(_ point: CGPoint, in rect: CGRect) -> Bool {
        path(in: rect).contains(point)
    }

    func bounds(in rect: CGRect) -> CGRect {
        self.rect.applying(transform)
    }

    mutating func applyTransform(_ transform: CGAffineTransform) {
        self.transform = transform.concatenating(self.transform)
    }
}
