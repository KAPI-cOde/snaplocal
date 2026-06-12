// CanvasInteraction.swift
// SnapLocal - Drag / Interaction handlers for CanvasViewModel
//
// Copyright © 2024 SnapLocal. All rights reserved.

import SwiftUI
import CoreGraphics
import AppKit

// MARK: - Drawing Actions

@MainActor
extension CanvasViewModel {

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

        // 選択中注釈のハンドルは描画ツールでも操作可能(T8.9)。
        // 描画直後の自動選択ではハンドルを出さないため乗っ取りもしない(明示選択のみ)
        if currentTool.supportsGrabMove, !selectionIsFromCreation, beginHandleDragIfHit(at: localPoint) { return }

        // Grab-to-move: in any drawing tool, clicking on an existing annotation moves it
        if currentTool.supportsGrabMove {
            let innerRect = CGRect(origin: .zero, size: canvasSize)
            if let hitAnn = annotations.reversed().first(where: { !$0.isLocked && $0.hitTest(localPoint, in: innerRect) }) {
                dragState.start(at: localPoint)
                // Always make the hit annotation the primary selection for grab-move
                selectedAnnotationID = hitAnn.id
                selectedAnnotationIDs = [hitAnn.id]
                selectionIsFromCreation = false
                let bounds = hitAnn.bounds(in: innerRect)
                dragStartAnnotation = hitAnn
                dragState.dragOffset = CGSize(width: localPoint.x - bounds.midX,
                                              height: localPoint.y - bounds.midY)
                multiDragStartPositions = [:]
                isGrabMoving = true
                return
            }
            // 空き地から新規描画を始めたら選択解除(残ったハンドルの誤操作防止)
            if selectedAnnotationID != nil || !selectedAnnotationIDs.isEmpty {
                selectedAnnotationID = nil
                selectedAnnotationIDs = []
            }
        }

        switch currentTool {
        case .select:
            if beginHandleDragIfHit(at: localPoint) { return }

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

    private func beginHandleDragIfHit(at localPoint: CGPoint) -> Bool {
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
                return true
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
                    return true
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
            let r: CGFloat = 16   // T9.17: 実機で「白丸を掴めない」FB — 端点判定を±10→16ptへ拡大(線本体22ptより先勝ちなので競合しない)
            let hitStart = abs(localPoint.x - startCanvas.x) <= r && abs(localPoint.y - startCanvas.y) <= r
            let hitEnd   = abs(localPoint.x - endCanvas.x)   <= r && abs(localPoint.y - endCanvas.y)   <= r
            if hitStart || hitEnd {
                // Bake current transform into absolute canvas coords
                endpointDragBakedStart = startCanvas
                endpointDragBakedEnd   = endCanvas
                dragState.start(at: localPoint)
                resizingHandleIndex = hitEnd ? 10 : 9
                dragStartAnnotation = ann
                return true
            }
        }

        return false
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
        if currentTool == .redact, dragState.isDrawing, !isGrabMoving,
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

        if currentTool == .select {
            // Rubber-band update
            if isRubberBanding, let start = dragState.startPoint {
                let minX = min(start.x, localPoint.x), maxX = max(start.x, localPoint.x)
                let minY = min(start.y, localPoint.y), maxY = max(start.y, localPoint.y)
                rubberBandRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
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
            if autoConfirmCropOnDragEnd { confirmCrop() }
            return
        }

        // ハンドルドラッグの確定はツール非依存(T8.9)。select の場合も同一動作
        if resizingHandleIndex != nil {
            isDraggingAnnotation = false
            snapGuides = []
            resizingHandleIndex = nil
            resizingStartBounds = nil
            resizingStartTransform = nil
            calloutTailBakedBase = nil
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
            var a = RedactAnnotation(type: .mosaic, color: color, lineWidth: lineWidth, rect: rect)
            a.intensity = currentMosaicScale
            annotation = AnyAnnotation(a)
        case .blur:
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: max(abs(end.x - start.x), 20),
                height: max(abs(end.y - start.y), 20)
            )
            var a = RedactAnnotation(type: .blur, color: color, lineWidth: lineWidth, rect: rect)
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

}
