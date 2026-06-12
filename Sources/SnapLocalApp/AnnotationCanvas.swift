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
    var redactPreviewThrottle = 0
    @Published var backgroundImage: CGImage?
    @Published var canvasSize: CGSize = .zero
    /// annotations が現在どの座標空間(canvasSizeの値)で表現されているか(T9.5)。
    /// adoptCanvasSpace() がこの値と新fitの比で注釈を換算し、常に canvasSize と一致させる。
    /// nil = 基準不明(旧データ等)。その場合は換算せず次の adopt で現サイズを採用する
    var annotationsBasis: CGSize? = nil
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
    var editingAnnotationID: UUID? = nil
    @Published var selectedAnnotationID: UUID?
    @Published var hoveredAnnotationID: UUID?
    @Published var isDraggingAnnotation = false
    // Multi-selection
    @Published var selectedAnnotationIDs: Set<UUID> = []
    @Published var rubberBandRect: CGRect? = nil
    var isRubberBanding = false
    var multiDragStartPositions: [UUID: CGAffineTransform] = [:]
    // Resize handles
    var resizingHandleIndex: Int? = nil          // 0=TL 1=TR 2=BL 3=BR
    var resizingStartBounds: CGRect? = nil
    var resizingStartTransform: CGAffineTransform? = nil
    // Crop mode
    @Published var isCropMode = false
    var autoConfirmCropOnDragEnd = false  // T8.7
    var selectionIsFromCreation = false  // T8.9: 描画直後の自動選択(ハンドル非表示・乗っ取りなし)を区別
    @Published var cropStart: CGPoint?
    @Published var cropEnd: CGPoint?
    @Published var cropAspectRatio: CGFloat? = nil  // nil = free, else width/height
    @Published var cropAnimToken: UUID = UUID()  // changes when crop is confirmed (triggers fade)
    // Crop handle editing
    var cropHandleActive: CropHandle? = nil
    var cropHandleStartRect: CGRect = .zero
    var cropHandleDragOrigin: CGPoint = .zero

    // Measure tool (transient, not saved)
    @Published var measureStart: CGPoint?
    @Published var measureEnd: CGPoint?

    let undoManager = UndoManager()
    var isUndoing = false
    var dragStartAnnotation: AnyAnnotation? = nil
    var calloutTailBakedBase: CalloutAnnotation? = nil
    // index 9 = start endpoint, 10 = end endpoint for line/arrow
    var endpointDragBakedStart: CGPoint = .zero
    var endpointDragBakedEnd: CGPoint = .zero

    // MARK: - Selection helpers

    /// 単一選択(selectedAnnotationID)と複数選択(selectedAnnotationIDs)を統合して返す。
    /// 7箇所の重複 `selectedAnnotationIDs.isEmpty ? (selectedAnnotationID.map { [$0] } ?? []) : Array(selectedAnnotationIDs)` を統合。
    var effectiveSelectedIDs: [UUID] {
        selectedAnnotationIDs.isEmpty ? (selectedAnnotationID.map { [$0] } ?? []) : Array(selectedAnnotationIDs)
    }

    // MARK: - Coordinate conversion (view → image)

    /// view座標のrectを画像ピクセル座標(左上原点)へ変換し、画像範囲内に切り詰める。
    /// `CGImage.cropping(to:)` 用 — クロップは Y=0 が上なのでY反転は不要(CLAUDE.md)。
    /// 範囲外・空・canvasSize未確定のときは nil。
    func canvasRectToPixelRect(_ rect: CGRect, in image: CGImage) -> CGRect? {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let scaleX = CGFloat(image.width) / canvasSize.width
        let scaleY = CGFloat(image.height) / canvasSize.height
        let pixelRect = CGRect(
            x: rect.minX * scaleX, y: rect.minY * scaleY,
            width: rect.width * scaleX, height: rect.height * scaleY
        ).intersection(CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        guard !pixelRect.isNull, pixelRect.width > 0, pixelRect.height > 0 else { return nil }
        return pixelRect
    }

    /// view座標のrectをCoreImage座標(左下原点)へ変換し、画像範囲内に切り詰める。
    /// CI座標は Y=0 が下なので `imgH - rect.maxY * scaleY` のY反転を行う(CLAUDE.md)。
    /// CIFilterが空rectで失敗しないよう最小2pxを保証。範囲外・空のときは nil。
    func canvasRectToCIRect(_ rect: CGRect, in image: CGImage) -> CGRect? {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let imgW = CGFloat(image.width), imgH = CGFloat(image.height)
        let scaleX = imgW / canvasSize.width, scaleY = imgH / canvasSize.height
        let ciRect = CGRect(
            x: rect.minX * scaleX,
            y: imgH - rect.maxY * scaleY,
            width: max(rect.width * scaleX, 2),
            height: max(rect.height * scaleY, 2)
        ).intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))
        guard !ciRect.isNull, ciRect.width > 0, ciRect.height > 0 else { return nil }
        return ciRect
    }

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
        let ids = effectiveSelectedIDs
        for id in ids {
            guard var ann = annotations.first(where: { $0.id == id }),
                  ann.hasStrokeRepresentation, ann.color != currentColor else { continue }
            ann.color = currentColor
            updateAnnotation(ann)
        }
    }

    func applyCurrentLineWidthToSelection() {
        let ids = effectiveSelectedIDs
        for id in ids {
            guard var ann = annotations.first(where: { $0.id == id }),
                  ann.hasStrokeRepresentation, ann.lineWidth != currentLineWidth else { continue }
            ann.lineWidth = currentLineWidth
            updateAnnotation(ann)
        }
    }

    func applyCustomColorToSelection(hex: String?) {
        let ids = effectiveSelectedIDs
        for id in ids {
            guard var ann = annotations.first(where: { $0.id == id }) else { continue }
            ann.customColorHex = hex
            updateAnnotation(ann)
        }
    }

    func applyCurrentLineStyleToSelection() {
        let ids = effectiveSelectedIDs
        for id in ids {
            guard var ann = annotations.first(where: { $0.id == id }), ann.lineStyle != currentLineStyle else { continue }
            ann.lineStyle = currentLineStyle
            updateAnnotation(ann)
        }
    }

    func applyCurrentOpacityToSelection() {
        let ids = effectiveSelectedIDs
        for id in ids {
            guard var ann = annotations.first(where: { $0.id == id }), ann.opacity != currentOpacity else { continue }
            ann.opacity = currentOpacity
            updateAnnotation(ann)
            if !ann.hasStrokeRepresentation { updateFilterPreview(for: ann) }
        }
    }

    func applyCurrentFilledToSelection() {
        let ids = effectiveSelectedIDs
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
        // 安全網(T9.5): 同サイズ連続キャプチャ+キー遷移なし等で adoptCanvasSpace が
        // 一度も走らないまま描き始めた場合。新注釈は現 canvasSize 空間で作られている
        if annotationsBasis == nil, canvasSize.width > 1, canvasSize.height > 1 {
            annotationsBasis = canvasSize
        }
        if !isUndoing {
            undoManager.registerMainActorUndo(withTarget: self) { target in
                target.isUndoing = true
                target.removeAnnotation(id: annotation.id)
                target.isUndoing = false
            }
        }
        annotations.append(annotation)
        selectedAnnotationID = annotation.id
        selectedAnnotationIDs = [annotation.id]
        selectionIsFromCreation = true
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
        let ids = effectiveSelectedIDs
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
                selectionIsFromCreation = false
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

    func resetAndLoad(image: CGImage, annotations: [AnyAnnotation], basis: CGSize? = nil) {
        backgroundImage = image
        backgroundDirty = false
        // canvasSize は View の onAppear/onChange が管理する — ここで上書きしない
        self.annotations = annotations
        // 保存時の基準サイズ(nil = 旧データ)。次の adoptCanvasSpace() が現fitへ換算する
        annotationsBasis = basis
        // 画像サイズが同じ項目への切替では fit が変わらず onChange(of: fit) が発火しない。
        // canvasSize が確定済みならこの場で現空間へ換算する(値は変えないので所有権規約に抵触しない)
        if canvasSize.width > 1, canvasSize.height > 1 {
            adoptCanvasSpace(canvasSize)
        }
        selectedAnnotationID = nil
        undoManager.removeAllActions()
        updateUndoRedoState()
        recomputeAllFilterPreviews()
        loadToken = UUID()
    }

    /// fit(表示画像サイズ)の確定・変化時に View から呼ぶ漏斗(T9.5)。
    /// annotations は常に annotationsBasis 空間の座標なので、基準が変わるときは
    /// 注釈ごと新空間へ比例換算してから canvasSize を更新する。
    /// 基準不明(nil・旧データ)のときは換算せず現サイズを基準として採用する。
    func adoptCanvasSpace(_ newSize: CGSize) {
        if canvasSize == newSize, annotationsBasis == newSize { return }
        canvasSize = newSize
        guard newSize.width > 1, newSize.height > 1 else { return }
        if let basis = annotationsBasis, basis.width > 1, basis.height > 1 {
            let s = newSize.width / basis.width
            if abs(s - 1) > 0.0005 {
                rescaleAnnotations(by: s)
            }
        }
        annotationsBasis = newSize
    }

    /// 全注釈に一様スケール(+任意の平行移動)を適用し、テキストのフォントサイズも追従させる。
    /// 座標空間の付け替え(ビューサイズ追従・画像オペの空間変換)用であり、undo には載せない
    func rescaleAnnotations(by s: CGFloat, then translation: CGSize = .zero) {
        guard !annotations.isEmpty else { return }
        let t = CGAffineTransform(scaleX: s, y: s)
            .concatenating(CGAffineTransform(translationX: translation.width, y: translation.height))
        for i in annotations.indices {
            annotations[i].transform = annotations[i].transform.concatenating(t)
            if annotations[i].type == .text, let fs = annotations[i].textFontSize {
                annotations[i].textFontSize = fs * s
            }
        }
        objectWillChange.send()
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
