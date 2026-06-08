// App.swift
// SnapLocal - App Entry Point

import SwiftUI
import CoreGraphics
import AppKit
import OSLog
import UserNotifications

private let logger = Logger(subsystem: "com.snaplocal.app", category: "App")

@main
struct SnapLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appSettings) {
                // Remove default settings menu
            }
        }
    }

}

// AppDelegate to ensure window is properly configured and in foreground
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        logger.debug("applicationWillFinishLaunching called")
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.debug("applicationDidFinishLaunching called")
        NSApp.activate(ignoringOtherApps: true)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        
        // Ensure main window appears on screen with proper level
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if let mainWindow = NSApplication.shared.mainWindow {
                mainWindow.level = .normal
                mainWindow.makeKeyAndOrderFront(nil)
                mainWindow.orderFrontRegardless()
                logger.debug("Main window configured: \(mainWindow)")
            } else {
                logger.warning("Main window not yet available")
                // Try again in next run loop
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if let mainWindow = NSApplication.shared.mainWindow {
                        mainWindow.level = .normal
                        mainWindow.makeKeyAndOrderFront(nil)
                        mainWindow.orderFrontRegardless()
                        logger.debug("Main window configured (retry): \(mainWindow)")
                    }
                }
            }
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
@MainActor
final class SnapLocalState: ObservableObject, @unchecked Sendable {
    @Published var statusMessage = ""
    @Published var statusVisible = false
    @Published var history: [VaultItem] = []
    @Published var searchQuery = ""
    @Published var isRegionCapturing = false

    var canvas = CanvasViewModel()
    private let vault: PersistentVault
    private var captureEngine: CaptureEngine?
    private var statusTask: Task<Void, Never>?
    // ID of the VaultItem currently shown on canvas (for annotation save-back)
    private var currentVaultID: UUID?

    init() {
        vault = PersistentVault(directory: SettingsManager.shared.saveDirectoryURL)
        let hotkey = SettingsManager.shared.hotkeyConfig
        captureEngine = CaptureEngine(hotkey: hotkey) { [weak self] result in
            Task { @MainActor in
                self?.handleCaptureResult(result)
            }
        }
        captureEngine?.registerHotkey()
        refreshHistory()
    }

    // MARK: - Status

    func showStatus(_ message: String) {
        statusTask?.cancel()
        statusMessage = message
        statusVisible = true
        statusTask = Task {
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                statusVisible = false
            } catch {}
        }
    }

    // MARK: - Capture

    func captureNow() {
        showStatus("撮影中…")
        captureEngine?.captureScreen()
    }

    func captureRegion() {
        isRegionCapturing = true
        showStatus("範囲を選択 — ドラッグして選択")
        RegionCapture.start { [weak self] rect in
            guard let self else { return }
            self.isRegionCapturing = false
            guard let rect else {
                self.showStatus("キャンセルしました")
                return
            }
            self.showStatus("撮影中…")
            self.captureEngine?.captureRegion(rect)
        }
    }

    func acceptCapture(_ image: CGImage) {
        canvas.backgroundImage = image
        canvas.annotations.removeAll()
        currentVaultID = nil
        copyImageToClipboard(image)
        showStatus("撮影 → クリップボードにコピーしました")
        sendNotification(title: "撮影完了", body: "クリップボードにコピーしました")
        Task {
            guard let item = await vault.save(image: image) else { return }
            currentVaultID = item.id
            await loadHistory()
            // Run OCR in background, update when done
            let ocrText = await OCRService.recognizeText(in: image)
            if !ocrText.isEmpty {
                await vault.updateOCR(id: item.id, text: ocrText)
                await loadHistory()
                showStatus("OCR完了 — 検索可能になりました")
            }
        }
    }

    // MARK: - Clipboard

    func pasteFromClipboard() {
        guard let nsImage = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            showStatus("クリップボードに画像がありません")
            return
        }
        acceptCapture(cgImage)
    }

    func copyToClipboard() {
        guard let image = canvas.renderAnnotations() ?? canvas.backgroundImage else {
            showStatus("コピーする画像がありません")
            return
        }
        copyImageToClipboard(image)
        showStatus("クリップボードにコピーしました")
    }

    private func copyImageToClipboard(_ image: CGImage) {
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([nsImage])
    }

    // MARK: - Capture result

    func handleCaptureResult(_ result: Result<CGImage, Error>) {
        switch result {
        case .success(let image):
            acceptCapture(image)
        case .failure(let error):
            showStatus(Self.captureFailureMessage(for: error))
        }
    }

    func deleteHistoryItem(_ item: VaultItem) {
        Task {
            await vault.delete(id: item.id)
            await loadHistory()
        }
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func captureFailureMessage(for error: Error) -> String {
        if case CaptureError.permissionDenied = error {
            return "画面録画権限が必要です"
        }
        let nsError = error as NSError
        return "撮影失敗: \(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
    }

    // MARK: - History

    func loadHistoryItem(_ item: VaultItem) {
        guard let cgImage = cgImage(from: item.imageData) else { return }
        canvas.resetAndLoad(image: cgImage, annotations: item.annotations)
        currentVaultID = item.id
        showStatus("履歴を読み込みました")
    }

    private func cgImage(from data: Data) -> CGImage? {
        NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    // MARK: - Save

    func saveAnnotatedImage() {
        guard let image = canvas.renderAnnotations() ?? canvas.backgroundImage,
              let data = pngData(from: image) else {
            showStatus("保存できる画像がありません")
            return
        }

        // Save-back annotations to vault if this is an existing vault item
        if let id = currentVaultID {
            Task { await vault.updateAnnotations(id: id, annotations: canvas.annotations) }
        }

        do {
            let directory = SettingsManager.shared.saveDirectoryURL
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let url = directory.appendingPathComponent("SnapLocal-\(formatter.string(from: Date())).png")
            try data.write(to: url, options: .atomic)
            showStatus("保存しました: \(url.lastPathComponent)")
            refreshHistory()
        } catch {
            showStatus("保存失敗: \(error.localizedDescription)")
        }
    }

    func refreshHistory() {
        Task { await loadHistory() }
    }

    private func loadHistory() async {
        let q = searchQuery
        let items = q.isEmpty ? await vault.allItems() : await vault.search(query: q)
        history = items
    }

    func applySearch() {
        Task { await loadHistory() }
    }

    private func pngData(from image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

// MARK: - Compact Toolbar

struct CompactToolbar: View {
    @ObservedObject var canvas: CanvasViewModel
    let onCapture: () -> Void
    let onCaptureRegion: () -> Void
    let onSave: () -> Void
    let onCopy: () -> Void
    let onPaste: () -> Void

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
    }

    private var cropModeControls: some View {
        HStack(spacing: 8) {
            Image(systemName: "crop")
                .foregroundStyle(Color.accentColor)
            Text("切り取りモード — ドラッグで範囲選択")
                .font(.caption)
                .foregroundStyle(.secondary)
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

            Button(action: onPaste) {
                Image(systemName: "doc.on.clipboard.fill")
            }
            .help("クリップボードから貼り付け (⌘V)")
            .keyboardShortcut("v", modifiers: .command)

            Button(action: { canvas.enterCropMode() }) {
                Image(systemName: "scissors")
            }
            .help("画像を切り取り (⌘K)")
            .disabled(canvas.backgroundImage == nil)
            .keyboardShortcut("k", modifiers: .command)

            Button(action: onCopy) {
                Image(systemName: "doc.on.clipboard")
            }
            .help("クリップボードにコピー (⌘C)")
            .disabled(canvas.backgroundImage == nil)
            .keyboardShortcut("c", modifiers: .command)

            Button(action: onSave) {
                Image(systemName: "square.and.arrow.down")
            }
            .help("保存 (⌘S)")
            .disabled(canvas.backgroundImage == nil)
            .keyboardShortcut("s", modifiers: .command)

            Divider().frame(height: 18)

            Picker("", selection: $canvas.currentTool) {
                ForEach(DrawingTool.allCases, id: \.self) { tool in
                    Image(systemName: tool.systemImage).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)

            if canvas.currentTool == .redact {
                Picker("", selection: $canvas.currentRedactMode) {
                    ForEach(RedactMode.allCases, id: \.self) { mode in
                        Image(systemName: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 60)
                .help("モザイク / ぼかし")
            }

            Divider().frame(height: 18)

            ForEach(AnnotationColor.allCases, id: \.self) { color in
                Button(action: { canvas.currentColor = color }) {
                    ZStack {
                        Circle()
                            .fill(color.color)
                            .frame(width: 12, height: 12)
                            .overlay(
                                Circle()
                                    .stroke(Color.primary.opacity(color == .white ? 0.3 : 0), lineWidth: 0.5)
                                    .frame(width: 12, height: 12)
                            )
                        if canvas.currentColor == color {
                            Circle()
                                .stroke(Color.primary.opacity(0.8), lineWidth: 2)
                                .frame(width: 17, height: 17)
                        }
                    }
                }
                .buttonStyle(.plain)
                .frame(width: 18, height: 18)
                .help(color.rawValue)
            }

            Divider().frame(height: 18)

            Picker("", selection: $canvas.currentLineWidth) {
                Text("S").tag(LineWidth.thin)
                Text("M").tag(LineWidth.medium)
                Text("L").tag(LineWidth.thick)
            }
            .pickerStyle(.segmented)
            .frame(width: 76)
            .disabled(!canvas.currentTool.usesLineWidth)
            .opacity(canvas.currentTool.usesLineWidth ? 1.0 : 0.5)

            Spacer()

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
        }
    }
}

// MARK: - History Rail

struct HistoryRail: View {
    let history: [VaultItem]
    @Binding var searchQuery: String
    let onSelect: (VaultItem) -> Void
    let onDelete: (VaultItem) -> Void
    let onRefresh: () -> Void
    let onSearch: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("検索", text: $searchQuery)
                    .font(.caption2)
                    .textFieldStyle(.plain)
                    .onChange(of: searchQuery) { _, _ in onSearch() }
                if !searchQuery.isEmpty {
                    Button(action: { searchQuery = ""; onSearch() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial)

            Divider()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(history) { item in
                        Button(action: { onSelect(item) }) {
                            VStack(spacing: 2) {
                                Group {
                                    if let nsImage = NSImage(data: item.thumbnailData) {
                                        Image(nsImage: nsImage)
                                            .resizable()
                                            .scaledToFill()
                                    } else {
                                        Image(systemName: item.level.systemImage)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: 58, height: 38)
                                .clipShape(RoundedRectangle(cornerRadius: 4))

                                if !item.ocrText.isEmpty && !searchQuery.isEmpty {
                                    Text(item.ocrText)
                                        .font(.system(size: 7))
                                        .lineLimit(2)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 58, alignment: .leading)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("削除", role: .destructive) { onDelete(item) }
                            Button("クリップボードにコピー") { onSelect(item) }
                        }
                        .help(item.createdAt.formatted(date: .abbreviated, time: .shortened)
                              + (item.ocrText.isEmpty ? "" : "\n" + String(item.ocrText.prefix(60))))
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }

            Divider()
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 4)
        }
        .frame(width: 80)
        .background(.regularMaterial)
    }
}

// MARK: - Status Chip

struct StatusChip: View {
    let message: String
    let visible: Bool

    var body: some View {
        if visible {
            Text(message)
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

// MARK: - Content View

struct ContentView: View {
    @StateObject private var state = SnapLocalState()

    var body: some View {
        VStack(spacing: 0) {
            CompactToolbar(
                canvas: state.canvas,
                onCapture: state.captureNow,
                onCaptureRegion: state.captureRegion,
                onSave: state.saveAnnotatedImage,
                onCopy: state.copyToClipboard,
                onPaste: state.pasteFromClipboard
            )
            Divider()
            HStack(spacing: 0) {
                AnnotationCanvasView(
                    viewModel: state.canvas,
                    onCapture: state.captureNow,
                    onOpenPermissions: state.openScreenRecordingSettings
                )
                    .frame(minWidth: 600, minHeight: 400)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .overlay(alignment: .bottom) {
                        StatusChip(message: state.statusMessage, visible: state.statusVisible)
                            .padding(.bottom, 14)
                            .animation(.easeInOut(duration: 0.2), value: state.statusVisible)
                    }

                Divider()
                HistoryRail(
                    history: state.history,
                    searchQuery: $state.searchQuery,
                    onSelect: state.loadHistoryItem,
                    onDelete: state.deleteHistoryItem,
                    onRefresh: state.refreshHistory,
                    onSearch: state.applySearch
                )
            }
        }
    }
}

// MARK: - Canvas View

struct AnnotationCanvasView: View {
    @ObservedObject var viewModel: CanvasViewModel
    var onCapture: (() -> Void)? = nil
    var onOpenPermissions: (() -> Void)? = nil

    @FocusState private var textFieldFocused: Bool
    @FocusState private var canvasFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image = viewModel.backgroundImage {
                    Image(decorative: image, scale: 1.0, orientation: .up)
                        .resizable()
                        .scaledToFit()
                    annotationLayer(size: proxy.size)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 56))
                            .foregroundStyle(.secondary)
                        Text("撮影するとここに編集キャンバスが表示されます")
                            .foregroundStyle(.secondary)
                        if let onCapture = onCapture {
                            Button("撮影する", action: onCapture)
                                .buttonStyle(.borderedProminent)
                        }
                        if let onOpenPermissions = onOpenPermissions {
                            Button("画面録画の設定を開く", action: onOpenPermissions)
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(in: proxy.frame(in: .local)))
            .onAppear { viewModel.canvasSize = proxy.size }
            .onChange(of: proxy.size) { _, newSize in viewModel.canvasSize = newSize }
            .overlay(textInputOverlay)
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
            .onKeyPress("[") {
                if !viewModel.showTextInput {
                    let all = LineWidth.allCases
                    if let i = all.firstIndex(of: viewModel.currentLineWidth), i > 0 { viewModel.currentLineWidth = all[i - 1] }
                }
                return .handled
            }
            .onKeyPress("]") {
                if !viewModel.showTextInput {
                    let all = LineWidth.allCases
                    if let i = all.firstIndex(of: viewModel.currentLineWidth), i < all.count - 1 { viewModel.currentLineWidth = all[i + 1] }
                }
                return .handled
            }
            .onKeyPress(.escape) {
                if viewModel.isCropMode { viewModel.cancelCrop(); return .handled }
                if viewModel.showTextInput { viewModel.cancelTextInput(); return .handled }
                if viewModel.selectedAnnotationID != nil {
                    viewModel.selectedAnnotationID = nil
                    viewModel.objectWillChange.send()
                    return .handled
                }
                return .ignored
            }
        }
    }

    private func annotationLayer(size: CGSize) -> some View {
        Canvas { context, _ in
            let canvasRect = CGRect(origin: .zero, size: size)

            // Crop mode: draw only the crop selection overlay
            if viewModel.isCropMode {
                if let start = viewModel.cropStart, let end = viewModel.cropEnd {
                    let sel = CGRect(
                        x: min(start.x, end.x), y: min(start.y, end.y),
                        width: abs(end.x - start.x), height: abs(end.y - start.y)
                    )
                    let dim = Color.black.opacity(0.45)
                    // Four dark panels around selection
                    context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: sel.minY)), with: .color(dim))
                    context.fill(Path(CGRect(x: 0, y: sel.maxY, width: size.width, height: size.height - sel.maxY)), with: .color(dim))
                    context.fill(Path(CGRect(x: 0, y: sel.minY, width: sel.minX, height: sel.height)), with: .color(dim))
                    context.fill(Path(CGRect(x: sel.maxX, y: sel.minY, width: size.width - sel.maxX, height: sel.height)), with: .color(dim))
                    // Selection border
                    context.stroke(Path(sel), with: .color(.white), lineWidth: 1.5)
                    // Rule-of-thirds grid inside selection
                    let dash = StrokeStyle(lineWidth: 0.5, dash: [4, 3])
                    for i in [1, 2] {
                        let x = sel.minX + sel.width * CGFloat(i) / 3
                        let y = sel.minY + sel.height * CGFloat(i) / 3
                        var lv = Path(); lv.move(to: CGPoint(x: x, y: sel.minY)); lv.addLine(to: CGPoint(x: x, y: sel.maxY))
                        var lh = Path(); lh.move(to: CGPoint(x: sel.minX, y: y)); lh.addLine(to: CGPoint(x: sel.maxX, y: y))
                        context.stroke(lv, with: .color(.white.opacity(0.5)), style: dash)
                        context.stroke(lh, with: .color(.white.opacity(0.5)), style: dash)
                    }
                    // Corner handles
                    let h: CGFloat = 10
                    for corner in [CGPoint(x: sel.minX, y: sel.minY), CGPoint(x: sel.maxX, y: sel.minY),
                                   CGPoint(x: sel.minX, y: sel.maxY), CGPoint(x: sel.maxX, y: sel.maxY)] {
                        context.fill(Path(CGRect(x: corner.x - h/2, y: corner.y - h/2, width: h, height: h).insetBy(dx: 1, dy: 1)), with: .color(.white))
                    }
                } else {
                    // No selection yet — show a hint
                    context.fill(Path(canvasRect), with: .color(.black.opacity(0.2)))
                }
                return
            }

            // Normal annotation rendering
            let beingDragged = viewModel.isDraggingAnnotation ? viewModel.selectedAnnotationID : nil

            for annotation in viewModel.annotations {
                if annotation.type == .text, let text = annotation.textContent {
                    let bounds = annotation.bounds(in: canvasRect)
                    let fontSize = max(bounds.height * 0.7, 14)
                    context.draw(
                        Text(text)
                            .font(.system(size: fontSize, weight: .semibold))
                            .foregroundColor(annotation.color.color),
                        in: bounds
                    )
                    if annotation.id == viewModel.selectedAnnotationID {
                        context.stroke(Path(bounds), with: .color(.accentColor),
                                       style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
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
                } else {
                    let path = annotation.path(in: canvasRect)
                    let lw = annotation.lineWidth.rawValue
                    let strokeStyle = StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round)
                    if annotation.id == viewModel.selectedAnnotationID {
                        context.stroke(path, with: .color(.white),
                                       style: StrokeStyle(lineWidth: lw + 4, lineCap: .round, lineJoin: .round))
                        if annotation.type == .arrow {
                            context.fill(path, with: .color(.white))
                        }
                    }
                    context.stroke(path, with: .color(annotation.color.color), style: strokeStyle)
                    if annotation.type == .arrow {
                        context.fill(path, with: .color(annotation.color.color))
                    }
                    if annotation.id == viewModel.selectedAnnotationID {
                        let bounds = annotation.bounds(in: canvasRect).insetBy(dx: -4, dy: -4)
                        context.stroke(Path(bounds), with: .color(.accentColor),
                                       style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    }
                }
            }

            // Drawing preview
            if viewModel.dragState.isDrawing,
               let start = viewModel.dragState.startPoint,
               let end = viewModel.dragState.currentPoint,
               !viewModel.isCropMode {
                let previewColor = viewModel.currentColor.color.opacity(0.75)
                let lw = viewModel.currentLineWidth.rawValue
                if viewModel.currentTool == .arrow {
                    let dx = end.x - start.x, dy = end.y - start.y
                    let length = hypot(dx, dy)
                    if length > 1 {
                        let angle = atan2(dy, dx)
                        let headLen: CGFloat = lw * 4 + 12
                        let headAngle: CGFloat = .pi / 5.5
                        let shaftEnd = length > headLen
                            ? CGPoint(x: end.x - headLen * cos(angle), y: end.y - headLen * sin(angle))
                            : start
                        var p = Path()
                        p.move(to: start)
                        p.addLine(to: shaftEnd)
                        p.move(to: end)
                        p.addLine(to: CGPoint(x: end.x - headLen * cos(angle - headAngle),
                                              y: end.y - headLen * sin(angle - headAngle)))
                        p.addLine(to: CGPoint(x: end.x - headLen * cos(angle + headAngle),
                                              y: end.y - headLen * sin(angle + headAngle)))
                        p.closeSubpath()
                        context.stroke(p, with: .color(previewColor), lineWidth: lw)
                        context.fill(p, with: .color(previewColor))
                    }
                } else {
                    var preview = Path()
                    switch viewModel.currentTool {
                    case .line:
                        preview.move(to: start)
                        preview.addLine(to: end)
                    case .rectangle, .redact:
                        preview = Path(CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                             width: abs(end.x - start.x), height: abs(end.y - start.y)))
                    case .ellipse:
                        preview = Path(ellipseIn: CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                                         width: abs(end.x - start.x), height: abs(end.y - start.y)))
                    default: break
                    }
                    if !preview.isEmpty {
                        context.stroke(preview, with: .color(previewColor),
                                       style: StrokeStyle(lineWidth: lw, dash: [4, 2]))
                    }
                }
            }
        }
    }

    private func dragGesture(in rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if viewModel.dragState.isDrawing {
                    viewModel.handleDragUpdate(at: value.location, in: rect)
                } else {
                    canvasFocused = true
                    viewModel.handleDragStart(at: value.location, in: rect)
                }
            }
            .onEnded { value in
                viewModel.handleDragEnd(at: value.location, in: rect)
            }
    }

    @ViewBuilder
    private var textInputOverlay: some View {
        if viewModel.showTextInput {
            TextField("テキスト", text: $viewModel.textInputString)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14, weight: .medium))
                .frame(width: viewModel.textInputRect.width)
                .position(x: viewModel.textInputRect.midX, y: viewModel.textInputRect.midY)
                .focused($textFieldFocused)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        textFieldFocused = true
                    }
                }
                .onSubmit { viewModel.confirmTextInput() }
                .onExitCommand { viewModel.cancelTextInput() }
        }
    }
}
