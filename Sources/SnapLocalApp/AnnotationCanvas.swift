// AnnotationCanvas.swift - Part 1: Models & Protocol
// SnapLocal - Canvas + Shapes + Undo/Redo
//
// Copyright © 2024 SnapLocal. All rights reserved.

import SwiftUI
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

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
}

enum AnnotationType: String, Codable, CaseIterable {
    case line = "line"
    case arrow = "arrow"
    case rectangle = "rectangle"
    case ellipse = "ellipse"
    case text = "text"
    case mosaic = "mosaic"
    case blur = "blur"
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
}

enum LineWidth: CGFloat, Codable, CaseIterable {
    case thin = 2
    case thick = 5
}

// MARK: - Drawing Tool

enum DrawingTool: String, Codable, CaseIterable {
    case select = "select"
    case line = "line"
    case arrow = "arrow"
    case rectangle = "rectangle"
    case ellipse = "ellipse"
    case text = "text"
    case mosaic = "mosaic"
    case blur = "blur"
    
    var systemImage: String {
        switch self {
        case .select: return "arrow.up.left.and.arrow.down.right"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .text: return "textformat"
        case .mosaic: return "square.grid.3x3"
        case .blur: return "circle.lefthalf.filled"
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
        case .mosaic: return "モザイク"
        case .blur: return "ぼかし"
        }
    }
    
    var annotationType: AnnotationType? {
        switch self {
        case .select: return nil
        case .line: return .line
        case .arrow: return .arrow
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        case .text: return .text
        case .mosaic: return .mosaic
        case .blur: return .blur
        }
    }
    
    // Whether this tool uses line width (stroke-based tools)
    var usesLineWidth: Bool {
        switch self {
        case .line, .arrow, .rectangle, .ellipse, .text:
            return true
        case .select, .mosaic, .blur:
            return false
        }
    }
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

// MARK: - Canvas ViewModel

@MainActor
final class CanvasViewModel: ObservableObject {
    @Published var annotations: [AnyAnnotation] = []
    @Published var currentTool: DrawingTool = .arrow
    @Published var currentColor: AnnotationColor = .red
    @Published var currentLineWidth: LineWidth = .thin
    @Published var dragState = DragState()
    @Published var backgroundImage: CGImage?
    @Published var canvasSize: CGSize = .zero
    @Published var showTextInput = false
    @Published var textInputRect: CGRect = .zero
    @Published var textInputString = ""
    @Published var selectedAnnotationID: UUID?

    let undoManager = UndoManager()
    private var isUndoing = false
    private var dragStartAnnotation: AnyAnnotation? = nil
    // Cached CoreImage previews for mosaic/blur annotations (view-space bounds → filtered CGImage)
    var filterPreviews: [UUID: CGImage] = [:]
    private let ciPreviewCtx = CIContext(options: [.useSoftwareRenderer: false])
    
    // MARK: - Filter Previews

    func updateFilterPreview(for annotation: AnyAnnotation) {
        guard !annotation.hasStrokeRepresentation,
              let bgImage = backgroundImage,
              canvasSize.width > 0, canvasSize.height > 0 else { return }
        let imgW = CGFloat(bgImage.width), imgH = CGFloat(bgImage.height)
        let scaleX = imgW / canvasSize.width, scaleY = imgH / canvasSize.height
        let vr = annotation.bounds(in: CGRect(origin: .zero, size: canvasSize))
        let ciRect = CGRect(
            x: vr.minX * scaleX,
            y: imgH - vr.maxY * scaleY,
            width: max(vr.width * scaleX, 2),
            height: max(vr.height * scaleY, 2)
        ).intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))
        guard !ciRect.isNull, ciRect.width > 0, ciRect.height > 0 else { return }
        let ciSource = CIImage(cgImage: bgImage)
        var filtered: CIImage?
        switch annotation.type {
        case .blur:
            let f = CIFilter.gaussianBlur()
            f.inputImage = ciSource.cropped(to: ciRect)
            f.radius = 20
            filtered = f.outputImage?.cropped(to: ciRect)
        case .mosaic:
            let f = CIFilter.pixellate()
            f.inputImage = ciSource.cropped(to: ciRect)
            f.scale = 12
            filtered = f.outputImage?.cropped(to: ciRect)
        default: return
        }
        if let out = filtered, let cg = ciPreviewCtx.createCGImage(out, from: ciRect) {
            filterPreviews[annotation.id] = cg
        }
    }

    func recomputeAllFilterPreviews() {
        filterPreviews.removeAll()
        for ann in annotations where !ann.hasStrokeRepresentation {
            updateFilterPreview(for: ann)
        }
    }

    // MARK: - Annotation Management

    func addAnnotation(_ annotation: AnyAnnotation) {
        if !isUndoing {
            undoManager.registerUndo(withTarget: self) { target in
                target.isUndoing = true
                target.removeAnnotation(id: annotation.id)
                target.isUndoing = false
            }
        }
        annotations.append(annotation)
        if !annotation.hasStrokeRepresentation {
            updateFilterPreview(for: annotation)
        }
        objectWillChange.send()
        updateUndoRedoState()
    }

    func removeAnnotation(id: UUID) {
        if let index = annotations.firstIndex(where: { $0.id == id }) {
            let annotation = annotations[index]
            if !isUndoing {
                undoManager.registerUndo(withTarget: self) { target in
                    target.isUndoing = true
                    target.annotations.insert(annotation, at: index)
                    target.isUndoing = false
                }
            }
            annotations.remove(at: index)
            filterPreviews.removeValue(forKey: id)
            if selectedAnnotationID == id {
                selectedAnnotationID = nil
            }
            objectWillChange.send()
            updateUndoRedoState()
        }
    }
    
    func updateAnnotation(_ annotation: AnyAnnotation) {
        if let index = annotations.firstIndex(where: { $0.id == annotation.id }) {
            let oldAnnotation = annotations[index]
            if !isUndoing {
                undoManager.registerUndo(withTarget: self) { target in
                    target.isUndoing = true
                    target.annotations[index] = oldAnnotation
                    target.isUndoing = false
                }
            }
            annotations[index] = annotation
            objectWillChange.send()
        }
    }
    
    func selectAnnotation(at point: CGPoint) {
        // Check from top to bottom (last added = topmost)
        for annotation in annotations.reversed() {
            if annotation.hitTest(point, in: CGRect(origin: .zero, size: canvasSize)) {
                selectedAnnotationID = annotation.id
                return
            }
        }
        selectedAnnotationID = nil    }
    
    func deleteSelectedAnnotation() {
        if let id = selectedAnnotationID {
            removeAnnotation(id: id)
        }
    }
    
    // MARK: - Drawing Actions
    
    func handleDragStart(at point: CGPoint, in canvasRect: CGRect) {
        let localPoint = CGPoint(x: point.x - canvasRect.minX, y: point.y - canvasRect.minY)
        
        switch currentTool {
        case .select:
            dragState.start(at: localPoint)
            selectAnnotation(at: localPoint)
            if let id = selectedAnnotationID,
               let index = annotations.firstIndex(where: { $0.id == id }) {
                let annotation = annotations[index]
                dragStartAnnotation = annotation
                let bounds = annotation.bounds(in: CGRect(origin: .zero, size: canvasSize))
                dragState.dragOffset = CGSize(width: localPoint.x - bounds.midX, height: localPoint.y - bounds.midY)
            }
        case .text:
            dragState.start(at: localPoint)
            let textW: CGFloat = 240, textH: CGFloat = 40
            let tx = min(max(localPoint.x, 0), max(canvasSize.width - textW, 0))
            let ty = min(max(localPoint.y, 0), max(canvasSize.height - textH, 0))
            textInputRect = CGRect(x: tx, y: ty, width: textW, height: textH)
            textInputString = ""
            showTextInput = true
        default:
            dragState.start(at: localPoint)
        }
    }
    
    func handleDragUpdate(at point: CGPoint, in canvasRect: CGRect) {
        let localPoint = CGPoint(x: point.x - canvasRect.minX, y: point.y - canvasRect.minY)
        dragState.update(to: localPoint)
        
        if currentTool == .select, let id = selectedAnnotationID,
           var annotation = annotations.first(where: { $0.id == id }) {
            let newCenter = CGPoint(x: localPoint.x - dragState.dragOffset.width, y: localPoint.y - dragState.dragOffset.height)
            let bounds = annotation.bounds(in: CGRect(origin: .zero, size: canvasSize))
            let deltaX = newCenter.x - bounds.midX
            let deltaY = newCenter.y - bounds.midY
            annotation.applyTransform(CGAffineTransform(translationX: deltaX, y: deltaY))
            // 直接更新 — undoはdragEnd時に1回だけ登録
            if let index = annotations.firstIndex(where: { $0.id == id }) {
                annotations[index] = annotation
            }
        }
        objectWillChange.send()
    }

    func handleDragEnd(at point: CGPoint, in canvasRect: CGRect) {
        guard let (start, end) = dragState.end() else { return }

        switch currentTool {
        case .select:
            // ドラッグ全体を1回のundoとして登録
            if let original = dragStartAnnotation,
               let index = annotations.firstIndex(where: { $0.id == original.id }) {
                let orig = original
                undoManager.registerUndo(withTarget: self) { target in
                    target.isUndoing = true
                    target.annotations[index] = orig
                    target.objectWillChange.send()
                    target.isUndoing = false
                }
                updateUndoRedoState()
                if !annotations[index].hasStrokeRepresentation {
                    updateFilterPreview(for: annotations[index])
                }
            }
            dragStartAnnotation = nil
        case .text:
            break
        default:
            if let type = currentTool.annotationType {
                createAnnotation(type: type, from: start, to: end)
            }
        }
        objectWillChange.send()
    }
    
    func handleDragCancel() {
        dragState.cancel()
        objectWillChange.send()
    }
    
    private func createAnnotation(type: AnnotationType, from start: CGPoint, to end: CGPoint) {
        let color = currentColor
        let lineWidth = currentLineWidth
        
        let annotation: AnyAnnotation
        
        switch type {
        case .line:
            let a = LineAnnotation(color: color, lineWidth: lineWidth, startPoint: start, endPoint: end)
            annotation = AnyAnnotation(a)
        case .arrow:
            let a = ArrowAnnotation(color: color, lineWidth: lineWidth, startPoint: start, endPoint: end)
            annotation = AnyAnnotation(a)
        case .rectangle:
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            let a = RectangleAnnotation(color: color, lineWidth: lineWidth, rect: rect)
            annotation = AnyAnnotation(a)
        case .ellipse:
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            let a = EllipseAnnotation(color: color, lineWidth: lineWidth, rect: rect)
            annotation = AnyAnnotation(a)
        case .mosaic:
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: max(abs(end.x - start.x), 20),
                height: max(abs(end.y - start.y), 20)
            )
            let a = MosaicAnnotation(color: color, lineWidth: lineWidth, rect: rect)
            annotation = AnyAnnotation(a)
        case .blur:
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: max(abs(end.x - start.x), 20),
                height: max(abs(end.y - start.y), 20)
            )
            let a = BlurAnnotation(color: color, lineWidth: lineWidth, rect: rect)
            annotation = AnyAnnotation(a)
        case .text:
            return
        }
        
        addAnnotation(annotation)
    }
    
    func confirmTextInput() {
        guard !textInputString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showTextInput = false
            return
        }
        let rect = textInputRect
        let a = TextAnnotation(color: currentColor, lineWidth: currentLineWidth, rect: rect, text: textInputString)
        let annotation = AnyAnnotation(a)
        addAnnotation(annotation)
        showTextInput = false
        textInputString = ""
    }
    
    func cancelTextInput() {
        showTextInput = false
        textInputString = ""
    }
    
    // MARK: - Undo/Redo

    @Published var canUndo: Bool = false
    @Published var canRedo: Bool = false

    func undo() {
        undoManager.undo()
        updateUndoRedoState()
    }

    func redo() {
        undoManager.redo()
        updateUndoRedoState()
    }

    func updateUndoRedoState() {
        canUndo = undoManager.canUndo
        canRedo = undoManager.canRedo
    }

    func resetAndLoad(image: CGImage, annotations: [AnyAnnotation]) {
        backgroundImage = image
        // canvasSize は View の onAppear/onChange が管理する — ここで上書きしない
        self.annotations = annotations
        selectedAnnotationID = nil
        undoManager.removeAllActions()
        updateUndoRedoState()
        recomputeAllFilterPreviews()
    }
    
    // MARK: - Export

    func renderAnnotations() -> CGImage? {
        guard let bgImage = backgroundImage else { return nil }

        let imageW = CGFloat(bgImage.width)
        let imageH = CGFloat(bgImage.height)
        // アノテーションはview座標 → 物理ピクセルへのスケール係数
        let scaleX = canvasSize.width  > 0 ? imageW / canvasSize.width  : 1
        let scaleY = canvasSize.height > 0 ? imageH / canvasSize.height : 1

        // STEP 1: CI フィルタ（モザイク・ぼかし）をフル解像度で適用
        let ciImage = CIImage(cgImage: bgImage)
        var resultCI = ciImage
        let ciCtx = CIContext(options: [.useSoftwareRenderer: false])

        for annotation in annotations where !annotation.hasStrokeRepresentation {
            // view空間 → CI空間変換（スケール + Y軸反転）
            let vr = annotation.bounds(in: CGRect(origin: .zero, size: canvasSize))
            let ciRect = CGRect(
                x: vr.minX * scaleX,
                y: imageH - vr.maxY * scaleY,
                width: vr.width  * scaleX,
                height: vr.height * scaleY
            )
            if let filtered = applyFilter(type: annotation.type, to: resultCI, in: ciRect) {
                resultCI = filtered
            }
        }

        let filteredCGImage = resultCI !== ciImage
            ? ciCtx.createCGImage(resultCI, from: resultCI.extent)
            : nil

        // STEP 2: 物理ピクセルサイズのコンテキストにストローク系アノテーションを描画
        guard let cgCtx = CGContext(
            data: nil,
            width: bgImage.width,
            height: bgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return filteredCGImage ?? bgImage }

        let fullRect = CGRect(x: 0, y: 0, width: imageW, height: imageH)
        cgCtx.draw(filteredCGImage ?? bgImage, in: fullRect)

        let viewRect = CGRect(origin: .zero, size: canvasSize)
        let toImage = CGAffineTransform(scaleX: scaleX, y: scaleY)
        let strokeScale = min(scaleX, scaleY)

        for annotation in annotations {
            guard annotation.hasStrokeRepresentation else { continue }
            cgCtx.saveGState()
            if annotation.type == .text, let text = annotation.textContent {
                let rect = annotation.bounds(in: viewRect).applying(toImage)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: max(rect.height * 0.6, 14 * scaleY), weight: .semibold),
                    .foregroundColor: NSColor(cgColor: annotation.color.cgColor) ?? .labelColor
                ]
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: cgCtx, flipped: false)
                NSAttributedString(string: text, attributes: attrs).draw(in: rect)
                NSGraphicsContext.restoreGraphicsState()
            } else {
                let cgPath = annotation.path(in: viewRect).applying(toImage).cgPath
                if annotation.type == .arrow {
                    cgCtx.addPath(cgPath)
                    cgCtx.setFillColor(annotation.color.cgColor)
                    cgCtx.fillPath()
                    cgCtx.addPath(cgPath)
                }
                cgCtx.addPath(cgPath)
                cgCtx.setStrokeColor(annotation.color.cgColor)
                cgCtx.setLineWidth(annotation.lineWidth.rawValue * strokeScale)
                cgCtx.setLineCap(.round)
                cgCtx.setLineJoin(.round)
                cgCtx.strokePath()
            }
            cgCtx.restoreGState()
        }

        return cgCtx.makeImage() ?? filteredCGImage ?? bgImage
    }

    private func applyFilter(type: AnnotationType, to image: CIImage, in ciRect: CGRect) -> CIImage? {
        let black = CIImage(color: .black).cropped(to: image.extent)
        let white = CIImage(color: .white).cropped(to: ciRect)
        let mask  = white.composited(over: black)

        switch type {
        case .mosaic:
            let f = CIFilter.pixellate()
            f.inputImage = image
            f.scale = 12.0
            guard let out = f.outputImage else { return nil }
            return out.applyingFilter("CIBlendWithMask", parameters: [kCIInputMaskImageKey: mask])
                .composited(over: image)
        case .blur:
            let f = CIFilter.gaussianBlur()
            f.inputImage = image
            f.radius = 20.0
            guard let out = f.outputImage else { return nil }
            return out.applyingFilter("CIBlendWithMask", parameters: [kCIInputMaskImageKey: mask])
                .composited(over: image)
        default:
            return nil
        }
    }
}