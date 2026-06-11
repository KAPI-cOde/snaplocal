// CanvasOverlays.swift
// SnapLocal - AnnotationCanvasView overlay methods (extracted from CanvasView.swift — mechanical move only)

import SwiftUI
import AppKit

// MARK: - AnnotationCanvasView Overlays

extension AnnotationCanvasView {

    // Animated crop overlay using TimelineView for marching ants
    @ViewBuilder
    func cropOverlayLayer(size: CGSize) -> some View {
        TimelineView(.animation(minimumInterval: 0.05)) { timeline in
            Canvas { context, _ in
                let phase = timeline.date.timeIntervalSinceReferenceDate * 20
                drawCropOverlay(context: context, size: size, dashPhase: CGFloat(phase))
            }
        }
    }

    func drawCropOverlay(context: GraphicsContext, size: CGSize, dashPhase: CGFloat) {
        let dim = Color.black.opacity(0.45)

        guard let start = viewModel.cropStart, let end = viewModel.cropEnd else {
            // No selection yet — dim the whole canvas with a hint
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(dim))
            let hint = "ドラッグしてクロップ範囲を選択"
            context.draw(Text(hint).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.8)),
                         at: CGPoint(x: size.width / 2, y: size.height / 2))
            return
        }

        let sel = CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        )

        // Four dark panels
        context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: sel.minY)), with: .color(dim))
        context.fill(Path(CGRect(x: 0, y: sel.maxY, width: size.width, height: size.height - sel.maxY)), with: .color(dim))
        context.fill(Path(CGRect(x: 0, y: sel.minY, width: sel.minX, height: sel.height)), with: .color(dim))
        context.fill(Path(CGRect(x: sel.maxX, y: sel.minY, width: size.width - sel.maxX, height: sel.height)), with: .color(dim))

        // Marching ants border (white dashes moving)
        context.stroke(
            Path(sel),
            with: .color(.white.opacity(0.9)),
            style: StrokeStyle(lineWidth: 1.5, dash: [8, 4], dashPhase: -dashPhase)
        )
        // Outer thin border for contrast
        context.stroke(Path(sel.insetBy(dx: -0.5, dy: -0.5)), with: .color(.black.opacity(0.4)), lineWidth: 0.5)

        // Rule-of-thirds grid
        let dash = StrokeStyle(lineWidth: 0.5, dash: [4, 3])
        for i in [1, 2] {
            let x = sel.minX + sel.width * CGFloat(i) / 3
            let y = sel.minY + sel.height * CGFloat(i) / 3
            var lv = Path(); lv.move(to: CGPoint(x: x, y: sel.minY)); lv.addLine(to: CGPoint(x: x, y: sel.maxY))
            var lh = Path(); lh.move(to: CGPoint(x: sel.minX, y: y)); lh.addLine(to: CGPoint(x: sel.maxX, y: y))
            context.stroke(lv, with: .color(.white.opacity(0.4)), style: dash)
            context.stroke(lh, with: .color(.white.opacity(0.4)), style: dash)
        }

        // Corner L-brackets (CleanShot X style)
        let bracketLen: CGFloat = 16, bracketW: CGFloat = 3
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: sel.minX, y: sel.minY),  1, 1),
            (CGPoint(x: sel.maxX, y: sel.minY), -1, 1),
            (CGPoint(x: sel.minX, y: sel.maxY),  1,-1),
            (CGPoint(x: sel.maxX, y: sel.maxY), -1,-1),
        ]
        for (pt, sx, sy) in corners {
            var h = Path()
            h.move(to: CGPoint(x: pt.x, y: pt.y))
            h.addLine(to: CGPoint(x: pt.x + sx * bracketLen, y: pt.y))
            var v = Path()
            v.move(to: CGPoint(x: pt.x, y: pt.y))
            v.addLine(to: CGPoint(x: pt.x, y: pt.y + sy * bracketLen))
            context.stroke(h, with: .color(.white), style: StrokeStyle(lineWidth: bracketW, lineCap: .square))
            context.stroke(v, with: .color(.white), style: StrokeStyle(lineWidth: bracketW, lineCap: .square))
        }

        // Mid-edge handles
        let edgePts: [CGPoint] = [
            CGPoint(x: sel.midX, y: sel.minY), CGPoint(x: sel.midX, y: sel.maxY),
            CGPoint(x: sel.minX, y: sel.midY), CGPoint(x: sel.maxX, y: sel.midY)
        ]
        let hs: CGFloat = 6
        for ep in edgePts {
            context.fill(
                Path(ellipseIn: CGRect(x: ep.x - hs, y: ep.y - hs, width: hs*2, height: hs*2)),
                with: .color(.white)
            )
        }

        // Size label inside selection
        if sel.width > 60 && sel.height > 30 {
            let img = viewModel.backgroundImage
            let imgW = img.map { CGFloat($0.width) } ?? size.width
            let imgH = img.map { CGFloat($0.height) } ?? size.height
            let scaleX = imgW / size.width
            let scaleY = imgH / size.height
            let cropW = Int(sel.width * scaleX)
            let cropH = Int(sel.height * scaleY)
            let label = "\(cropW) × \(cropH) px"
            let labelY = sel.minY + sel.height - 28
            context.draw(
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white),
                at: CGPoint(x: sel.midX, y: labelY)
            )
        }
    }

    /// 選択中アノテーションのリサイズ/端点/テールハンドル。
    /// Canvas(GraphicsContext)ではなくSwiftUIビューで描くことで出現/消滅をアニメーションさせる。
    /// ヒットテストはCanvasViewModel側の座標計算で行うため、ここは表示専用(allowsHitTesting(false))。
    @ViewBuilder
    func selectionHandlesOverlay(size: CGSize) -> some View {
        let canvasRect = CGRect(origin: .zero, size: size)
        if viewModel.currentTool == .select || viewModel.currentTool.supportsGrabMove,
           !viewModel.isCropMode,
           !viewModel.annotationsHidden,
           viewModel.selectedAnnotationIDs.count <= 1,
           let ann = viewModel.annotations.first(where: { $0.id == viewModel.selectedAnnotationID }) {
            ZStack {
                if CanvasViewModel.isResizable(ann.type) {
                    let bounds = ann.bounds(in: canvasRect)
                    let handles = viewModel.handleCorners(for: bounds)
                    ForEach(Array(handles.enumerated()), id: \.offset) { i, pt in
                        // corners (0-3): circles, slightly larger / mid-edges (4-7): rounded squares
                        handleDot(circle: i < 4, diameter: i < 4 ? 11 : 9, tint: .accentColor)
                            .position(pt)
                    }
                    if ann.type == .callout, let baseTail = ann.calloutTailPoint {
                        handleDot(circle: true, diameter: 10, tint: .orange)
                            .position(baseTail.applying(ann.transform))
                    }
                }
                if ann.type == .arrow || ann.type == .line,
                   let baseStart = ann.lineStartPoint, let baseEnd = ann.lineEndPoint {
                    handleDot(circle: true, diameter: 11, tint: .secondary)
                        .position(baseStart.applying(ann.transform))
                    handleDot(circle: true, diameter: 11, tint: .accentColor)
                        .position(baseEnd.applying(ann.transform))
                }
            }
        }
    }

    func handleDot(circle: Bool, diameter: CGFloat, tint: Color) -> some View {
        Group {
            if circle {
                Circle().fill(.white)
                    .overlay(Circle().stroke(tint, lineWidth: 1.5))
            } else {
                RoundedRectangle(cornerRadius: 2).fill(.white)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(tint, lineWidth: 1.5))
            }
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
        .transition(.opacity.combined(with: .scale(scale: 0.5)))
    }

    func annotationLayer(size: CGSize) -> some View {
        Canvas { context, _ in
            let canvasRect = CGRect(origin: .zero, size: size)

            // Crop mode: handled by cropOverlayLayer (animated, separate view)
            if viewModel.isCropMode { return }

            // Normal annotation rendering
            let beingDragged = (viewModel.isDraggingAnnotation || viewModel.resizingHandleIndex != nil)
                ? viewModel.selectedAnnotationID : nil

            guard !viewModel.annotationsHidden else { return }

            // Ordinal step numbers: display 1,2,3 regardless of stored stepNumber
            var ordinalStep = 0
            let stepOrdinals: [UUID: Int] = Dictionary(uniqueKeysWithValues: viewModel.annotations.filter { $0.type == .step }.map { ann in
                ordinalStep += 1; return (ann.id, ordinalStep)
            })

            // Hover glow: faint accent outline behind hovered annotation (select + grab-capable tools)
            if (viewModel.currentTool.supportsGrabMove || viewModel.currentTool == .select),
               let hid = viewModel.hoveredAnnotationID,
               hid != viewModel.selectedAnnotationID,
               let hovered = viewModel.annotations.first(where: { $0.id == hid }) {
                let hBounds = hovered.bounds(in: canvasRect).insetBy(dx: -4, dy: -4)
                context.stroke(Path(hBounds), with: .color(.accentColor.opacity(0.35)),
                               style: StrokeStyle(lineWidth: 1.5))
            }

            for annotation in viewModel.annotations {
                let annotationOpacity = annotation.opacity
                if annotation.type == .highlight {
                    let path = annotation.path(in: canvasRect)
                    context.fill(path, with: .color(annotation.resolvedColor.opacity(0.38 * annotationOpacity)))
                    if annotation.id == viewModel.selectedAnnotationID || viewModel.selectedAnnotationIDs.contains(annotation.id) {
                        context.stroke(path, with: .color(.accentColor),
                                       style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    }
                } else if annotation.type == .step, let n = stepOrdinals[annotation.id] {
                    let bounds = annotation.bounds(in: canvasRect)
                    let circlePath = annotation.path(in: canvasRect)
                    if annotation.id == viewModel.selectedAnnotationID {
                        context.fill(circlePath, with: .color(.white.opacity(0.5)))
                    }
                    context.fill(circlePath, with: .color(annotation.resolvedColor.opacity(annotationOpacity)))
                    let textColor: Color = annotation.color.isLight ? .black : .white
                    let fs = min(bounds.width, bounds.height) * 0.5
                    context.draw(
                        Text("\(n)")
                            .font(.system(size: max(fs, 10), weight: .bold))
                            .foregroundColor(textColor),
                        in: bounds
                    )
                    if annotation.id == viewModel.selectedAnnotationID {
                        context.stroke(circlePath, with: .color(.accentColor),
                                       style: StrokeStyle(lineWidth: 2.5, dash: [5, 3]))
                    }
                } else if annotation.type == .text, let text = annotation.textContent {
                    let bounds = annotation.bounds(in: canvasRect)
                    let fontSize = annotation.textFontSize ?? max(bounds.height * 0.7, 14)
                    if annotation.textHasBackground {
                        let bgColor: Color = annotation.color == .white ? .black : .white
                        let bgBounds = bounds.insetBy(dx: -4, dy: -2)
                        context.fill(
                            RoundedRectangle(cornerRadius: 4).path(in: bgBounds),
                            with: .color(bgColor.opacity(0.82 * annotationOpacity))
                        )
                    }
                    let textView = Text(text)
                        .font(.system(size: fontSize, weight: .semibold))
                        .foregroundColor(annotation.resolvedColor.opacity(annotationOpacity))
                    if annotation.textHasBackground {
                        context.draw(textView, in: bounds)
                    } else {
                        // Add subtle drop shadow for legibility on any background
                        context.drawLayer { ctx in
                            ctx.addFilter(.shadow(color: .black.opacity(0.45), radius: 2, x: 0, y: 1))
                            ctx.draw(textView, in: bounds)
                        }
                    }
                    if annotation.id == viewModel.selectedAnnotationID {
                        context.stroke(Path(bounds), with: .color(.accentColor),
                                       style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    }
                } else if annotation.type == .spotlight {
                    // Spotlight: dim the whole canvas, punch out the ellipse
                    let spotPath = annotation.path(in: canvasRect)
                    context.drawLayer { ctx in
                        ctx.fill(Path(canvasRect), with: .color(.black.opacity(0.6 * annotationOpacity)))
                        ctx.blendMode = .destinationOut
                        ctx.fill(spotPath, with: .color(.black))
                    }
                    // Bright ring around spotlight
                    context.stroke(spotPath, with: .color(.white.opacity(0.6 * annotationOpacity)),
                                   style: StrokeStyle(lineWidth: 2))
                    if annotation.id == viewModel.selectedAnnotationID {
                        context.stroke(spotPath, with: .color(.accentColor),
                                       style: StrokeStyle(lineWidth: 2.5, dash: [5, 3]))
                    }
                } else if !annotation.hasStrokeRepresentation {
                    let bounds = annotation.bounds(in: canvasRect)
                    // Show placeholder while dragging (cached preview belongs to old position)
                    let showPlaceholder = annotation.id == beingDragged
                    if !showPlaceholder, let preview = viewModel.filterPreviews[annotation.id] {
                        context.draw(Image(decorative: preview, scale: 1.0, orientation: .up), in: bounds)
                    } else {
                        context.fill(Path(bounds), with: .color(.gray.opacity(0.4)))
                        context.stroke(Path(bounds), with: .color(.white.opacity(0.7)),
                                       style: StrokeStyle(lineWidth: 1.5, dash: [4, 2]))
                        // Label the type
                        let label = annotation.type == .mosaic ? "⬛" : "⬜"
                        context.draw(Text(label).font(.system(size: 11)), at: CGPoint(x: bounds.midX, y: bounds.midY))
                    }
                    if annotation.id == viewModel.selectedAnnotationID {
                        context.stroke(Path(bounds.insetBy(dx: -3, dy: -3)), with: .color(.accentColor),
                                       style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    }
                } else if annotation.type == .arrow {
                    // Solid polygon arrow — fill only, no outline stroke
                    let path = annotation.path(in: canvasRect)
                    if annotation.id == viewModel.selectedAnnotationID {
                        context.fill(path, with: .color(.white))
                    }
                    context.fill(path, with: .color(annotation.resolvedColor.opacity(annotationOpacity)))
                    if annotation.id == viewModel.selectedAnnotationID {
                        let bounds = annotation.bounds(in: canvasRect).insetBy(dx: -5, dy: -5)
                        context.stroke(Path(bounds.insetBy(dx: -1, dy: -1)),
                                       with: .color(.white.opacity(0.4)), lineWidth: 3)
                        context.stroke(Path(bounds), with: .color(.accentColor.opacity(0.9)), lineWidth: 1.5)
                    }
                } else {
                    let path = annotation.path(in: canvasRect)
                    let lw = annotation.lineWidth.rawValue
                    let strokeStyle = annotation.lineStyle.strokeStyle(lineWidth: lw)
                    if annotation.id == viewModel.selectedAnnotationID {
                        context.stroke(path, with: .color(.white),
                                       style: StrokeStyle(lineWidth: lw + 4, lineCap: .round, lineJoin: .round))
                    }
                    if annotation.isFilled {
                        context.fill(path, with: .color(annotation.resolvedColor.opacity(0.35 * annotationOpacity)))
                        context.stroke(path, with: .color(annotation.resolvedColor.opacity(annotationOpacity)), style: strokeStyle)
                    } else {
                        context.stroke(path, with: .color(annotation.resolvedColor.opacity(annotationOpacity)), style: strokeStyle)
                    }
                    if annotation.id == viewModel.selectedAnnotationID {
                        let bounds = annotation.bounds(in: canvasRect).insetBy(dx: -5, dy: -5)
                        context.stroke(Path(bounds.insetBy(dx: -1, dy: -1)),
                                       with: .color(.white.opacity(0.4)), lineWidth: 3)
                        context.stroke(Path(bounds), with: .color(.accentColor.opacity(0.9)), lineWidth: 1.5)
                    }
                }
            }

            // Smart alignment guides during drag
            for guide in viewModel.snapGuides {
                var line = Path()
                if guide.axis == .vertical {
                    line.move(to: CGPoint(x: guide.position, y: 0))
                    line.addLine(to: CGPoint(x: guide.position, y: canvasRect.height))
                } else {
                    line.move(to: CGPoint(x: 0, y: guide.position))
                    line.addLine(to: CGPoint(x: canvasRect.width, y: guide.position))
                }
                context.stroke(line, with: .color(.cyan.opacity(0.9)),
                               style: StrokeStyle(lineWidth: 1, dash: [4, 2]))
            }

            // Lock badges on locked annotations
            for annotation in viewModel.annotations where annotation.isLocked {
                let bounds = annotation.bounds(in: canvasRect)
                let badge = CGPoint(x: bounds.maxX - 6, y: bounds.minY + 6)
                context.draw(Text("🔒").font(.system(size: 10)), at: badge)
            }

            // Multi-selection outlines
            if viewModel.selectedAnnotationIDs.count > 1 {
                // Individual outlines
                for ann in viewModel.annotations where viewModel.selectedAnnotationIDs.contains(ann.id) {
                    let bounds = ann.bounds(in: canvasRect).insetBy(dx: -4, dy: -4)
                    context.stroke(Path(bounds), with: .color(.accentColor.opacity(0.55)),
                                   style: StrokeStyle(lineWidth: 1.0, dash: [4, 3]))
                }
                // Combined bounding box for all selected annotations
                let selectedAnns = viewModel.annotations.filter { viewModel.selectedAnnotationIDs.contains($0.id) }
                if !selectedAnns.isEmpty {
                    let unionBounds = selectedAnns.map { $0.bounds(in: canvasRect) }.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -8, dy: -8)
                    context.stroke(Path(unionBounds), with: .color(.accentColor.opacity(0.85)),
                                   style: StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                }
            }

            // NOTE: resize/endpoint/tail handles are rendered by selectionHandlesOverlay
            // (SwiftUI views, so appear/disappear can animate — PLAN.md T2.2)

            // Rubber-band selection rectangle
            if let band = viewModel.rubberBandRect {
                context.fill(Path(band), with: .color(.accentColor.opacity(0.1)))
                context.stroke(Path(band), with: .color(.accentColor),
                               style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }

            // Pencil live preview
            if viewModel.currentTool == .pencil && viewModel.currentPencilPoints.count >= 2 {
                let pts = viewModel.currentPencilPoints
                let previewColor = viewModel.currentColor.color.opacity(viewModel.currentOpacity * 0.85)
                let lw = viewModel.currentLineWidth.rawValue
                var pencilPath = Path()
                pencilPath.move(to: pts[0])
                for i in 1..<pts.count {
                    let prev = pts[i-1], curr = pts[i]
                    let mid = CGPoint(x: (prev.x + curr.x) / 2, y: (prev.y + curr.y) / 2)
                    pencilPath.addQuadCurve(to: mid, control: prev)
                }
                pencilPath.addLine(to: pts.last!)
                context.stroke(pencilPath, with: .color(previewColor),
                               style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
            }

            // Drawing preview
            if viewModel.dragState.isDrawing,
               let start = viewModel.dragState.startPoint,
               let end = viewModel.dragState.currentPoint,
               !viewModel.isCropMode,
               !viewModel.isGrabMoving {
                let previewColor = viewModel.currentColor.color.opacity(viewModel.currentOpacity * 0.85)
                let lw = viewModel.currentLineWidth.rawValue
                if viewModel.currentTool == .arrow {
                    // Live preview: solid polygon arrow matching final rendering
                    var preview = ArrowAnnotation(
                        color: viewModel.currentColor, lineWidth: viewModel.currentLineWidth,
                        startPoint: start, endPoint: end)
                    preview.doubleSided = viewModel.currentArrowDoubleSided
                    let p = preview.path(in: canvasRect)
                    context.fill(p, with: .color(previewColor))
                } else {
                    var preview = Path()
                    switch viewModel.currentTool {
                    case .line:
                        preview.move(to: start)
                        preview.addLine(to: end)
                    case .redact:
                        // Live mosaic/blur preview during drag
                        let redactRect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                               width: abs(end.x - start.x), height: abs(end.y - start.y))
                        if let livePreview = viewModel.redactDragPreview {
                            context.draw(Image(decorative: livePreview, scale: 1.0, orientation: .up),
                                         in: redactRect)
                        } else {
                            preview = Path(redactRect)
                        }
                    case .rectangle:
                        preview = Path(CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                             width: abs(end.x - start.x), height: abs(end.y - start.y)))
                    case .roundedRect:
                        let r = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                       width: abs(end.x - start.x), height: abs(end.y - start.y))
                        preview = Path(roundedRect: r, cornerRadius: min(r.width, r.height) * 0.15)
                    case .ellipse:
                        preview = Path(ellipseIn: CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                                         width: abs(end.x - start.x), height: abs(end.y - start.y)))
                    case .step:
                        let stepSize: CGFloat = viewModel.currentLineWidth == .thick ? 48 : viewModel.currentLineWidth == .medium ? 36 : 28
                        let rect = CGRect(x: start.x - stepSize/2, y: start.y - stepSize/2, width: stepSize, height: stepSize)
                        let nextN = viewModel.annotations.filter { $0.type == .step }.count + 1
                        context.fill(Path(ellipseIn: rect), with: .color(previewColor.opacity(0.75)))
                        let textColor: Color = viewModel.currentColor.isLight ? .black : .white
                        context.draw(
                            Text("\(nextN)").font(.system(size: stepSize * 0.48, weight: .bold)).foregroundStyle(textColor),
                            in: rect
                        )
                        // skip to default fallthrough — don't set preview (already drawn)
                        break
                    case .callout:
                        let r = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                       width: abs(end.x - start.x), height: abs(end.y - start.y))
                        let cr = min(r.width, r.height) * 0.2
                        var calloutPath = Path(roundedRect: r, cornerRadius: cr)
                        // Tail from drag start (anchor point) toward the box
                        let closest = CGPoint(x: max(r.minX, min(r.maxX, start.x)), y: max(r.minY, min(r.maxY, start.y)))
                        let cdx = start.x - closest.x, cdy = start.y - closest.y
                        let perpLen: CGFloat = 8
                        let tAngle = atan2(cdy, cdx) + .pi / 2
                        var tail = Path()
                        tail.move(to: CGPoint(x: closest.x + cos(tAngle) * perpLen, y: closest.y + sin(tAngle) * perpLen))
                        tail.addLine(to: start)
                        tail.addLine(to: CGPoint(x: closest.x - cos(tAngle) * perpLen, y: closest.y - sin(tAngle) * perpLen))
                        tail.closeSubpath()
                        calloutPath.addPath(tail)
                        preview = calloutPath
                    case .highlight:
                        preview = Path(CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                              width: abs(end.x - start.x), height: abs(end.y - start.y)))
                    case .spotlight:
                        let r = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                       width: abs(end.x - start.x), height: abs(end.y - start.y))
                        let spotPreviewPath = viewModel.currentSpotlightShape == .ellipse ? Path(ellipseIn: r) : Path(r)
                        context.drawLayer { ctx in
                            ctx.fill(Path(canvasRect), with: .color(.black.opacity(0.5)))
                            ctx.blendMode = .destinationOut
                            ctx.fill(spotPreviewPath, with: .color(.black))
                        }
                        context.stroke(spotPreviewPath, with: .color(.white.opacity(0.6)),
                                       style: StrokeStyle(lineWidth: 1.5, dash: [4, 2]))
                    default: break
                    }
                    if !preview.isEmpty {
                        let isFillTool = (viewModel.currentTool == .rectangle || viewModel.currentTool == .ellipse || viewModel.currentTool == .roundedRect) && viewModel.currentFilled
                        let isHighlight = viewModel.currentTool == .highlight
                        if isFillTool || viewModel.currentTool == .step || isHighlight {
                            context.fill(preview, with: .color(previewColor.opacity(isHighlight ? 0.38 : viewModel.currentTool == .step ? 0.7 : 0.35)))
                        }
                        if viewModel.currentTool != .step && !isHighlight {
                            // Solid preview (WYSIWYG) — same look as final annotation
                            context.stroke(preview, with: .color(previewColor.opacity(0.85)),
                                           style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
                        }

                        // Size label for rectangular tools
                        let showsSize = [DrawingTool.rectangle, .ellipse, .roundedRect, .callout, .redact, .highlight].contains(viewModel.currentTool)
                        if showsSize {
                            let rx = min(start.x, end.x), ry = min(start.y, end.y)
                            let rw = abs(end.x - start.x), rh = abs(end.y - start.y)
                            if rw > 20 && rh > 10 {
                                let img = viewModel.backgroundImage
                                let scaleX = img.map { CGFloat($0.width) / size.width } ?? 1.0
                                let scaleY = img.map { CGFloat($0.height) / size.height } ?? 1.0
                                let pxW = Int(rw * scaleX), pxH = Int(rh * scaleY)
                                let label = "\(pxW) × \(pxH)"
                                let labelPos = CGPoint(x: rx + rw / 2, y: ry + rh + 14)
                                let resolvedLabel = context.resolve(
                                    Text(label)
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.white)
                                )
                                let labelSize = resolvedLabel.measure(in: CGSize(width: 200, height: 40))
                                let bgRect = CGRect(x: labelPos.x - labelSize.width / 2 - 4,
                                                   y: labelPos.y - labelSize.height / 2 - 2,
                                                   width: labelSize.width + 8, height: labelSize.height + 4)
                                context.fill(Path(roundedRect: bgRect, cornerRadius: 3),
                                             with: .color(.black.opacity(0.6)))
                                context.draw(resolvedLabel, at: labelPos)
                            }
                        }
                    }
                }
            }

            // Measure tool overlay
            if viewModel.currentTool == .measure,
               let ms = viewModel.measureStart, let me = viewModel.measureEnd {
                // Draw dashed measuring line
                var linePath = Path()
                linePath.move(to: ms)
                linePath.addLine(to: me)
                context.stroke(linePath, with: .color(.yellow),
                               style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [6, 4]))

                // Endpoint dots
                for pt in [ms, me] {
                    context.fill(Path(ellipseIn: CGRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8)),
                                 with: .color(.yellow))
                    context.stroke(Path(ellipseIn: CGRect(x: pt.x - 4, y: pt.y - 4, width: 8, height: 8)),
                                   with: .color(.black.opacity(0.5)), lineWidth: 1)
                }

                // Pixel distance label
                if let img = viewModel.backgroundImage, viewModel.canvasSize.width > 0, viewModel.canvasSize.height > 0 {
                    let scaleX = CGFloat(img.width) / viewModel.canvasSize.width
                    let scaleY = CGFloat(img.height) / viewModel.canvasSize.height
                    let dxPx = abs(me.x - ms.x) * scaleX
                    let dyPx = abs(me.y - ms.y) * scaleY
                    let distPx = hypot(dxPx, dyPx)
                    let angleDeg = abs(atan2(me.y - ms.y, me.x - ms.x) * 180 / .pi)
                    let angleStr = String(format: "%.1f°", min(angleDeg, 180 - angleDeg))
                    let label = String(format: "%.0f × %.0f px  %.0f px  %@", dxPx, dyPx, distPx, angleStr)
                    let mid = CGPoint(x: (ms.x + me.x) / 2, y: (ms.y + me.y) / 2 - 16)
                    let text = Text(label).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.primary).bold()
                    var resolvedText = context.resolve(text)
                    let textSize = resolvedText.measure(in: CGSize(width: 400, height: 40))
                    let bg = CGRect(x: mid.x - textSize.width / 2 - 5, y: mid.y - textSize.height / 2 - 3,
                                   width: textSize.width + 10, height: textSize.height + 6)
                    context.fill(Path(roundedRect: bg, cornerRadius: 4), with: .color(.black.opacity(0.7)))
                    context.draw(text, at: mid, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    func textInputOverlay(viewport: CGSize) -> some View {
        if viewModel.showTextInput {
            // キャンバス座標 → ビューポート座標(キャンバスは中央配置・中心基準で写像)
            let ccx = viewModel.canvasSize.width / 2
            let ccy = viewModel.canvasSize.height / 2
            let r = viewModel.textInputRect
            let viewX = viewport.width / 2 + (r.midX - ccx) * zoom + panOffset.width
            let viewY = viewport.height / 2 + (r.midY - ccy) * zoom + panOffset.height
            let textColor = viewModel.currentColor.color
            let nsColor = NSColor(textColor)
            let inputW = max(r.width * zoom, 160)

            VStack(spacing: 4) {
                MultilineTextInput(
                    text: $viewModel.textInputString,
                    fontSize: viewModel.currentFontSize * zoom,
                    color: nsColor,
                    minWidth: inputW,
                    onCommit: { viewModel.confirmTextInput() },
                    onCancel: { viewModel.cancelTextInput() },
                    onHeightChange: { h in
                        withAnimation(.easeOut(duration: 0.1)) { textInputHeight = max(36, h) }
                        let canvasH = h / zoom
                        viewModel.updateTextInputHeight(canvasH)
                    }
                )
                .frame(width: inputW, height: textInputHeight)
                .background {
                    RoundedRectangle(cornerRadius: 5).fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 5).stroke(textColor.opacity(0.5), lineWidth: 1.5)
                }
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                .onAppear {
                    textInputHeight = viewModel.currentFontSize * zoom + 16
                }

                // Hint bar
                HStack(spacing: DS.Space.xs) {
                    Text("⏎ 確定").font(.system(size: DS.FontSize.caption2)).foregroundStyle(.secondary)
                    Text("⇧⏎ 改行").font(.system(size: DS.FontSize.caption2)).foregroundStyle(.secondary)
                    Text("Esc キャンセル").font(.system(size: DS.FontSize.caption2)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, DS.Space.xs)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.small))
            }
            .position(x: viewX, y: viewY)
            .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .center)))
            .onChange(of: viewModel.showTextInput) { _, show in
                if !show { textInputHeight = 36 }
            }
        }
    }
}
