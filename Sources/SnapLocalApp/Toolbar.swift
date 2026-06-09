// Toolbar.swift
// SnapLocal - CompactToolbar and toolbar-only helper views
// (extracted from App.swift — PLAN.md T0.2, mechanical move only)

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Compact Toolbar

struct CompactToolbar: View {
    @ObservedObject var canvas: CanvasViewModel
    let onCapture: () -> Void
    let onCaptureRegion: () -> Void
    let onCaptureWindow: () -> Void
    let onPin: () -> Void
    let onCaptureWithDelay: (Int) -> Void
    let onRepeatRegion: () -> Void
    let onSave: () -> Void
    let onSaveAs: () -> Void
    let onCopy: () -> Void
    let onPaste: () -> Void
    let onShare: () -> Void
    var onAutoRedactFaces: (() -> Void)? = nil
    @Binding var sidebarVisible: Bool
    var onCaptureToClipboard: (() -> Void)? = nil
    var onCaptureRegionToClipboard: (() -> Void)? = nil
    var currentOCRText: String = ""
    @State private var showOCRPanel = false
    @State private var showHelp = false
    @State private var showSettings = false
    @State private var showAdjustments = false
    @State private var showDecoration = false
    @State private var showColorPopover = false
    @State private var showSaveTemplate = false
    @State private var templateNameInput = ""
    @State private var showExtendCanvas = false
    @State private var extendSymmetric = true
    @State private var extendAll: CGFloat = 40
    @State private var extendTop: CGFloat = 40
    @State private var extendRight: CGFloat = 40
    @State private var extendBottom: CGFloat = 40
    @State private var extendLeft: CGFloat = 40
    @State private var extendBgChoice: Int = 0   // 0=white 1=black 2=transparent
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        HStack(spacing: 6) {
            if canvas.isCropMode {
                cropModeControls
            } else {
                normalControls
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        // Hidden keyboard shortcut buttons that were moved to menus
        .background {
            Group {
                Button(action: onPaste) { EmptyView() }
                    .keyboardShortcut("v", modifiers: .command)
                Button(action: onRepeatRegion) { EmptyView() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button(action: onSaveAs) { EmptyView() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button(action: onShare) { EmptyView() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button { canvas.rotateImage(clockwise: false) } label: { EmptyView() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    .disabled(canvas.backgroundImage == nil)
                Button { canvas.rotateImage(clockwise: true) } label: { EmptyView() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    .disabled(canvas.backgroundImage == nil)
                Button(action: onPin) { EmptyView() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(canvas.backgroundImage == nil)
            }
            .frame(width: 0, height: 0).opacity(0)
        }
    }

    private var cropModeControls: some View {
        HStack(spacing: 8) {
            Image(systemName: "crop")
                .foregroundStyle(Color.accentColor)
            Text("切り取り")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider().frame(height: 16)
            // Aspect ratio presets
            let ratioOptions: [(String, CGFloat?)] = [
                ("フリー", nil), ("1:1", 1.0), ("4:3", 4.0/3.0), ("16:9", 16.0/9.0), ("3:2", 3.0/2.0)
            ]
            ForEach(ratioOptions, id: \.0) { label, ratio in
                let isActive = canvas.cropAspectRatio == ratio
                Button(label) { canvas.cropAspectRatio = ratio }
                    .font(.caption)
                    .controlSize(.mini)
                    .buttonStyle(.bordered)
                    .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                    .fontWeight(isActive ? .semibold : .regular)
            }
            Spacer()
            Button("確定") { canvas.confirmCrop() }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(canvas.cropStart == nil || canvas.cropEnd == nil)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button("キャンセル") { canvas.cancelCrop() }
                .keyboardShortcut(.escape, modifiers: [])
                .controlSize(.small)
        }
    }

    private var normalControls: some View {
        HStack(spacing: 6) {
            // ─ キャプチャ ─
            Button(action: onCapture) {
                Image(systemName: "camera.viewfinder")
            }
            .help("全画面撮影 (⌘⇧2)")
            .keyboardShortcut("2", modifiers: [.command, .shift])

            Button(action: onCaptureRegion) {
                Image(systemName: "crop")
            }
            .help("範囲選択撮影 (⌘⇧4)")
            .keyboardShortcut("4", modifiers: [.command, .shift])

            Button(action: onCaptureWindow) {
                Image(systemName: "macwindow.on.rectangle")
            }
            .help("ウィンドウ撮影 (⌘⇧3)")
            .keyboardShortcut("3", modifiers: [.command, .shift])

            Menu {
                Button("前回の範囲を再撮影 (⌘⇧R)") { onRepeatRegion() }
                Divider()
                Section("遅延撮影") {
                    Button("3秒後") { onCaptureWithDelay(3) }
                    Button("5秒後") { onCaptureWithDelay(5) }
                    Button("10秒後") { onCaptureWithDelay(10) }
                }
                Divider()
                Section("クリップボードのみ") {
                    Button("全画面→クリップボード (⌘⌃2)") { onCaptureToClipboard?() }
                    Button("範囲選択→クリップボード (⌘⌃4)") { onCaptureRegionToClipboard?() }
                }
                Divider()
                Button("クリップボードから貼り付け (⌘V)") { onPaste() }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 18)
            .help("その他のキャプチャ")

            if canvas.backgroundImage != nil { annotationToolControls }
            if canvas.backgroundImage != nil { imageEditControls }

            normalControlsExport
        }
    }

    @ViewBuilder
    private var annotationToolControls: some View {
            Divider().frame(height: 18)

            // ─ 描画ツール（主要6つ + もっと見る）─
            HStack(spacing: 2) {
                let moreTools: [DrawingTool] = [.ellipse, .roundedRect, .callout, .step,
                                                .highlight, .pencil, .stamp, .spotlight, .colorPicker, .measure]
                toolButton(.select, canvas: canvas)
                toolButton(.arrow, canvas: canvas)
                toolButton(.rectangle, canvas: canvas)
                toolButton(.line, canvas: canvas)
                toolButton(.text, canvas: canvas)
                toolButton(.redact, canvas: canvas)

                if moreTools.contains(canvas.currentTool) {
                    Divider().frame(width: 1, height: 18).padding(.horizontal, 1)
                    toolButton(canvas.currentTool, canvas: canvas)
                }

                Menu {
                    Section("描画") {
                        ForEach([DrawingTool.ellipse, .roundedRect, .callout,
                                 .step, .highlight, .pencil, .stamp, .spotlight], id: \.self) { tool in
                            Button(action: { canvas.currentTool = tool }) {
                                Label(tool.helpText, systemImage: tool.systemImage)
                            }
                        }
                    }
                    Section("計測・色") {
                        Button(action: { canvas.currentTool = .colorPicker }) {
                            Label(DrawingTool.colorPicker.helpText, systemImage: DrawingTool.colorPicker.systemImage)
                        }
                        Button(action: { canvas.currentTool = .measure }) {
                            Label(DrawingTool.measure.helpText, systemImage: DrawingTool.measure.systemImage)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(moreTools.contains(canvas.currentTool) ? Color.accentColor : Color.primary)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 22)
                .help("その他のツール")
            }

            if canvas.currentTool == .arrow {
                Toggle(isOn: $canvas.currentArrowDoubleSided) {
                    Image(systemName: "arrow.left.and.right")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("両方向矢印")
            }

            if canvas.currentTool == .redact {
                Picker("", selection: $canvas.currentRedactMode) {
                    ForEach(RedactMode.allCases, id: \.self) { mode in
                        Image(systemName: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 60)
                .help("モザイク / ぼかし")

                if canvas.currentRedactMode == .mosaic {
                    Slider(value: $canvas.currentMosaicScale, in: 4...30)
                        .frame(width: 60)
                        .help("モザイクの粗さ")
                } else {
                    Slider(value: $canvas.currentBlurRadius, in: 4...40)
                        .frame(width: 60)
                        .help("ぼかしの強さ")
                }

                Button {
                    onAutoRedactFaces?()
                } label: {
                    Image(systemName: "person.crop.rectangle.badge.plus")
                }
                .help("顔を自動検出してモザイク/ぼかし")
                .disabled(canvas.backgroundImage == nil)
            }

            if canvas.currentTool == .colorPicker {
                Button {
                    let sampler = NSColorSampler()
                    sampler.show { color in
                        guard let color else { return }
                        let r = UInt8(color.redComponent * 255)
                        let g = UInt8(color.greenComponent * 255)
                        let b = UInt8(color.blueComponent * 255)
                        let hex = String(format: "%02X%02X%02XFF", r, g, b)
                        canvas.currentCustomColorHex = hex
                        SettingsManager.shared.addRecentCustomColor(hex)
                        canvas.applyCustomColorToSelection(hex: hex)
                        canvas.currentTool = canvas.colorPickerPreviousTool
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "eyedropper.full")
                        Text("画面全体")
                            .font(.system(size: 10))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("画面全体から色をサンプリング (NSColorSampler)")
            }

            if canvas.currentTool == .spotlight {
                Picker("", selection: $canvas.currentSpotlightShape) {
                    ForEach(SpotlightShape.allCases, id: \.self) { s in
                        Image(systemName: s.systemImage).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 60)
                .help("楕円 / 矩形")
            }

            if canvas.currentTool == .stamp {
                let stamps = ["✅", "❌", "⚠️", "💡", "🐛", "📌", "❗", "❓", "✨", "🔍",
                              "👆", "👀", "🔥", "💯", "🎯", "🔑", "⭐", "🚀", "🛑", "🤔"]
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(stamps, id: \.self) { emoji in
                            Button(action: { canvas.currentStamp = emoji }) {
                                Text(emoji)
                                    .font(.system(size: 16))
                                    .frame(width: 26, height: 26)
                                    .background(canvas.currentStamp == emoji ? Color.accentColor.opacity(0.25) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                        }
                        // Custom stamp input
                        Divider().frame(height: 20)
                        TextField("絵文字", text: Binding(
                            get: { stamps.contains(canvas.currentStamp) ? "" : canvas.currentStamp },
                            set: { if !$0.isEmpty { canvas.currentStamp = String($0.unicodeScalars.suffix(2)) } }
                        ))
                        .frame(width: 36)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .multilineTextAlignment(.center)
                        .help("カスタム絵文字を入力")
                    }
                    .padding(.horizontal, 2)
                }
                .frame(maxWidth: 300)
                .help("スタンプを選択（クリックで配置）")
            }

            if canvas.currentTool == .rectangle || canvas.currentTool == .ellipse || canvas.currentTool == .roundedRect || canvas.currentTool == .callout {
                Toggle(isOn: $canvas.currentFilled) {
                    Image(systemName: canvas.currentFilled ? "square.fill" : "square")
                }
                .toggleStyle(.button)
                .help(canvas.currentFilled ? "塗りつぶし → アウトライン (F)" : "アウトライン → 塗りつぶし (F)")
                .controlSize(.small)
                .onChange(of: canvas.currentFilled) { _, _ in canvas.applyCurrentFilledToSelection() }
            }

            if canvas.currentTool == .text {
                Picker("", selection: $canvas.currentFontSize) {
                    Text("S").tag(CGFloat(14))
                    Text("M").tag(CGFloat(18))
                    Text("L").tag(CGFloat(24))
                    Text("XL").tag(CGFloat(32))
                }
                .pickerStyle(.segmented)
                .frame(width: 90)
                .help("テキストサイズ")

                Toggle(isOn: $canvas.currentTextBackground) {
                    Image(systemName: canvas.currentTextBackground ? "textformat.alt" : "textformat")
                }
                .toggleStyle(.button)
                .help(canvas.currentTextBackground ? "背景あり（クリックで背景なしへ）" : "背景なし（クリックで背景ありへ）")
                .controlSize(.small)
            }

            // ─ カラー（シングルスウォッチ → ポップオーバーで全パレット）─
            Divider().frame(height: 18)

            Button {
                showColorPopover.toggle()
            } label: {
                let activeColor: Color = {
                    if let hex = canvas.currentCustomColorHex,
                       let c = ColorWellView.hexToNSColor(hex) {
                        return Color(nsColor: c)
                    }
                    return canvas.currentColor.color
                }()
                ZStack {
                    Circle().fill(activeColor).frame(width: 16, height: 16)
                        .overlay(Circle().stroke(Color.primary.opacity(activeColor == .white ? 0.3 : 0), lineWidth: 0.5))
                    Circle().stroke(Color.primary.opacity(0.6), lineWidth: 1.5).frame(width: 20, height: 20)
                }
            }
            .buttonStyle(.plain)
            .frame(width: 22, height: 22)
            .help("カラー (1-8, カスタム)")
            .popover(isPresented: $showColorPopover, arrowEdge: .bottom) {
                colorPalettePopover
            }

    } // annotationToolControls

    @ViewBuilder
    private var imageEditControls: some View {
        Divider().frame(height: 18)

        Button { canvas.enterCropMode() } label: {
            Image(systemName: "scissors")
        }
        .help("切り取り (⌘K)")
        .keyboardShortcut("k", modifiers: .command)

        Button { showAdjustments.toggle() } label: {
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(canvas.hasActiveAdjustments ? Color.accentColor : Color.primary)
        }
        .help(canvas.hasActiveAdjustments ? "明るさ・コントラスト・彩度（調整中）" : "明るさ・コントラスト・彩度")
        .popover(isPresented: $showAdjustments, arrowEdge: .bottom) {
            adjustmentsPopover
        }

        Button { showDecoration.toggle() } label: {
            Image(systemName: canvas.decorationEnabled ? "wand.and.stars.inverse" : "wand.and.stars")
                .foregroundStyle(canvas.decorationEnabled ? Color.accentColor : Color.primary)
        }
        .help("書き出し装飾 (パディング・角丸・影)")
        .popover(isPresented: $showDecoration, arrowEdge: .bottom) {
            decorationPopover
        }

        Menu {
            Section("回転・反転") {
                Button("90°左に回転 (⌘⌥←)") { canvas.rotateImage(clockwise: false) }
                Button("90°右に回転 (⌘⌥→)") { canvas.rotateImage(clockwise: true) }
                Button("左右反転") { canvas.flipImage(horizontal: true) }
                Button("上下反転") { canvas.flipImage(horizontal: false) }
            }
            Divider()
            Section("リサイズ (\(canvas.backgroundImage.map { "\($0.width)×\($0.height)" } ?? "—"))") {
                Button("25%に縮小") { canvas.resizeCanvas(scale: 0.25) }
                Button("50%に縮小") { canvas.resizeCanvas(scale: 0.5) }
                Button("75%に縮小") { canvas.resizeCanvas(scale: 0.75) }
                Button("2倍に拡大") { canvas.resizeCanvas(scale: 2.0) }
                Divider()
                Button("1920×1080 (FHD)") { canvas.resizeToFit(width: 1920, height: 1080) }
                Button("1280×720 (HD)") { canvas.resizeToFit(width: 1280, height: 720) }
                Button("1080×1080 (正方形)") { canvas.resizeToFit(width: 1080, height: 1080) }
                Button("1200×630 (OGP)") { canvas.resizeToFit(width: 1200, height: 630) }
            }
            Divider()
            Button("余白を追加…") { showExtendCanvas = true }
            Button("余白を自動トリミング") { canvas.trimWhitespace() }
            Divider()
            Button("クリップボードの画像を下に結合") {
                if let ns = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
                   let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    canvas.stitch(with: cg, vertical: true)
                }
            }
            Button("クリップボードの画像を右に結合") {
                if let ns = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
                   let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    canvas.stitch(with: cg, vertical: false)
                }
            }
        } label: {
            Image(systemName: "photo")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 22)
        .help("回転・反転・リサイズ・結合")
        .sheet(isPresented: $showExtendCanvas) {
            extendCanvasSheet
        }
    }

    @ViewBuilder
    private var imageOnlyExportControls: some View {
        // OCR text panel — show when the current image has recognized text
        if !currentOCRText.isEmpty {
            Button { showOCRPanel.toggle() } label: {
                Image(systemName: "text.viewfinder")
                    .foregroundStyle(showOCRPanel ? Color.accentColor : Color.primary)
            }
            .help("OCRテキストを表示・コピー")
            .popover(isPresented: $showOCRPanel, arrowEdge: .bottom) {
                OCRTextPanel(text: currentOCRText)
            }
        }

        Button(action: onCopy) {
            Image(systemName: "doc.on.clipboard")
        }
        .help("クリップボードにコピー (⌘C)")
        .keyboardShortcut("c", modifiers: .command)

        Button(action: onSave) {
            Image(systemName: "square.and.arrow.down")
        }
        .help("保存 (⌘S)")
        .keyboardShortcut("s", modifiers: .command)

        Menu {
            Button("別名で保存… (⌘⇧S)") { onSaveAs() }
            Divider()
            Button("共有… (⌘⇧E)") { onShare() }
            Divider()
            Button("画面にピン留め (⌘⇧P)") { onPin() }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 22)
        .help("別名保存 / 共有 / ピン留め")

        Divider().frame(height: 18)

        Button(action: { canvas.undo() }) {
            Image(systemName: "arrow.uturn.backward")
        }
        .disabled(!canvas.canUndo)
        .help("元に戻す (⌘Z)")
        .keyboardShortcut("z", modifiers: .command)

        Button(action: { canvas.redo() }) {
            Image(systemName: "arrow.uturn.forward")
        }
        .disabled(!canvas.canRedo)
        .help("やり直し (⌘⇧Z)")
        .keyboardShortcut("z", modifiers: [.command, .shift])

        Button(action: { canvas.deleteSelectedAnnotation() }) {
            Image(systemName: "trash")
        }
        .disabled(canvas.selectedAnnotationID == nil)
        .help("削除 (⌫)")
        .keyboardShortcut(.delete, modifiers: [])

        if !canvas.annotations.isEmpty {
            Toggle(isOn: $canvas.annotationsHidden) {
                Image(systemName: canvas.annotationsHidden ? "eye.slash" : "eye")
            }
            .toggleStyle(.button)
            .help(canvas.annotationsHidden ? "アノテーション表示 (⌘')" : "アノテーション非表示 (⌘')")
            .keyboardShortcut("'", modifiers: .command)
        }

        if !canvas.annotations.isEmpty {
            let selCount = canvas.selectedAnnotationIDs.count
            Text(selCount > 1 ? "\(selCount)/\(canvas.annotations.count)" : "\(canvas.annotations.count)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(selCount > 1 ? Color.accentColor : Color.secondary)
                .monospacedDigit()
                .help(selCount > 1
                      ? "\(selCount)個選択中 / \(canvas.annotations.count)個 (⌘Aで全選択、⌫で選択削除)"
                      : "\(canvas.annotations.count)個のアノテーション (⌘Aで全選択、⌘⇧⌫で全削除)")

            if selCount > 1 {
                Divider().frame(height: 14)
                HStack(spacing: 1) {
                    ForEach([
                        ("align.horizontal.left", CanvasViewModel.AlignEdge.left, "左揃え"),
                        ("align.horizontal.center", .centerX, "中央揃え（水平）"),
                        ("align.horizontal.right", .right, "右揃え"),
                        ("align.vertical.top", .top, "上揃え"),
                        ("align.vertical.center", .centerY, "中央揃え（垂直）"),
                        ("align.vertical.bottom", .bottom, "下揃え"),
                    ], id: \.0) { icon, edge, help in
                        Button { canvas.alignSelected(edge) } label: {
                            Image(systemName: icon).font(.system(size: 9))
                        }
                        .buttonStyle(.plain)
                        .frame(width: 16, height: 16)
                        .help(help)
                    }
                }
            }
        }

        Menu {
            if !canvas.annotations.isEmpty {
                Button("現在のアノテーションをテンプレートとして保存…") {
                    templateNameInput = ""
                    showSaveTemplate = true
                }
                if !settings.annotationTemplates.isEmpty { Divider() }
            }
            if settings.annotationTemplates.isEmpty {
                Text("テンプレートなし").foregroundStyle(.secondary)
            } else {
                ForEach(settings.annotationTemplates) { t in
                    Menu(t.name) {
                        Button("適用（追加）") {
                            for var ann in t.annotations {
                                ann.id = UUID()
                                canvas.addAnnotation(ann)
                            }
                        }
                        Button("削除", role: .destructive) {
                            settings.deleteTemplate(id: t.id)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "square.on.square.dashed")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 22)
        .help("アノテーションテンプレート")
        .alert("テンプレート名を入力", isPresented: $showSaveTemplate) {
            TextField("テンプレート名", text: $templateNameInput)
            Button("保存") {
                let name = templateNameInput.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                settings.saveTemplate(name: name, annotations: canvas.annotations)
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("現在の\(canvas.annotations.count)個のアノテーションを保存します")
        }
    }

    @ViewBuilder
    private var colorPalettePopover: some View {
        VStack(spacing: 8) {
            // 8 standard colors
            HStack(spacing: 6) {
                ForEach(Array(AnnotationColor.allCases.enumerated()), id: \.element) { idx, color in
                    Button(action: {
                        canvas.currentColor = color
                        canvas.currentCustomColorHex = nil
                        canvas.applyCurrentColorToSelection()
                        canvas.applyCustomColorToSelection(hex: nil)
                    }) {
                        ZStack {
                            Circle().fill(color.color).frame(width: 18, height: 18)
                                .overlay(Circle().stroke(Color.primary.opacity(color == .white ? 0.3 : 0), lineWidth: 0.5))
                            if canvas.currentColor == color && canvas.currentCustomColorHex == nil {
                                Circle().stroke(Color.primary.opacity(0.8), lineWidth: 2).frame(width: 23, height: 23)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(width: 24, height: 24)
                    .help("\(color.rawValue) (\(idx + 1))")
                }
            }
            if !settings.recentCustomColors.isEmpty {
                Divider()
                HStack(spacing: 6) {
                    ForEach(settings.recentCustomColors.prefix(6), id: \.self) { hex in
                        Button(action: {
                            canvas.currentCustomColorHex = hex
                            canvas.applyCustomColorToSelection(hex: hex)
                        }) {
                            ZStack {
                                if let c = ColorWellView.hexToNSColor(hex) {
                                    Circle().fill(Color(nsColor: c)).frame(width: 18, height: 18)
                                        .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                                }
                                if canvas.currentCustomColorHex == hex {
                                    Circle().stroke(Color.primary.opacity(0.8), lineWidth: 2).frame(width: 23, height: 23)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .frame(width: 24, height: 24)
                    }
                }
            }
            Divider()
            HStack(spacing: 8) {
                ColorWellView(colorHex: $canvas.currentCustomColorHex) { hex in
                    canvas.currentCustomColorHex = hex
                    canvas.applyCustomColorToSelection(hex: hex)
                    if let hex { settings.addRecentCustomColor(hex) }
                }
                .frame(width: 28, height: 22)
                .cornerRadius(4)
                Text("カスタムカラー")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                // Line width — show for drawing tools, or when an annotation is selected (select tool)
                if canvas.currentTool.usesLineWidth || canvas.selectedAnnotationID != nil {
                    Picker("", selection: $canvas.currentLineWidth) {
                        Text("S").tag(LineWidth.thin)
                        Text("M").tag(LineWidth.medium)
                        Text("L").tag(LineWidth.thick)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 60)
                    .onChange(of: canvas.currentLineWidth) { _, _ in canvas.applyCurrentLineWidthToSelection() }
                }
            }
            HStack(spacing: 8) {
                // Opacity
                HStack(spacing: 4) {
                    Image(systemName: "circle.lefthalf.filled").font(.system(size: 9)).foregroundStyle(.secondary)
                    Slider(value: $canvas.currentOpacity, in: 0.1...1.0, step: 0.05)
                        .frame(width: 80).controlSize(.mini)
                        .onChange(of: canvas.currentOpacity) { _, _ in canvas.applyCurrentOpacityToSelection() }
                    Text("\(Int(canvas.currentOpacity * 100))%")
                        .font(.system(size: 9, design: .monospaced)).frame(width: 28)
                }
                Spacer()
                // Line style — only when line controls are relevant
                if canvas.currentTool.usesLineWidth || canvas.selectedAnnotationID != nil {
                    Picker("", selection: $canvas.currentLineStyle) {
                        LineStylePreview(style: .solid).tag(LineStyle.solid)
                        LineStylePreview(style: .dashed).tag(LineStyle.dashed)
                        LineStylePreview(style: .dotted).tag(LineStyle.dotted)
                    }
                    .pickerStyle(.segmented).frame(width: 72)
                    .onChange(of: canvas.currentLineStyle) { _, _ in canvas.applyCurrentLineStyleToSelection() }
                }
            }
        }
        .padding(10)
        .frame(width: 320)
    }

    @ViewBuilder
    private var normalControlsExport: some View {
        Spacer()

        if canvas.backgroundImage != nil { imageOnlyExportControls }

        Button(action: { showHelp.toggle() }) {
            Image(systemName: "questionmark.circle")
        }
        .help("ショートカットキー一覧")
        .popover(isPresented: $showHelp, arrowEdge: .bottom) {
            HelpPopoverContent()
        }

        Button(action: { showSettings.toggle() }) {
            Image(systemName: "gearshape")
        }
        .help("設定 (⌘,)")
        .keyboardShortcut(",", modifiers: .command)
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
        }

        Button(action: { withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible.toggle() } }) {
            Image(systemName: sidebarVisible ? "sidebar.right" : "sidebar.right")
                .symbolVariant(sidebarVisible ? .none : .slash)
        }
        .help("履歴を表示/非表示 (⌘⇧H)")
        .keyboardShortcut("h", modifiers: [.command, .shift])
    }

    private var adjustmentsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("画像調整").font(.headline).padding(.bottom, 2)
            HStack {
                Text("明るさ").frame(width: 60, alignment: .trailing)
                Slider(value: $canvas.adjustBrightness, in: -0.5...0.5)
                    .frame(width: 140)
                Text(String(format: "%+.2f", canvas.adjustBrightness))
                    .font(.system(size: 10, design: .monospaced)).frame(width: 36)
            }
            HStack {
                Text("コントラスト").frame(width: 60, alignment: .trailing)
                Slider(value: $canvas.adjustContrast, in: 0.5...2.0)
                    .frame(width: 140)
                Text(String(format: "%.2f", canvas.adjustContrast))
                    .font(.system(size: 10, design: .monospaced)).frame(width: 36)
            }
            HStack {
                Text("彩度").frame(width: 60, alignment: .trailing)
                Slider(value: $canvas.adjustSaturation, in: 0.0...2.0)
                    .frame(width: 140)
                Text(String(format: "%.2f", canvas.adjustSaturation))
                    .font(.system(size: 10, design: .monospaced)).frame(width: 36)
            }
            HStack {
                Text("シャープ").frame(width: 60, alignment: .trailing)
                Slider(value: $canvas.adjustSharpness, in: 0.0...1.0)
                    .frame(width: 140)
                Text(String(format: "%.2f", canvas.adjustSharpness))
                    .font(.system(size: 10, design: .monospaced)).frame(width: 36)
            }
            HStack {
                Button("リセット") { canvas.resetAdjustments() }
                    .controlSize(.small)
                Spacer()
                Button("適用") { canvas.bakeAdjustments(); showAdjustments = false }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    @ViewBuilder
    private func extendPaddingRow(label: String, value: Binding<CGFloat>) -> some View {
        HStack {
            Text(label).frame(width: 60, alignment: .leading)
            Slider(value: value, in: 0...500, step: 10)
            Text("\(Int(value.wrappedValue))")
                .frame(width: 36, alignment: .trailing)
                .font(.system(size: 12, design: .monospaced))
        }
    }

    private var extendCanvasSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("余白を追加").font(.headline)

            Toggle("全方向に同じ余白", isOn: $extendSymmetric)

            if extendSymmetric {
                HStack {
                    Text("余白 (px)")
                        .frame(width: 80, alignment: .leading)
                    Slider(value: $extendAll, in: 0...500, step: 10)
                    Text("\(Int(extendAll))")
                        .frame(width: 36, alignment: .trailing)
                        .font(.system(size: 12, design: .monospaced))
                }
            } else {
                extendPaddingRow(label: "上 (px)", value: $extendTop)
                extendPaddingRow(label: "右 (px)", value: $extendRight)
                extendPaddingRow(label: "下 (px)", value: $extendBottom)
                extendPaddingRow(label: "左 (px)", value: $extendLeft)
            }

            Divider()

            HStack {
                Text("背景色")
                    .frame(width: 80, alignment: .leading)
                Picker("", selection: $extendBgChoice) {
                    Text("白").tag(0)
                    Text("黒").tag(1)
                    Text("透明").tag(2)
                }
                .pickerStyle(.segmented)
            }

            HStack {
                Spacer()
                Button("キャンセル") { showExtendCanvas = false }
                    .keyboardShortcut(.cancelAction)
                Button("追加") {
                    let t = extendSymmetric ? extendAll : extendTop
                    let r = extendSymmetric ? extendAll : extendRight
                    let b = extendSymmetric ? extendAll : extendBottom
                    let l = extendSymmetric ? extendAll : extendLeft
                    let cgColor: CGColor
                    switch extendBgChoice {
                    case 1:  cgColor = CGColor(gray: 0, alpha: 1)
                    case 2:  cgColor = CGColor(gray: 0, alpha: 0)
                    default: cgColor = CGColor(gray: 1, alpha: 1)
                    }
                    canvas.extendCanvas(top: t, right: r, bottom: b, left: l, bgColor: cgColor)
                    showExtendCanvas = false
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private var decorationPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("書き出し装飾").font(.headline)
                Spacer()
                Toggle("", isOn: $canvas.decorationEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .padding(.bottom, 2)
            Divider()

            // Live mini-preview
            let isEnabled = canvas.decorationEnabled
            let padFrac = isEnabled ? min(canvas.decorationPadding / 120, 1.0) : 0.0
            let cornerR = isEnabled ? canvas.decorationCornerRadius * 2 : 0.0
            let showShadow = isEnabled && canvas.decorationShadow
            let gradIdx = max(0, min(CanvasViewModel.gradientPresets.count - 1, canvas.decorationGradientIndex))
            let (gc1, gc2) = CanvasViewModel.gradientPresets[gradIdx]

            HStack {
                Spacer()
                ZStack {
                    // Outer bg
                    let outerW = 160 + padFrac * 30
                    let outerH = 90 + padFrac * 20
                    Group {
                        switch canvas.decorationBackgroundStyle {
                        case 1:
                            RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.15))
                        case 2:
                            RoundedRectangle(cornerRadius: 6)
                                .fill(LinearGradient(
                                    colors: [Color(cgColor: gc1), Color(cgColor: gc2)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                        case 3:
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.secondary.opacity(0.12))
                                .overlay(RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4,2]))
                                    .foregroundStyle(.secondary.opacity(0.4)))
                        case 4:
                            RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.3))
                                .overlay(Image(systemName: "photo.fill")
                                    .font(.system(size: 18)).foregroundStyle(.secondary.opacity(0.5)))
                        default:
                            RoundedRectangle(cornerRadius: 6).fill(Color.white)
                        }
                    }
                    .frame(width: outerW, height: outerH)

                    // Inner image representation
                    RoundedRectangle(cornerRadius: cornerR)
                        .fill(Color.accentColor.opacity(0.15))
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerR)
                                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                        )
                        .frame(width: 160, height: 90)
                        .shadow(color: showShadow ? .black.opacity(0.3) : .clear,
                                radius: showShadow ? 8 : 0, y: showShadow ? 4 : 0)
                        .overlay(
                            Text("プレビュー")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        )
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                Spacer()
            }
            .animation(.easeOut(duration: 0.2), value: canvas.decorationPadding)
            .animation(.easeOut(duration: 0.2), value: canvas.decorationCornerRadius)
            .animation(.easeOut(duration: 0.15), value: canvas.decorationShadow)
            .animation(.easeOut(duration: 0.15), value: canvas.decorationBackgroundStyle)
            .animation(.easeOut(duration: 0.15), value: canvas.decorationGradientIndex)
            .opacity(isEnabled ? 1 : 0.4)

            Divider()

            Group {
                HStack {
                    Text("背景").frame(width: 70, alignment: .trailing)
                    Picker("", selection: $canvas.decorationBackgroundStyle) {
                        Text("白").tag(0)
                        Text("暗").tag(1)
                        Text("グラデ").tag(2)
                        Text("透明").tag(3)
                        Text("壁紙").tag(4)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                }
                if canvas.decorationBackgroundStyle == 2 {
                    gradientSwatchRow
                }
                HStack {
                    Text("パディング").frame(width: 70, alignment: .trailing)
                    Slider(value: $canvas.decorationPadding, in: 0...120, step: 4)
                        .frame(width: 130)
                    Text("\(Int(canvas.decorationPadding))px")
                        .font(.system(size: 10, design: .monospaced)).frame(width: 36)
                }
                HStack {
                    Text("角丸").frame(width: 70, alignment: .trailing)
                    Slider(value: $canvas.decorationCornerRadius, in: 0...40, step: 2)
                        .frame(width: 130)
                    Text("\(Int(canvas.decorationCornerRadius))px")
                        .font(.system(size: 10, design: .monospaced)).frame(width: 36)
                }
                Toggle("ドロップシャドウ", isOn: $canvas.decorationShadow)
            }
            .disabled(!canvas.decorationEnabled)
            .opacity(canvas.decorationEnabled ? 1 : 0.4)
        }
        .padding(14)
        .frame(width: 320)
    }

    @ViewBuilder
    private var gradientSwatchRow: some View {
        HStack {
            Text("色").frame(width: 70, alignment: .trailing)
            HStack(spacing: 5) {
                ForEach(CanvasViewModel.gradientPresets.indices, id: \.self) { idx in
                    gradientSwatch(idx: idx)
                }
            }
        }
    }

    @ViewBuilder
    private func gradientSwatch(idx: Int) -> some View {
        let (c1, c2) = CanvasViewModel.gradientPresets[idx]
        let isSelected = canvas.decorationGradientIndex == idx
        ZStack {
            LinearGradient(colors: [Color(cgColor: c1), Color(cgColor: c2)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .clipShape(Circle())
            if isSelected {
                Circle().strokeBorder(Color.white, lineWidth: 2)
                Circle().strokeBorder(Color.accentColor, lineWidth: 1.5).padding(1)
            }
        }
        .frame(width: 22, height: 22)
        .onTapGesture { canvas.decorationGradientIndex = idx }
        .shadow(color: .black.opacity(0.2), radius: 2)
    }

    @ViewBuilder
    private func toolButton(_ tool: DrawingTool, canvas: CanvasViewModel) -> some View {
        let isSelected = canvas.currentTool == tool
        Button(action: { canvas.currentTool = tool }) {
            Image(systemName: tool.systemImage)
                .frame(width: 22, height: 22)
                .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .help(tool.helpText)
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
    }
}

// MARK: - OCR Text Panel

struct OCRTextPanel: View {
    let text: String
    @State private var copiedAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("OCRテキスト")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    withAnimation { copiedAll = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedAll = false }
                } label: {
                    Label(copiedAll ? "コピー済" : "全コピー",
                          systemImage: copiedAll ? "checkmark" : "doc.on.clipboard")
                        .font(.system(size: 10))
                        .foregroundStyle(copiedAll ? Color.green : Color.accentColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            ScrollView(.vertical, showsIndicators: true) {
                // Use TextEditor for native selectable text
                TextEditor(text: .constant(text))
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 80)
                    .padding(8)
            }
            .frame(width: 340, height: 220)
        }
    }
}

// MARK: - Hint Row

// MARK: - Color Well View

struct ColorWellView: NSViewRepresentable {
    @Binding var colorHex: String?
    var onColorPicked: (String?) -> Void

    func makeNSView(context: Context) -> NSColorWell {
        let well = NSColorWell(style: .minimal)
        well.isBordered = false
        well.color = colorHex.flatMap { Self.hexToNSColor($0) } ?? .red
        well.target = context.coordinator
        well.action = #selector(Coordinator.colorChanged(_:))
        return well
    }

    func updateNSView(_ nsView: NSColorWell, context: Context) {
        context.coordinator.onColorPicked = onColorPicked
        if let hex = colorHex, let c = Self.hexToNSColor(hex) {
            nsView.color = c
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onColorPicked: onColorPicked) }

    static func hexToNSColor(_ hex: String) -> NSColor? {
        guard hex.count == 8,
              let r = UInt8(hex.prefix(2), radix: 16),
              let g = UInt8(hex.dropFirst(2).prefix(2), radix: 16),
              let b = UInt8(hex.dropFirst(4).prefix(2), radix: 16),
              let a = UInt8(hex.dropFirst(6).prefix(2), radix: 16) else { return nil }
        return NSColor(red: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: CGFloat(a)/255)
    }

    static func nsColorToHex(_ c: NSColor) -> String {
        let rgb = c.usingColorSpace(.sRGB) ?? c
        let r = UInt8(max(0, min(255, rgb.redComponent * 255)))
        let g = UInt8(max(0, min(255, rgb.greenComponent * 255)))
        let b = UInt8(max(0, min(255, rgb.blueComponent * 255)))
        let a = UInt8(max(0, min(255, rgb.alphaComponent * 255)))
        return String(format: "%02X%02X%02X%02X", r, g, b, a)
    }

    class Coordinator: NSObject {
        var onColorPicked: (String?) -> Void
        init(onColorPicked: @escaping (String?) -> Void) { self.onColorPicked = onColorPicked }

        @objc func colorChanged(_ sender: NSColorWell) {
            let hex = ColorWellView.nsColorToHex(sender.color)
            onColorPicked(hex)
        }
    }
}

struct LineStylePreview: View {
    let style: LineStyle
    var body: some View {
        Canvas { ctx, size in
            let y = size.height / 2
            var path = Path()
            path.move(to: CGPoint(x: 3, y: y))
            path.addLine(to: CGPoint(x: size.width - 3, y: y))
            let dash: [CGFloat] = {
                switch style {
                case .solid: return []
                case .dashed: return [4, 3]
                case .dotted: return [1.5, 3]
                }
            }()
            ctx.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 1.5, lineCap: style == .dotted ? .round : .butt, dash: dash))
        }
        .frame(width: 22, height: 14)
    }
}
