// AnnotationCanvas.swift
// SnapLocal - Canvas + Shapes + Undo/Redo
//
// Copyright © 2024 SnapLocal. All rights reserved.

import SwiftUI
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

// MARK: - Canvas ViewModel

@MainActor
final class CanvasViewModel: ObservableObject {
    @Published var annotations: [AnyAnnotation] = []
    @Published private var _currentTool: DrawingTool = .arrow
    var colorPickerPreviousTool: DrawingTool = .arrow
    var currentTool: DrawingTool {
        get { _currentTool }
        set {
            if newValue == .colorPicker && _currentTool != .colorPicker {
                colorPickerPreviousTool = _currentTool
            }
            if newValue != .measure && _currentTool == .measure {
                measureStart = nil; measureEnd = nil
            }
            _currentTool = newValue
        }
    }
    @Published var currentColor: AnnotationColor = .red { didSet { saveCurrentStyle() } }
    @Published var currentLineWidth: LineWidth = .thin { didSet { saveCurrentStyle() } }
    @Published var currentRedactMode: RedactMode = .mosaic
    @Published var currentSpotlightShape: SpotlightShape = .ellipse
    @Published var currentMosaicScale: Float = 12
    @Published var currentBlurRadius: Float = 20
    @Published var currentFontSize: CGFloat = 18 { didSet { saveCurrentStyle() } }
    @Published var currentFilled: Bool = false { didSet { saveCurrentStyle() } }
    /// 両方向矢印。意図的に**永続化しない** — 一度ONにすると(既存の両方向矢印を
    /// 選択しただけでも同期されて)以後の矢印が全部両端になる事故が起きていた。
    /// 起動ごとに通常の片側矢印へ戻る
    @Published var currentArrowDoubleSided: Bool = false
    @Published var currentOpacity: Double = 1.0 { didSet { saveCurrentStyle() } }
    @Published var currentTextBackground: Bool = false { didSet { saveCurrentStyle() } }
    @Published var currentLineStyle: LineStyle = .solid { didSet { saveCurrentStyle() } }
    @Published var currentCustomColorHex: String? = nil { didSet { saveCurrentStyle() } }
    @Published var snapGuides: [SnapGuide] = []
    @Published var annotationsHidden: Bool = false
    @Published var currentPencilPoints: [CGPoint] = []
    @Published var currentStamp: String = "✅"
    @Published var isGrabMoving = false  // true when non-select tool is moving an existing annotation
    @Published var dragState = DragState()
    // Live mosaic/blur preview while dragging redact tool
    @Published var redactDragPreview: CGImage? = nil
    @Published var redactDragPreviewBounds: CGRect = .zero
    private var redactPreviewThrottle = 0
    @Published var backgroundImage: CGImage?
    @Published var canvasSize: CGSize = .zero
    @Published var loadToken: UUID = UUID()
    /// 背景画像が編集(クロップ・回転・結合等)されてvault未保存の状態か。
    /// SnapLocalState が注釈と同じ保存タイミングで読み、新規アイテムとして永続化する(T7.2)
    @Published var backgroundDirty = false
    // Placement ripple: canvas-space center of the most recently placed annotation
    @Published var lastPlacedCenter: CGPoint = .zero
    @Published var lastPlacedAt: CFAbsoluteTime = 0
    @Published var currentZoom: CGFloat = 1.0
    // Non-destructive image adjustments (pending until baked)
    @Published var adjustBrightness: Double = 0.0   // -0.5 … 0.5
    @Published var adjustContrast: Double = 1.0     // 0.5 … 2.0
    @Published var adjustSaturation: Double = 1.0   // 0.0 … 2.0
    @Published var adjustSharpness: Double = 0.0    // 0.0 … 1.0 (CISharpenLuminance radius)
    @Published var showTextInput = false
    @Published var textInputRect: CGRect = .zero
    @Published var textInputString = ""
    private var editingAnnotationID: UUID? = nil
    @Published var selectedAnnotationID: UUID?
    @Published var hoveredAnnotationID: UUID?
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
    @Published var cropAspectRatio: CGFloat? = nil  // nil = free, else width/height
    @Published var cropAnimToken: UUID = UUID()  // changes when crop is confirmed (triggers fade)
    // Crop handle editing
    var cropHandleActive: CropHandle? = nil
    private var cropHandleStartRect: CGRect = .zero
    private var cropHandleDragOrigin: CGPoint = .zero

    // Measure tool (transient, not saved)
    @Published var measureStart: CGPoint?
    @Published var measureEnd: CGPoint?

    let undoManager = UndoManager()
    private var isUndoing = false
    private var dragStartAnnotation: AnyAnnotation? = nil
    private var calloutTailBakedBase: CalloutAnnotation? = nil
    // index 9 = start endpoint, 10 = end endpoint for line/arrow
    private var endpointDragBakedStart: CGPoint = .zero
    private var endpointDragBakedEnd: CGPoint = .zero

    // MARK: - Style persistence

    init() {
        let ud = UserDefaults.standard
        if let c = ud.string(forKey: "canvas.color"), let col = AnnotationColor(rawValue: c) { currentColor = col }
        if let lw = LineWidth(rawValue: CGFloat(ud.float(forKey: "canvas.lineWidth"))) { currentLineWidth = lw }
        currentFontSize = CGFloat(ud.float(forKey: "canvas.fontSize")).isZero ? 18 : CGFloat(ud.float(forKey: "canvas.fontSize"))
        currentFilled = ud.bool(forKey: "canvas.filled")
        let op = ud.double(forKey: "canvas.opacity")
        currentOpacity = op == 0 ? 1.0 : op
        currentTextBackground = ud.bool(forKey: "canvas.textBg")
        if let ls = ud.string(forKey: "canvas.lineStyle"), let style = LineStyle(rawValue: ls) { currentLineStyle = style }
        let hex = ud.string(forKey: "canvas.customColorHex")
        currentCustomColorHex = hex?.isEmpty == false ? hex : nil
    }

    func saveCurrentStyle() {
        let ud = UserDefaults.standard
        ud.set(currentColor.rawValue, forKey: "canvas.color")
        ud.set(Float(currentLineWidth.rawValue), forKey: "canvas.lineWidth")
        ud.set(Float(currentFontSize), forKey: "canvas.fontSize")
        ud.set(currentFilled, forKey: "canvas.filled")
        ud.set(currentOpacity, forKey: "canvas.opacity")
        ud.set(currentTextBackground, forKey: "canvas.textBg")
        ud.set(currentLineStyle.rawValue, forKey: "canvas.lineStyle")
        ud.set(currentCustomColorHex ?? "", forKey: "canvas.customColorHex")
    }

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

    func applyCustomColorToSelection(hex: String?) {
        let ids = selectedAnnotationIDs.isEmpty ? (selectedAnnotationID.map { [$0] } ?? []) : Array(selectedAnnotationIDs)
        for id in ids {
            guard var ann = annotations.first(where: { $0.id == id }) else { continue }
            ann.customColorHex = hex
            updateAnnotation(ann)
        }
    }

    func applyCurrentLineStyleToSelection() {
        let ids = selectedAnnotationIDs.isEmpty ? (selectedAnnotationID.map { [$0] } ?? []) : Array(selectedAnnotationIDs)
        for id in ids {
            guard var ann = annotations.first(where: { $0.id == id }), ann.lineStyle != currentLineStyle else { continue }
            ann.lineStyle = currentLineStyle
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
    let ciPreviewCtx = CIContext(options: [.useSoftwareRenderer: false])
    
    func recomputeAllFilterPreviews() {
        filterPreviews.removeAll()
        for ann in annotations where !ann.hasStrokeRepresentation {
            updateFilterPreview(for: ann)
        }
    }

    func clearRedactDragPreview() { redactDragPreview = nil }

    // MARK: - Annotation Management

    func addAnnotation(_ annotation: AnyAnnotation) {
        if !isUndoing {
            undoManager.registerMainActorUndo(withTarget: self) { target in
                target.isUndoing = true
                target.removeAnnotation(id: annotation.id)
                target.isUndoing = false
            }
        }
        annotations.append(annotation)
        if !annotation.hasStrokeRepresentation {
            updateFilterPreview(for: annotation)
        }
        // Record placement for ripple animation
        let b = annotation.bounds(in: CGRect(origin: .zero, size: canvasSize))
        if b.width > 0 || b.height > 0 {
            lastPlacedCenter = CGPoint(x: b.midX, y: b.midY)
            lastPlacedAt = CFAbsoluteTimeGetCurrent()
        }
        objectWillChange.send()
        updateUndoRedoState()
    }

    func removeAnnotation(id: UUID) {
        if let index = annotations.firstIndex(where: { $0.id == id }) {
            let annotation = annotations[index]
            if !isUndoing {
                undoManager.registerMainActorUndo(withTarget: self) { target in
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
                undoManager.registerMainActorUndo(withTarget: self) { target in
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
                if annotation.type == .arrow {
                    currentArrowDoubleSided = annotation.arrowDoubleSided
                }
                currentOpacity = annotation.opacity
                currentLineStyle = annotation.lineStyle
                currentCustomColorHex = annotation.customColorHex
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
            undoManager.registerMainActorUndo(withTarget: self) { target in
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
        [CGPoint(x: bounds.minX,  y: bounds.minY),   // 0 TL
         CGPoint(x: bounds.maxX,  y: bounds.minY),   // 1 TR
         CGPoint(x: bounds.minX,  y: bounds.maxY),   // 2 BL
         CGPoint(x: bounds.maxX,  y: bounds.maxY),   // 3 BR
         CGPoint(x: bounds.midX,  y: bounds.minY),   // 4 Top-mid
         CGPoint(x: bounds.midX,  y: bounds.maxY),   // 5 Bottom-mid
         CGPoint(x: bounds.minX,  y: bounds.midY),   // 6 Left-mid
         CGPoint(x: bounds.maxX,  y: bounds.midY)]   // 7 Right-mid
    }

    func hitTestHandle(at point: CGPoint, corners: [CGPoint]) -> Int? {
        let r: CGFloat = 8
        // Check corners first (priority)
        for i in 0..<4 where i < corners.count {
            let c = corners[i]
            if abs(point.x - c.x) <= r && abs(point.y - c.y) <= r { return i }
        }
        // Then mid-edge handles
        for i in 4..<corners.count {
            let c = corners[i]
            if abs(point.x - c.x) <= r && abs(point.y - c.y) <= r { return i }
        }
        return nil
    }

    enum AlignEdge { case left, centerX, right, top, centerY, bottom, distributeX, distributeY }

    func alignSelected(_ edge: AlignEdge) {
        let ids = selectedAnnotationIDs.isEmpty
            ? (selectedAnnotationID.map { [$0] } ?? [])
            : Array(selectedAnnotationIDs)
        guard ids.count > 1 else { return }

        let canvas = CGRect(origin: .zero, size: canvasSize)
        let targets = annotations.filter { ids.contains($0.id) }
        guard !targets.isEmpty else { return }
        let bounds = targets.map { $0.bounds(in: canvas) }

        let snapshot = annotations
        undoManager.registerMainActorUndo(withTarget: self) { target in
            target.isUndoing = true
            target.annotations = snapshot
            target.isUndoing = false
            target.updateUndoRedoState()
        }

        switch edge {
        case .left:
            let minX = bounds.map { $0.minX }.min()!
            for (ann, b) in zip(targets, bounds) {
                var a = ann; a.applyTransform(CGAffineTransform(translationX: minX - b.minX, y: 0))
                if let i = annotations.firstIndex(where: { $0.id == a.id }) { annotations[i] = a }
            }
        case .centerX:
            let cx = (bounds.map { $0.minX }.min()! + bounds.map { $0.maxX }.max()!) / 2
            for (ann, b) in zip(targets, bounds) {
                var a = ann; a.applyTransform(CGAffineTransform(translationX: cx - b.midX, y: 0))
                if let i = annotations.firstIndex(where: { $0.id == a.id }) { annotations[i] = a }
            }
        case .right:
            let maxX = bounds.map { $0.maxX }.max()!
            for (ann, b) in zip(targets, bounds) {
                var a = ann; a.applyTransform(CGAffineTransform(translationX: maxX - b.maxX, y: 0))
                if let i = annotations.firstIndex(where: { $0.id == a.id }) { annotations[i] = a }
            }
        case .top:
            let minY = bounds.map { $0.minY }.min()!
            for (ann, b) in zip(targets, bounds) {
                var a = ann; a.applyTransform(CGAffineTransform(translationX: 0, y: minY - b.minY))
                if let i = annotations.firstIndex(where: { $0.id == a.id }) { annotations[i] = a }
            }
        case .centerY:
            let cy = (bounds.map { $0.minY }.min()! + bounds.map { $0.maxY }.max()!) / 2
            for (ann, b) in zip(targets, bounds) {
                var a = ann; a.applyTransform(CGAffineTransform(translationX: 0, y: cy - b.midY))
                if let i = annotations.firstIndex(where: { $0.id == a.id }) { annotations[i] = a }
            }
        case .bottom:
            let maxY = bounds.map { $0.maxY }.max()!
            for (ann, b) in zip(targets, bounds) {
                var a = ann; a.applyTransform(CGAffineTransform(translationX: 0, y: maxY - b.maxY))
                if let i = annotations.firstIndex(where: { $0.id == a.id }) { annotations[i] = a }
            }
        case .distributeX:
            let sorted = zip(targets, bounds).sorted { $0.1.midX < $1.1.midX }
            guard sorted.count >= 2 else { break }
            let first = sorted.first!.1.midX, last = sorted.last!.1.midX
            let step = (last - first) / CGFloat(sorted.count - 1)
            for (idx, (ann, b)) in sorted.enumerated() {
                let targetX = first + step * CGFloat(idx)
                var a = ann; a.applyTransform(CGAffineTransform(translationX: targetX - b.midX, y: 0))
                if let i = annotations.firstIndex(where: { $0.id == a.id }) { annotations[i] = a }
            }
        case .distributeY:
            let sorted = zip(targets, bounds).sorted { $0.1.midY < $1.1.midY }
            guard sorted.count >= 2 else { break }
            let first = sorted.first!.1.midY, last = sorted.last!.1.midY
            let step = (last - first) / CGFloat(sorted.count - 1)
            for (idx, (ann, b)) in sorted.enumerated() {
                let targetY = first + step * CGFloat(idx)
                var a = ann; a.applyTransform(CGAffineTransform(translationX: 0, y: targetY - b.midY))
                if let i = annotations.firstIndex(where: { $0.id == a.id }) { annotations[i] = a }
            }
        }
        updateUndoRedoState()
        objectWillChange.send()
    }

    func clearAllAnnotations() {
        guard !annotations.isEmpty else { return }
        let snapshot = annotations
        undoManager.registerMainActorUndo(withTarget: self) { target in
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
        let ids: Set<UUID> = selectedAnnotationIDs.isEmpty
            ? (selectedAnnotationID.map { [$0] } ?? [])
            : selectedAnnotationIDs
        let selected = annotations.filter { ids.contains($0.id) }
        guard !selected.isEmpty, let data = try? JSONEncoder().encode(selected) else { return }
        NSPasteboard.general.addTypes([Self.annotationPasteboardType], owner: nil)
        NSPasteboard.general.setData(data, forType: Self.annotationPasteboardType)
    }

    /// Returns true if annotation(s) were pasted from clipboard.
    @discardableResult
    func pasteAnnotationFromClipboard() -> Bool {
        guard let data = NSPasteboard.general.data(forType: Self.annotationPasteboardType) else { return false }
        // Try multi-annotation array first, then fall back to single annotation
        let offset = CGAffineTransform(translationX: 10, y: 10)
        if var anns = try? JSONDecoder().decode([AnyAnnotation].self, from: data), !anns.isEmpty {
            var lastID: UUID?
            for i in anns.indices {
                anns[i].id = UUID()
                anns[i].applyTransform(offset)
                addAnnotation(anns[i])
                lastID = anns[i].id
            }
            selectedAnnotationIDs = Set(anns.map { $0.id })
            selectedAnnotationID = lastID
            return true
        }
        // Legacy: single annotation JSON
        guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        json["id"] = UUID().uuidString
        guard let newData = try? JSONSerialization.data(withJSONObject: json),
              var ann = try? JSONDecoder().decode(AnyAnnotation.self, from: newData) else { return false }
        ann.applyTransform(offset)
        addAnnotation(ann)
        selectedAnnotationID = ann.id
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

        // Option+click: eyedropper — sample exact pixel color
        if currentTool != .colorPicker,
           NSEvent.modifierFlags.contains(.option) {
            if let hex = sampleColor(at: localPoint) {
                currentCustomColorHex = hex
                applyCustomColorToSelection(hex: hex)
                SettingsManager.shared.addRecentCustomColor(hex)
            }
            return
        }

        if isCropMode {
            // If a selection exists, check for handle/move interaction
            if let cs = cropStart, let ce = cropEnd {
                let sel = CGRect(
                    x: min(cs.x, ce.x), y: min(cs.y, ce.y),
                    width: abs(ce.x - cs.x), height: abs(ce.y - cs.y)
                )
                if let handle = CropHandle.handle(at: localPoint, in: sel) {
                    cropHandleActive = handle
                    cropHandleStartRect = sel
                    cropHandleDragOrigin = localPoint
                    dragState.start(at: localPoint)
                    return
                }
            }
            // No selection or click outside → start a new crop drag
            cropHandleActive = nil
            dragState.start(at: localPoint)
            cropStart = localPoint
            cropEnd = localPoint
            return
        }

        // Grab-to-move: in any drawing tool, clicking on an existing annotation moves it
        let grabSupportedTools: Set<DrawingTool> = [.arrow, .line, .rectangle, .ellipse,
            .roundedRect, .callout, .highlight, .step, .redact, .spotlight]
        if grabSupportedTools.contains(currentTool) {
            let innerRect = CGRect(origin: .zero, size: canvasSize)
            if let hitAnn = annotations.reversed().first(where: { !$0.isLocked && $0.hitTest(localPoint, in: innerRect) }) {
                dragState.start(at: localPoint)
                // Always make the hit annotation the primary selection for grab-move
                selectedAnnotationID = hitAnn.id
                selectedAnnotationIDs = [hitAnn.id]
                let bounds = hitAnn.bounds(in: innerRect)
                dragStartAnnotation = hitAnn
                dragState.dragOffset = CGSize(width: localPoint.x - bounds.midX,
                                              height: localPoint.y - bounds.midY)
                multiDragStartPositions = [:]
                isGrabMoving = true
                return
            }
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
                // Callout tail handle (index 8)
                if ann.type == .callout, let baseTail = ann.calloutTailPoint {
                    let tailCanvas = baseTail.applying(ann.transform)
                    let r: CGFloat = 10
                    if abs(localPoint.x - tailCanvas.x) <= r && abs(localPoint.y - tailCanvas.y) <= r,
                       let data = try? JSONEncoder().encode(ann),
                       var decoded = try? JSONDecoder().decode(CalloutAnnotation.self, from: data) {
                        // Bake the current AnyAnnotation.transform into absolute coordinates
                        let t = ann.transform
                        decoded.rect = decoded.rect.applying(t)
                        decoded.tailPoint = decoded.tailPoint.applying(t)
                        decoded.transform = .identity
                        calloutTailBakedBase = decoded
                        dragState.start(at: localPoint)
                        resizingHandleIndex = 8
                        dragStartAnnotation = ann
                        return
                    }
                }
            }

            // Arrow / Line endpoint handles (indices 9=start, 10=end) — single selection
            if let id = selectedAnnotationID,
               selectedAnnotationIDs.count <= 1,
               let ann = annotations.first(where: { $0.id == id }),
               (ann.type == .arrow || ann.type == .line),
               let baseStart = ann.lineStartPoint, let baseEnd = ann.lineEndPoint {
                let t = ann.transform
                let startCanvas = baseStart.applying(t)
                let endCanvas   = baseEnd.applying(t)
                let r: CGFloat = 10
                let hitStart = abs(localPoint.x - startCanvas.x) <= r && abs(localPoint.y - startCanvas.y) <= r
                let hitEnd   = abs(localPoint.x - endCanvas.x)   <= r && abs(localPoint.y - endCanvas.y)   <= r
                if hitStart || hitEnd {
                    // Bake current transform into absolute canvas coords
                    endpointDragBakedStart = startCanvas
                    endpointDragBakedEnd   = endCanvas
                    dragState.start(at: localPoint)
                    resizingHandleIndex = hitEnd ? 10 : 9
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
        case .pencil:
            dragState.start(at: localPoint)
            currentPencilPoints = [localPoint]
        case .stamp:
            let stampSize: CGFloat = 48
            let stampRect = CGRect(
                x: localPoint.x - stampSize / 2, y: localPoint.y - stampSize / 2,
                width: stampSize, height: stampSize
            )
            var a = TextAnnotation(color: currentColor, lineWidth: .thin, rect: stampRect, text: currentStamp)
            a.fontSize = 40
            var annotation = AnyAnnotation(a)
            annotation.opacity = currentOpacity
            addAnnotation(annotation)
            selectedAnnotationID = annotation.id
        case .colorPicker:
            if let hex = sampleColor(at: localPoint) {
                currentCustomColorHex = hex
                applyCustomColorToSelection(hex: hex)
                SettingsManager.shared.addRecentCustomColor(hex)
            }
            currentTool = colorPickerPreviousTool
        case .measure:
            measureStart = localPoint
            measureEnd = localPoint
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

        // Live redact drag preview (throttled to every 2nd event for performance)
        if currentTool == .redact, dragState.isDrawing,
           let dragStart = dragState.startPoint {
            redactPreviewThrottle += 1
            if redactPreviewThrottle % 2 == 0 {
                updateRedactDragPreview(start: dragStart, end: localPoint)
            }
        }

        if isCropMode {
            // Handle-based resize/move
            if let handle = cropHandleActive {
                let delta = CGSize(
                    width: localPoint.x - cropHandleDragOrigin.x,
                    height: localPoint.y - cropHandleDragOrigin.y
                )
                let newRect = handle.apply(delta: delta, to: cropHandleStartRect)
                cropHandleStartRect = newRect
                cropHandleDragOrigin = localPoint
                cropStart = CGPoint(x: newRect.minX, y: newRect.minY)
                cropEnd = CGPoint(x: newRect.maxX, y: newRect.maxY)
                objectWillChange.send()
                return
            }
            // Normal drag: create new selection with optional ratio constraint
            var cropPt = localPoint
            if let start = cropStart {
                let dx = cropPt.x - start.x, dy = cropPt.y - start.y
                let ratio = NSEvent.modifierFlags.contains(.shift) ? 1.0 : cropAspectRatio
                if let r = ratio {
                    let absDx = abs(dx), absDy = abs(dy)
                    if absDx / r >= absDy {
                        let constrainedDy = absDx / r * (dy < 0 ? -1 : 1)
                        cropPt = CGPoint(x: cropPt.x, y: start.y + constrainedDy)
                    } else {
                        let constrainedDx = absDy * r * (dx < 0 ? -1 : 1)
                        cropPt = CGPoint(x: start.x + constrainedDx, y: cropPt.y)
                    }
                }
            }
            cropEnd = cropPt
            objectWillChange.send()
            return
        }

        if currentTool == .measure {
            measureEnd = localPoint
            objectWillChange.send()
            return
        }

        // Grab-move in progress (non-select tool dragging an existing annotation)
        if isGrabMoving {
            if let id = selectedAnnotationID, var annotation = annotations.first(where: { $0.id == id }) {
                isDraggingAnnotation = true
                hoveredAnnotationID = nil
                let newCenter = CGPoint(x: localPoint.x - dragState.dragOffset.width,
                                        y: localPoint.y - dragState.dragOffset.height)
                let bounds = annotation.bounds(in: CGRect(origin: .zero, size: canvasSize))
                let proposedBounds = CGRect(x: bounds.minX + (newCenter.x - bounds.midX),
                                            y: bounds.minY + (newCenter.y - bounds.midY),
                                            width: bounds.width, height: bounds.height)
                let (snappedDx, snappedDy, guides) = computeSnap(for: proposedBounds, excluding: id)
                let deltaX = newCenter.x - bounds.midX - snappedDx
                let deltaY = newCenter.y - bounds.midY - snappedDy
                snapGuides = guides
                annotation.applyTransform(CGAffineTransform(translationX: deltaX, y: deltaY))
                if let index = annotations.firstIndex(where: { $0.id == id }) {
                    annotations[index] = annotation
                }
                objectWillChange.send()
            }
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

            // Callout tail drag (handle index 8)
            if resizingHandleIndex == 8,
               var baked = calloutTailBakedBase,
               let id = selectedAnnotationID,
               let origAnn = dragStartAnnotation {
                baked.tailPoint = localPoint
                var newAnn = AnyAnnotation(baked)
                newAnn.opacity = origAnn.opacity
                newAnn.isLocked = origAnn.isLocked
                newAnn.lineStyle = origAnn.lineStyle
                newAnn.customColorHex = origAnn.customColorHex
                if let index = annotations.firstIndex(where: { $0.id == id }) {
                    annotations[index] = newAnn
                }
                objectWillChange.send()
                return
            }

            // Arrow / Line endpoint drag (handle index 9=start, 10=end)
            if let handleIdx = resizingHandleIndex, (handleIdx == 9 || handleIdx == 10),
               let id = selectedAnnotationID,
               let origAnn = dragStartAnnotation,
               let data = try? JSONEncoder().encode(origAnn) {
                // Shift-constrain to 45° increments
                var pt = localPoint
                if NSEvent.modifierFlags.contains(.shift) {
                    let anchor = handleIdx == 9 ? endpointDragBakedEnd : endpointDragBakedStart
                    pt = shiftConstrainedPoint(pt, from: anchor)
                }
                var json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                let t = origAnn.transform
                func encodePoint(_ p: CGPoint) -> [String: Double] { ["x": Double(p.x), "y": Double(p.y)] }
                if handleIdx == 9 {
                    json["startPoint"] = encodePoint(pt)
                    json["endPoint"]   = encodePoint(endpointDragBakedEnd)
                } else {
                    json["startPoint"] = encodePoint(endpointDragBakedStart)
                    json["endPoint"]   = encodePoint(pt)
                }
                // Reset transform to identity (coords now baked in canvas space)
                json["transform"] = ["a": 1.0, "b": 0.0, "c": 0.0, "d": 1.0, "tx": 0.0, "ty": 0.0]
                if let newData = try? JSONSerialization.data(withJSONObject: json),
                   var newAnn = try? JSONDecoder().decode(AnyAnnotation.self, from: newData) {
                    newAnn.opacity = origAnn.opacity
                    newAnn.isLocked = origAnn.isLocked
                    newAnn.lineStyle = origAnn.lineStyle
                    newAnn.customColorHex = origAnn.customColorHex
                    if let index = annotations.firstIndex(where: { $0.id == id }) {
                        annotations[index] = newAnn
                    }
                }
                objectWillChange.send()
                return
            }

            // Resize mode
            if let handleIdx = resizingHandleIndex,
               let id = selectedAnnotationID,
               let startBounds = resizingStartBounds,
               let startTransform = resizingStartTransform,
               var annotation = annotations.first(where: { $0.id == id }) {
                let newBounds: CGRect
                if handleIdx < 4 {
                    // Corner handles: both axes change
                    let fixedCorners: [CGPoint] = [
                        CGPoint(x: startBounds.maxX, y: startBounds.maxY), // 0-TL → BR fixed
                        CGPoint(x: startBounds.minX, y: startBounds.maxY), // 1-TR → BL fixed
                        CGPoint(x: startBounds.maxX, y: startBounds.minY), // 2-BL → TR fixed
                        CGPoint(x: startBounds.minX, y: startBounds.minY), // 3-BR → TL fixed
                    ]
                    let fx = fixedCorners[handleIdx]
                    let nx = min(localPoint.x, fx.x), ny = min(localPoint.y, fx.y)
                    let nw = max(abs(localPoint.x - fx.x), 4), nh = max(abs(localPoint.y - fx.y), 4)
                    newBounds = CGRect(x: nx, y: ny, width: nw, height: nh)
                } else {
                    // Mid-edge handles: one axis changes, other stays fixed
                    switch handleIdx {
                    case 4: // Top-mid: only top edge moves, bottom fixed
                        let newY = min(localPoint.y, startBounds.maxY - 4)
                        newBounds = CGRect(x: startBounds.minX, y: newY, width: startBounds.width,
                                           height: max(startBounds.maxY - newY, 4))
                    case 5: // Bottom-mid: only bottom edge moves, top fixed
                        let newMaxY = max(localPoint.y, startBounds.minY + 4)
                        newBounds = CGRect(x: startBounds.minX, y: startBounds.minY, width: startBounds.width,
                                           height: newMaxY - startBounds.minY)
                    case 6: // Left-mid: only left edge moves, right fixed
                        let newX = min(localPoint.x, startBounds.maxX - 4)
                        newBounds = CGRect(x: newX, y: startBounds.minY, width: max(startBounds.maxX - newX, 4),
                                           height: startBounds.height)
                    default: // 7: Right-mid: only right edge moves, left fixed
                        let newMaxX = max(localPoint.x, startBounds.minX + 4)
                        newBounds = CGRect(x: startBounds.minX, y: startBounds.minY,
                                           width: newMaxX - startBounds.minX, height: startBounds.height)
                    }
                }
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
                hoveredAnnotationID = nil
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

        // Pencil: accumulate freehand points (skip if distance too small to reduce noise)
        if currentTool == .pencil {
            if let last = currentPencilPoints.last {
                let dist = hypot(localPoint.x - last.x, localPoint.y - last.y)
                if dist >= 2 { currentPencilPoints.append(localPoint) }
            } else {
                currentPencilPoints.append(localPoint)
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
        if currentTool == .measure {
            measureEnd = CGPoint(x: point.x - canvasRect.minX, y: point.y - canvasRect.minY)
            objectWillChange.send()
            // Don't call dragState.end() — measure has no dragState
            return
        }

        clearRedactDragPreview()

        // Grab-move finalization
        if isGrabMoving {
            isGrabMoving = false
            isDraggingAnnotation = false
            snapGuides = []
            _ = dragState.end()
            // Restore hoveredAnnotationID so cursor doesn't flicker back to crosshair
            let innerRect = CGRect(origin: .zero, size: canvasSize)
            hoveredAnnotationID = annotations.reversed().first(where: {
                !$0.isLocked && $0.hitTest(point, in: innerRect)
            })?.id
            if let original = dragStartAnnotation,
               let index = annotations.firstIndex(where: { $0.id == original.id }) {
                let orig = original
                undoManager.registerMainActorUndo(withTarget: self) { target in
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
            return
        }

        guard let (start, end) = dragState.end() else { return }

        if isCropMode {
            cropHandleActive = nil
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
            calloutTailBakedBase = nil
            // Multi-move undo: snapshot all moved annotations
            if !multiDragStartPositions.isEmpty {
                let startPositions = multiDragStartPositions
                let currentSnapshot = annotations.filter { startPositions[$0.id] != nil }
                undoManager.registerMainActorUndo(withTarget: self) { target in
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
                undoManager.registerMainActorUndo(withTarget: self) { target in
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
        case .pencil:
            let raw = currentPencilPoints
            currentPencilPoints = []
            if raw.count >= 2 {
                let epsilon: CGFloat = max(currentLineWidth.rawValue * 0.25, 1.0)
                let pts = simplifyPoints(raw, epsilon: epsilon)
                var annotation = AnyAnnotation(PencilAnnotation(
                    color: currentColor,
                    lineWidth: currentLineWidth,
                    points: pts
                ))
                annotation.opacity = currentOpacity
                annotation.lineStyle = currentLineStyle
                annotation.customColorHex = currentCustomColorHex
                addAnnotation(annotation)
                selectedAnnotationID = annotation.id
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
        calloutTailBakedBase = nil
        currentPencilPoints = []
        dragState.cancel()
        if isCropMode { cropStart = nil; cropEnd = nil }
        objectWillChange.send()
    }
    
    // Douglas-Peucker line simplification: reduces point count while preserving shape
    private func simplifyPoints(_ points: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var maxDist: CGFloat = 0
        var maxIdx = 0
        let first = points.first!, last = points.last!
        let dx = last.x - first.x, dy = last.y - first.y
        let len = hypot(dx, dy)
        for i in 1..<(points.count - 1) {
            let p = points[i]
            let dist = len < 1e-6
                ? hypot(p.x - first.x, p.y - first.y)
                : abs(dy * p.x - dx * p.y + last.x * first.y - last.y * first.x) / len
            if dist > maxDist { maxDist = dist; maxIdx = i }
        }
        if maxDist > epsilon {
            let left = simplifyPoints(Array(points[...maxIdx]), epsilon: epsilon)
            let right = simplifyPoints(Array(points[maxIdx...]), epsilon: epsilon)
            return left.dropLast() + right
        }
        return [first, last]
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
            var a = ArrowAnnotation(color: color, lineWidth: lineWidth, startPoint: start, endPoint: end)
            a.doubleSided = currentArrowDoubleSided
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
            let stepNum = (annotations.compactMap { $0.stepNumber }.max() ?? 0) + 1
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
            a.tailPoint = start  // drag start becomes the pointer/tail tip
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
        case .text, .pencil:
            return
        case .spotlight:
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            annotation = AnyAnnotation(SpotlightAnnotation(rect: rect, shape: currentSpotlightShape))
        }

        var mutableAnnotation = annotation
        mutableAnnotation.opacity = currentOpacity
        mutableAnnotation.lineStyle = currentLineStyle
        mutableAnnotation.customColorHex = currentCustomColorHex
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

    func updateTextInputHeight(_ viewHeight: CGFloat) {
        // Convert overlay height back to canvas space (divide by zoom approximation via stored rect width ratio)
        textInputRect.size.height = max(textInputRect.size.height, viewHeight)
    }

    func confirmTextInput() {
        // Trim only leading/trailing whitespace, preserve internal newlines for multiline text
        let trimmed = textInputString.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
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

    // MARK: - Decoration (beautify / export wrapper)

    @Published var decorationEnabled: Bool = false
    @Published var decorationPadding: CGFloat = 40     // px per side in output image
    @Published var decorationCornerRadius: CGFloat = 12
    @Published var decorationShadow: Bool = true
    // 0=white 1=dark 2=gradient 3=transparent 4=wallpaper
    @Published var decorationBackgroundStyle: Int = 0
    @Published var decorationGradientIndex: Int = 0

    // Curated gradient presets: [(colorA, colorB), diagonal top-left → bottom-right]
    static let gradientPresets: [(CGColor, CGColor)] = [
        (CGColor(red: 0.40, green: 0.49, blue: 0.92, alpha: 1), CGColor(red: 0.46, green: 0.29, blue: 0.64, alpha: 1)), // Indigo→Violet
        (CGColor(red: 0.10, green: 0.69, blue: 0.84, alpha: 1), CGColor(red: 0.16, green: 0.42, blue: 0.80, alpha: 1)), // Cyan→Blue
        (CGColor(red: 0.25, green: 0.80, blue: 0.65, alpha: 1), CGColor(red: 0.08, green: 0.55, blue: 0.45, alpha: 1)), // Mint→Teal
        (CGColor(red: 1.00, green: 0.58, blue: 0.30, alpha: 1), CGColor(red: 0.93, green: 0.22, blue: 0.35, alpha: 1)), // Peach→Rose
        (CGColor(red: 0.97, green: 0.78, blue: 0.24, alpha: 1), CGColor(red: 0.97, green: 0.44, blue: 0.14, alpha: 1)), // Yellow→Orange
        (CGColor(red: 0.97, green: 0.48, blue: 0.69, alpha: 1), CGColor(red: 0.75, green: 0.30, blue: 0.80, alpha: 1)), // Pink→Purple
        (CGColor(red: 0.20, green: 0.75, blue: 0.40, alpha: 1), CGColor(red: 0.04, green: 0.50, blue: 0.65, alpha: 1)), // Green→Teal
        (CGColor(red: 0.18, green: 0.18, blue: 0.22, alpha: 1), CGColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1)), // Charcoal dark
    ]

    // MARK: - Undo/Redo

    @Published var canUndo: Bool = false
    @Published var canRedo: Bool = false

    @Published var undoRedoToast: String? = nil
    private var undoRedoToastTask: Task<Void, Never>?

    func undo() {
        guard canUndo else { return }
        undoManager.undo()
        updateUndoRedoState()
        showUndoRedoToast("元に戻した")
    }

    func redo() {
        guard canRedo else { return }
        undoManager.redo()
        updateUndoRedoState()
        showUndoRedoToast("やり直した")
    }

    private func showUndoRedoToast(_ message: String) {
        undoRedoToastTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { undoRedoToast = message }
        undoRedoToastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            withAnimation(.easeIn(duration: 0.2)) { self.undoRedoToast = nil }
        }
    }

    func updateUndoRedoState() {
        canUndo = undoManager.canUndo
        canRedo = undoManager.canRedo
    }

    func resetAndLoad(image: CGImage, annotations: [AnyAnnotation]) {
        backgroundImage = image
        backgroundDirty = false
        // canvasSize は View の onAppear/onChange が管理する — ここで上書きしない
        self.annotations = annotations
        selectedAnnotationID = nil
        undoManager.removeAllActions()
        updateUndoRedoState()
        recomputeAllFilterPreviews()
        loadToken = UUID()
    }
    
}
// MARK: - UndoManager + MainActor

private struct UnsafeSendableBox<T>: @unchecked Sendable { let value: T }

extension UndoManager {
    /// UndoManagerのハンドラは新SDKで@Sendable扱いになりMainActor状態に触れない。
    /// undo/redoはメインスレッドで発火するため、assumeIsolatedで包んで登録する。
    /// (非Sendableなtargetは@unchecked Sendableボックス経由で渡す。
    ///  クロージャがtargetを強参照するが、CanvasViewModelはアプリ存続期間オブジェクトなので許容)
    @MainActor
    func registerMainActorUndo<T: AnyObject>(withTarget target: T,
                                             handler: @escaping @MainActor (T) -> Void) {
        let box = UnsafeSendableBox(value: target)
        registerUndo(withTarget: target) { _ in
            MainActor.assumeIsolated { handler(box.value) }
        }
    }
}
