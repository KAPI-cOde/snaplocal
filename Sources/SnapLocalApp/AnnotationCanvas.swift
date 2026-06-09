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
    case step = "step"
    case roundedRect = "roundedRect"
    case callout = "callout"
    case highlight = "highlight"
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
    case medium = 4
    case thick = 8
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

    var systemImage: String {
        switch self {
        case .select: return "arrow.up.left.and.arrow.down.right"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .text: return "textformat"
        case .step: return "number.circle"
        case .roundedRect: return "rectangle.roundedtop"
        case .callout: return "bubble.left"
        case .highlight: return "highlighter"
        case .redact: return "eye.slash"
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
        }
    }

    var annotationType: AnnotationType? {
        switch self {
        case .select, .redact: return nil
        case .line: return .line
        case .arrow: return .arrow
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        case .text: return .text
        case .step: return .step
        case .roundedRect: return .roundedRect
        case .callout: return .callout
        case .highlight: return .highlight
        }
    }

    var usesLineWidth: Bool {
        switch self {
        case .line, .arrow, .rectangle, .ellipse, .text, .step, .roundedRect, .callout: return true
        case .select, .redact, .highlight: return false
        }
    }
}

enum RedactMode: String, Codable, CaseIterable {
    case mosaic, blur

    var annotationType: AnnotationType { self == .mosaic ? .mosaic : .blur }
    var systemImage: String { self == .mosaic ? "square.grid.3x3" : "aqi.medium" }
    var displayName: String { self == .mosaic ? "モザイク" : "ぼかし" }
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

// MARK: - Canvas ViewModel

@MainActor
final class CanvasViewModel: ObservableObject {
    @Published var annotations: [AnyAnnotation] = []
    @Published var currentTool: DrawingTool = .arrow
    @Published var currentColor: AnnotationColor = .red
    @Published var currentLineWidth: LineWidth = .thin
    @Published var currentRedactMode: RedactMode = .mosaic
    @Published var currentMosaicScale: Float = 12
    @Published var currentBlurRadius: Float = 20
    @Published var currentFontSize: CGFloat = 18
    @Published var currentFilled: Bool = false
    @Published var currentOpacity: Double = 1.0
    @Published var currentTextBackground: Bool = false
    @Published var snapGuides: [SnapGuide] = []
    @Published var dragState = DragState()
    @Published var backgroundImage: CGImage?
    @Published var canvasSize: CGSize = .zero
    @Published var showTextInput = false
    @Published var textInputRect: CGRect = .zero
    @Published var textInputString = ""
    private var editingAnnotationID: UUID? = nil
    @Published var selectedAnnotationID: UUID?
    @Published var isDraggingAnnotation = false
    // Multi-selection
    @Published var selectedAnnotationIDs: Set<UUID> = []
    @Published var rubberBandRect: CGRect? = nil
    private var isRubberBanding = false
    private var multiDragStartPositions: [UUID: CGAffineTransform] = [:]
    // Resize handles
    var resizingHandleIndex: Int? = nil          // 0=TL 1=TR 2=BL 3=BR
    var resizingStartBounds: CGRect? = nil
    var resizingStartTransform: CGAffineTransform? = nil
    // Crop mode
    @Published var isCropMode = false
    @Published var cropStart: CGPoint?
    @Published var cropEnd: CGPoint?

    let undoManager = UndoManager()
    private var isUndoing = false
    private var dragStartAnnotation: AnyAnnotation? = nil

    func applyCurrentColorToSelection() {
        let ids = selectedAnnotationIDs.isEmpty ? (selectedAnnotationID.map { [$0] } ?? []) : Array(selectedAnnotationIDs)
        for id in ids {
            guard var ann = annotations.first(where: { $0.id == id }),
                  ann.hasStrokeRepresentation, ann.color != currentColor else { continue }
            ann.color = currentColor
            updateAnnotation(ann)
        }
    }

    func applyCurrentLineWidthToSelection() {
        let ids = selectedAnnotationIDs.isEmpty ? (selectedAnnotationID.map { [$0] } ?? []) : Array(selectedAnnotationIDs)
        for id in ids {
            guard var ann = annotations.first(where: { $0.id == id }),
                  ann.hasStrokeRepresentation, ann.lineWidth != currentLineWidth else { continue }
            ann.lineWidth = currentLineWidth
            updateAnnotation(ann)
        }
    }

    func applyCurrentOpacityToSelection() {
        let ids = selectedAnnotationIDs.isEmpty ? (selectedAnnotationID.map { [$0] } ?? []) : Array(selectedAnnotationIDs)
        for id in ids {
            guard var ann = annotations.first(where: { $0.id == id }), ann.opacity != currentOpacity else { continue }
            ann.opacity = currentOpacity
            updateAnnotation(ann)
            if !ann.hasStrokeRepresentation { updateFilterPreview(for: ann) }
        }
    }

    func applyCurrentFilledToSelection() {
        let ids = selectedAnnotationIDs.isEmpty ? (selectedAnnotationID.map { [$0] } ?? []) : Array(selectedAnnotationIDs)
        for id in ids {
            guard var ann = annotations.first(where: { $0.id == id }),
                  (ann.type == .rectangle || ann.type == .ellipse || ann.type == .roundedRect),
                  ann.isFilled != currentFilled else { continue }
            ann.isFilled = currentFilled
            updateAnnotation(ann)
        }
    }
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
                    if !annotation.hasStrokeRepresentation {
                        target.updateFilterPreview(for: annotation)
                    }
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
    
    func toggleLockSelected() {
        let ids = selectedAnnotationIDs.isEmpty ? (selectedAnnotationID.map { [$0] } ?? []) : Array(selectedAnnotationIDs)
        for id in ids {
            guard var ann = annotations.first(where: { $0.id == id }) else { continue }
            ann.isLocked.toggle()
            updateAnnotation(ann)
        }
        // Deselect if we just locked
        if let id = selectedAnnotationID, annotations.first(where: { $0.id == id })?.isLocked == true {
            selectedAnnotationID = nil
            selectedAnnotationIDs = []
        }
    }

    func selectAnnotation(at point: CGPoint, pickStyleOnly: Bool = false) {
        for annotation in annotations.reversed() {
            if annotation.isLocked { continue }
            if annotation.hitTest(point, in: CGRect(origin: .zero, size: canvasSize)) {
                if pickStyleOnly {
                    if annotation.hasStrokeRepresentation {
                        currentColor = annotation.color
                        currentLineWidth = annotation.lineWidth
                    }
                    if annotation.type == .text, let fs = annotation.textFontSize {
                        currentFontSize = fs
                    }
                    return
                }
                selectedAnnotationID = annotation.id
                selectedAnnotationIDs = [annotation.id]
                if annotation.hasStrokeRepresentation {
                    currentColor = annotation.color
                    currentLineWidth = annotation.lineWidth
                }
                if annotation.type == .text, let fs = annotation.textFontSize {
                    currentFontSize = fs
                }
                if annotation.type == .rectangle || annotation.type == .ellipse || annotation.type == .roundedRect {
                    currentFilled = annotation.isFilled
                }
                currentOpacity = annotation.opacity
                if annotation.type == .text {
                    currentTextBackground = annotation.textHasBackground
                }
                return
            }
        }
        if !pickStyleOnly {
            selectedAnnotationID = nil
            selectedAnnotationIDs = []
        }
    }
    
    func deleteSelectedAnnotation() {
        if selectedAnnotationIDs.count > 1 {
            // Multi-delete: skip locked
            let ids = selectedAnnotationIDs.filter { id in annotations.first(where: { $0.id == id })?.isLocked != true }
            guard !ids.isEmpty else { return }
            let snapshot = annotations
            undoManager.registerUndo(withTarget: self) { target in
                target.isUndoing = true
                target.annotations = snapshot
                target.isUndoing = false
                target.recomputeAllFilterPreviews()
                target.updateUndoRedoState()
            }
            annotations.removeAll { ids.contains($0.id) }
            ids.forEach { filterPreviews.removeValue(forKey: $0) }
            selectedAnnotationIDs = []
            selectedAnnotationID = nil
            updateUndoRedoState()
        } else if let id = selectedAnnotationID,
                  annotations.first(where: { $0.id == id })?.isLocked != true {
            removeAnnotation(id: id)
        }
    }

    static func isResizable(_ type: AnnotationType) -> Bool {
        [.rectangle, .ellipse, .mosaic, .blur, .text, .step, .roundedRect, .callout, .highlight].contains(type)
    }

    func handleCorners(for bounds: CGRect) -> [CGPoint] {
        [CGPoint(x: bounds.minX, y: bounds.minY),   // 0 TL
         CGPoint(x: bounds.maxX, y: bounds.minY),   // 1 TR
         CGPoint(x: bounds.minX, y: bounds.maxY),   // 2 BL
         CGPoint(x: bounds.maxX, y: bounds.maxY)]   // 3 BR
    }

    func hitTestHandle(at point: CGPoint, corners: [CGPoint]) -> Int? {
        let r: CGFloat = 8
        for (i, c) in corners.enumerated() {
            if abs(point.x - c.x) <= r && abs(point.y - c.y) <= r { return i }
        }
        return nil
    }

    func clearAllAnnotations() {
        guard !annotations.isEmpty else { return }
        let snapshot = annotations
        undoManager.registerUndo(withTarget: self) { target in
            target.isUndoing = true
            target.annotations = snapshot
            target.isUndoing = false
            target.recomputeAllFilterPreviews()
            target.updateUndoRedoState()
        }
        annotations.removeAll()
        filterPreviews.removeAll()
        selectedAnnotationID = nil
        selectedAnnotationIDs = []
        updateUndoRedoState()
        objectWillChange.send()
    }

    static let annotationPasteboardType = NSPasteboard.PasteboardType("com.snaplocal.annotation.v1")

    func copySelectedAnnotationToClipboard() {
        guard let id = selectedAnnotationID,
              let annotation = annotations.first(where: { $0.id == id }),
              let data = try? JSONEncoder().encode(annotation) else { return }
        NSPasteboard.general.addTypes([Self.annotationPasteboardType], owner: nil)
        NSPasteboard.general.setData(data, forType: Self.annotationPasteboardType)
    }

    /// Returns true if annotation was pasted from clipboard.
    @discardableResult
    func pasteAnnotationFromClipboard() -> Bool {
        guard let data = NSPasteboard.general.data(forType: Self.annotationPasteboardType),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        json["id"] = UUID().uuidString
        guard let newData = try? JSONSerialization.data(withJSONObject: json),
              var newAnnotation = try? JSONDecoder().decode(AnyAnnotation.self, from: newData) else { return false }
        newAnnotation.applyTransform(CGAffineTransform(translationX: 10, y: 10))
        addAnnotation(newAnnotation)
        selectedAnnotationID = newAnnotation.id
        return true
    }

    func duplicateSelectedAnnotation() {
        guard let id = selectedAnnotationID,
              let annotation = annotations.first(where: { $0.id == id }),
              let data = try? JSONEncoder().encode(annotation),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        json["id"] = UUID().uuidString
        guard let newData = try? JSONSerialization.data(withJSONObject: json),
              var newAnnotation = try? JSONDecoder().decode(AnyAnnotation.self, from: newData) else { return }
        newAnnotation.applyTransform(CGAffineTransform(translationX: 10, y: 10))
        addAnnotation(newAnnotation)
        selectedAnnotationID = newAnnotation.id
    }

    func bringSelectedToFront() {
        guard let id = selectedAnnotationID,
              let i = annotations.firstIndex(where: { $0.id == id }),
              i < annotations.count - 1 else { return }
        let a = annotations.remove(at: i)
        annotations.append(a)
        objectWillChange.send()
    }

    func sendSelectedToBack() {
        guard let id = selectedAnnotationID,
              let i = annotations.firstIndex(where: { $0.id == id }),
              i > 0 else { return }
        let a = annotations.remove(at: i)
        annotations.insert(a, at: 0)
        objectWillChange.send()
    }

    
    // MARK: - Drawing Actions
    
    func handleDragStart(at point: CGPoint, in canvasRect: CGRect) {
        let localPoint = CGPoint(x: point.x - canvasRect.minX, y: point.y - canvasRect.minY)

        if isCropMode {
            dragState.start(at: localPoint)
            cropStart = localPoint
            cropEnd = localPoint
            return
        }

        switch currentTool {
        case .select:
            // Check resize handles first (single selection only)
            if let id = selectedAnnotationID,
               selectedAnnotationIDs.count <= 1,
               let ann = annotations.first(where: { $0.id == id }),
               Self.isResizable(ann.type) {
                let bounds = ann.bounds(in: CGRect(origin: .zero, size: canvasSize))
                let corners = handleCorners(for: bounds)
                if let h = hitTestHandle(at: localPoint, corners: corners) {
                    dragState.start(at: localPoint)
                    resizingHandleIndex = h
                    resizingStartBounds = bounds
                    resizingStartTransform = ann.transform
                    dragStartAnnotation = ann
                    return
                }
            }

            if NSEvent.modifierFlags.contains(.option) {
                // Option+drag: duplicate the hit annotation and drag the copy
                let innerRect = CGRect(origin: .zero, size: canvasSize)
                let hitAnn = annotations.reversed().first(where: { !$0.isLocked && $0.hitTest(localPoint, in: innerRect) })
                if let ann = hitAnn,
                   let data = try? JSONEncoder().encode(ann),
                   var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let _ = { json["id"] = UUID().uuidString }() as Void?,
                   let newData = try? JSONSerialization.data(withJSONObject: json),
                   var newAnn = try? JSONDecoder().decode(AnyAnnotation.self, from: newData) {
                    addAnnotation(newAnn)
                    selectedAnnotationID = newAnn.id
                    selectedAnnotationIDs = [newAnn.id]
                    dragState.start(at: localPoint)
                    let bounds = newAnn.bounds(in: innerRect)
                    dragState.dragOffset = CGSize(width: localPoint.x - bounds.midX, height: localPoint.y - bounds.midY)
                    dragStartAnnotation = newAnn
                    multiDragStartPositions = [:]
                } else {
                    // No annotation hit: pick style (eyedropper)
                    selectAnnotation(at: localPoint, pickStyleOnly: true)
                }
                return
            }

            // Shift+click: toggle annotation in multi-selection
            if NSEvent.modifierFlags.contains(.shift) {
                let canvasRect = CGRect(origin: .zero, size: canvasSize)
                if let ann = annotations.reversed().first(where: { $0.hitTest(localPoint, in: canvasRect) }) {
                    if selectedAnnotationIDs.contains(ann.id) {
                        selectedAnnotationIDs.remove(ann.id)
                        selectedAnnotationID = selectedAnnotationIDs.first
                    } else {
                        selectedAnnotationIDs.insert(ann.id)
                        selectedAnnotationID = ann.id
                    }
                }
                objectWillChange.send()
                return
            }

            dragState.start(at: localPoint)
            // Hit-test: if nothing hit, start rubber-band selection
            let canvasRect = CGRect(origin: .zero, size: canvasSize)
            let hitAnn = annotations.reversed().first(where: { $0.hitTest(localPoint, in: canvasRect) })
            if hitAnn == nil {
                isRubberBanding = true
                rubberBandRect = CGRect(x: localPoint.x, y: localPoint.y, width: 0, height: 0)
                selectedAnnotationID = nil
                selectedAnnotationIDs = []
                objectWillChange.send()
                return
            }

            selectAnnotation(at: localPoint)
            if let id = selectedAnnotationID,
               let index = annotations.firstIndex(where: { $0.id == id }) {
                let annotation = annotations[index]
                dragStartAnnotation = annotation
                let bounds = annotation.bounds(in: CGRect(origin: .zero, size: canvasSize))
                dragState.dragOffset = CGSize(width: localPoint.x - bounds.midX, height: localPoint.y - bounds.midY)
                // If this annotation is part of multi-selection, store all start transforms
                if selectedAnnotationIDs.count > 1 && selectedAnnotationIDs.contains(id) {
                    multiDragStartPositions = Dictionary(uniqueKeysWithValues:
                        annotations.filter { selectedAnnotationIDs.contains($0.id) }
                            .map { ($0.id, $0.transform) }
                    )
                } else {
                    selectedAnnotationIDs = [id]
                    multiDragStartPositions = [:]
                }
            }
        case .text:
            dragState.start(at: localPoint)
            let textW: CGFloat = 240, textH: CGFloat = currentFontSize * 2.2
            let tx = min(max(localPoint.x, 0), max(canvasSize.width - textW, 0))
            let ty = min(max(localPoint.y, 0), max(canvasSize.height - textH, 0))
            textInputRect = CGRect(x: tx, y: ty, width: textW, height: textH)
            textInputString = ""
            showTextInput = true
        default:
            dragState.start(at: localPoint)
        }
    }
    
    private func shiftConstrainedPoint(_ end: CGPoint, from start: CGPoint) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        let angle = atan2(abs(dy), abs(dx))
        if angle < .pi / 8 {
            return CGPoint(x: end.x, y: start.y)
        } else if angle < 3 * .pi / 8 {
            let side = min(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
        } else {
            return CGPoint(x: start.x, y: end.y)
        }
    }

    func handleDragUpdate(at point: CGPoint, in canvasRect: CGRect) {
        var localPoint = CGPoint(x: point.x - canvasRect.minX, y: point.y - canvasRect.minY)

        if NSEvent.modifierFlags.contains(.shift), let start = dragState.startPoint {
            switch currentTool {
            case .line, .arrow:
                localPoint = shiftConstrainedPoint(localPoint, from: start)
            case .rectangle, .ellipse, .redact, .roundedRect:
                // Lock to square/circle by using the smaller dimension
                let dx = localPoint.x - start.x, dy = localPoint.y - start.y
                let side = min(abs(dx), abs(dy))
                localPoint = CGPoint(x: start.x + (dx < 0 ? -side : side),
                                     y: start.y + (dy < 0 ? -side : side))
            default: break
            }
        }

        dragState.update(to: localPoint)

        if isCropMode {
            cropEnd = localPoint
            objectWillChange.send()
            return
        }

        if currentTool == .select {
            // Rubber-band update
            if isRubberBanding, let start = dragState.startPoint {
                let minX = min(start.x, localPoint.x), maxX = max(start.x, localPoint.x)
                let minY = min(start.y, localPoint.y), maxY = max(start.y, localPoint.y)
                rubberBandRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                objectWillChange.send()
                return
            }

            // Resize mode
            if let handleIdx = resizingHandleIndex,
               let id = selectedAnnotationID,
               let startBounds = resizingStartBounds,
               let startTransform = resizingStartTransform,
               var annotation = annotations.first(where: { $0.id == id }) {
                // Compute fixed corner and new bounds
                let fixedCorners: [CGPoint] = [
                    CGPoint(x: startBounds.maxX, y: startBounds.maxY), // 0-TL dragging → BR is fixed
                    CGPoint(x: startBounds.minX, y: startBounds.maxY), // 1-TR → BL is fixed
                    CGPoint(x: startBounds.maxX, y: startBounds.minY), // 2-BL → TR is fixed
                    CGPoint(x: startBounds.minX, y: startBounds.minY), // 3-BR → TL is fixed
                ]
                let fx = fixedCorners[handleIdx]
                let nx = min(localPoint.x, fx.x), ny = min(localPoint.y, fx.y)
                let nw = max(abs(localPoint.x - fx.x), 4), nh = max(abs(localPoint.y - fx.y), 4)
                let newBounds = CGRect(x: nx, y: ny, width: nw, height: nh)
                let sx = newBounds.width / max(startBounds.width, 1)
                let sy = newBounds.height / max(startBounds.height, 1)
                let tx = newBounds.minX - startBounds.minX * sx
                let ty = newBounds.minY - startBounds.minY * sy
                let mapT = CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: tx, ty: ty)
                annotation.transform = startTransform.concatenating(mapT)
                if let index = annotations.firstIndex(where: { $0.id == id }) {
                    annotations[index] = annotation
                }
                objectWillChange.send()
                return
            }

            // Move mode
            if let id = selectedAnnotationID,
               var annotation = annotations.first(where: { $0.id == id }) {
                isDraggingAnnotation = true
                let newCenter = CGPoint(x: localPoint.x - dragState.dragOffset.width, y: localPoint.y - dragState.dragOffset.height)
                let bounds = annotation.bounds(in: CGRect(origin: .zero, size: canvasSize))
                var deltaX = newCenter.x - bounds.midX
                var deltaY = newCenter.y - bounds.midY

                if !multiDragStartPositions.isEmpty {
                    // Multi-move: apply same delta to all selected annotations from their start positions
                    guard let dragStartAnn = dragStartAnnotation else { return }
                    let startBounds = dragStartAnn.bounds(in: CGRect(origin: .zero, size: canvasSize))
                    let totalDeltaX = localPoint.x - dragState.dragOffset.width - startBounds.midX
                    let totalDeltaY = localPoint.y - dragState.dragOffset.height - startBounds.midY
                    let totalMoveT = CGAffineTransform(translationX: totalDeltaX, y: totalDeltaY)
                    for (annId, startTransform) in multiDragStartPositions {
                        if var ann = annotations.first(where: { $0.id == annId }),
                           let idx = annotations.firstIndex(where: { $0.id == annId }) {
                            ann.transform = startTransform.concatenating(totalMoveT)
                            annotations[idx] = ann
                        }
                    }
                    snapGuides = []
                } else {
                    // Single move with snap guide computation
                    let proposedBounds = CGRect(
                        x: bounds.minX + deltaX, y: bounds.minY + deltaY,
                        width: bounds.width, height: bounds.height
                    )
                    let (snappedDx, snappedDy, guides) = computeSnap(for: proposedBounds, excluding: id)
                    deltaX -= snappedDx
                    deltaY -= snappedDy
                    snapGuides = guides

                    annotation.applyTransform(CGAffineTransform(translationX: deltaX, y: deltaY))
                    if let index = annotations.firstIndex(where: { $0.id == id }) {
                        annotations[index] = annotation
                    }
                }
            }
        }
        objectWillChange.send()
    }

    private func computeSnap(for proposed: CGRect, excluding excludedID: UUID) -> (dx: CGFloat, dy: CGFloat, guides: [SnapGuide]) {
        let threshold: CGFloat = 6
        let canvas = CGRect(origin: .zero, size: canvasSize)
        let others = annotations.filter { $0.id != excludedID }
        let sources: [CGRect] = others.map { $0.bounds(in: canvas) } + [canvas]

        var bestDx: CGFloat = threshold, bestDy: CGFloat = threshold
        var guides: [SnapGuide] = []

        for src in sources {
            let xPairs: [(CGFloat, CGFloat)] = [
                (proposed.minX, src.minX), (proposed.midX, src.midX), (proposed.maxX, src.maxX),
                (proposed.minX, src.maxX), (proposed.maxX, src.minX)
            ]
            for (mine, theirs) in xPairs {
                let diff = mine - theirs
                if abs(diff) < abs(bestDx) {
                    bestDx = diff
                    guides.removeAll { $0.axis == .vertical }
                    guides.append(SnapGuide(axis: .vertical, position: theirs))
                }
            }
            let yPairs: [(CGFloat, CGFloat)] = [
                (proposed.minY, src.minY), (proposed.midY, src.midY), (proposed.maxY, src.maxY),
                (proposed.minY, src.maxY), (proposed.maxY, src.minY)
            ]
            for (mine, theirs) in yPairs {
                let diff = mine - theirs
                if abs(diff) < abs(bestDy) {
                    bestDy = diff
                    guides.removeAll { $0.axis == .horizontal }
                    guides.append(SnapGuide(axis: .horizontal, position: theirs))
                }
            }
        }
        // Only snap if within threshold
        if abs(bestDx) >= threshold { bestDx = 0; guides.removeAll { $0.axis == .vertical } }
        if abs(bestDy) >= threshold { bestDy = 0; guides.removeAll { $0.axis == .horizontal } }
        return (bestDx, bestDy, guides)
    }

    func handleDragEnd(at point: CGPoint, in canvasRect: CGRect) {
        guard let (start, end) = dragState.end() else { return }

        if isCropMode {
            cropEnd = CGPoint(x: point.x - canvasRect.minX, y: point.y - canvasRect.minY)
            objectWillChange.send()
            return
        }

        switch currentTool {
        case .select:
            isDraggingAnnotation = false
            snapGuides = []
            // Rubber-band selection finalize
            if isRubberBanding {
                isRubberBanding = false
                if let band = rubberBandRect, band.width > 4 || band.height > 4 {
                    let canvasRect = CGRect(origin: .zero, size: canvasSize)
                    let hits = annotations.filter { $0.bounds(in: canvasRect).intersects(band) }
                    selectedAnnotationIDs = Set(hits.map { $0.id })
                    selectedAnnotationID = hits.last?.id
                }
                rubberBandRect = nil
                objectWillChange.send()
                return
            }
            let wasResizing = resizingHandleIndex != nil
            resizingHandleIndex = nil
            resizingStartBounds = nil
            resizingStartTransform = nil
            // Multi-move undo: snapshot all moved annotations
            if !multiDragStartPositions.isEmpty {
                let startPositions = multiDragStartPositions
                let currentSnapshot = annotations.filter { startPositions[$0.id] != nil }
                undoManager.registerUndo(withTarget: self) { target in
                    target.isUndoing = true
                    for (id, startT) in startPositions {
                        if let idx = target.annotations.firstIndex(where: { $0.id == id }) {
                            target.annotations[idx].transform = startT
                        }
                    }
                    target.objectWillChange.send()
                    target.isUndoing = false
                }
                updateUndoRedoState()
                for ann in currentSnapshot where !ann.hasStrokeRepresentation {
                    updateFilterPreview(for: ann)
                }
                multiDragStartPositions = [:]
            } else if let original = dragStartAnnotation,
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
            _ = wasResizing
        case .text:
            break
        case .redact:
            let w = abs(end.x - start.x), h = abs(end.y - start.y)
            if w > 4 || h > 4 {
                createAnnotation(type: currentRedactMode.annotationType, from: start, to: end)
            }
        case .step:
            createAnnotation(type: .step, from: start, to: end)
        case .roundedRect:
            let w = abs(end.x - start.x), h = abs(end.y - start.y)
            if w > 4 || h > 4 {
                createAnnotation(type: .roundedRect, from: start, to: end)
            }
        case .callout:
            let w = abs(end.x - start.x), h = abs(end.y - start.y)
            if w > 8 || h > 8 {
                createAnnotation(type: .callout, from: start, to: end)
                // Auto-open text input inside the callout bubble (above the tail)
                let bubbleRect = CGRect(
                    x: min(start.x, end.x),
                    y: min(start.y, end.y),
                    width: w,
                    height: h * 0.82
                )
                let inset: CGFloat = 8
                textInputRect = bubbleRect.insetBy(dx: inset, dy: inset)
                textInputString = ""
                editingAnnotationID = nil
                showTextInput = true
            }
        case .highlight:
            let w = abs(end.x - start.x), h = abs(end.y - start.y)
            if w > 4 || h > 4 {
                createAnnotation(type: .highlight, from: start, to: end)
            }
        default:
            if let type = currentTool.annotationType {
                let dist = hypot(end.x - start.x, end.y - start.y)
                if dist > 4 {
                    createAnnotation(type: type, from: start, to: end)
                }
            }
        }
        objectWillChange.send()
    }
    
    func handleDragCancel() {
        isDraggingAnnotation = false
        resizingHandleIndex = nil
        resizingStartBounds = nil
        resizingStartTransform = nil
        dragState.cancel()
        if isCropMode { cropStart = nil; cropEnd = nil }
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
            var a = RectangleAnnotation(color: color, lineWidth: lineWidth, rect: rect)
            a.isFilled = currentFilled
            annotation = AnyAnnotation(a)
        case .ellipse:
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            var a = EllipseAnnotation(color: color, lineWidth: lineWidth, rect: rect)
            a.isFilled = currentFilled
            annotation = AnyAnnotation(a)
        case .mosaic:
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: max(abs(end.x - start.x), 20),
                height: max(abs(end.y - start.y), 20)
            )
            var a = MosaicAnnotation(color: color, lineWidth: lineWidth, rect: rect)
            a.intensity = currentMosaicScale
            annotation = AnyAnnotation(a)
        case .blur:
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: max(abs(end.x - start.x), 20),
                height: max(abs(end.y - start.y), 20)
            )
            var a = BlurAnnotation(color: color, lineWidth: lineWidth, rect: rect)
            a.intensity = currentBlurRadius
            annotation = AnyAnnotation(a)
        case .roundedRect:
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            var a = RoundedRectAnnotation(color: color, lineWidth: lineWidth, rect: rect)
            a.isFilled = currentFilled
            annotation = AnyAnnotation(a)
        case .step:
            let size: CGFloat
            switch lineWidth {
            case .thin:   size = 28
            case .medium: size = 36
            case .thick:  size = 48
            }
            let stepNum = annotations.filter { $0.type == .step }.count + 1
            let rect = CGRect(x: start.x - size / 2, y: start.y - size / 2, width: size, height: size)
            let a = StepAnnotation(color: color, lineWidth: lineWidth, rect: rect, stepNumber: stepNum)
            annotation = AnyAnnotation(a)
        case .callout:
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            var a = CalloutAnnotation(color: color, lineWidth: lineWidth, rect: rect)
            a.isFilled = currentFilled
            annotation = AnyAnnotation(a)
        case .highlight:
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            annotation = AnyAnnotation(HighlightAnnotation(color: color, rect: rect))
        case .text:
            return
        }

        var mutableAnnotation = annotation
        mutableAnnotation.opacity = currentOpacity
        addAnnotation(mutableAnnotation)
        selectedAnnotationID = mutableAnnotation.id
    }

    func beginEditingSelectedText() {
        guard let id = selectedAnnotationID,
              let annotation = annotations.first(where: { $0.id == id }),
              annotation.type == .text,
              let text = annotation.textContent else { return }
        let bounds = annotation.bounds(in: CGRect(origin: .zero, size: canvasSize))
        editingAnnotationID = id
        textInputRect = bounds
        textInputString = text
        if let fs = annotation.textFontSize { currentFontSize = fs }
        showTextInput = true
    }

    func confirmTextInput() {
        let trimmed = textInputString.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            showTextInput = false
            textInputString = ""
            editingAnnotationID = nil
        }
        guard !trimmed.isEmpty else { return }

        if let editID = editingAnnotationID,
           let existing = annotations.first(where: { $0.id == editID }) {
            let bounds = existing.bounds(in: CGRect(origin: .zero, size: canvasSize))
            removeAnnotation(id: editID)
            var a = TextAnnotation(color: existing.color, lineWidth: existing.lineWidth,
                                   rect: bounds, text: trimmed)
            a.fontSize = existing.textFontSize ?? currentFontSize
            a.hasBackground = existing.textHasBackground
            var newAnnotation = AnyAnnotation(a)
            newAnnotation.opacity = existing.opacity
            addAnnotation(newAnnotation)
            selectedAnnotationID = newAnnotation.id
        } else {
            var a = TextAnnotation(color: currentColor, lineWidth: currentLineWidth,
                                   rect: textInputRect, text: trimmed)
            a.fontSize = currentFontSize
            a.hasBackground = currentTextBackground
            var newAnnotation = AnyAnnotation(a)
            newAnnotation.opacity = currentOpacity
            addAnnotation(newAnnotation)
        }
    }

    func cancelTextInput() {
        showTextInput = false
        textInputString = ""
        editingAnnotationID = nil
    }

    // MARK: - Crop

    func enterCropMode() {
        dragState.cancel()
        isDraggingAnnotation = false
        isCropMode = true
        cropStart = nil
        cropEnd = nil
        selectedAnnotationID = nil
        showTextInput = false
    }

    func confirmCrop() {
        defer { cancelCrop() }
        guard let start = cropStart, let end = cropEnd,
              let bgImage = backgroundImage,
              canvasSize.width > 0, canvasSize.height > 0 else { return }
        let sel = CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        )
        guard sel.width > 4, sel.height > 4 else { return }
        let scaleX = CGFloat(bgImage.width) / canvasSize.width
        let scaleY = CGFloat(bgImage.height) / canvasSize.height
        let pixelRect = CGRect(
            x: sel.minX * scaleX, y: sel.minY * scaleY,
            width: sel.width * scaleX, height: sel.height * scaleY
        ).intersection(CGRect(x: 0, y: 0, width: CGFloat(bgImage.width), height: CGFloat(bgImage.height)))
        guard !pixelRect.isNull, pixelRect.width > 0, pixelRect.height > 0,
              let cropped = bgImage.cropping(to: pixelRect) else { return }
        backgroundImage = cropped
        annotations.removeAll()
        selectedAnnotationID = nil
        undoManager.removeAllActions()
        updateUndoRedoState()
        recomputeAllFilterPreviews()
    }

    func cancelCrop() {
        isCropMode = false
        cropStart = nil
        cropEnd = nil
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
            cgCtx.setAlpha(annotation.opacity)
            if annotation.type == .step, let n = annotation.stepNumber {
                let rect = annotation.bounds(in: viewRect).applying(toImage)
                let cgPath = annotation.path(in: viewRect).applying(toImage).cgPath
                cgCtx.addPath(cgPath)
                cgCtx.setFillColor(annotation.color.cgColor)
                cgCtx.fillPath()
                let textColor: NSColor = (annotation.color == .yellow || annotation.color == .white)
                    ? .black : .white
                let fs = min(rect.width, rect.height) * 0.5
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: max(fs, 10)),
                    .foregroundColor: textColor
                ]
                let str = NSAttributedString(string: "\(n)", attributes: attrs)
                let strSize = str.size()
                let strRect = CGRect(
                    x: rect.midX - strSize.width / 2,
                    y: rect.midY - strSize.height / 2,
                    width: strSize.width,
                    height: strSize.height
                )
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: cgCtx, flipped: false)
                str.draw(in: strRect)
                NSGraphicsContext.restoreGraphicsState()
            } else if annotation.type == .text, let text = annotation.textContent {
                let rect = annotation.bounds(in: viewRect).applying(toImage)
                let fs = annotation.textFontSize ?? max(rect.height * 0.6, 14)
                if annotation.textHasBackground {
                    let bgNS: NSColor = annotation.color == .white ? NSColor.black.withAlphaComponent(0.82) : NSColor.white.withAlphaComponent(0.82)
                    cgCtx.setFillColor(bgNS.cgColor)
                    let bgRect = rect.insetBy(dx: -4, dy: -2)
                    let radius = min(bgRect.width, bgRect.height) * 0.15
                    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
                    cgCtx.addPath(bgPath)
                    cgCtx.fillPath()
                }
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: fs * strokeScale, weight: .semibold),
                    .foregroundColor: NSColor(cgColor: annotation.color.cgColor) ?? .labelColor
                ]
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: cgCtx, flipped: false)
                NSAttributedString(string: text, attributes: attrs).draw(in: rect)
                NSGraphicsContext.restoreGraphicsState()
            } else if annotation.type == .highlight {
                let cgPath = annotation.path(in: viewRect).applying(toImage).cgPath
                cgCtx.addPath(cgPath)
                cgCtx.setFillColor(annotation.color.cgColor.copy(alpha: 0.38) ?? annotation.color.cgColor)
                cgCtx.fillPath()
            } else {
                let cgPath = annotation.path(in: viewRect).applying(toImage).cgPath
                if annotation.isFilled {
                    cgCtx.addPath(cgPath)
                    cgCtx.setFillColor(annotation.color.cgColor.copy(alpha: 0.35) ?? annotation.color.cgColor)
                    cgCtx.fillPath()
                } else if annotation.type == .arrow {
                    cgCtx.addPath(cgPath)
                    cgCtx.setFillColor(annotation.color.cgColor)
                    cgCtx.fillPath()
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