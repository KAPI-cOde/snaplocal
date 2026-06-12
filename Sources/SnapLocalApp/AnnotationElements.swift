// AnnotationElements.swift
// Concrete annotation types that conform to AnnotationElement.

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
    var hitTolerance: CGFloat { max(lineWidth.rawValue + 8, 22) }

    func path(in rect: CGRect) -> Path {
        let s = startPoint.applying(transform)
        let e = endPoint.applying(transform)
        var p = Path()
        p.move(to: s)
        p.addLine(to: e)
        return p
    }

    func hitTest(_ point: CGPoint, in rect: CGRect) -> Bool {
        return path(in: rect).strokedPath(StrokeStyle(lineWidth: hitTolerance)).contains(point)
    }

    func bounds(in rect: CGRect) -> CGRect { path(in: rect).boundingRect }
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
    var hitTolerance: CGFloat { max(lineWidth.rawValue + 8, 22) }
    var doubleSided: Bool = false

    func path(in rect: CGRect) -> Path {
        let s = startPoint.applying(transform)
        let e = endPoint.applying(transform)
        let dx = e.x - s.x, dy = e.y - s.y
        let length = hypot(dx, dy)
        guard length > 1 else { return Path() }
        let lw = lineWidth.rawValue
        // Unit vectors: forward (ux,uy) and perpendicular left (px,py)
        let ux = dx / length, uy = dy / length
        let px = -uy, py = ux
        // Arrow proportions
        let headLen = min(lw * 3.5 + 12, length * 0.65)
        let halfHead = headLen * 0.55          // half-width of arrowhead base
        let halfShaft = max(lw * 0.45, 1.5)   // half-width of shaft
        // Build as a single solid polygon (shaft + head unified)
        if doubleSided && length > headLen * 2.2 {
            // Double-sided: head-tail-shaft-head polygon
            let tailBase = CGPoint(x: s.x + headLen * ux, y: s.y + headLen * uy)
            let tipBase   = CGPoint(x: e.x - headLen * ux, y: e.y - headLen * uy)
            var p = Path()
            p.move(to: e)
            p.addLine(to: CGPoint(x: tipBase.x + halfHead * px, y: tipBase.y + halfHead * py))
            p.addLine(to: CGPoint(x: tipBase.x + halfShaft * px, y: tipBase.y + halfShaft * py))
            p.addLine(to: CGPoint(x: tailBase.x + halfShaft * px, y: tailBase.y + halfShaft * py))
            p.addLine(to: CGPoint(x: tailBase.x + halfHead * px, y: tailBase.y + halfHead * py))
            p.addLine(to: s)
            p.addLine(to: CGPoint(x: tailBase.x - halfHead * px, y: tailBase.y - halfHead * py))
            p.addLine(to: CGPoint(x: tailBase.x - halfShaft * px, y: tailBase.y - halfShaft * py))
            p.addLine(to: CGPoint(x: tipBase.x - halfShaft * px, y: tipBase.y - halfShaft * py))
            p.addLine(to: CGPoint(x: tipBase.x - halfHead * px, y: tipBase.y - halfHead * py))
            p.closeSubpath()
            return p
        } else {
            // Single-sided: tip→left-wing→shaft-left→shaft-start-left→shaft-start-right→shaft-right→right-wing
            let shaftStart = doubleSided ? CGPoint(x: s.x + headLen * ux, y: s.y + headLen * uy) : s
            let tipBase = CGPoint(x: e.x - headLen * ux, y: e.y - headLen * uy)
            var p = Path()
            p.move(to: e)
            p.addLine(to: CGPoint(x: tipBase.x + halfHead * px, y: tipBase.y + halfHead * py))
            p.addLine(to: CGPoint(x: tipBase.x + halfShaft * px, y: tipBase.y + halfShaft * py))
            p.addLine(to: CGPoint(x: shaftStart.x + halfShaft * px, y: shaftStart.y + halfShaft * py))
            if doubleSided {
                p.addLine(to: CGPoint(x: shaftStart.x + halfHead * px, y: shaftStart.y + halfHead * py))
                p.addLine(to: s)
                p.addLine(to: CGPoint(x: shaftStart.x - halfHead * px, y: shaftStart.y - halfHead * py))
            }
            p.addLine(to: CGPoint(x: shaftStart.x - halfShaft * px, y: shaftStart.y - halfShaft * py))
            p.addLine(to: CGPoint(x: tipBase.x - halfShaft * px, y: tipBase.y - halfShaft * py))
            p.addLine(to: CGPoint(x: tipBase.x - halfHead * px, y: tipBase.y - halfHead * py))
            p.closeSubpath()
            return p
        }
    }

    func hitTest(_ point: CGPoint, in rect: CGRect) -> Bool {
        let p = path(in: rect)
        return p.contains(point) || p.strokedPath(StrokeStyle(lineWidth: hitTolerance)).contains(point)
    }

    func bounds(in rect: CGRect) -> CGRect { path(in: rect).boundingRect }
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
        Path(self.rect.applying(transform))
    }

    func hitTest(_ point: CGPoint, in rect: CGRect) -> Bool {
        let path = self.path(in: rect)
        if isFilled && path.contains(point) { return true }
        return path.strokedPath(StrokeStyle(lineWidth: hitTolerance)).contains(point)
    }

    func bounds(in rect: CGRect) -> CGRect { self.rect.applying(transform) }
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
        return path.strokedPath(StrokeStyle(lineWidth: hitTolerance, lineCap: .round, lineJoin: .round)).contains(point)
    }

    func bounds(in rect: CGRect) -> CGRect {
        let path = self.path(in: rect)
        return path.boundingRect
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
        Path(self.rect.applying(transform))
    }

    func hitTest(_ point: CGPoint, in rect: CGRect) -> Bool {
        path(in: rect).contains(point)
    }

    func bounds(in rect: CGRect) -> CGRect { self.rect.applying(transform) }
}

// MARK: - Rounded Rect Annotation

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
        return Path(roundedRect: r, cornerRadius: r.width * 0.15)
    }

    func hitTest(_ point: CGPoint, in rect: CGRect) -> Bool {
        let path = self.path(in: rect)
        if isFilled && path.contains(point) { return true }
        return path.strokedPath(StrokeStyle(lineWidth: hitTolerance)).contains(point)
    }

    func bounds(in rect: CGRect) -> CGRect { self.rect.applying(transform) }
}

// MARK: - Step Annotation

struct StepAnnotation: AnnotationElement {
    var id = UUID()
    let type: AnnotationType = .step
    var color: AnnotationColor
    var lineWidth: LineWidth = .medium
    var transform: CGAffineTransform = .identity
    var rect: CGRect
    var stepNumber: Int

    func path(in canvasRect: CGRect) -> Path {
        return Path(ellipseIn: rect.applying(transform))
    }

    func hitTest(_ point: CGPoint, in canvasRect: CGRect) -> Bool {
        path(in: canvasRect).contains(point)
    }

    func bounds(in canvasRect: CGRect) -> CGRect {
        rect.applying(transform)
    }
}

// MARK: - Callout Annotation

struct CalloutAnnotation: AnnotationElement {
    var id = UUID()
    let type: AnnotationType = .callout
    var color: AnnotationColor
    var lineWidth: LineWidth
    var transform: CGAffineTransform = .identity
    var rect: CGRect
    var tailPoint: CGPoint = CGPoint(x: 0, y: 0)
    var isFilled: Bool = true

    func path(in rect: CGRect) -> Path {
        let r = self.rect.applying(transform)
        let tail = tailPoint.applying(transform)
        let radius = min(r.width, r.height) * 0.2
        var p = Path(roundedRect: r, cornerRadius: radius)
        // Tail triangle toward tailPoint
        let closest = CGPoint(
            x: max(r.minX, min(r.maxX, tail.x)),
            y: max(r.minY, min(r.maxY, tail.y))
        )
        let dx = tail.x - closest.x, dy = tail.y - closest.y
        let perpLen: CGFloat = 8
        let angle = atan2(dy, dx) + .pi / 2
        let p1 = CGPoint(x: closest.x + cos(angle) * perpLen, y: closest.y + sin(angle) * perpLen)
        let p2 = CGPoint(x: closest.x - cos(angle) * perpLen, y: closest.y - sin(angle) * perpLen)
        var tailPath = Path()
        tailPath.move(to: p1)
        tailPath.addLine(to: self.tailPoint.applying(transform))
        tailPath.addLine(to: p2)
        tailPath.closeSubpath()
        p.addPath(tailPath)
        return p
    }

    func hitTest(_ point: CGPoint, in rect: CGRect) -> Bool {
        let p = self.path(in: rect)
        return p.contains(point) || p.strokedPath(StrokeStyle(lineWidth: max(lineWidth.rawValue + 8, 12))).contains(point)
    }

    func bounds(in rect: CGRect) -> CGRect { self.rect.applying(transform) }

    mutating func applyTransform(_ transform: CGAffineTransform) {
        self.transform = transform.concatenating(self.transform)
        tailPoint = tailPoint.applying(transform)
    }
}

// MARK: - Pencil Annotation

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
        return path(in: rect).strokedPath(StrokeStyle(lineWidth: hitTolerance, lineCap: .round, lineJoin: .round)).contains(point)
    }

    func bounds(in rect: CGRect) -> CGRect { path(in: rect).boundingRect }
}

// MARK: - Highlight Annotation

struct HighlightAnnotation: AnnotationElement {
    var id = UUID()
    let type: AnnotationType = .highlight
    var color: AnnotationColor
    var lineWidth: LineWidth = .thin
    var transform: CGAffineTransform = .identity
    var rect: CGRect

    func path(in rect: CGRect) -> Path {
        Path(self.rect.applying(transform))
    }

    func hitTest(_ point: CGPoint, in rect: CGRect) -> Bool {
        path(in: rect).contains(point)
    }

    func bounds(in rect: CGRect) -> CGRect { self.rect.applying(transform) }
}

// MARK: - Spotlight Annotation

struct SpotlightAnnotation: AnnotationElement {
    var id = UUID()
    let type: AnnotationType = .spotlight
    var color: AnnotationColor = .black
    var lineWidth: LineWidth = .thin
    var transform: CGAffineTransform = .identity
    var rect: CGRect
    var dimOpacity: Double = 0.55
    var shape: SpotlightShape = .ellipse

    func path(in rect: CGRect) -> Path {
        let r = self.rect.applying(transform)
        return shape == .ellipse ? Path(ellipseIn: r) : Path(r)
    }

    func hitTest(_ point: CGPoint, in rect: CGRect) -> Bool {
        let tolerance: CGFloat = 12
        return path(in: rect).strokedPath(StrokeStyle(lineWidth: tolerance)).contains(point)
    }

    func bounds(in rect: CGRect) -> CGRect { self.rect.applying(transform) }
}
