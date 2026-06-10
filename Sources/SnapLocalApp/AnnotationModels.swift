// AnnotationModels.swift
// SnapLocal - Canvas + Shapes + Undo/Redo
//
// Copyright © 2024 SnapLocal. All rights reserved.

import SwiftUI
import CoreGraphics
import CoreImage

// MARK: - Annotation Protocol

protocol AnnotationElement: Identifiable, Codable {
    var id: UUID { get }
    var type: AnnotationType { get }
    var color: AnnotationColor { get set }
    var lineWidth: LineWidth { get set }
    var transform: CGAffineTransform { get set }

    // Whether this annotation should be drawn as a stroke (line/rect/ellipse/arrow/text)
    // false for mosaic/blur which use Core Image filters
    var hasStrokeRepresentation: Bool { get }

    func path(in rect: CGRect) -> Path
    func hitTest(_ point: CGPoint, in rect: CGRect) -> Bool
    func bounds(in rect: CGRect) -> CGRect
    mutating func applyTransform(_ transform: CGAffineTransform)

    // Apply filter to image (for mosaic/blur)
    func applyFilter(to image: CIImage) -> CIImage?
}

// Default implementations
extension AnnotationElement {
    var hasStrokeRepresentation: Bool { true }
    func applyFilter(to image: CIImage) -> CIImage? { nil }

    /// Default applyTransform: prepend the given transform to the stored transform.
    /// IMPORTANT: order must be `transform.concatenating(self.transform)` — do not reverse.
    /// CalloutAnnotation overrides this to also transform its tailPoint.
    mutating func applyTransform(_ transform: CGAffineTransform) {
        self.transform = transform.concatenating(self.transform)
    }

    /// Hit-tolerance for stroke-based annotations: line width + 8, minimum 12.
    var hitTolerance: CGFloat { max(lineWidth.rawValue + 8, 12) }
}

enum AnnotationType: String, Codable, CaseIterable {
    case line = "line"
    case arrow = "arrow"
    case rectangle = "rectangle"
    case ellipse = "ellipse"
    case text = "text"
    case mosaic = "mosaic"
    case blur = "blur"
    case step = "step"
    case roundedRect = "roundedRect"
    case callout = "callout"
    case highlight = "highlight"
    case pencil = "pencil"
    case spotlight = "spotlight"
}

enum AnnotationColor: String, Codable, CaseIterable {
    case red, orange, yellow, green, blue, purple, black, white

    var color: Color {
        switch self {
        case .red:    return Color(red: 1,    green: 0.18, blue: 0.18)
        case .orange: return Color(red: 1,    green: 0.5,  blue: 0)
        case .yellow: return Color(red: 1,    green: 0.8,  blue: 0)
        case .green:  return Color(red: 0.1,  green: 0.78, blue: 0.18)
        case .blue:   return Color(red: 0.1,  green: 0.35, blue: 0.9)
        case .purple: return Color(red: 0.55, green: 0.1,  blue: 0.85)
        case .black:  return .black
        case .white:  return .white
        }
    }

    var cgColor: CGColor {
        switch self {
        case .red:    return CGColor(red: 1,    green: 0.18, blue: 0.18, alpha: 1)
        case .orange: return CGColor(red: 1,    green: 0.5,  blue: 0,    alpha: 1)
        case .yellow: return CGColor(red: 1,    green: 0.8,  blue: 0,    alpha: 1)
        case .green:  return CGColor(red: 0.1,  green: 0.78, blue: 0.18, alpha: 1)
        case .blue:   return CGColor(red: 0.1,  green: 0.35, blue: 0.9,  alpha: 1)
        case .purple: return CGColor(red: 0.55, green: 0.1,  blue: 0.85, alpha: 1)
        case .black:  return CGColor(red: 0,    green: 0,    blue: 0,    alpha: 1)
        case .white:  return CGColor(red: 1,    green: 1,    blue: 1,    alpha: 1)
        }
    }

    /// 明るい色(yellow/white)のとき true。テキスト色を黒にすべき判定に使う。
    /// CanvasOverlays / CanvasRendering 3箇所の重複を統合。
    var isLight: Bool { self == .yellow || self == .white }
}

enum LineWidth: CGFloat, Codable, CaseIterable {
    case thin = 2
    case medium = 4
    case thick = 8
}

enum LineStyle: String, Codable, CaseIterable {
    case solid, dashed, dotted

    func strokeStyle(lineWidth lw: CGFloat) -> StrokeStyle {
        switch self {
        case .solid:  return StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round)
        case .dashed: return StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round, dash: [lw * 3, lw * 2])
        case .dotted: return StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round, dash: [0.01, lw * 2])
        }
    }
}

// MARK: - Drawing Tool

enum DrawingTool: String, Codable, CaseIterable {
    case select = "select"
    case line = "line"
    case arrow = "arrow"
    case rectangle = "rectangle"
    case ellipse = "ellipse"
    case text = "text"
    case step = "step"
    case roundedRect = "roundedRect"
    case callout = "callout"
    case highlight = "highlight"
    case redact = "redact"   // unified mosaic/blur
    case pencil = "pencil"
    case stamp = "stamp"
    case colorPicker = "colorPicker"
    case measure = "measure"
    case spotlight = "spotlight"

    var systemImage: String {
        switch self {
        case .select: return "cursorarrow"                  // 標準ポインタ(旧: リサイズ風矢印で混同)
        case .line: return "line.diagonal"
        case .arrow: return "line.diagonal.arrow"           // 描き込む矢印の見た目(旧: arrow.up.rightは外部リンク風)
        case .rectangle: return "rectangle"
        case .ellipse: return "oval"
        case .text: return "textformat"
        case .step: return "number.circle"
        case .roundedRect: return "app"                     // 全周角丸の矩形(旧: 上だけ角丸)
        case .callout: return "bubble.left"
        case .highlight: return "highlighter"
        case .redact: return "checkerboard.rectangle"       // モザイク柄(旧: eye.slashは表示切替と混同)
        case .pencil: return "pencil.line"                  // フリーハンド描画(旧: scribbleは波線のみで意図が伝わらない)
        case .stamp: return "face.smiling"
        case .colorPicker: return "eyedropper.halffull"
        case .measure: return "ruler"
        case .spotlight: return "flashlight.on.fill"        // 旧: "spotlight"は実在しないシンボル名(空表示)
        }
    }

    var displayName: String {
        switch self {
        case .select: return "選択"
        case .line: return "線"
        case .arrow: return "矢印"
        case .rectangle: return "長方形"
        case .ellipse: return "楕円"
        case .text: return "テキスト"
        case .step: return "ステップ"
        case .roundedRect: return "角丸"
        case .callout: return "吹き出し"
        case .highlight: return "ハイライト"
        case .redact: return "隠す"
        case .pencil: return "鉛筆"
        case .stamp: return "スタンプ"
        case .colorPicker: return "スポイト"
        case .measure: return "定規"
        case .spotlight: return "スポットライト"
        }
    }

    var annotationType: AnnotationType? {
        switch self {
        case .select, .redact, .stamp, .colorPicker, .measure: return nil
        case .spotlight: return .spotlight
        case .line: return .line
        case .arrow: return .arrow
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        case .text: return .text
        case .step: return .step
        case .roundedRect: return .roundedRect
        case .callout: return .callout
        case .highlight: return .highlight
        case .pencil: return .pencil
        }
    }

    var usesLineWidth: Bool {
        switch self {
        case .line, .arrow, .rectangle, .ellipse, .text, .step, .roundedRect, .callout, .pencil: return true
        case .select, .redact, .highlight, .stamp, .colorPicker, .measure, .spotlight: return false
        }
    }

    /// 描画ツール使用中でも既存アノテーションをグラブ移動できるツール群。
    /// CanvasInteraction / CanvasView の重複 Set 定義を統合。
    /// `.select` は含まない (select は常にグラブ可能なため条件式で別扱い)。
    var supportsGrabMove: Bool {
        switch self {
        case .arrow, .line, .rectangle, .ellipse, .roundedRect, .callout, .highlight, .step, .redact, .spotlight:
            return true
        case .select, .text, .pencil, .stamp, .colorPicker, .measure:
            return false
        }
    }

    var shortcutKey: String {
        switch self {
        case .select: return "V"
        case .line: return "L"
        case .arrow: return "A"
        case .rectangle: return "R"
        case .ellipse: return "E"
        case .text: return "T"
        case .step: return "N"
        case .roundedRect: return "U"
        case .callout: return "B"
        case .highlight: return "H"
        case .redact: return "X"
        case .pencil: return "P"
        case .stamp: return "G"
        case .colorPicker: return "I"
        case .measure: return "Q"
        case .spotlight: return "O"
        }
    }

    var helpText: String { "\(displayName) (\(shortcutKey))" }
}

enum RedactMode: String, Codable, CaseIterable {
    case mosaic, blur

    var annotationType: AnnotationType { self == .mosaic ? .mosaic : .blur }
    var systemImage: String { self == .mosaic ? "square.grid.3x3" : "aqi.medium" }
    var displayName: String { self == .mosaic ? "モザイク" : "ぼかし" }
}

enum SpotlightShape: String, Codable, CaseIterable {
    case ellipse, rectangle

    var systemImage: String { self == .ellipse ? "circle" : "rectangle" }
}

// MARK: - Crop Handle

enum CropHandle {
    case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight, move

    static let hitRadius: CGFloat = 16

    func apply(delta: CGSize, to rect: CGRect) -> CGRect {
        var r = rect
        switch self {
        case .topLeft:
            r.origin.x += delta.width; r.size.width -= delta.width
            r.size.height += delta.height
        case .top:
            r.size.height += delta.height
        case .topRight:
            r.size.width += delta.width; r.size.height += delta.height
        case .left:
            r.origin.x += delta.width; r.size.width -= delta.width
        case .right:
            r.size.width += delta.width
        case .bottomLeft:
            r.origin.x += delta.width; r.size.width -= delta.width
            r.origin.y += delta.height; r.size.height -= delta.height
        case .bottom:
            r.origin.y += delta.height; r.size.height -= delta.height
        case .bottomRight:
            r.size.width += delta.width
            r.origin.y += delta.height; r.size.height -= delta.height
        case .move:
            r.origin.x += delta.width; r.origin.y += delta.height
        }
        if r.size.width < 4  { r.size.width = 4 }
        if r.size.height < 4 { r.size.height = 4 }
        return r
    }

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft:     return CGPoint(x: rect.minX, y: rect.minY)
        case .top:         return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight:    return CGPoint(x: rect.maxX, y: rect.minY)
        case .left:        return CGPoint(x: rect.minX, y: rect.midY)
        case .right:       return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomLeft:  return CGPoint(x: rect.minX, y: rect.maxY)
        case .bottom:      return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .move:        return CGPoint(x: rect.midX, y: rect.midY)
        }
    }

    static let allHandles: [CropHandle] = [.topLeft, .top, .topRight, .left, .right, .bottomLeft, .bottom, .bottomRight]

    static func handle(at point: CGPoint, in rect: CGRect) -> CropHandle? {
        for h in allHandles {
            let c = h.point(in: rect)
            if hypot(point.x - c.x, point.y - c.y) <= hitRadius { return h }
        }
        if rect.contains(point) { return .move }
        return nil
    }
}

// MARK: - Snap Guides

struct SnapGuide: Equatable {
    enum Axis { case horizontal, vertical }
    let axis: Axis
    let position: CGFloat
}

// MARK: - Drag State for Drawing

struct DragState {
    var startPoint: CGPoint?
    var currentPoint: CGPoint?
    var isDrawing: Bool = false
    var selectedElementID: UUID?
    var dragOffset: CGSize = .zero

    mutating func start(at point: CGPoint) {
        startPoint = point
        currentPoint = point
        isDrawing = true
    }

    mutating func update(to point: CGPoint) {
        currentPoint = point
    }

    mutating func end() -> (CGPoint, CGPoint)? {
        guard let start = startPoint, let end = currentPoint, isDrawing else { return nil }
        isDrawing = false
        startPoint = nil
        currentPoint = nil
        return (start, end)
    }

    mutating func cancel() {
        startPoint = nil
        currentPoint = nil
        isDrawing = false
    }
}
