// AnnotationCanvas.swift - Part 1: Models & Protocol
// SnapLocal - Canvas + Shapes + Undo/Redo
//
// Copyright © 2024 SnapLocal. All rights reserved.

import SwiftUI
import CoreGraphics
import AppKit

// MARK: - Annotation Protocol

protocol AnnotationElement: Identifiable, Codable {
    var id: UUID { get }
    var type: AnnotationType { get }
    var color: AnnotationColor { get set }
    var lineWidth: LineWidth { get set }
    var transform: CGAffineTransform { get set }
    func path(in rect: CGRect) -> Path
    func hitTest(_ point: CGPoint, in rect: CGRect) -> Bool
    func bounds(in rect: CGRect) -> CGRect
    mutating func applyTransform(_ transform: CGAffineTransform)
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
    case red = "red"
    case blue = "blue"
    case yellow = "yellow"

    var color: Color {
        switch self {
        case .red: return .red
        case .blue: return .blue
        case .yellow: return .yellow
        }
    }

    var cgColor: CGColor {
        switch self {
        case .red: return CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        case .blue: return CGColor(red: 0, green: 0, blue: 1, alpha: 1)
        case .yellow: return CGColor(red: 1, green: 1, blue: 0, alpha: 1)
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
        case .arrow: return "arrowshape.turn.up.right"
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
                let bounds = annotation.bounds(in: CGRect(origin: .zero, size: canvasSize))
                dragState.dragOffset = CGSize(width: localPoint.x - bounds.midX, height: localPoint.y - bounds.midY)
            }
        case .text:
            dragState.start(at: localPoint)
            textInputRect = CGRect(x: localPoint.x, y: localPoint.y, width: 200, height: 40)
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
            var newTransform = annotation.transform
            let newCenter = CGPoint(x: localPoint.x - dragState.dragOffset.width, y: localPoint.y - dragState.dragOffset.height)
            let bounds = annotation.bounds(in: CGRect(origin: .zero, size: canvasSize))
            let deltaX = newCenter.x - bounds.midX
            let deltaY = newCenter.y - bounds.midY
            newTransform = newTransform.translatedBy(x: deltaX, y: deltaY)
            annotation.applyTransform(CGAffineTransform(translationX: deltaX, y: deltaY))
            updateAnnotation(annotation)
        }
        objectWillChange.send()
    }

    func handleDragEnd(at point: CGPoint, in canvasRect: CGRect) {
        guard let (start, end) = dragState.end() else { return }
        
        switch currentTool {
        case .select:
            break
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
        canvasSize = CGSize(width: image.width, height: image.height)
        self.annotations = annotations
        selectedAnnotationID = nil
        undoManager.removeAllActions()
        updateUndoRedoState()
    }
    
    // MARK: - Export
    
    func renderAnnotations() -> CGImage? {
        guard let bgImage = backgroundImage else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: Int(canvasSize.width),
            height: Int(canvasSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        
        context.draw(bgImage, in: CGRect(origin: .zero, size: canvasSize))
        
        for annotation in annotations {
            context.saveGState()
            if annotation.type == .text, let text = annotation.textContent {
                let rect = annotation.bounds(in: CGRect(origin: .zero, size: canvasSize))
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: max(rect.height * 0.6, 14), weight: .semibold),
                    .foregroundColor: NSColor(cgColor: annotation.color.cgColor) ?? .labelColor
                ]
                let attributed = NSAttributedString(string: text, attributes: attributes)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                attributed.draw(in: rect)
                NSGraphicsContext.restoreGraphicsState()
                context.restoreGState()
                continue
            }
            let path = annotation.path(in: CGRect(origin: .zero, size: canvasSize)).cgPath
            context.addPath(path)
            context.setStrokeColor(annotation.color.cgColor)
            context.setLineWidth(annotation.lineWidth.rawValue)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
            context.restoreGState()
        }
        
        return context.makeImage()
    }
}