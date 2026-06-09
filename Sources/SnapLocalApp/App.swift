// App.swift
// SnapLocal - App Entry Point

import SwiftUI
import CoreGraphics
import AppKit
import OSLog
import UserNotifications
import UniformTypeIdentifiers
import ScreenCaptureKit
import PDFKit

private let logger = Logger(subsystem: "com.snaplocal.app", category: "App")

@main
struct SnapLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = SnapLocalState()

    var body: some Scene {
        WindowGroup {
            ContentView(state: appState)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appSettings) {}
        }

        MenuBarExtra("SnapLocal", systemImage: "camera.viewfinder") {
            MenuBarQuickActions(state: appState)
        }
        .menuBarExtraStyle(.menu)
    }
}

// MARK: - Menu Bar Quick Actions

struct MenuBarQuickActions: View {
    @ObservedObject var state: SnapLocalState

    var body: some View {
        Button("全画面撮影 (⌘⇧2)") { state.captureNow() }
        Button("範囲選択撮影 (⌘⇧4)") { state.captureRegion() }
        Button("前回の範囲を再撮影 (⌘⇧R)") { state.repeatLastRegionCapture() }
        Button("ウィンドウ撮影 (⌘⇧3)") { state.captureWindowMode() }
        Divider()
        Menu("遅延撮影") {
            Button("3秒後") { state.captureWithDelay(3) }
            Button("5秒後") { state.captureWithDelay(5) }
            Button("10秒後") { state.captureWithDelay(10) }
        }
        Divider()
        Button("SnapLocalを表示") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        Divider()
        Button("終了") { NSApp.terminate(nil) }
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
    @Published var showWindowPicker = false
    @Published var windowPickerItems: [SCWindow] = []
    @Published var selectedHistoryID: UUID? = nil
    @Published var searchFocusTrigger: Bool = false

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
        captureEngine?.regionCaptureAction = { [weak self] in
            Task { @MainActor in self?.captureRegion() }
        }
        captureEngine?.registerHotkey()
        refreshHistory()

        // Save annotations on quit
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let id = self.currentVaultID, !self.canvas.annotations.isEmpty else { return }
            let anns = self.canvas.annotations
            let v = self.vault
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                await v.updateAnnotations(id: id, annotations: anns)
                sem.signal()
            }
            sem.wait()
        }
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

    func captureWithDelay(_ seconds: Int) {
        showStatus("\(seconds)秒後に撮影します…")
        var remaining = seconds
        statusTask?.cancel()
        statusTask = Task {
            while remaining > 0 {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch { return }
                remaining -= 1
                if remaining > 0 {
                    showStatus("あと\(remaining)秒…")
                } else {
                    showStatus("撮影中…")
                    captureEngine?.captureScreen()
                }
            }
        }
    }

    func captureWindowMode() {
        showStatus("ウィンドウ一覧を取得中…")
        Task {
            do {
                let windows = try await CaptureEngine.availableWindows()
                windowPickerItems = windows
                showWindowPicker = true
                showStatus("ウィンドウを選択してください")
            } catch {
                showStatus("ウィンドウ一覧の取得に失敗しました")
            }
        }
    }

    func captureWindowNow(_ window: SCWindow) {
        showWindowPicker = false
        showStatus("ウィンドウを撮影中…")
        captureEngine?.captureWindow(window)
    }

    private(set) var lastRegionRect: CGRect?

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
            self.lastRegionRect = rect
            self.showStatus("撮影中…")
            self.captureEngine?.captureRegion(rect)
        }
    }

    func repeatLastRegionCapture() {
        guard let rect = lastRegionRect else {
            captureRegion()
            return
        }
        showStatus("撮影中…")
        captureEngine?.captureRegion(rect)
    }

    func acceptCapture(_ image: CGImage) {
        canvas.backgroundImage = image
        canvas.annotations.removeAll()
        canvas.loadToken = UUID()
        currentVaultID = nil
        selectedHistoryID = nil
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
        // Try annotation paste first
        if canvas.pasteAnnotationFromClipboard() {
            showStatus("アノテーションを貼り付けました")
            return
        }
        // Fall back to image paste
        guard let nsImage = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            showStatus("クリップボードに画像がありません")
            return
        }
        acceptCapture(cgImage)
    }

    func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data, let nsImage = NSImage(data: data),
                      let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                Task { @MainActor in self.acceptCapture(cgImage) }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil),
                      let nsImage = NSImage(contentsOf: url),
                      let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                Task { @MainActor in self.acceptCapture(cgImage) }
            }
            return true
        }
        return false
    }

    func pinCurrentImage() {
        guard let image = canvas.renderAnnotations() ?? canvas.backgroundImage else {
            showStatus("ピン留めする画像がありません")
            return
        }
        PinManager.shared.pin(image: image)
        showStatus("画面にピン留めしました")
    }

    func copyToClipboard() {
        guard let image = canvas.renderAnnotations() ?? canvas.backgroundImage else {
            showStatus("コピーする画像がありません")
            return
        }
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([nsImage])
        // Also copy annotation data if one is selected (allows cross-screenshot paste)
        canvas.copySelectedAnnotationToClipboard()
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

    func exportHistoryItem(_ item: VaultItem) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "SnapLocal-\(df.string(from: item.createdAt)).png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? item.imageData.write(to: url, options: .atomic)
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
        // Save current annotations before switching
        if let id = currentVaultID, !canvas.annotations.isEmpty {
            Task { await vault.updateAnnotations(id: id, annotations: canvas.annotations) }
        }
        canvas.resetAndLoad(image: cgImage, annotations: item.annotations)
        currentVaultID = item.id
        selectedHistoryID = item.id
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

    func saveAnnotatedImageAs() {
        guard let image = canvas.renderAnnotations() ?? canvas.backgroundImage else {
            showStatus("保存できる画像がありません")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg, .pdf]
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "SnapLocal-\(formatter.string(from: Date())).png"

        // Accessory view: scale factor selector
        let scales: [String] = ["0.5x", "1x", "2x"]
        let scaleValues: [CGFloat] = [0.5, 1.0, 2.0]
        let seg = NSSegmentedControl(labels: scales, trackingMode: .selectOne, target: nil, action: nil)
        seg.selectedSegment = 1
        let label = NSTextField(labelWithString: "サイズ:")
        let stack = NSStackView(views: [label, seg])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        panel.accessoryView = stack

        panel.begin { [self] response in
            guard response == .OK, let url = panel.url else { return }
            let scale = scaleValues[max(0, min(scaleValues.count - 1, seg.selectedSegment))]
            let targetImage: CGImage
            if scale == 1.0 {
                targetImage = image
            } else {
                let w = max(1, Int(CGFloat(image.width) * scale))
                let h = max(1, Int(CGFloat(image.height) * scale))
                guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    self.showStatus("スケール変換失敗"); return
                }
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                guard let scaled = ctx.makeImage() else { self.showStatus("スケール変換失敗"); return }
                targetImage = scaled
            }
            let ext = url.pathExtension.lowercased()
            let data: Data?
            if ext == "pdf" {
                let pdfDoc = PDFDocument()
                let nsImg = NSImage(cgImage: targetImage, size: NSSize(width: targetImage.width, height: targetImage.height))
                if let pdfPage = PDFPage(image: nsImg) {
                    pdfDoc.insert(pdfPage, at: 0)
                    data = pdfDoc.dataRepresentation()
                } else { data = nil }
            } else if ext == "jpg" || ext == "jpeg" {
                data = NSBitmapImageRep(cgImage: targetImage).representation(using: .jpeg, properties: [.compressionFactor: 0.92])
            } else {
                data = NSBitmapImageRep(cgImage: targetImage).representation(using: .png, properties: [:])
            }
            guard let data else { self.showStatus("エンコード失敗"); return }
            do {
                try data.write(to: url, options: .atomic)
                let px = "\(targetImage.width)×\(targetImage.height)"
                self.showStatus("保存しました: \(url.lastPathComponent) (\(px))")
            } catch {
                self.showStatus("保存失敗: \(error.localizedDescription)")
            }
        }
    }

    func navigateHistory(by delta: Int) {
        guard !history.isEmpty else { return }
        if let current = selectedHistoryID,
           let idx = history.firstIndex(where: { $0.id == current }) {
            let newIdx = max(0, min(history.count - 1, idx + delta))
            if newIdx != idx { loadHistoryItem(history[newIdx]) }
        } else {
            loadHistoryItem(history[0])
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
    let onCaptureWindow: () -> Void
    let onPin: () -> Void
    let onCaptureWithDelay: (Int) -> Void
    let onRepeatRegion: () -> Void
    let onSave: () -> Void
    let onSaveAs: () -> Void
    let onCopy: () -> Void
    let onPaste: () -> Void
    @State private var showHelp = false
    @State private var showSettings = false
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

            Button(action: onRepeatRegion) {
                Image(systemName: "arrow.counterclockwise.circle")
            }
            .help("前回の範囲を再撮影 (⌘⇧R)")
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Button(action: onCaptureWindow) {
                Image(systemName: "macwindow.on.rectangle")
            }
            .help("ウィンドウ撮影 (⌘⇧3)")
            .keyboardShortcut("3", modifiers: [.command, .shift])

            Button(action: onPin) {
                Image(systemName: "pin.fill")
            }
            .help("画面にピン留め (⌘⇧P)")
            .disabled(canvas.backgroundImage == nil)
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Menu {
                Button("3秒後") { onCaptureWithDelay(3) }
                Button("5秒後") { onCaptureWithDelay(5) }
                Button("10秒後") { onCaptureWithDelay(10) }
            } label: {
                Image(systemName: "timer")
            }
            .help("遅延撮影")
            .menuStyle(.borderlessButton)
            .frame(width: 22)

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

            Button(action: { canvas.rotateImage(clockwise: false) }) {
                Image(systemName: "rotate.left")
            }
            .help("90°左に回転 (⌘⌥←)")
            .disabled(canvas.backgroundImage == nil)
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])

            Button(action: { canvas.rotateImage(clockwise: true) }) {
                Image(systemName: "rotate.right")
            }
            .help("90°右に回転 (⌘⌥→)")
            .disabled(canvas.backgroundImage == nil)
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])

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

            Button(action: onSaveAs) {
                Image(systemName: "square.and.arrow.down.on.square")
            }
            .help("別名で保存… (⌘⇧S)")
            .disabled(canvas.backgroundImage == nil)
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Divider().frame(height: 18)

            // Tool buttons: two logical groups separated by mini-divider
            HStack(spacing: 2) {
                ForEach([DrawingTool.select, .line, .arrow, .rectangle, .ellipse, .roundedRect], id: \.self) { tool in
                    toolButton(tool, canvas: canvas)
                }
                Divider().frame(width: 1, height: 18).padding(.horizontal, 1)
                ForEach([DrawingTool.text, .step, .callout, .highlight, .pencil, .redact], id: \.self) { tool in
                    toolButton(tool, canvas: canvas)
                }
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
            }

            if canvas.currentTool == .rectangle || canvas.currentTool == .ellipse || canvas.currentTool == .roundedRect || canvas.currentTool == .callout {
                Toggle(isOn: $canvas.currentFilled) {
                    Image(systemName: canvas.currentFilled ? "square.fill" : "square")
                }
                .toggleStyle(.button)
                .help(canvas.currentFilled ? "塗りつぶし（クリックでアウトラインへ）" : "アウトライン（クリックで塗りつぶしへ）")
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

            // Opacity slider — always visible
            HStack(spacing: 2) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Slider(value: $canvas.currentOpacity, in: 0.1...1.0, step: 0.05)
                    .frame(width: 56)
                    .controlSize(.mini)
                    .onChange(of: canvas.currentOpacity) { _, _ in canvas.applyCurrentOpacityToSelection() }
            }
            .help("不透明度 \(Int(canvas.currentOpacity * 100))%")

            Divider().frame(height: 18)

            ForEach(AnnotationColor.allCases, id: \.self) { color in
                Button(action: { canvas.currentColor = color; canvas.applyCurrentColorToSelection() }) {
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
                .simultaneousGesture(TapGesture().onEnded {
                    canvas.currentCustomColorHex = nil
                    canvas.applyCustomColorToSelection(hex: nil)
                })
            }

            // Custom color well
            ColorWellView(colorHex: $canvas.currentCustomColorHex) { hex in
                canvas.currentCustomColorHex = hex
                canvas.applyCustomColorToSelection(hex: hex)
                if let hex { settings.addRecentCustomColor(hex) }
            }
            .frame(width: 18, height: 18)
            .cornerRadius(3)
            .help("カスタムカラー（クリックで色を選択）")

            // Recent custom colors (up to 5)
            ForEach(settings.recentCustomColors.prefix(5), id: \.self) { hex in
                Button(action: {
                    canvas.currentCustomColorHex = hex
                    canvas.applyCustomColorToSelection(hex: hex)
                }) {
                    ZStack {
                        if let c = ColorWellView.hexToNSColor(hex) {
                            Circle()
                                .fill(Color(nsColor: c))
                                .frame(width: 12, height: 12)
                                .overlay(
                                    Circle()
                                        .stroke(Color.primary.opacity(0.2), lineWidth: 0.5)
                                        .frame(width: 12, height: 12)
                                )
                        }
                        if canvas.currentCustomColorHex == hex {
                            Circle()
                                .stroke(Color.primary.opacity(0.8), lineWidth: 2)
                                .frame(width: 17, height: 17)
                        }
                    }
                }
                .buttonStyle(.plain)
                .frame(width: 18, height: 18)
                .help("最近使ったカラー: #\(hex.prefix(6))")
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
            .onChange(of: canvas.currentLineWidth) { _, _ in
                canvas.applyCurrentLineWidthToSelection()
            }

            Picker("", selection: $canvas.currentLineStyle) {
                Image(systemName: "line.horizontal.3").tag(LineStyle.solid)
                Image(systemName: "line.horizontal.3").tag(LineStyle.dashed)
                Image(systemName: "circle.dotted").tag(LineStyle.dotted)
            }
            .pickerStyle(.segmented)
            .frame(width: 76)
            .disabled(!canvas.currentTool.usesLineWidth)
            .opacity(canvas.currentTool.usesLineWidth ? 1.0 : 0.5)
            .help("線のスタイル（実線 / 破線 / 点線）")
            .onChange(of: canvas.currentLineStyle) { _, _ in
                canvas.applyCurrentLineStyleToSelection()
            }

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
        }
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
        .help("\(tool.displayName)")
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
    }
}

// MARK: - History Rail

struct HistoryRail: View {
    let history: [VaultItem]
    @Binding var searchQuery: String
    @Binding var focusTrigger: Bool
    let selectedID: UUID?
    let onSelect: (VaultItem) -> Void
    let onDelete: (VaultItem) -> Void
    let onRefresh: () -> Void
    let onSearch: () -> Void
    let onExport: (VaultItem) -> Void

    @FocusState private var searchFocused: Bool
    @State private var thumbCache: [UUID: NSImage] = [:]
    @State private var hoveredItemID: UUID? = nil

    private let thumbW: CGFloat = 68
    private let thumbH: CGFloat = 46

    private func historyItemLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            return f.string(from: date)
        } else if Calendar.current.isDateInYesterday(date) {
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            return "昨日 " + f.string(from: date)
        } else {
            let f = DateFormatter(); f.dateFormat = "M/d"
            return f.string(from: date)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("検索", text: $searchQuery)
                    .font(.caption2)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onChange(of: searchQuery) { _, _ in onSearch() }
                    .onChange(of: focusTrigger) { _, _ in searchFocused = true }
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

            ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(history) { item in
                        let isSelected = item.id == selectedID
                        Button(action: { onSelect(item) }) {
                            VStack(spacing: 3) {
                                Group {
                                    if let nsImage = thumbCache[item.id]
                                        ?? NSImage(data: item.thumbnailData) {
                                        Image(nsImage: nsImage)
                                            .resizable()
                                            .scaledToFill()
                                            .onAppear {
                                                if thumbCache[item.id] == nil {
                                                    thumbCache[item.id] = nsImage
                                                }
                                            }
                                    } else {
                                        Image(systemName: "photo")
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: thumbW, height: thumbH)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                                )

                                Text(historyItemLabel(item.createdAt))
                                    .font(.system(size: 8))
                                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                    .lineLimit(1)

                                if !item.ocrText.isEmpty && !searchQuery.isEmpty {
                                    Text(item.ocrText)
                                        .font(.system(size: 7))
                                        .lineLimit(2)
                                        .foregroundStyle(.secondary)
                                        .frame(width: thumbW, alignment: .leading)
                                }
                            }
                        }
                        .id(item.id)
                        .buttonStyle(.plain)
                        .onHover { hovering in hoveredItemID = hovering ? item.id : nil }
                        .popover(isPresented: Binding(
                            get: { hoveredItemID == item.id },
                            set: { if !$0 { hoveredItemID = nil } }
                        ), arrowEdge: .leading) {
                            Group {
                                if let nsImage = NSImage(data: item.imageData) {
                                    Image(nsImage: nsImage)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxWidth: 360, maxHeight: 280)
                                } else {
                                    Color.clear.frame(width: 120, height: 80)
                                }
                            }
                            .padding(4)
                        }
                        .contextMenu {
                            Button("開く") { onSelect(item) }
                            Button("ファイルに保存…") { onExport(item) }
                            Button("Finderで表示") {
                                NSWorkspace.shared.activateFileViewerSelecting([item.imageURL])
                            }
                            Button("クリップボードにコピー") {
                                if let nsImage = NSImage(contentsOf: item.imageURL) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.writeObjects([nsImage])
                                }
                            }
                            Button("共有…") {
                                let picker = NSSharingServicePicker(items: [item.imageURL])
                                if let btn = NSApp.keyWindow?.contentView?.subviews.first {
                                    picker.show(relativeTo: .zero, of: btn, preferredEdge: .minY)
                                }
                            }
                            if !item.ocrText.isEmpty {
                                Button("OCRテキストをコピー") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(item.ocrText, forType: .string)
                                }
                            }
                            Divider()
                            Button("削除", role: .destructive) { onDelete(item) }
                        }
                        .help(item.createdAt.formatted(date: .complete, time: .shortened)
                              + (item.ocrText.isEmpty ? "" : "\n" + String(item.ocrText.prefix(80))))
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            .onChange(of: selectedID) { _, newID in
                if let id = newID {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            } // ScrollViewReader

            Divider()
            HStack(spacing: 0) {
                Text("\(history.count)件")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                Spacer()
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .padding(.trailing, 4)
            }
            .padding(.vertical, 4)
        }
        .frame(width: 88)
        .background(.regularMaterial)
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

// MARK: - Scroll Wheel Zoom/Pan Helper

struct ScrollWheelHandler: NSViewRepresentable {
    let onScroll: (CGFloat, CGFloat, Bool) -> Void  // dx, dy, isCommandDown

    func makeNSView(context: Context) -> NSView {
        let view = ScrollableNSView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ScrollableNSView)?.onScroll = onScroll
    }

    class ScrollableNSView: NSView {
        var onScroll: ((CGFloat, CGFloat, Bool) -> Void)?

        override var acceptsFirstResponder: Bool { false }

        override func scrollWheel(with event: NSEvent) {
            let cmd = event.modifierFlags.contains(.command)
            onScroll?(event.scrollingDeltaX, event.scrollingDeltaY, cmd)
            if !cmd { super.scrollWheel(with: event) }
        }
    }
}

struct HintRow: View {
    let key: String
    let label: String
    var body: some View {
        HStack(spacing: 6) {
            Text(key)
                .monospacedDigit()
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
            Text(label)
        }
    }
}

// MARK: - Help Popover

struct HelpPopoverContent: View {
    private let sections: [(String, [(String, String)])] = [
        ("キャプチャ", [
            ("⌘⇧2", "全画面撮影"),
            ("⌘⇧3", "ウィンドウ撮影"),
            ("⌘⇧4", "範囲選択撮影"),
            ("タイマー", "3/5/10秒遅延撮影"),
            ("⌘V", "クリップボードから貼り付け"),
            ("⌘⇧P", "画面にピン留め"),
        ]),
        ("ツール", [
            ("V", "選択ツール"),
            ("L", "直線"),
            ("A", "矢印"),
            ("R", "長方形"),
            ("E", "楕円"),
            ("T", "テキスト"),
            ("N", "ステップ番号"),
            ("U", "角丸長方形"),
            ("B", "吹き出し"),
            ("H", "ハイライト"),
            ("P", "鉛筆（フリーハンド）"),
            ("X / M", "モザイク/ぼかし"),
            ("Tab", "次のツール"),
        ]),
        ("描画", [
            ("Shift+ドラッグ", "45°制約 / 正方形/正円"),
            ("Option+クリック", "スポイト（色を拾う）"),
            ("Option+ドラッグ", "アノテーション複製"),
            ("[  /  ]", "線幅 細/太"),
        ]),
        ("編集", [
            ("⌘Z / ⌘⇧Z", "元に戻す / やり直し"),
            ("⌫", "選択削除"),
            ("⌘A", "全アノテーション選択"),
            ("⌘D", "アノテーション複製"),
            ("⌘L", "ロック / ロック解除"),
            ("⌘'", "アノテーション表示/非表示"),
            ("矢印キー", "1px移動（Shift=10px）"),
            ("⌘] / ⌘[", "前面へ / 背面へ"),
            ("1〜8", "色を選択"),
            ("Enter", "テキスト再編集"),
            ("ダブルクリック", "テキスト再編集"),
            ("Esc", "選択解除 / モード終了"),
        ]),
        ("ズーム/パン", [
            ("ピンチ / スクロール", "ズーム・パン"),
            ("Space+ドラッグ", "パン"),
            ("⌘+ / ⌘-", "ズームイン/アウト"),
            ("⌘0", "ズームリセット"),
        ]),
        ("その他", [
            ("⌘↑ / ⌘↓", "履歴の前/次"),
            ("⌘K", "切り取りモード"),
            ("⌘⌥← / ⌘⌥→", "90°回転（左/右）"),
            ("⌘⇧R", "前回範囲を再撮影"),
            ("⌘C", "クリップボードにコピー"),
            ("⌘S", "ファイルに保存"),
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(sections, id: \.0) { section, rows in
                    Text(section)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(rows, id: \.0) { key, desc in
                            HStack(alignment: .top, spacing: 8) {
                                Text(key)
                                    .font(.system(size: 10, design: .monospaced))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                                    .frame(minWidth: 80, alignment: .leading)
                                Text(desc)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                    Divider()
                }
            }
            .padding(12)
        }
        .frame(width: 280, height: 380)
    }
}

// MARK: - Settings Sheet

struct SettingsSheet: View {
    @StateObject private var settings = SettingsManager.shared
    @State private var saveDirectoryPath: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("設定")
                    .font(.headline)
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            Form {
                Section("保存先") {
                    HStack {
                        Text(saveDirectoryPath)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("変更…") { chooseSaveDirectory() }
                            .controlSize(.small)
                    }
                }

                Section("ホットキー") {
                    Picker("全画面撮影", selection: Binding(
                        get: { settings.hotkeyConfig },
                        set: { settings.hotkeyConfig = $0 }
                    )) {
                        ForEach(settings.availableHotkeys, id: \.displayString) { h in
                            Text(h.displayString).tag(h)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("通知") {
                    Toggle("撮影完了を通知する", isOn: Binding(
                        get: { settings.notificationsEnabled },
                        set: { settings.notificationsEnabled = $0 }
                    ))
                }

                if #available(macOS 13.0, *) {
                    Section("起動") {
                        Toggle("ログイン時に起動", isOn: Binding(
                            get: { settings.launchAtLogin },
                            set: { settings.launchAtLogin = $0 }
                        ))
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 380)
        .onAppear { saveDirectoryPath = settings.saveDirectoryURL.path }
    }

    private func chooseSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "選択"
        panel.message = "スクリーンショットの保存先を選択してください"
        panel.directoryURL = settings.saveDirectoryURL
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveDirectoryURL = url
            saveDirectoryPath = url.path
        }
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

// MARK: - Window Picker Sheet

struct WindowPickerSheet: View {
    let windows: [SCWindow]
    let onSelect: (SCWindow) -> Void
    let onCancel: () -> Void

    @State private var hovered: CGWindowID? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ウィンドウを選択")
                    .font(.headline)
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if windows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "macwindow.badge.plus")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("キャプチャ可能なウィンドウが見つかりません")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(windows, id: \.windowID) { win in
                            WindowPickerRow(window: win, isHovered: hovered == win.windowID)
                                .onHover { hovering in
                                    hovered = hovering ? win.windowID : nil
                                }
                                .onTapGesture {
                                    onSelect(win)
                                }
                        }
                    }
                    .padding(8)
                }
                .frame(minHeight: 200, maxHeight: 480)
            }

            Divider()

            HStack {
                Spacer()
                Button("キャンセル", action: onCancel)
                    .keyboardShortcut(.escape)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 480)
    }
}

struct WindowPickerRow: View {
    let window: SCWindow
    let isHovered: Bool

    var appIcon: NSImage? {
        guard let bundleID = window.owningApplication?.bundleIdentifier,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }

    var appName: String {
        window.owningApplication?.applicationName ?? "不明なアプリ"
    }

    var windowTitle: String {
        let t = window.title ?? ""
        return t.isEmpty ? appName : t
    }

    var body: some View {
        HStack(spacing: 10) {
            if let icon = appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: "macwindow")
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(windowTitle)
                    .lineLimit(1)
                    .font(.body)
                Text(appName)
                    .lineLimit(1)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(Int(window.frame.width))×\(Int(window.frame.height))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isHovered ? Color.accentColor.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}

// MARK: - Content View

struct ContentView: View {
    @ObservedObject var state: SnapLocalState
    @State private var isDropTargeted = false

    var windowTitle: String {
        if let img = state.canvas.backgroundImage {
            return "SnapLocal — \(img.width) × \(img.height)"
        }
        return "SnapLocal"
    }

    var body: some View {
        VStack(spacing: 0) {
            CompactToolbar(
                canvas: state.canvas,
                onCapture: state.captureNow,
                onCaptureRegion: state.captureRegion,
                onCaptureWindow: state.captureWindowMode,
                onPin: state.pinCurrentImage,
                onCaptureWithDelay: state.captureWithDelay,
                onRepeatRegion: state.repeatLastRegionCapture,
                onSave: state.saveAnnotatedImage,
                onSaveAs: state.saveAnnotatedImageAs,
                onCopy: state.copyToClipboard,
                onPaste: state.pasteFromClipboard
            )
            .sheet(isPresented: $state.showWindowPicker) {
                WindowPickerSheet(
                    windows: state.windowPickerItems,
                    onSelect: { state.captureWindowNow($0) },
                    onCancel: {
                        state.showWindowPicker = false
                        state.showStatus("キャンセルしました")
                    }
                )
            }
            .navigationTitle(windowTitle)
            Divider()
            HStack(spacing: 0) {
                AnnotationCanvasView(
                    viewModel: state.canvas,
                    onCapture: state.captureNow,
                    onOpenPermissions: state.openScreenRecordingSettings,
                    onFocusSearch: { state.searchFocusTrigger.toggle() },
                    onNavigateHistory: { delta in state.navigateHistory(by: delta) }
                )
                    .frame(minWidth: 600, minHeight: 400)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .onDrop(of: [UTType.image, UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                        state.handleDroppedProviders(providers)
                    }
                    .overlay {
                        if isDropTargeted {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 4]))
                                .padding(4)
                                .overlay(
                                    Text("画像をドロップ")
                                        .font(.title2)
                                        .foregroundStyle(Color.accentColor)
                                        .padding(12)
                                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                                )
                        }
                    }
                    .overlay(alignment: .bottom) {
                        StatusChip(message: state.statusMessage, visible: state.statusVisible)
                            .padding(.bottom, 14)
                            .animation(.easeInOut(duration: 0.2), value: state.statusVisible)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let img = state.canvas.backgroundImage {
                            Text("\(img.width) × \(img.height)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                                .padding([.bottom, .trailing], 8)
                        }
                    }

                Divider()
                HistoryRail(
                    history: state.history,
                    searchQuery: $state.searchQuery,
                    focusTrigger: $state.searchFocusTrigger,
                    selectedID: state.selectedHistoryID,
                    onSelect: state.loadHistoryItem,
                    onDelete: state.deleteHistoryItem,
                    onRefresh: state.refreshHistory,
                    onSearch: state.applySearch,
                    onExport: state.exportHistoryItem
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
    var onFocusSearch: (() -> Void)? = nil
    var onNavigateHistory: ((Int) -> Void)? = nil

    @FocusState private var textFieldFocused: Bool
    @FocusState private var canvasFocused: Bool
    @State private var isHovering = false
    @State private var zoom: CGFloat = 1.0
    @State private var baseZoom: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var basePan: CGSize = .zero
    @State private var isPanning = false

    private func updateCursor() {
        guard isHovering else { return }
        if isPanning {
            NSCursor.openHand.set()
            return
        }
        switch viewModel.currentTool {
        case .select: NSCursor.arrow.set()
        default:      NSCursor.crosshair.set()
        }
    }

    private func toCanvas(_ point: CGPoint, size: CGSize) -> CGPoint {
        let cx = size.width / 2, cy = size.height / 2
        return CGPoint(x: (point.x - cx) / zoom + cx, y: (point.y - cy) / zoom + cy)
    }

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
                            .font(.system(size: 48))
                            .foregroundStyle(.tertiary)
                        if let onCapture = onCapture {
                            Button("撮影する", action: onCapture)
                                .buttonStyle(.borderedProminent)
                        }
                        VStack(spacing: 4) {
                            HintRow(key: "⌘⇧2", label: "全画面撮影")
                            HintRow(key: "⌘⇧4", label: "範囲選択撮影")
                            HintRow(key: "⌘V",  label: "クリップボードから貼り付け")
                        }
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        if let onOpenPermissions = onOpenPermissions {
                            Button("画面録画の設定を開く", action: onOpenPermissions)
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .scaleEffect(zoom, anchor: .center)
            .offset(panOffset)
            .contentShape(Rectangle())
            .gesture(isPanning ? panGesture() : nil)
            .gesture(isPanning ? nil : dragGesture(in: proxy.frame(in: .local), size: proxy.size))
            .gesture(MagnificationGesture()
                .onChanged { value in
                    zoom = max(0.25, min(8.0, baseZoom * value))
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
            .onAppear { viewModel.canvasSize = proxy.size }
            .onChange(of: proxy.size) { _, newSize in viewModel.canvasSize = newSize }
            .overlay(textInputOverlay)
            .overlay(
                ScrollWheelHandler { dx, dy, isCmd in
                    if isCmd {
                        // ⌘+scroll → zoom
                        let factor = 1.0 + dy * 0.02
                        zoom = max(0.25, min(8.0, zoom * factor))
                        baseZoom = zoom
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
                if abs(zoom - 1.0) > 0.01 {
                    Text("\(Int(zoom * 100))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .padding(8)
                        .onTapGesture { zoom = 1.0; baseZoom = 1.0; panOffset = .zero; basePan = .zero }
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
            .onKeyPress("a", phases: .down) { press in
                guard !viewModel.showTextInput, press.modifiers.contains(.command) else { return .ignored }
                viewModel.selectedAnnotationIDs = Set(viewModel.annotations.map { $0.id })
                viewModel.selectedAnnotationID = viewModel.annotations.last?.id
                viewModel.objectWillChange.send()
                return .handled
            }
            .onKeyPress("=", phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                zoom = min(8.0, zoom * 1.25); baseZoom = zoom; return .handled
            }
            .onKeyPress("-", phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                zoom = max(0.25, zoom / 1.25); baseZoom = zoom; return .handled
            }
            .onKeyPress("0", phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                zoom = 1.0; baseZoom = 1.0
                panOffset = .zero; basePan = .zero
                return .handled
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
                let tools = DrawingTool.allCases
                if let i = tools.firstIndex(of: viewModel.currentTool) {
                    if press.modifiers.contains(.shift) {
                        viewModel.currentTool = tools[(i - 1 + tools.count) % tools.count]
                    } else {
                        viewModel.currentTool = tools[(i + 1) % tools.count]
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
                guard !viewModel.showTextInput,
                      press.modifiers.contains(.command) && press.modifiers.contains(.shift) else { return .ignored }
                viewModel.clearAllAnnotations()
                return .handled
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
            .onKeyPress(characters: .init(charactersIn: "[]"), phases: .down) { press in
                guard !viewModel.showTextInput else { return .ignored }
                if press.modifiers.contains(.command) {
                    if press.key.character == "[" { viewModel.sendSelectedToBack() }
                    else { viewModel.bringSelectedToFront() }
                } else {
                    let all = LineWidth.allCases
                    if press.key.character == "[" {
                        if let i = all.firstIndex(of: viewModel.currentLineWidth), i > 0 { viewModel.currentLineWidth = all[i - 1] }
                    } else {
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
                if viewModel.currentTool == .select,
                   let id = viewModel.selectedAnnotationID,
                   let ann = viewModel.annotations.first(where: { $0.id == id }),
                   ann.type == .text {
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
                        guard viewModel.backgroundImage != nil,
                              viewModel.currentTool == .select else { return }
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
            .onHover { inside in
                isHovering = inside
                if inside {
                    updateCursor()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .onChange(of: viewModel.currentTool) { _, _ in updateCursor() }
            .onChange(of: viewModel.loadToken) { _, _ in
                zoom = 1.0; baseZoom = 1.0; panOffset = .zero; basePan = .zero
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
            let beingDragged = (viewModel.isDraggingAnnotation || viewModel.resizingHandleIndex != nil)
                ? viewModel.selectedAnnotationID : nil

            guard !viewModel.annotationsHidden else { return }

            for annotation in viewModel.annotations {
                let annotationOpacity = annotation.opacity
                if annotation.type == .highlight {
                    let path = annotation.path(in: canvasRect)
                    context.fill(path, with: .color(annotation.resolvedColor.opacity(0.38 * annotationOpacity)))
                    if annotation.id == viewModel.selectedAnnotationID || viewModel.selectedAnnotationIDs.contains(annotation.id) {
                        context.stroke(path, with: .color(.accentColor),
                                       style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    }
                } else if annotation.type == .step, let n = annotation.stepNumber {
                    let bounds = annotation.bounds(in: canvasRect)
                    let circlePath = annotation.path(in: canvasRect)
                    if annotation.id == viewModel.selectedAnnotationID {
                        context.fill(circlePath, with: .color(.white.opacity(0.5)))
                    }
                    context.fill(circlePath, with: .color(annotation.resolvedColor.opacity(annotationOpacity)))
                    let textColor: Color = annotation.color == .yellow || annotation.color == .white ? .black : .white
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
                    context.draw(
                        Text(text)
                            .font(.system(size: fontSize, weight: .semibold))
                            .foregroundColor(annotation.resolvedColor.opacity(annotationOpacity)),
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
                    let strokeStyle = annotation.lineStyle.strokeStyle(lineWidth: lw)
                    if annotation.id == viewModel.selectedAnnotationID {
                        context.stroke(path, with: .color(.white),
                                       style: StrokeStyle(lineWidth: lw + 4, lineCap: .round, lineJoin: .round))
                        if annotation.type == .arrow {
                            context.fill(path, with: .color(.white))
                        }
                    }
                    if annotation.isFilled {
                        context.fill(path, with: .color(annotation.resolvedColor.opacity(0.35 * annotationOpacity)))
                        context.stroke(path, with: .color(annotation.resolvedColor.opacity(annotationOpacity)), style: strokeStyle)
                    } else {
                        context.stroke(path, with: .color(annotation.resolvedColor.opacity(annotationOpacity)), style: strokeStyle)
                        if annotation.type == .arrow {
                            context.fill(path, with: .color(annotation.resolvedColor.opacity(annotationOpacity)))
                        }
                    }
                    if annotation.id == viewModel.selectedAnnotationID {
                        let bounds = annotation.bounds(in: canvasRect).insetBy(dx: -4, dy: -4)
                        context.stroke(Path(bounds), with: .color(.accentColor),
                                       style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
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
                for ann in viewModel.annotations where viewModel.selectedAnnotationIDs.contains(ann.id) {
                    let bounds = ann.bounds(in: canvasRect).insetBy(dx: -4, dy: -4)
                    context.stroke(Path(bounds), with: .color(.accentColor.opacity(0.7)),
                                   style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }

            // Resize handles for selected resizable annotation (single select only)
            if viewModel.currentTool == .select,
               viewModel.selectedAnnotationIDs.count <= 1,
               let id = viewModel.selectedAnnotationID,
               let ann = viewModel.annotations.first(where: { $0.id == id }),
               CanvasViewModel.isResizable(ann.type) {
                let bounds = ann.bounds(in: canvasRect)
                for corner in viewModel.handleCorners(for: bounds) {
                    let r = CGRect(x: corner.x - 5, y: corner.y - 5, width: 10, height: 10)
                    context.fill(Path(ellipseIn: r), with: .color(.white))
                    context.stroke(Path(ellipseIn: r), with: .color(.accentColor), lineWidth: 1.5)
                }
            }

            // Rubber-band selection rectangle
            if let band = viewModel.rubberBandRect {
                context.fill(Path(band), with: .color(.accentColor.opacity(0.1)))
                context.stroke(Path(band), with: .color(.accentColor),
                               style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }

            // Pencil live preview
            if viewModel.currentTool == .pencil && viewModel.currentPencilPoints.count >= 2 {
                let pts = viewModel.currentPencilPoints
                let previewColor = viewModel.currentColor.color.opacity(0.75)
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
                        preview = Path(ellipseIn: rect)
                    case .callout:
                        let r = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                       width: abs(end.x - start.x), height: abs(end.y - start.y))
                        let cr = min(r.width, r.height) * 0.15
                        preview = Path(roundedRect: r, cornerRadius: cr)
                    case .highlight:
                        preview = Path(CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                                              width: abs(end.x - start.x), height: abs(end.y - start.y)))
                    default: break
                    }
                    if !preview.isEmpty {
                        let isFillTool = (viewModel.currentTool == .rectangle || viewModel.currentTool == .ellipse || viewModel.currentTool == .roundedRect) && viewModel.currentFilled
                        let isHighlight = viewModel.currentTool == .highlight
                        if isFillTool || viewModel.currentTool == .step || isHighlight {
                            context.fill(preview, with: .color(previewColor.opacity(isHighlight ? 0.38 : viewModel.currentTool == .step ? 0.7 : 0.35)))
                        }
                        if viewModel.currentTool != .step && !isHighlight {
                            context.stroke(preview, with: .color(previewColor),
                                           style: StrokeStyle(lineWidth: lw, dash: [4, 2]))
                        }
                    }
                }
            }
        }
    }

    private func panGesture() -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                panOffset = CGSize(
                    width: basePan.width + value.translation.width,
                    height: basePan.height + value.translation.height
                )
            }
            .onEnded { value in
                basePan = panOffset
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
            }
            .onEnded { value in
                let loc = toCanvas(value.location, size: size)
                viewModel.handleDragEnd(at: loc, in: rect)
            }
    }

    @ViewBuilder
    private var textInputOverlay: some View {
        if viewModel.showTextInput {
            let cx = viewModel.canvasSize.width / 2
            let cy = viewModel.canvasSize.height / 2
            let r = viewModel.textInputRect
            let viewX = cx + (r.midX - cx) * zoom + panOffset.width
            let viewY = cy + (r.midY - cy) * zoom + panOffset.height
            TextField("テキスト", text: $viewModel.textInputString)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: viewModel.currentFontSize * zoom, weight: .semibold))
                .frame(width: r.width * zoom)
                .position(x: viewX, y: viewY)
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
