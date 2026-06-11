// CanvasView.swift
// SnapLocal - AnnotationCanvasView and canvas-only helpers
// (extracted from App.swift — mechanical move only)

import SwiftUI
import AppKit
import CoreGraphics

// MARK: - Canvas View

struct AnnotationCanvasView: View {
    @ObservedObject var viewModel: CanvasViewModel
    var onCapture: (() -> Void)? = nil
    var onOpenPermissions: (() -> Void)? = nil
    var onFocusSearch: (() -> Void)? = nil
    var onNavigateHistory: ((Int) -> Void)? = nil
    var onCopyOriginal: (() -> Void)? = nil
    var onCopyRegion: (() -> Void)? = nil
    var onOcrRegion: (() -> Void)? = nil

    @FocusState private var textFieldFocused: Bool
    @FocusState private var canvasFocused: Bool
    @State var textInputHeight: CGFloat = 36
    @State private var isHovering = false
    @State var zoom: CGFloat = 1.0
    @State private var baseZoom: CGFloat = 1.0
    @State var panOffset: CGSize = .zero
    @State private var basePan: CGSize = .zero
    @State private var isPanning = false
    @State private var isPanDragging = false
    @State private var hoverLocation: CGPoint? = nil
    @State private var hoverColorHex: String? = nil
    @State private var hoverCanvasPoint: CGPoint? = nil
    @State private var imageOpacity: Double = 1.0
    /// ユーザーが手動でズームしたか。false の間は canvasSize の変化(ウィンドウ
    /// フレーム復元・リサイズ)に追従して自動フィットし直す
    @State private var userZoomed = false

    @State private var hoverHandleIndex: Int? = nil

    // MARK: - Zoom semantics
    // zoom は「scaledToFit 済みベースサイズへの倍率」。したがってフィット表示 = zoom 1.0。
    // fitScale = zoom 1.0 のときの画像1pxあたりの表示pt
    private var fitScale: CGFloat {
        guard let img = viewModel.backgroundImage,
              viewModel.canvasSize.width > 0, viewModel.canvasSize.height > 0 else { return 1 }
        return min(viewModel.canvasSize.width / CGFloat(img.width),
                   viewModel.canvasSize.height / CGFloat(img.height))
    }
    /// 実寸(画像1px = 画面1デバイスpx = 撮影時と同じ大きさ)になる zoom 値
    private var naturalZoom: CGFloat {
        (1.0 / (NSScreen.main?.backingScaleFactor ?? 2.0)) / fitScale
    }
    /// 読み込み直後の既定: 実寸。ビューポートに収まらない場合のみフィットまで縮小
    /// (常に zoom ≤ 1.0 なので画像がUIから溢れない)
    private var autoFitZoom: CGFloat { max(0.25, min(1.0, naturalZoom)) }
    /// バッジ・状態表示用の実ピクセル比(1.0 = 実寸)
    private var effectiveZoom: CGFloat {
        guard viewModel.backgroundImage != nil else { return zoom }
        return zoom / naturalZoom
    }

    private func updateCursor() {
        guard isHovering else { return }
        if isPanning {
            (isPanDragging ? NSCursor.closedHand : NSCursor.openHand).set()
            return
        }
        // closedHand while actively drag-moving an annotation (any tool)
        if viewModel.isGrabMoving || viewModel.isDraggingAnnotation {
            NSCursor.closedHand.set()
            return
        }
        switch viewModel.currentTool {
        case .select:
            if let hi = hoverHandleIndex {
                switch hi {
                case 0, 3: cursorNWSE.set()               // TL, BR corners → ↖↘
                case 1, 2: cursorNESW.set()               // TR, BL corners → ↗↙
                case 4, 5: NSCursor.resizeUpDown.set()    // Top/Bottom mid
                case 6, 7: NSCursor.resizeLeftRight.set() // Left/Right mid
                default:   NSCursor.crosshair.set()
                }
            } else if viewModel.hoveredAnnotationID != nil {
                NSCursor.openHand.set()
            } else {
                NSCursor.arrow.set()
            }
        case .text:
            NSCursor.iBeam.set()
        case .colorPicker:
            NSCursor.crosshair.set()
        default:
            // Show grab cursor when hovering over an annotation with a grab-capable drawing tool
            if viewModel.hoveredAnnotationID != nil {
                NSCursor.openHand.set()
            } else {
                NSCursor.crosshair.set()
            }
        }
    }

    /// 表示画像(scaledToFit)の実サイズ。canvasSize はこの値に一致させ、
    /// view座標 0..canvasSize が常に画像全域へ写像されるようにする(T7.3 WYSIWYG)
    private func fittedCanvasSize(in viewport: CGSize) -> CGSize {
        guard let img = viewModel.backgroundImage,
              viewport.width > 0, viewport.height > 0 else { return viewport }
        let s = min(viewport.width / CGFloat(img.width),
                    viewport.height / CGFloat(img.height))
        return CGSize(width: CGFloat(img.width) * s, height: CGFloat(img.height) * s)
    }

    private func toCanvas(_ point: CGPoint, size: CGSize) -> CGPoint {
        // パンを外し、ビューポート中心でズームを外し、中央配置されたキャンバス
        // (= 表示画像、サイズ canvasSize)のローカル座標へ平行移動する
        // (順写像: view = viewCenter + (canvas - canvasCenter) * zoom + panOffset)
        let vcx = size.width / 2, vcy = size.height / 2
        let ccx = viewModel.canvasSize.width / 2, ccy = viewModel.canvasSize.height / 2
        return CGPoint(x: (point.x - panOffset.width - vcx) / zoom + ccx,
                       y: (point.y - panOffset.height - vcy) / zoom + ccy)
    }

    private func eyedropperSwatchView(hex: String, viewSize: CGSize, at loc: CGPoint) -> some View {
        let swatchW: CGFloat = 100, swatchH: CGFloat = 28
        let offsetX: CGFloat = 20, offsetY: CGFloat = 20
        let x = min(loc.x + offsetX, viewSize.width - swatchW - 4)
        let y = min(loc.y + offsetY, viewSize.height - swatchH - 4)
        let nsColor = ColorWellView.hexToNSColor(hex)
        let color = nsColor.map { Color(nsColor: $0) } ?? Color.clear
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: DS.Radius.small)
                    .fill(color)
                    .frame(width: 16, height: 16)
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.small).stroke(Color.white.opacity(0.6), lineWidth: 1))
                Text("#" + hex.prefix(6).lowercased())
                    .font(.system(size: DS.FontSize.caption, design: .monospaced))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, DS.Space.xs)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.medium))
            .shadow(DS.Shadow.overlay)
            .offset(x: x, y: y)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    var body: some View {
        GeometryReader { proxy in
            let fit = fittedCanvasSize(in: proxy.size)
            ZStack {
                if let image = viewModel.backgroundImage {
                    // 画像とアノテーション層を表示画像サイズ(アスペクト一致)の
                    // 内側スタックに束ねて中央配置する。canvasSize はこの fit に
                    // 一致するため、view座標が常に画像全域へ写像される(T7.3)
                    ZStack {
                    Image(decorative: image, scale: 1.0, orientation: .up)
                        .resizable()
                        .interpolation(effectiveZoom >= 3.0 ? .none : .high)
                        .scaledToFit()
                        .brightness(viewModel.adjustBrightness)
                        .contrast(viewModel.adjustContrast)
                        .saturation(viewModel.adjustSaturation)
                        .opacity(imageOpacity)
                        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
                    annotationLayer(size: fit)
                    selectionHandlesOverlay(size: fit)
                        .allowsHitTesting(false)
                        .animation(viewModel.isDraggingAnnotation || viewModel.resizingHandleIndex != nil
                                   ? nil : DS.Anim.fast,
                                   value: viewModel.selectedAnnotationID)
                        .animation(DS.Anim.fast, value: viewModel.currentTool)
                    // Animated crop overlay (TimelineView for marching ants)
                    if viewModel.isCropMode {
                        cropOverlayLayer(size: fit)
                            .allowsHitTesting(false)
                    }
                    // Pixel grid overlay at zoom ≥ 4×
                    if effectiveZoom >= 4.0, let img = viewModel.backgroundImage {
                        let cellW = fit.width / CGFloat(img.width)
                        let cellH = fit.height / CGFloat(img.height)
                        Canvas { ctx, size in
                            let opacity = min(0.35, Double((effectiveZoom - 4) / 4) * 0.35)
                            ctx.stroke(
                                {
                                    var p = Path()
                                    var x: CGFloat = 0
                                    while x <= size.width { p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)); x += cellW }
                                    var y: CGFloat = 0
                                    while y <= size.height { p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y)); y += cellH }
                                    return p
                                }(),
                                with: .color(.primary.opacity(opacity)),
                                style: StrokeStyle(lineWidth: 0.5)
                            )
                        }
                        .allowsHitTesting(false)
                    }
                    }
                    .frame(width: fit.width, height: fit.height)
                } else {
                    VStack(spacing: DS.Space.l) {
                        ZStack {
                            Circle()
                                .fill(Color.accentColor.opacity(0.08))
                                .frame(width: 96, height: 96)
                            Image(systemName: "camera.viewfinder")
                                .font(.system(size: 40, weight: .light))
                                .foregroundStyle(Color.accentColor.opacity(0.75))
                        }
                        if let onCapture = onCapture {
                            Button("撮影する", action: onCapture)
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                        }
                        Grid(horizontalSpacing: DS.Space.s, verticalSpacing: DS.Space.xs) {
                            HintRow(key: "⌘⇧2", label: "全画面撮影")
                            HintRow(key: "⌘⇧3", label: "ウィンドウ撮影")
                            HintRow(key: "⌘⇧4", label: "範囲選択撮影")
                            HintRow(key: "⌘V",  label: "クリップボードから貼り付け")
                        }
                        .font(.caption)
                        .padding(.top, DS.Space.xs)
                        if let onOpenPermissions = onOpenPermissions {
                            Button("画面録画の設定を開く", action: onOpenPermissions)
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // 内側スタック(fit)を中央に置いたままビューポート全域を占有する
            // (ジェスチャ領域とズーム中心をビューポート基準に保つ)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .scaleEffect(zoom, anchor: .center)
            .offset(panOffset)
            .clipped()   // ズーム・パンした画像がツールバー等のUIへ溢れないように
            .contentShape(Rectangle())
            .gesture(isPanning ? panGesture() : nil)
            .gesture(isPanning ? nil : dragGesture(in: proxy.frame(in: .local), size: proxy.size))
            .gesture(MagnificationGesture()
                .onChanged { value in
                    zoom = max(0.25, min(8.0, baseZoom * value))
                    userZoomed = true
                }
                .onEnded { value in
                    baseZoom = max(0.25, min(8.0, baseZoom * value))
                    zoom = baseZoom
                }
            )
            .contextMenu {
                if let id = viewModel.selectedAnnotationID,
                   let ann = viewModel.annotations.first(where: { $0.id == id }) {
                    if ann.type == .text {
                        Button("テキストを編集") { viewModel.beginEditingSelectedText() }
                        Divider()
                    }
                    Button(ann.isLocked ? "ロック解除" : "ロック") { viewModel.toggleLockSelected() }
                    Button("複製 (⌘D)") { viewModel.duplicateSelectedAnnotation() }
                    Button("前面へ (⌘])") { viewModel.bringSelectedToFront() }
                    Button("背面へ (⌘[)") { viewModel.sendSelectedToBack() }
                    if [AnnotationType.rectangle, .ellipse, .roundedRect, .highlight, .spotlight].contains(ann.type) {
                        Divider()
                        Button("この範囲をコピー (⌘⌥⇧C)") { onCopyRegion?() }
                        Button("この範囲のテキストを認識 (⌘⌥T)") { onOcrRegion?() }
                        Button("この範囲で切り取り") {
                            let bounds = ann.bounds(in: CGRect(origin: .zero, size: viewModel.canvasSize))
                            viewModel.cropToRect(bounds)
                        }
                    }
                    Divider()
                    if !ann.isLocked {
                        Button("削除", role: .destructive) { viewModel.deleteSelectedAnnotation() }
                        Divider()
                    }
                }
                Button("選択ツール (V)") { viewModel.currentTool = .select }
                Button("矢印ツール (A)") { viewModel.currentTool = .arrow }
                Button("長方形ツール (R)") { viewModel.currentTool = .rectangle }
                Button("テキストツール (T)") { viewModel.currentTool = .text }
                Button("ステップツール (N)") { viewModel.currentTool = .step }
                Button("角丸ツール (U)") { viewModel.currentTool = .roundedRect }
                Button("吹き出しツール (B)") { viewModel.currentTool = .callout }
                Button("ハイライトツール (H)") { viewModel.currentTool = .highlight }
                if viewModel.backgroundImage != nil {
                    Divider()
                    Button("切り取りモード (⌘K)") { viewModel.enterCropMode() }
                    if !viewModel.annotations.isEmpty {
                        Button("全アノテーション削除", role: .destructive) {
                            viewModel.clearAllAnnotations()
                        }
                    }
                }
            }
            .onAppear { viewModel.canvasSize = fit; viewModel.currentZoom = effectiveZoom }
            .onChange(of: fit) { _, newFit in
                // fit はビューポートと画像アスペクトの両方に依存するため、
                // ウィンドウリサイズだけでなく画像差し替え(クロップ・回転等)にも追従する
                viewModel.canvasSize = newFit
                // 手動ズーム前ならレイアウト確定に追従して再フィット
                // (起動時、ウィンドウフレーム復元前の小さいcanvasSizeで計算された
                //  ズームのまま固まる問題の自己修正)
                if !userZoomed {
                    zoom = autoFitZoom; baseZoom = zoom
                }
                viewModel.currentZoom = effectiveZoom
            }
            .onChange(of: zoom) { _, _ in viewModel.currentZoom = effectiveZoom }
            .modifier(ZoomNotificationHandler(
                zoom: $zoom, baseZoom: $baseZoom,
                panOffset: $panOffset, basePan: $basePan,
                userZoomed: $userZoomed,
                canvasSize: viewModel.canvasSize,
                imageSize: viewModel.backgroundImage.map { CGSize(width: $0.width, height: $0.height) }
            ))
            .overlay(textInputOverlay(viewport: proxy.size))
            .overlay(
                ScrollWheelHandler { dx, dy, isCmd, cursor in
                    if isCmd {
                        // ⌘+scroll → zoom toward cursor
                        let oldZoom = zoom
                        let newZoom = max(0.25, min(8.0, zoom * (1.0 + dy * 0.02)))
                        zoom = newZoom; baseZoom = newZoom; userZoomed = true
                        // Adjust pan so the canvas point under the cursor stays fixed
                        if let cur = cursor {
                            let viewCenter = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
                            let oldPan = panOffset
                            let ptX = cur.x - viewCenter.x - oldPan.width
                            let ptY = cur.y - viewCenter.y - oldPan.height
                            let ratio = newZoom / oldZoom
                            panOffset = CGSize(
                                width: cur.x - viewCenter.x - ptX * ratio,
                                height: cur.y - viewCenter.y - ptY * ratio
                            )
                            basePan = panOffset
                        }
                    } else {
                        // scroll → pan
                        panOffset = CGSize(width: basePan.width - dx, height: basePan.height - dy)
                        basePan = panOffset
                    }
                }
                .allowsHitTesting(true)
                .opacity(0)
            )
            .overlay(alignment: .topTrailing) {
                // 100% = 実寸(撮影時と同じ大きさ)。タップで既定表示に戻す
                let pct = Int(round(effectiveZoom * 100))
                if viewModel.backgroundImage != nil && pct != 100 {
                    Text("\(pct)%")
                        .font(.system(size: DS.FontSize.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, DS.Space.xs)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.small))
                        .padding(DS.Space.xs)
                        .onTapGesture {
                            withAnimation(DS.Anim.smooth) {
                                zoom = autoFitZoom; baseZoom = zoom
                                panOffset = .zero; basePan = .zero; userZoomed = true
                            }
                        }
                }
            }
            .overlay {
                if viewModel.currentTool == .colorPicker,
                   let loc = hoverLocation,
                   let hex = hoverColorHex {
                    eyedropperSwatchView(hex: hex, viewSize: proxy.size, at: loc)
                }
            }
            // Annotation placement ripple (brief expanding ring to confirm placement)
            .overlay {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { tl in
                    let elapsed = tl.date.timeIntervalSinceReferenceDate - Double(viewModel.lastPlacedAt)
                    if elapsed < 0.45, elapsed >= 0 {
                        let t = CGFloat(elapsed / 0.45)
                        let cx = proxy.size.width / 2
                        let cy = proxy.size.height / 2
                        let lp = viewModel.lastPlacedCenter
                        // キャンバス座標 → ビューポート座標(中央配置なので中心基準で写像)
                        let vx = cx + (lp.x - viewModel.canvasSize.width / 2) * zoom + panOffset.width
                        let vy = cy + (lp.y - viewModel.canvasSize.height / 2) * zoom + panOffset.height
                        let size = 24 + t * 48
                        Circle()
                            .stroke(Color.white.opacity((1 - t) * 0.6), lineWidth: max(0.5, 2 * (1 - t)))
                            .frame(width: size, height: size)
                            .position(x: vx, y: vy)
                            .allowsHitTesting(false)
                    }
                }
            }
            // Undo/redo toast (center-bottom)
            .overlay(alignment: .bottom) {
                if let msg = viewModel.undoRedoToast {
                    Text(msg)
                        .font(.system(size: DS.FontSize.body, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, DS.Space.s)
                        .padding(.vertical, DS.Space.xs)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.medium))
                        .overlay(RoundedRectangle(cornerRadius: DS.Radius.medium).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                        .shadow(DS.Shadow.overlay)
                        .padding(.bottom, DS.Space.l)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            // Pixel coordinate display (bottom-left, shows when hovering over the canvas image)
            .overlay(alignment: .bottomLeading) {
                if let pt = hoverCanvasPoint,
                   viewModel.backgroundImage != nil,
                   !viewModel.dragState.isDrawing,
                   !viewModel.isDraggingAnnotation,
                   viewModel.currentTool != .colorPicker {
                    let img = viewModel.backgroundImage!
                    let sx = CGFloat(img.width) / viewModel.canvasSize.width
                    let sy = CGFloat(img.height) / viewModel.canvasSize.height
                    let px = Int(pt.x * sx), py = Int(pt.y * sy)
                    let inBounds = px >= 0 && px < img.width && py >= 0 && py < img.height
                    if inBounds {
                        Text("\(px), \(py)")
                            .font(.system(size: DS.FontSize.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, DS.Space.xxs)
                            .padding(.vertical, 2)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.small))
                            .padding(DS.Space.xs)
                            .transition(.opacity)
                    }
                }
            }
            // Selected annotation size indicator (bottom-right)
            .overlay(alignment: .bottomTrailing) {
                if viewModel.currentTool == .select,
                   let id = viewModel.selectedAnnotationID,
                   let ann = viewModel.annotations.first(where: { $0.id == id }) {
                    let b = ann.bounds(in: CGRect(origin: .zero, size: viewModel.canvasSize))
                    let img = viewModel.backgroundImage
                    let sx = img.map { CGFloat($0.width) / viewModel.canvasSize.width } ?? 1
                    let sy = img.map { CGFloat($0.height) / viewModel.canvasSize.height } ?? 1
                    let pw = Int(b.width * sx), ph = Int(b.height * sy)
                    if pw > 0 && ph > 0 {
                        Text("\(pw) × \(ph)")
                            .font(.system(size: DS.FontSize.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, DS.Space.xxs)
                            .padding(.vertical, 2)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.small))
                            .padding(DS.Space.xs)
                            .transition(.opacity)
                    }
                }
            }
            .focusable()
            .focused($canvasFocused)
            // Tool shortcut keys (only when text field not focused)
            .onKeyPress("v") { if !viewModel.showTextInput { viewModel.currentTool = .select }; return .handled }
            .onKeyPress("l") { if !viewModel.showTextInput { viewModel.currentTool = .line }; return .handled }
            .onKeyPress("a") { if !viewModel.showTextInput { viewModel.currentTool = .arrow }; return .handled }
            .onKeyPress("r") { if !viewModel.showTextInput { viewModel.currentTool = .rectangle }; return .handled }
            .onKeyPress("e") { if !viewModel.showTextInput { viewModel.currentTool = .ellipse }; return .handled }
            .onKeyPress("t") { if !viewModel.showTextInput { viewModel.currentTool = .text }; return .handled }
            .onKeyPress("x") { if !viewModel.showTextInput { viewModel.currentTool = .redact }; return .handled }
            .onKeyPress("m") { if !viewModel.showTextInput { viewModel.currentTool = .redact }; return .handled }
            .onKeyPress("n") { if !viewModel.showTextInput { viewModel.currentTool = .step }; return .handled }
            .onKeyPress("u") { if !viewModel.showTextInput { viewModel.currentTool = .roundedRect }; return .handled }
            .onKeyPress("b") { if !viewModel.showTextInput { viewModel.currentTool = .callout }; return .handled }
            .onKeyPress("h") { if !viewModel.showTextInput { viewModel.currentTool = .highlight }; return .handled }
            .onKeyPress("p") { if !viewModel.showTextInput { viewModel.currentTool = .pencil }; return .handled }
            .onKeyPress("g") { if !viewModel.showTextInput { viewModel.currentTool = .stamp }; return .handled }
            .onKeyPress("i") { if !viewModel.showTextInput { viewModel.currentTool = .colorPicker }; return .handled }
            .onKeyPress("q") { if !viewModel.showTextInput { viewModel.currentTool = .measure }; return .handled }
            .onKeyPress("o") { if !viewModel.showTextInput { viewModel.currentTool = .spotlight }; return .handled }
            .onKeyPress("c", phases: .down) { press in
                if press.modifiers.contains([.command, .option, .shift]) {
                    onCopyRegion?(); return .handled
                }
                guard press.modifiers.contains([.command, .option]) else { return .ignored }
                onCopyOriginal?(); return .handled
            }
            .onKeyPress("t", phases: .down) { press in
                guard press.modifiers.contains([.command, .option]) else { return .ignored }
                onOcrRegion?(); return .handled
            }
            .onKeyPress("a", phases: .down) { press in
                guard !viewModel.showTextInput, press.modifiers.contains(.command) else { return .ignored }
                let allIDs: Set<UUID> = Set(viewModel.annotations.map { $0.id })
                viewModel.selectedAnnotationIDs = allIDs
                viewModel.selectedAnnotationID = viewModel.annotations.last?.id
                viewModel.objectWillChange.send()
                return .handled
            }
            .onKeyPress("=", phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                withAnimation(.easeOut(duration: 0.15)) { zoom = min(8.0, zoom * 1.25); baseZoom = zoom; userZoomed = true }
                return .handled
            }
            .onKeyPress("-", phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                withAnimation(.easeOut(duration: 0.15)) { zoom = max(0.25, zoom / 1.25); baseZoom = zoom; userZoomed = true }
                return .handled
            }
            .onKeyPress("0", phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                // ⌘0 = 実寸(画像1px = 画面1デバイスpx)
                withAnimation(.easeOut(duration: 0.2)) {
                    zoom = max(0.25, min(8.0, naturalZoom)); baseZoom = zoom
                    panOffset = .zero; basePan = .zero; userZoomed = true
                }
                return .handled
            }
            .onKeyPress("f", phases: .down) { press in
                guard !viewModel.showTextInput else { return .ignored }
                if press.modifiers.isEmpty {
                    // F = toggle fill for rectangle/ellipse/roundedRect tools
                    let fillable: [DrawingTool] = [.rectangle, .ellipse, .roundedRect, .callout]
                    if fillable.contains(viewModel.currentTool) {
                        viewModel.currentFilled.toggle()
                        viewModel.applyCurrentFilledToSelection()
                        return .handled
                    }
                    return .ignored
                }
                // ⌘F は検索フォーカス(後段のハンドラとメニューが担当)。フィットは⌘9
                return .ignored
            }
            .onKeyPress(.space, phases: .down) { _ in
                guard !viewModel.showTextInput else { return .ignored }
                isPanning = true; updateCursor(); return .handled
            }
            .onKeyPress(.space, phases: .up) { _ in
                isPanning = false; updateCursor(); return .handled
            }
            // Number keys 1-8 → color selection
            .onKeyPress(characters: .init(charactersIn: "12345678"), phases: .down) { press in
                guard !viewModel.showTextInput else { return .ignored }
                let colors = AnnotationColor.allCases
                if let digit = press.key.character.wholeNumberValue, digit >= 1, digit <= colors.count {
                    viewModel.currentColor = colors[digit - 1]
                    viewModel.applyCurrentColorToSelection()
                }
                return .handled
            }
            .onKeyPress(.tab, phases: .down) { press in
                guard !viewModel.showTextInput else { return .ignored }
                let isSelectMode = viewModel.currentTool == .select
                if isSelectMode && !viewModel.annotations.isEmpty {
                    // Tab cycles through annotations when in select mode
                    let anns = viewModel.annotations
                    let currentIdx = anns.firstIndex { $0.id == viewModel.selectedAnnotationID } ?? -1
                    let next: Int
                    if press.modifiers.contains(.shift) {
                        next = (currentIdx - 1 + anns.count) % anns.count
                    } else {
                        next = (currentIdx + 1) % anns.count
                    }
                    viewModel.selectedAnnotationID = anns[next].id
                    viewModel.selectedAnnotationIDs = []
                } else {
                    // Tab cycles through tools in drawing modes
                    let tools = DrawingTool.allCases
                    if let i = tools.firstIndex(of: viewModel.currentTool) {
                        if press.modifiers.contains(.shift) {
                            viewModel.currentTool = tools[(i - 1 + tools.count) % tools.count]
                        } else {
                            viewModel.currentTool = tools[(i + 1) % tools.count]
                        }
                    }
                }
                return .handled
            }
            .onKeyPress("d", phases: .down) { press in
                guard !viewModel.showTextInput, press.modifiers.contains(.command) else { return .ignored }
                viewModel.duplicateSelectedAnnotation()
                return .handled
            }
            .onKeyPress("f", phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                onFocusSearch?()
                return .handled
            }
            .onKeyPress(.delete, phases: .down) { press in
                guard !viewModel.showTextInput else { return .ignored }
                if press.modifiers.contains(.command) && press.modifiers.contains(.shift) {
                    viewModel.clearAllAnnotations()
                    return .handled
                }
                let mods = press.modifiers
                if mods.isEmpty || mods == .option {
                    viewModel.deleteSelectedAnnotation()
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(.escape, phases: .down) { _ in
                if viewModel.currentTool == .colorPicker {
                    viewModel.currentTool = viewModel.colorPickerPreviousTool
                    return .handled
                }
                return .ignored
            }
            .onKeyPress("l", phases: .down) { press in
                guard !viewModel.showTextInput, press.modifiers.contains(.command) else { return .ignored }
                viewModel.toggleLockSelected()
                return .handled
            }
            // Arrow key nudge for selected annotation (⌘↑/⌘↓ = history navigation)
            .onKeyPress(characters: .init(charactersIn: "\u{F700}\u{F701}\u{F702}\u{F703}"),
                        phases: [.down, .repeat]) { press in
                guard !viewModel.showTextInput else { return .ignored }
                // ⌘+arrow: navigate history
                if press.modifiers.contains(.command) {
                    switch press.key {
                    case .upArrow:    onNavigateHistory?(-1); return .handled
                    case .downArrow:  onNavigateHistory?(1);  return .handled
                    default: break
                    }
                }
                // Crop mode: arrow keys move/resize the crop rect
                if viewModel.isCropMode, viewModel.cropStart != nil, viewModel.cropEnd != nil {
                    let step: CGFloat = press.modifiers.contains(.shift) ? 10 : 1
                    let canvasW = viewModel.canvasSize.width, canvasH = viewModel.canvasSize.height
                    var s = viewModel.cropStart!, e = viewModel.cropEnd!
                    if press.modifiers.contains(.option) {
                        // ⌥+arrow: resize (move end corner)
                        switch press.key {
                        case .upArrow:    e.y = max(s.y + 4, e.y - step)
                        case .downArrow:  e.y = min(canvasH, e.y + step)
                        case .leftArrow:  e.x = max(s.x + 4, e.x - step)
                        case .rightArrow: e.x = min(canvasW, e.x + step)
                        default: break
                        }
                    } else {
                        // plain arrow: move whole rect
                        let w = abs(e.x - s.x), h = abs(e.y - s.y)
                        switch press.key {
                        case .upArrow:
                            let ny = max(0, min(s.y, e.y) - step)
                            s.y = ny; e.y = ny + h
                        case .downArrow:
                            let ny = min(canvasH - h, min(s.y, e.y) + step)
                            s.y = ny; e.y = ny + h
                        case .leftArrow:
                            let nx = max(0, min(s.x, e.x) - step)
                            s.x = nx; e.x = nx + w
                        case .rightArrow:
                            let nx = min(canvasW - w, min(s.x, e.x) + step)
                            s.x = nx; e.x = nx + w
                        default: break
                        }
                    }
                    viewModel.cropStart = s; viewModel.cropEnd = e
                    return .handled
                }
                let step: CGFloat = press.modifiers.contains(.shift) ? 10 : 1
                let dx: CGFloat
                let dy: CGFloat
                switch press.key {
                case .upArrow:    dx = 0;     dy = -step
                case .downArrow:  dx = 0;     dy = step
                case .leftArrow:  dx = -step; dy = 0
                case .rightArrow: dx = step;  dy = 0
                default: return .ignored
                }
                let t = CGAffineTransform(translationX: dx, y: dy)
                // Move all selected annotations (multi-select or single)
                let ids = viewModel.selectedAnnotationIDs.isEmpty
                    ? Set(viewModel.selectedAnnotationID.map { [$0] } ?? [])
                    : viewModel.selectedAnnotationIDs
                guard !ids.isEmpty else { return .ignored }
                for id in ids {
                    guard var ann = viewModel.annotations.first(where: { $0.id == id }), !ann.isLocked else { continue }
                    ann.applyTransform(t)
                    viewModel.updateAnnotation(ann)
                    if !ann.hasStrokeRepresentation { viewModel.updateFilterPreview(for: ann) }
                }
                viewModel.updateUndoRedoState()
                return .handled
            }
            .onKeyPress(characters: .init(charactersIn: "[]{}"), phases: .down) { press in
                guard !viewModel.showTextInput else { return .ignored }
                let ch = press.key.character
                let isCmd = press.modifiers.contains(.command)
                let isShift = press.modifiers.contains(.shift)
                if isCmd {
                    if ch == "[" { viewModel.sendSelectedToBack() }
                    if ch == "]" { viewModel.bringSelectedToFront() }
                } else if isShift {
                    // Shift+[ = { and Shift+] = } → adjust opacity ±10%
                    let delta: Double = (ch == "{") ? -0.1 : 0.1
                    viewModel.currentOpacity = max(0.1, min(1.0, viewModel.currentOpacity + delta))
                    viewModel.applyCurrentOpacityToSelection()
                } else {
                    let all = LineWidth.allCases
                    if ch == "[" {
                        if let i = all.firstIndex(of: viewModel.currentLineWidth), i > 0 { viewModel.currentLineWidth = all[i - 1] }
                    } else if ch == "]" {
                        if let i = all.firstIndex(of: viewModel.currentLineWidth), i < all.count - 1 { viewModel.currentLineWidth = all[i + 1] }
                    }
                }
                return .handled
            }
            .onKeyPress(.return) {
                guard !viewModel.showTextInput else { return .ignored }
                if viewModel.isCropMode && viewModel.cropStart != nil {
                    viewModel.confirmCrop(); return .handled
                }
                let isSelectTool = viewModel.currentTool == .select
                let selID = viewModel.selectedAnnotationID
                let selAnn = selID.flatMap { id in viewModel.annotations.first(where: { $0.id == id }) }
                if isSelectTool, selAnn?.type == .text {
                    viewModel.beginEditingSelectedText(); return .handled
                }
                return .ignored
            }
            .onKeyPress(.escape) {
                if viewModel.isCropMode { viewModel.cancelCrop(); return .handled }
                if viewModel.showTextInput { viewModel.cancelTextInput(); return .handled }
                if viewModel.selectedAnnotationID != nil {
                    viewModel.selectedAnnotationID = nil
                    viewModel.objectWillChange.send()
                    return .handled
                }
                if viewModel.currentTool != .select {
                    viewModel.currentTool = .select
                    return .handled
                }
                return .ignored
            }
            .gesture(
                SpatialTapGesture(count: 2)
                    .onEnded { value in
                        guard viewModel.backgroundImage != nil else { return }
                        // Double-click in crop mode → confirm crop
                        if viewModel.isCropMode {
                            viewModel.confirmCrop()
                            return
                        }
                        guard viewModel.currentTool == .select else { return }
                        let localPt = toCanvas(CGPoint(x: value.location.x, y: value.location.y), size: proxy.size)
                        for ann in viewModel.annotations.reversed() {
                            if ann.type == .text && ann.hitTest(localPt, in: CGRect(origin: .zero, size: viewModel.canvasSize)) {
                                viewModel.selectedAnnotationID = ann.id
                                viewModel.beginEditingSelectedText()
                                return
                            }
                        }
                    }
            )
            .simultaneousGesture(
                SpatialTapGesture(count: 1)
                    .onEnded { value in
                        // 描画ツールでの純クリック=注釈の選び直し(ヒットなしは選択解除)。
                        // selectAnnotation がスタイルコントロール(太さ/色)も選択注釈に同期する
                        guard viewModel.backgroundImage != nil,
                              !viewModel.isCropMode,
                              viewModel.currentTool.supportsGrabMove else { return }
                        let localPt = toCanvas(CGPoint(x: value.location.x, y: value.location.y), size: proxy.size)
                        viewModel.selectAnnotation(at: localPt)
                    }
            )
            .onHover { inside in
                isHovering = inside
                if inside {
                    updateCursor()
                } else {
                    NSCursor.arrow.set()
                    hoverLocation = nil
                    hoverColorHex = nil
                }
            }
            .onContinuousHover { phase in
                if case .active(let location) = phase {
                    let canvasLoc = toCanvas(location, size: proxy.size)
                    hoverCanvasPoint = canvasLoc
                    if viewModel.currentTool == .colorPicker {
                        hoverLocation = location
                        hoverColorHex = viewModel.sampleColor(at: canvasLoc)
                    } else {
                        hoverLocation = nil
                        hoverColorHex = nil
                    }
                    if !viewModel.isDraggingAnnotation && !viewModel.isGrabMoving &&
                       (viewModel.currentTool == .select || viewModel.currentTool.supportsGrabMove) {
                        let canvasLoc = toCanvas(location, size: proxy.size)
                        let hit = viewModel.annotations.last(where: {
                            !$0.isLocked && $0.hitTest(canvasLoc, in: CGRect(origin: .zero, size: viewModel.canvasSize))
                        })
                        viewModel.hoveredAnnotationID = hit?.id
                        // Full handle detection only in select mode
                        if viewModel.currentTool == .select {
                            if let selID = viewModel.selectedAnnotationID,
                               let ann = viewModel.annotations.first(where: { $0.id == selID }) {
                                let r: CGFloat = 10
                                if CanvasViewModel.isResizable(ann.type) {
                                    let bounds = ann.bounds(in: CGRect(origin: .zero, size: viewModel.canvasSize))
                                    let corners = viewModel.handleCorners(for: bounds)
                                    var hi = viewModel.hitTestHandle(at: canvasLoc, corners: corners)
                                    if hi == nil, ann.type == .callout, let baseTail = ann.calloutTailPoint {
                                        let tailCanvas = baseTail.applying(ann.transform)
                                        if abs(canvasLoc.x - tailCanvas.x) <= r && abs(canvasLoc.y - tailCanvas.y) <= r {
                                            hi = 8
                                        }
                                    }
                                    hoverHandleIndex = hi
                                } else if (ann.type == .arrow || ann.type == .line),
                                          let baseStart = ann.lineStartPoint, let baseEnd = ann.lineEndPoint {
                                    let t = ann.transform
                                    let startC = baseStart.applying(t), endC = baseEnd.applying(t)
                                    if abs(canvasLoc.x - endC.x) <= r && abs(canvasLoc.y - endC.y) <= r {
                                        hoverHandleIndex = 10
                                    } else if abs(canvasLoc.x - startC.x) <= r && abs(canvasLoc.y - startC.y) <= r {
                                        hoverHandleIndex = 9
                                    } else {
                                        hoverHandleIndex = nil
                                    }
                                } else {
                                    hoverHandleIndex = nil
                                }
                            } else {
                                hoverHandleIndex = nil
                            }
                        } else {
                            hoverHandleIndex = nil
                        }
                    } else {
                        viewModel.hoveredAnnotationID = nil
                        hoverHandleIndex = nil
                    }
                    updateCursor()
                } else {
                    hoverLocation = nil
                    hoverColorHex = nil
                    hoverCanvasPoint = nil
                    viewModel.hoveredAnnotationID = nil
                }
            }
            .onChange(of: viewModel.currentTool) { _, _ in
                updateCursor()
                if viewModel.currentTool != .colorPicker {
                    hoverLocation = nil
                    hoverColorHex = nil
                }
            }
            .onChange(of: viewModel.loadToken) { _, _ in
                // 既定表示: 実寸(撮影時と同じ大きさ)。ビューポートに収まらない場合のみ
                // フィットまで縮小(zoom ≤ 1.0 なので小さい画像がUIから溢れない)
                zoom = viewModel.backgroundImage != nil ? autoFitZoom : 1.0
                baseZoom = zoom
                userZoomed = false
                panOffset = .zero; basePan = .zero
                viewModel.currentZoom = effectiveZoom
                imageOpacity = 0
                withAnimation(.easeOut(duration: 0.25)) { imageOpacity = 1.0 }
            }
            .onChange(of: viewModel.cropAnimToken) { _, _ in
                imageOpacity = 0
                withAnimation(.easeOut(duration: 0.2)) { imageOpacity = 1.0 }
            }
        }
    }


    private func panGesture() -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                isPanDragging = true
                updateCursor()
                panOffset = CGSize(
                    width: basePan.width + value.translation.width,
                    height: basePan.height + value.translation.height
                )
            }
            .onEnded { value in
                isPanDragging = false
                basePan = panOffset
                updateCursor()
            }
    }

    private func dragGesture(in rect: CGRect, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let loc = toCanvas(value.location, size: size)
                if viewModel.dragState.isDrawing {
                    viewModel.handleDragUpdate(at: loc, in: rect)
                } else {
                    canvasFocused = true
                    viewModel.handleDragStart(at: loc, in: rect)
                }
                updateCursor()
            }
            .onEnded { value in
                let loc = toCanvas(value.location, size: size)
                viewModel.handleDragEnd(at: loc, in: rect)
                updateCursor()
            }
    }

}
