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
import Combine
import Vision

extension Notification.Name {
    static let snapLocalZoomIn    = Notification.Name("snaplocal.zoom.in")
    static let snapLocalZoomOut   = Notification.Name("snaplocal.zoom.out")
    static let snapLocalZoomReset = Notification.Name("snaplocal.zoom.reset")
    static let snapLocalZoomFit   = Notification.Name("snaplocal.zoom.fit")
}

private let logger = Logger(subsystem: "com.snaplocal.app", category: "App")

// MARK: - Zoom Notification Handler

private struct ZoomNotificationHandler: ViewModifier {
    @Binding var zoom: CGFloat
    @Binding var baseZoom: CGFloat
    @Binding var panOffset: CGSize
    @Binding var basePan: CGSize
    let canvasSize: CGSize
    let imageSize: CGSize?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .snapLocalZoomIn)) { _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    zoom = min(8.0, zoom * 1.25); baseZoom = zoom
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .snapLocalZoomOut)) { _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    zoom = max(0.25, zoom / 1.25); baseZoom = zoom
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .snapLocalZoomReset)) { _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    zoom = 1.0; baseZoom = 1.0; panOffset = .zero; basePan = .zero
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .snapLocalZoomFit)) { _ in
                guard let sz = imageSize, sz.width > 0, sz.height > 0 else { return }
                let fitW = canvasSize.width / sz.width
                let fitH = canvasSize.height / sz.height
                withAnimation(.easeOut(duration: 0.2)) {
                    zoom = max(0.25, min(4.0, min(fitW, fitH) * 0.9)); baseZoom = zoom
                    panOffset = .zero; basePan = .zero
                }
            }
    }
}

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

            // File menu extras
            CommandGroup(after: .saveItem) {
                Button("別名で保存…") { appState.saveAnnotatedImageAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Finderで表示") { appState.revealCurrentItemInFinder() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Divider()
                Button("履歴をZIPで書き出し") { appState.exportHistoryAsZip() }
                Button("履歴をPDFで書き出し") { appState.exportHistoryAsPDF() }
            }

            // Capture menu
            CommandMenu("キャプチャ") {
                Button("全画面撮影") { appState.captureNow() }
                    .keyboardShortcut("2", modifiers: [.command, .shift])
                Button("範囲選択撮影") { appState.captureRegion() }
                    .keyboardShortcut("4", modifiers: [.command, .shift])
                Button("ウィンドウ撮影") { appState.captureWindowMode() }
                    .keyboardShortcut("3", modifiers: [.command, .shift])
                Button("前回の範囲を再撮影") { appState.repeatLastRegionCapture() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("全画面→クリップボードのみ") { appState.captureNowToClipboard() }
                    .keyboardShortcut("2", modifiers: [.command, .control])
                Button("範囲→クリップボードのみ") { appState.captureRegionToClipboard() }
                    .keyboardShortcut("4", modifiers: [.command, .control])
                Divider()
                Menu("遅延撮影") {
                    Button("3秒後") { appState.captureWithDelay(3) }
                    Button("5秒後") { appState.captureWithDelay(5) }
                    Button("10秒後") { appState.captureWithDelay(10) }
                }
            }

            // View menu
            CommandMenu("表示") {
                Button("ズームイン") { NotificationCenter.default.post(name: .snapLocalZoomIn, object: nil) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("ズームアウト") { NotificationCenter.default.post(name: .snapLocalZoomOut, object: nil) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("実寸 (100%)") { NotificationCenter.default.post(name: .snapLocalZoomReset, object: nil) }
                    .keyboardShortcut("0", modifiers: .command)
                Button("フィット表示") { NotificationCenter.default.post(name: .snapLocalZoomFit, object: nil) }
                    .keyboardShortcut("f", modifiers: .command)
                Divider()
                Button("ピン留めウィンドウをすべて閉じる") { PinManager.shared.closeAll() }
                    .disabled(!PinManager.shared.hasPinnedWindows)
            }
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
        // Last capture thumbnail row
        if let last = state.history.first, let nsImage = NSImage(data: last.thumbnailData) {
            Button {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                state.loadHistoryItem(last)
            } label: {
                HStack(spacing: 8) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 80, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(last.title ?? "最新のスクリーンショット")
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text(last.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
        }
        Button("全画面撮影 (⌘⇧2)") { state.captureNow() }
        Button("範囲選択撮影 (⌘⇧4)") { state.captureRegion() }
        Button("前回の範囲を再撮影 (⌘⇧R)") { state.repeatLastRegionCapture() }
        Button("ウィンドウ撮影 (⌘⇧3)") { state.captureWindowMode() }
        Divider()
        Button("全画面→クリップボードのみ (⌘⌃2)") { state.captureNowToClipboard() }
        Button("範囲→クリップボードのみ (⌘⌃4)") { state.captureRegionToClipboard() }
        Divider()
        Menu("遅延撮影") {
            Button("3秒後") { state.captureWithDelay(3) }
            Button("5秒後") { state.captureWithDelay(5) }
            Button("10秒後") { state.captureWithDelay(10) }
        }
        Divider()
        Button("クリップボードにコピー") { state.copyToClipboard() }
            .disabled(state.canvas.backgroundImage == nil)
        Button("共有…") { state.shareCurrentImage() }
            .disabled(state.canvas.backgroundImage == nil)
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
    private var autoSaveTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var clipboardOnlyCapture = false   // set before a "capture to clipboard only" call
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

        // AppIntents notifications
        NotificationCenter.default.addObserver(forName: .intentCaptureScreen, object: nil, queue: .main) { [weak self] _ in
            self?.captureNow()
        }
        NotificationCenter.default.addObserver(forName: .intentCaptureRegion, object: nil, queue: .main) { [weak self] _ in
            self?.captureRegion()
        }

        // Auto-save annotations 3 seconds after last change
        canvas.$annotations
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleAutoSave() }
            .store(in: &cancellables)

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

    private func scheduleAutoSave() {
        autoSaveTask?.cancel()
        autoSaveTask = Task {
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                guard let id = currentVaultID else { return }
                let anns = canvas.annotations
                await vault.updateAnnotations(id: id, annotations: anns)
            } catch {}
        }
    }

    // MARK: - Capture

    func captureNow() {
        showStatus("撮影中…")
        captureEngine?.captureScreen()
    }

    func captureNowToClipboard() {
        clipboardOnlyCapture = true
        showStatus("撮影中（クリップボードへ）…")
        captureEngine?.captureScreen()
    }

    func captureRegionToClipboard() {
        clipboardOnlyCapture = true
        RegionCapture.start(initialRect: lastRegionRect) { [weak self] rect, preCaptured in
            guard let rect else { self?.clipboardOnlyCapture = false; return }
            if let img = preCaptured {
                self?.regionCapturePlayedSound = true
                self?.acceptCapture(img)
            } else {
                self?.captureEngine?.captureRegion(rect)
            }
        }
    }

    func captureWithDelay(_ seconds: Int) {
        showStatus("\(seconds)秒後に撮影します…")
        CountdownOverlay.shared.show(count: seconds)
        var remaining = seconds
        statusTask?.cancel()
        statusTask = Task {
            while remaining > 0 {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch { CountdownOverlay.shared.hide(); return }
                remaining -= 1
                if remaining > 0 {
                    CountdownOverlay.shared.show(count: remaining)
                    showStatus("あと\(remaining)秒…")
                } else {
                    CountdownOverlay.shared.hide()
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
                showStatus("ウィンドウにカーソルを合わせてクリック")
                WindowHoverCapture.start(windows: windows) { [weak self] selected in
                    guard let self else { return }
                    if let win = selected {
                        self.captureWindowNow(win)
                    } else {
                        self.showStatus("キャンセルしました")
                    }
                }
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
    private var regionCapturePlayedSound = false   // prevents double-shutter in region capture fast path

    func captureRegion() {
        isRegionCapturing = true
        showStatus("範囲を選択 — ドラッグして選択")
        RegionCapture.start(initialRect: lastRegionRect) { [weak self] rect, preCaptured in
            guard let self else { return }
            self.isRegionCapturing = false
            guard let rect else {
                self.showStatus("キャンセルしました")
                return
            }
            self.lastRegionRect = rect
            if let img = preCaptured {
                // Fast path: shutter sound already played in RegionCapture.commit()
                self.regionCapturePlayedSound = true
                self.acceptCapture(img)
            } else {
                self.showStatus("撮影中…")
                self.captureEngine?.captureRegion(rect)
            }
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
        let skipSound = regionCapturePlayedSound
        regionCapturePlayedSound = false
        CameraFlash.shared.flash(playSound: !skipSound)
        // Clipboard-only mode: copy and return immediately, skip history/HUD
        if clipboardOnlyCapture {
            clipboardOnlyCapture = false
            copyImageToClipboard(image)
            showStatus("クリップボードにコピーしました（履歴には保存しません）")
            return
        }
        // Persist current annotations before overwriting canvas
        if let id = currentVaultID, !canvas.annotations.isEmpty {
            let anns = canvas.annotations
            let v = vault
            Task { await v.updateAnnotations(id: id, annotations: anns) }
        }
        canvas.backgroundImage = image
        canvas.annotations.removeAll()
        canvas.loadToken = UUID()
        currentVaultID = nil
        selectedHistoryID = nil
        if SettingsManager.shared.autoCopyOnCapture {
            copyImageToClipboard(image)
            showStatus("撮影 → クリップボードにコピーしました")
            sendNotification(title: "撮影完了", body: "クリップボードにコピーしました")
        } else {
            showStatus("撮影しました")
            sendNotification(title: "撮影完了", body: "HUDから操作できます")
        }

        // Post-capture: open editor immediately if that setting is enabled, otherwise show HUD
        if SettingsManager.shared.openEditorOnCapture {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
        } else {
            let actions = CaptureNotificationActions(
                copy: { [weak self] in self?.copyToClipboard() },
                save: { [weak self] in self?.saveAnnotatedImage() },
                annotate: { [weak self] in
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
                    // Auto-switch to arrow tool so the user can immediately start annotating
                    if let self, self.canvas.currentTool == .select || self.canvas.annotations.isEmpty {
                        self.canvas.currentTool = .arrow
                    }
                },
                pin: { [weak self] in self?.pinCurrentImage() },
                share: { [weak self] in self?.shareCurrentImage() }
            )
            let cursorScreen = NSScreen.screens.first(where: { NSPointInRect(NSEvent.mouseLocation, $0.frame) })
            CaptureNotificationWindow.shared.show(image: image, actions: actions, onScreen: cursorScreen)
        }

        Task {
            guard let item = await vault.save(image: image) else { return }
            currentVaultID = item.id
            await loadHistory()

            // QR / barcode detection (runs in parallel with OCR below)
            async let qrPayloads = detectBarcodes(in: image)

            // Run OCR in background, update when done
            let ocrText = await OCRService.recognizeText(in: image)
            if !ocrText.isEmpty {
                await vault.updateOCR(id: item.id, text: ocrText)
                // Auto-set title from first meaningful OCR line (≤40 chars)
                let firstLine = ocrText
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first(where: { $0.count >= 3 }) ?? ""
                if !firstLine.isEmpty {
                    let autoTitle = String(firstLine.prefix(40))
                    await vault.updateTitle(id: item.id, title: autoTitle)
                }
                await loadHistory()
                showStatus("OCR完了 — 検索可能になりました")
            }

            // Handle QR results
            let payloads = await qrPayloads
            if let first = payloads.first {
                if let url = URL(string: first), url.scheme != nil {
                    showStatus("QRコード検出: \(first)  ↗ 開く")
                    detectedQRURL = url
                } else {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(first, forType: .string)
                    showStatus("QRコード検出 — テキストをコピーしました: \(String(first.prefix(40)))")
                }
            }
        }
    }

    @Published var detectedQRURL: URL? = nil

    private func detectBarcodes(in image: CGImage) async -> [String] {
        await withCheckedContinuation { continuation in
            let request = VNDetectBarcodesRequest { req, _ in
                let payloads = (req.results as? [VNBarcodeObservation] ?? [])
                    .compactMap { $0.payloadStringValue }
                continuation.resume(returning: payloads)
            }
            request.symbologies = [.qr, .aztec, .dataMatrix]
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([request])
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
        guard let raw = canvas.renderAnnotations() ?? canvas.backgroundImage else {
            showStatus("コピーする画像がありません")
            return
        }
        let image = canvas.applyDecoration(to: raw)
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([nsImage])
        // Also copy annotation data if one is selected (allows cross-screenshot paste)
        canvas.copySelectedAnnotationToClipboard()
        showStatus("クリップボードにコピーしました")
    }

    func copyOriginalToClipboard() {
        guard let image = canvas.backgroundImage else {
            showStatus("コピーする画像がありません"); return
        }
        copyImageToClipboard(image)
        showStatus("オリジナル（アノテーションなし）をコピーしました")
    }

    func openInPreview() {
        // If there's a saved vault item for the current canvas, open it directly
        if let id = currentVaultID,
           let item = history.first(where: { $0.id == id }) {
            NSWorkspace.shared.open([item.imageURL], withAppBundleIdentifier: "com.apple.Preview",
                                    options: [], additionalEventParamDescriptor: nil, launchIdentifiers: nil)
            return
        }
        // Otherwise render annotations to a temp file
        guard let image = canvas.renderAnnotations() ?? canvas.backgroundImage,
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            showStatus("画像がありません"); return
        }
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapLocal-preview-\(UUID().uuidString).png")
        guard (try? data.write(to: tmpURL)) != nil else { showStatus("一時ファイル作成失敗"); return }
        NSWorkspace.shared.open([tmpURL], withAppBundleIdentifier: "com.apple.Preview",
                                options: [], additionalEventParamDescriptor: nil, launchIdentifiers: nil)
    }

    func shareCurrentImage() {
        guard let raw = canvas.renderAnnotations() ?? canvas.backgroundImage else {
            showStatus("共有する画像がありません")
            return
        }
        let image = canvas.applyDecoration(to: raw)
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            showStatus("共有する画像がありません")
            return
        }
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapLocal-share-\(UUID().uuidString).png")
        do {
            try data.write(to: tmpURL)
        } catch {
            showStatus("共有の準備に失敗しました")
            return
        }
        DispatchQueue.main.async {
            let picker = NSSharingServicePicker(items: [tmpURL])
            if let contentView = NSApp.keyWindow?.contentView {
                picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
            }
        }
    }

    private func copyImageToClipboard(_ image: CGImage) {
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([nsImage])
    }

    func copySelectedRegion() {
        guard let id = canvas.selectedAnnotationID,
              let ann = canvas.annotations.first(where: { $0.id == id }),
              let bgImage = canvas.backgroundImage,
              canvas.canvasSize.width > 0, canvas.canvasSize.height > 0 else {
            showStatus("コピーする領域を選択してください")
            return
        }
        let bounds = ann.bounds(in: CGRect(origin: .zero, size: canvas.canvasSize))
        let scaleX = CGFloat(bgImage.width) / canvas.canvasSize.width
        let scaleY = CGFloat(bgImage.height) / canvas.canvasSize.height
        let pixelRect = CGRect(
            x: bounds.minX * scaleX, y: bounds.minY * scaleY,
            width: bounds.width * scaleX, height: bounds.height * scaleY
        ).intersection(CGRect(x: 0, y: 0, width: CGFloat(bgImage.width), height: CGFloat(bgImage.height)))
        guard !pixelRect.isNull, pixelRect.width > 0, pixelRect.height > 0,
              let cropped = bgImage.cropping(to: pixelRect) else { return }
        copyImageToClipboard(cropped)
        showStatus("選択範囲をコピーしました (\(Int(pixelRect.width))×\(Int(pixelRect.height)) px)")
    }

    func ocrSelectedRegion() {
        guard let id = canvas.selectedAnnotationID,
              let ann = canvas.annotations.first(where: { $0.id == id }),
              let bgImage = canvas.backgroundImage,
              canvas.canvasSize.width > 0, canvas.canvasSize.height > 0 else {
            showStatus("テキストを認識する領域を選択してください")
            return
        }
        let bounds = ann.bounds(in: CGRect(origin: .zero, size: canvas.canvasSize))
        let scaleX = CGFloat(bgImage.width) / canvas.canvasSize.width
        let scaleY = CGFloat(bgImage.height) / canvas.canvasSize.height
        let pixelRect = CGRect(
            x: bounds.minX * scaleX, y: bounds.minY * scaleY,
            width: bounds.width * scaleX, height: bounds.height * scaleY
        ).intersection(CGRect(x: 0, y: 0, width: CGFloat(bgImage.width), height: CGFloat(bgImage.height)))
        guard !pixelRect.isNull, pixelRect.width > 0, pixelRect.height > 0,
              let cropped = bgImage.cropping(to: pixelRect) else { return }
        showStatus("OCR実行中…")
        Task {
            let text = await OCRService.recognizeText(in: cropped)
            if text.isEmpty {
                showStatus("テキストが見つかりませんでした")
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                showStatus("テキストをコピーしました (\(text.count)文字)")
            }
        }
    }

    // MARK: - Auto-redact faces

    func autoRedactFaces(in image: CGImage, canvas: CanvasViewModel) {
        showStatus("顔を検出中…")
        Task {
            let normalizedFaces = await detectFaceRects(in: image)
            if normalizedFaces.isEmpty {
                showStatus("顔が検出されませんでした")
                return
            }
            // Vision returns rects normalized [0,1] with origin at bottom-left of the image.
            // Canvas coords have origin at top-left.
            let iw = CGFloat(image.width)
            let ih = CGFloat(image.height)
            let scaleX = canvas.canvasSize.width / iw
            let scaleY = canvas.canvasSize.height / ih
            let isBlur = canvas.currentRedactMode == .blur
            for normalized in normalizedFaces {
                let pixX = normalized.minX * iw
                let pixY = (1 - normalized.maxY) * ih   // flip Y
                let pixW = normalized.width * iw
                let pixH = normalized.height * ih
                let faceRect = CGRect(
                    x: pixX * scaleX - 8, y: pixY * scaleY - 8,
                    width: pixW * scaleX + 16, height: pixH * scaleY + 16
                )
                if isBlur {
                    var a = BlurAnnotation(rect: faceRect)
                    a.intensity = Float(canvas.currentBlurRadius)
                    canvas.annotations.append(AnyAnnotation(a))
                } else {
                    var a = MosaicAnnotation(rect: faceRect)
                    a.intensity = Float(canvas.currentMosaicScale)
                    canvas.annotations.append(AnyAnnotation(a))
                }
            }
            canvas.recomputeAllFilterPreviews()
            canvas.objectWillChange.send()
            showStatus("顔を\(normalizedFaces.count)箇所検出しました")
        }
    }

    private func detectFaceRects(in image: CGImage) async -> [CGRect] {
        await withCheckedContinuation { continuation in
            let request = VNDetectFaceRectanglesRequest { req, _ in
                let obs = req.results as? [VNFaceObservation] ?? []
                continuation.resume(returning: obs.map { $0.boundingBox })
            }
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([request])
        }
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

    func exportHistoryAsZip() {
        guard !history.isEmpty else { showStatus("エクスポートする履歴がありません"); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "zip")!]
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "SnapLocal-export-\(df.string(from: Date())).zip"
        panel.begin { [self] response in
            guard response == .OK, let url = panel.url else { return }
            showStatus("ZIP作成中…")
            Task {
                do {
                    let tmpDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("SnapLocalExport-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
                    for item in history {
                        let dst = tmpDir.appendingPathComponent(item.imageURL.lastPathComponent)
                        try? FileManager.default.copyItem(at: item.imageURL, to: dst)
                    }
                    if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                    var err: NSError?
                    NSFileCoordinator().coordinate(readingItemAt: tmpDir, options: .forUploading, error: &err) { zipURL in
                        try? FileManager.default.copyItem(at: zipURL, to: url)
                    }
                    try? FileManager.default.removeItem(at: tmpDir)
                    showStatus("ZIPを保存しました: \(url.lastPathComponent) (\(history.count)件)")
                } catch {
                    showStatus("ZIP作成失敗: \(error.localizedDescription)")
                }
            }
        }
    }

    func exportHistoryAsPDF() {
        guard !history.isEmpty else { showStatus("エクスポートする履歴がありません"); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.pdf]
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "SnapLocal-\(df.string(from: Date())).pdf"
        panel.begin { [self] response in
            guard response == .OK, let url = panel.url else { return }
            showStatus("PDF作成中…")
            Task.detached(priority: .userInitiated) { [history = history] in
                let pagePt = CGSize(width: 595.0, height: 842.0)   // A4 @72 dpi
                let margin: CGFloat = 36.0
                var mediaBox = CGRect(origin: .zero, size: pagePt)
                guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
                    await MainActor.run { self.showStatus("PDF作成失敗") }
                    return
                }
                let dateFormatter = DateFormatter()
                dateFormatter.dateStyle = .short
                dateFormatter.timeStyle = .short

                for (idx, item) in history.enumerated() {
                    ctx.beginPDFPage(nil)
                    // White background
                    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
                    ctx.fill(CGRect(origin: .zero, size: pagePt))

                    // Load image
                    if let nsImg = NSImage(contentsOf: item.imageURL),
                       let cgImg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        let maxW = pagePt.width - margin * 2
                        let maxH = pagePt.height - margin * 2 - 40
                        let iw = CGFloat(cgImg.width), ih = CGFloat(cgImg.height)
                        let scale = min(maxW / iw, maxH / ih, 1.0)
                        let dw = iw * scale, dh = ih * scale
                        let x = (pagePt.width - dw) / 2
                        let y = pagePt.height - margin - dh
                        ctx.draw(cgImg, in: CGRect(x: x, y: y, width: dw, height: dh))
                    }

                    // Footer: index + date + title
                    let title = item.title ?? item.imageURL.deletingPathExtension().lastPathComponent
                    let dateStr = dateFormatter.string(from: item.createdAt)
                    let footer = "\(idx + 1) / \(history.count)   \(dateStr)   \(title)"
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 9),
                        .foregroundColor: NSColor.gray
                    ]
                    let str = NSAttributedString(string: footer, attributes: attrs)
                    let line = CTLineCreateWithAttributedString(str)
                    ctx.textPosition = CGPoint(x: margin, y: 14)
                    CTLineDraw(line, ctx)

                    ctx.endPDFPage()
                }
                ctx.closePDF()
                await MainActor.run { self.showStatus("PDFを保存しました: \(url.lastPathComponent) (\(history.count)ページ)") }
            }
        }
    }

    func deleteAllHistory() {
        Task {
            for item in history { await vault.delete(id: item.id) }
            canvas.backgroundImage = nil
            canvas.annotations.removeAll()
            currentVaultID = nil
            selectedHistoryID = nil
            await loadHistory()
            showStatus("すべての履歴を削除しました")
        }
    }

    func renameHistoryItem(_ item: VaultItem, title: String?) {
        Task {
            await vault.updateTitle(id: item.id, title: title)
            await loadHistory()
        }
    }

    func updateNotesForItem(_ item: VaultItem, notes: String?) {
        Task {
            await vault.updateNotes(id: item.id, notes: notes)
            await loadHistory()
        }
    }

    func toggleStar(for item: VaultItem) {
        Task {
            await vault.toggleStar(id: item.id)
            await loadHistory()
        }
    }

    func stitchFromClipboard(vertical: Bool) {
        guard let nsImage = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
              let other = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            showStatus("クリップボードに画像がありません")
            return
        }
        canvas.stitch(with: other, vertical: vertical)
        showStatus(vertical ? "下に結合しました" : "右に結合しました")
    }

    func revealCurrentItemInFinder() {
        guard let id = currentVaultID,
              let item = history.first(where: { $0.id == id }) else {
            showStatus("保存済みのファイルがありません")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([item.imageURL])
    }

    func duplicateHistoryItem(_ item: VaultItem) {
        Task {
            _ = await vault.duplicate(id: item.id)
            await loadHistory()
            showStatus("複製しました")
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

    var hasScreenRecordingPermission: Bool { CGPreflightScreenCaptureAccess() }

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
        guard let raw = canvas.renderAnnotations() ?? canvas.backgroundImage else {
            showStatus("保存できる画像がありません")
            return
        }
        let image = canvas.applyDecoration(to: raw)

        if let id = currentVaultID {
            Task {
                await vault.updateAnnotations(id: id, annotations: canvas.annotations)
                if !canvas.annotations.isEmpty, let annotatedRaw = canvas.renderAnnotations() {
                    await vault.updateThumbnail(id: id, annotatedImage: annotatedRaw)
                }
            }
        }

        let fmt = SettingsManager.shared.exportFormat
        let quality = SettingsManager.shared.jpegQuality
        let data: Data?
        if fmt == .jpeg {
            data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg,
                properties: [.compressionFactor: quality])
        } else {
            data = pngData(from: image)
        }
        guard let data else {
            showStatus("保存できる画像がありません"); return
        }

        do {
            let directory = SettingsManager.shared.saveDirectoryURL
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let now = Date()
            let title = history.first(where: { $0.id == currentVaultID })?.title
            let baseName = SettingsManager.shared.filename(
                for: now, width: image.width, height: image.height, title: title)
            let url = directory.appendingPathComponent("\(baseName).\(fmt.fileExtension)")
            try data.write(to: url, options: .atomic)
            let px = "\(image.width)×\(image.height)"
            showStatus("保存しました: \(url.lastPathComponent) (\(px))")
            refreshHistory()
        } catch {
            showStatus("保存失敗: \(error.localizedDescription)")
        }
    }

    func saveAnnotatedImageAs() {
        guard let raw = canvas.renderAnnotations() ?? canvas.backgroundImage else {
            showStatus("保存できる画像がありません")
            return
        }
        let image = canvas.applyDecoration(to: raw)
        let panel = NSSavePanel()
        let webpType = UTType("org.webmproject.webp") ?? .png
        panel.allowedContentTypes = [.png, .jpeg, webpType, .pdf]
        let baseName = SettingsManager.shared.filename(for: Date(), width: image.width, height: image.height, title: nil)
        panel.nameFieldStringValue = "\(baseName).png"

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
            if ext == "pdf" {
                let pdfDoc = PDFDocument()
                let nsImg = NSImage(cgImage: targetImage, size: NSSize(width: targetImage.width, height: targetImage.height))
                if let pdfPage = PDFPage(image: nsImg) {
                    pdfDoc.insert(pdfPage, at: 0)
                    if let pdfData = pdfDoc.dataRepresentation() {
                        do {
                            try pdfData.write(to: url, options: .atomic)
                            self.showStatus("保存しました: \(url.lastPathComponent)")
                        } catch { self.showStatus("保存失敗: \(error.localizedDescription)") }
                    } else { self.showStatus("PDF生成失敗") }
                } else { self.showStatus("PDF生成失敗") }
            } else if ext == "webp" {
                guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "org.webmproject.webp" as CFString, 1, nil) else {
                    self.showStatus("WebP書き出し失敗"); return
                }
                CGImageDestinationAddImage(dest, targetImage, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
                if CGImageDestinationFinalize(dest) {
                    let px = "\(targetImage.width)×\(targetImage.height)"
                    self.showStatus("保存しました: \(url.lastPathComponent) (\(px))")
                } else { self.showStatus("WebP書き出し失敗") }
            } else {
                let data: Data?
                if ext == "jpg" || ext == "jpeg" {
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
        let wasEmpty = history.isEmpty && currentVaultID == nil
        history = items
        // Auto-load the most recent screenshot on first launch
        if wasEmpty, let first = items.first {
            loadHistoryItem(first)
        }
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
    let onShare: () -> Void
    var onAutoRedactFaces: (() -> Void)? = nil
    @Binding var sidebarVisible: Bool
    var onCaptureToClipboard: (() -> Void)? = nil
    var onCaptureRegionToClipboard: (() -> Void)? = nil
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

            // ─ 線の太さ（コンパクト）─
            Picker("", selection: $canvas.currentLineWidth) {
                Text("S").tag(LineWidth.thin)
                Text("M").tag(LineWidth.medium)
                Text("L").tag(LineWidth.thick)
            }
            .pickerStyle(.segmented)
            .frame(width: 76)
            .disabled(!canvas.currentTool.usesLineWidth)
            .opacity(canvas.currentTool.usesLineWidth ? 1.0 : 0.5)
            .help("線の太さ  ([ ] で変更)")
            .onChange(of: canvas.currentLineWidth) { _, _ in
                canvas.applyCurrentLineWidthToSelection()
            }

    } // annotationToolControls

    @ViewBuilder
    private var imageEditControls: some View {
        Divider().frame(height: 18)

        Button(action: onPin) {
            Image(systemName: "pin.fill")
        }
        .help("画面にピン留め (⌘⇧P)")
        .keyboardShortcut("p", modifiers: [.command, .shift])

        Button { canvas.enterCropMode() } label: {
            Image(systemName: "scissors")
        }
        .help("切り取り (⌘K)")
        .keyboardShortcut("k", modifiers: .command)

        Button { showAdjustments.toggle() } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .help("明るさ・コントラスト・彩度")
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
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 22)
        .help("別名保存 / 共有")

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
                // Opacity
                HStack(spacing: 4) {
                    Image(systemName: "circle.lefthalf.filled").font(.system(size: 9)).foregroundStyle(.secondary)
                    Slider(value: $canvas.currentOpacity, in: 0.1...1.0, step: 0.05)
                        .frame(width: 64).controlSize(.mini)
                        .onChange(of: canvas.currentOpacity) { _, _ in canvas.applyCurrentOpacityToSelection() }
                    Text("\(Int(canvas.currentOpacity * 100))%")
                        .font(.system(size: 9, design: .monospaced)).frame(width: 28)
                }
                // Line style
                Picker("", selection: $canvas.currentLineStyle) {
                    LineStylePreview(style: .solid).tag(LineStyle.solid)
                    LineStylePreview(style: .dashed).tag(LineStyle.dashed)
                    LineStylePreview(style: .dotted).tag(LineStyle.dotted)
                }
                .pickerStyle(.segmented).frame(width: 72)
                .disabled(!canvas.currentTool.usesLineWidth)
                .onChange(of: canvas.currentLineStyle) { _, _ in canvas.applyCurrentLineStyleToSelection() }
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
    var onRename: ((VaultItem, String?) -> Void)? = nil
    var onDuplicate: ((VaultItem) -> Void)? = nil
    var onDeleteAll: (() -> Void)? = nil
    var onExportZip: (() -> Void)? = nil
    var onExportPDF: (() -> Void)? = nil
    var onUpdateNotes: ((VaultItem, String?) -> Void)? = nil
    var onToggleStar: ((VaultItem) -> Void)? = nil

    @FocusState private var searchFocused: Bool
    @State private var thumbCache: [UUID: NSImage] = [:]
    @State private var hoveredItemID: UUID? = nil
    @State private var popoverItemID: UUID? = nil   // delayed popover — avoids flicker on fast scroll
    @State private var popoverTask: Task<Void, Never>? = nil
    @State private var renamingItemID: UUID? = nil
    @State private var quickLookItem: VaultItem? = nil
    @State private var renameText: String = ""
    @State private var showDeleteAllConfirm = false
    @State private var showOnlyStarred = false

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

    private enum DateGroup: String {
        case today = "今日"
        case yesterday = "昨日"
        case thisWeek = "今週"
        case older = "それ以前"
    }

    private func dateGroup(for date: Date) -> DateGroup {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return .today }
        if cal.isDateInYesterday(date) { return .yesterday }
        if let daysAgo = cal.dateComponents([.day], from: date, to: Date()).day, daysAgo < 7 { return .thisWeek }
        return .older
    }

    private var displayedHistory: [VaultItem] {
        showOnlyStarred ? history.filter { $0.isStarred } : history
    }

    private var groupedHistory: [(DateGroup, [VaultItem])] {
        let order: [DateGroup] = [.today, .yesterday, .thisWeek, .older]
        let grouped = Dictionary(grouping: displayedHistory, by: { dateGroup(for: $0.createdAt) })
        return order.compactMap { g in
            guard let items = grouped[g], !items.isEmpty else { return nil }
            return (g, items)
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

            if displayedHistory.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text(searchQuery.isEmpty ? "キャプチャなし" : "見つかりません")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(groupedHistory, id: \.0.rawValue) { group, items in
                        Text(group.rawValue)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                        VStack(spacing: 6) {
                        ForEach(items) { item in
                            HistoryItemRow(
                                item: item,
                                isSelected: item.id == selectedID,
                                isHovered: hoveredItemID == item.id,
                                showPopover: popoverItemID == item.id,
                                isRenaming: renamingItemID == item.id,
                                renameText: $renameText,
                                searchQuery: searchQuery,
                                thumbW: thumbW, thumbH: thumbH,
                                thumbCache: $thumbCache,
                                onSelect: { onSelect(item) },
                                onToggleStar: { onToggleStar?(item) },
                                onDelete: { onDelete(item) },
                                onDuplicate: { onDuplicate?(item) },
                                onExport: { onExport(item) },
                                onRename: { name in onRename?(item, name); renamingItemID = nil },
                                onRenameBegin: { renameText = item.title ?? ""; renamingItemID = item.id },
                                onRenameCancelled: { renamingItemID = nil },
                                onPopoverDismiss: { popoverItemID = nil },
                                onUpdateNotes: onUpdateNotes,
                                historyItemLabel: historyItemLabel,
                                onHoverChanged: { hovering in
                                    hoveredItemID = hovering ? item.id : nil
                                    popoverTask?.cancel()
                                    if hovering {
                                        popoverTask = Task {
                                            try? await Task.sleep(nanoseconds: 400_000_000)
                                            if hoveredItemID == item.id { popoverItemID = item.id }
                                        }
                                    } else {
                                        popoverItemID = nil
                                    }
                                }
                            )
                        }   // ForEach(items)
                        }   // VStack for items
                        .padding(.horizontal, 6)
                        .padding(.bottom, 4)
                    }   // ForEach(groupedHistory)
                }   // outer VStack
            }
            .onChange(of: selectedID) { _, newID in
                if let id = newID {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            .onKeyPress(.space) {
                if let id = hoveredItemID, let item = displayedHistory.first(where: { $0.id == id }) {
                    if quickLookItem?.id == item.id {
                        quickLookItem = nil
                    } else {
                        quickLookItem = item
                    }
                    return .handled
                }
                return .ignored
            }
            .onKeyPress(characters: .init(charactersIn: "\u{F700}\u{F701}"), phases: [.down, .repeat]) { press in
                // ↑/↓ keyboard navigation in history
                let list = displayedHistory
                guard !list.isEmpty else { return .ignored }
                let currentIdx = list.firstIndex(where: { $0.id == selectedID }) ?? -1
                let delta = press.key == .upArrow ? -1 : 1
                let nextIdx = max(0, min(list.count - 1, currentIdx + delta))
                let nextItem = list[nextIdx]
                if nextItem.id != selectedID {
                    onSelect(nextItem)
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(nextItem.id, anchor: .center)
                    }
                }
                return .handled
            }
            .onKeyPress(.return) {
                if let id = selectedID, let item = displayedHistory.first(where: { $0.id == id }) {
                    onSelect(item); return .handled
                }
                return .ignored
            }
            .onKeyPress(.deleteForward) {
                if let id = selectedID, let item = displayedHistory.first(where: { $0.id == id }) {
                    onDelete(item); return .handled
                }
                return .ignored
            }
            } // ScrollViewReader

            Divider()
            HStack(spacing: 0) {
                Text("\(displayedHistory.count)件")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                Spacer()
                Button(action: { showOnlyStarred.toggle() }) {
                    Image(systemName: showOnlyStarred ? "star.fill" : "star")
                        .font(.caption2)
                        .foregroundStyle(showOnlyStarred ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(showOnlyStarred ? "全件表示" : "スター付きのみ表示")
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                if let onExportZip {
                    Button(action: onExportZip) {
                        Image(systemName: "arrow.down.doc")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help("すべての履歴をZIPでエクスポート")
                }
                if let onExportPDF {
                    Button(action: onExportPDF) {
                        Image(systemName: "doc.richtext")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help("すべての履歴をPDFでエクスポート")
                }
                if let onDeleteAll {
                    Button(action: { showDeleteAllConfirm = true }) {
                        Image(systemName: "trash")
                            .font(.caption2)
                            .foregroundStyle(.red.opacity(0.7))
                    }
                    .buttonStyle(.borderless)
                    .padding(.trailing, 4)
                    .confirmationDialog("すべての履歴を削除しますか？\nこの操作は取り消せません。", isPresented: $showDeleteAllConfirm, titleVisibility: .visible) {
                        Button("すべて削除", role: .destructive) { onDeleteAll() }
                        Button("キャンセル", role: .cancel) {}
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 88)
        .background(.regularMaterial)
        .onKeyPress(.escape) {
            if quickLookItem != nil {
                HistoryQuickLook.shared.dismiss()
                quickLookItem = nil
                return .handled
            }
            return .ignored
        }
        .onChange(of: quickLookItem?.id) { _, newID in
            if let item = quickLookItem {
                HistoryQuickLook.shared.show(item: item)
            } else {
                HistoryQuickLook.shared.dismiss()
            }
        }
    }
}

// MARK: - History Item Row

private struct HistoryItemRow: View {
    let item: VaultItem
    let isSelected: Bool
    let isHovered: Bool
    let showPopover: Bool
    let isRenaming: Bool
    @Binding var renameText: String
    let searchQuery: String
    let thumbW: CGFloat
    let thumbH: CGFloat
    @Binding var thumbCache: [UUID: NSImage]
    let onSelect: () -> Void
    let onToggleStar: () -> Void
    let onDelete: () -> Void
    let onDuplicate: () -> Void
    let onExport: () -> Void
    let onRename: (String?) -> Void
    let onRenameBegin: () -> Void
    let onRenameCancelled: () -> Void
    let onPopoverDismiss: () -> Void
    var onUpdateNotes: ((VaultItem, String?) -> Void)?
    let historyItemLabel: (Date) -> String
    let onHoverChanged: (Bool) -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 3) {
                thumbnailView
                labelView
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
        .onDrag { NSItemProvider(contentsOf: item.imageURL) ?? NSItemProvider() }
        .onHover(perform: onHoverChanged)
        .popover(isPresented: Binding(get: { showPopover }, set: { if !$0 { onPopoverDismiss() } }), arrowEdge: .leading) {
            HistoryItemPopover(item: item, onUpdateNotes: onUpdateNotes)
        }
        .contextMenu { contextMenuContent }
        .help(makeHelp())
    }

    private func makeHelp() -> String {
        var s = item.createdAt.formatted(date: .complete, time: .shortened)
        if item.width > 0 { s += "  \(item.width)×\(item.height)" }
        s += "  Space: クイックルック"
        if !item.ocrText.isEmpty { s += "\n" + String(item.ocrText.prefix(80)) }
        return s
    }

    @ViewBuilder private var thumbnailView: some View {
        Group {
            if let nsImage = thumbCache[item.id] ?? NSImage(data: item.thumbnailData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .onAppear { if thumbCache[item.id] == nil { thumbCache[item.id] = nsImage } }
            } else {
                Image(systemName: "photo")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: thumbW, height: thumbH)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(alignment: .topTrailing) {
            if item.annotations.count > 0 {
                Text("\(item.annotations.count)")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(Color.accentColor, in: Capsule())
                    .padding(2)
            }
        }
        .overlay(alignment: .bottomLeading) {
            let dim = item.dimensionLabel
            if !dim.isEmpty {
                Text(dim)
                    .font(.system(size: 6, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(Color.black.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .padding(2)
            }
        }
        .overlay(alignment: .topLeading) {
            if item.isStarred || isHovered {
                let icon = item.isStarred ? "star.fill" : "star"
                let color: Color = item.isStarred ? .yellow : .white.opacity(0.8)
                Button(action: onToggleStar) {
                    Image(systemName: icon)
                        .font(.system(size: 8))
                        .foregroundStyle(color)
                        .padding(2)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .padding(2)
            }
        }
        .overlay(alignment: .topTrailing) {
            if item.notes != nil {
                Image(systemName: "note.text")
                    .font(.system(size: 7))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(2)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2))
    }

    @ViewBuilder private var labelView: some View {
        if isRenaming {
            TextField("名前", text: $renameText)
                .font(.system(size: 8))
                .textFieldStyle(.roundedBorder)
                .frame(width: thumbW)
                .onSubmit { onRename(renameText.isEmpty ? nil : renameText) }
                .onExitCommand { onRenameCancelled() }
        } else {
            VStack(spacing: 1) {
                if let title = item.title {
                    Text(title)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                        .lineLimit(1)
                        .frame(width: thumbW, alignment: .leading)
                }
                Text(historyItemLabel(item.createdAt))
                    .font(.system(size: 8))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder private var contextMenuContent: some View {
        Button(item.isStarred ? "スターを外す" : "スターを付ける") { onToggleStar() }
        Divider()
        Button("開く") { onSelect() }
        Button("複製") { onDuplicate() }
        Button("名前を変更…") { onRenameBegin() }
        Divider()
        Button("ファイルに保存…") { onExport() }
        Button("Finderで表示") { NSWorkspace.shared.activateFileViewerSelecting([item.imageURL]) }
        Button("Previewで開く") {
            NSWorkspace.shared.open([item.imageURL], withAppBundleIdentifier: "com.apple.Preview",
                                    options: [], additionalEventParamDescriptor: nil, launchIdentifiers: nil)
        }
        Button("ファイルパスをコピー") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.imageURL.path, forType: .string)
        }
        Button("Markdownリンクをコピー") {
            let alt = item.title ?? "screenshot"
            let md = "![" + alt + "](" + item.imageURL.path + ")"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(md, forType: .string)
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
        Button("削除", role: .destructive) { onDelete() }
    }
}

// MARK: - History Item Popover

struct HistoryItemPopover: View {
    let item: VaultItem
    var onUpdateNotes: ((VaultItem, String?) -> Void)?

    @State private var notesText: String

    init(item: VaultItem, onUpdateNotes: ((VaultItem, String?) -> Void)?) {
        self.item = item
        self.onUpdateNotes = onUpdateNotes
        self._notesText = State(initialValue: item.notes ?? "")
    }

    var body: some View {
        VStack(spacing: 6) {
            if let nsImage = NSImage(data: item.imageData) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 360, maxHeight: 240)
            } else {
                Color.clear.frame(width: 120, height: 80)
            }
            let dim = item.dimensionLabel
            if !dim.isEmpty {
                Text(dim)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if !item.ocrText.isEmpty {
                Divider()
                HStack(alignment: .top, spacing: 6) {
                    Text(item.ocrText)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.ocrText, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("テキストをコピー")
                }
                .frame(width: 360)
            }
            Divider()
            TextEditor(text: $notesText)
                .font(.system(size: 12))
                .frame(width: 360, height: 56)
                .scrollContentBackground(.hidden)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if notesText.isEmpty {
                        Text("メモを追加…")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 12))
                            .padding(.top, 4).padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: notesText) { _, newVal in
                    onUpdateNotes?(item, newVal.isEmpty ? nil : newVal)
                }
        }
        .padding(8)
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
    // dx, dy, isCommandDown, cursorInView (nil if not cmd)
    let onScroll: (CGFloat, CGFloat, Bool, CGPoint?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ScrollableNSView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ScrollableNSView)?.onScroll = onScroll
    }

    class ScrollableNSView: NSView {
        var onScroll: ((CGFloat, CGFloat, Bool, CGPoint?) -> Void)?

        override var acceptsFirstResponder: Bool { false }

        override func scrollWheel(with event: NSEvent) {
            let cmd = event.modifierFlags.contains(.command)
            let cursor: CGPoint? = cmd ? convert(event.locationInWindow, from: nil) : nil
            onScroll?(event.scrollingDeltaX, event.scrollingDeltaY, cmd, cursor)
            if !cmd { super.scrollWheel(with: event) }
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

// MARK: - Multiline text input (NSTextView wrapper)
// Supports Return=commit, Shift/Option+Return=newline, Escape=cancel
struct MultilineTextInput: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    var color: NSColor
    var minWidth: CGFloat
    var onCommit: () -> Void
    var onCancel: () -> Void
    var onHeightChange: ((CGFloat) -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NonScrollingTextView()
        tv.delegate = context.coordinator
        tv.isEditable = true
        tv.isRichText = false
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 0
        tv.autoresizingMask = [.width]
        tv.onHeightChange = onHeightChange

        let sv = NSScrollView()
        sv.hasVerticalScroller = false
        sv.hasHorizontalScroller = false
        sv.drawsBackground = false
        sv.borderType = .noBorder
        sv.documentView = tv
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? NonScrollingTextView else { return }
        context.coordinator.isUpdating = true
        if tv.string != text { tv.string = text }
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        tv.font = font
        tv.textColor = color
        context.coordinator.isUpdating = false
        // Become first responder on first appearance
        if !context.coordinator.didBecomeFirstResponder {
            context.coordinator.didBecomeFirstResponder = true
            DispatchQueue.main.async { sv.window?.makeFirstResponder(tv) }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit, onCancel: onCancel, onHeightChange: onHeightChange)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        let onCommit: () -> Void
        let onCancel: () -> Void
        let onHeightChange: ((CGFloat) -> Void)?
        var isUpdating = false
        var didBecomeFirstResponder = false

        init(text: Binding<String>, onCommit: @escaping () -> Void, onCancel: @escaping () -> Void, onHeightChange: ((CGFloat) -> Void)?) {
            _text = text
            self.onCommit = onCommit
            self.onCancel = onCancel
            self.onHeightChange = onHeightChange
        }

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let tv = notification.object as? NSTextView else { return }
            text = tv.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                let mods = NSApp.currentEvent?.modifierFlags ?? []
                if mods.contains(.shift) || mods.contains(.option) {
                    textView.insertNewlineIgnoringFieldEditor(nil)
                    text = textView.string
                    return true
                }
                onCommit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                onCancel()
                return true
            }
            return false
        }
    }
}

class NonScrollingTextView: NSTextView {
    var onHeightChange: ((CGFloat) -> Void)?

    override func didChangeText() {
        super.didChangeText()
        sizeToFit()
        let h = frame.height
        onHeightChange?(h + 8)
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
            ("⌘⇧4", "範囲選択撮影（ウィンドウスナップ対応）"),
            ("⌘⇧R", "前回範囲を再撮影"),
            ("⌘⌃2", "全画面→クリップボードのみ（履歴に保存しない）"),
            ("⌘⌃4", "範囲選択→クリップボードのみ"),
            ("タイマー", "3/5/10秒遅延撮影"),
            ("⌘V", "クリップボードから貼り付け"),
            ("⌘⇧P", "画面にピン留め"),
            ("⌘F", "フィット表示"),
        ]),
        ("範囲選択モード（⌘⇧4）", [
            ("スクリーンフリーズ", "起動時に画面を静止画として固定 — ツールチップやメニューも撮影可能"),
            ("ドラッグ", "範囲を選択（ウィンドウ自動スナップ対応）"),
            ("Shift+ドラッグ", "正方形に制約"),
            ("Space+ドラッグ中", "選択範囲を移動（サイズ固定）"),
            ("矢印キー", "1px微調整（Shift=10px）"),
            ("↵ / ダブルクリック", "確定して撮影（即時反映 — 再キャプチャ不要）"),
            ("Esc", "キャンセル / やり直し"),
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
            ("G", "スタンプ（クリックで絵文字配置）"),
            ("I", "スポイト（クリックで色をサンプリング）"),
            ("X / M", "モザイク/ぼかし"),
            ("O", "スポットライト"),
            ("Q", "ピクセル定規"),
            ("Tab", "アノテーション選択切り替え（選択モード）/ 次のツール"),
        ]),
        ("描画", [
            ("Shift+ドラッグ", "45°制約 / 正方形/正円"),
            ("F", "塗りつぶし切り替え（長方形・楕円・吹き出し）"),
            ("Option+クリック", "スポイト（色を拾う）"),
            ("Option+ドラッグ", "アノテーション複製"),
            ("[  /  ]", "線幅 細/太"),
            ("{  /  }", "不透明度 -10% / +10%"),
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
            ("テキスト入力中⇧⏎", "テキストに改行を挿入（複数行対応）"),
            ("⌘K → 矢印", "クロップ範囲を移動（⌥+矢印でリサイズ）"),
            ("Esc", "選択解除 / モード終了"),
        ]),
        ("ズーム/パン", [
            ("ピンチ / スクロール", "ズーム・パン"),
            ("Space+ドラッグ", "パン"),
            ("⌘+ / ⌘-", "ズームイン/アウト"),
            ("⌘0", "ズームリセット (100%)"),
            ("⌘F", "フィット表示"),
        ]),
        ("その他", [
            ("⌘↑ / ⌘↓", "履歴の前/次"),
            ("⌘K", "切り取りモード"),
            ("⌘⌥← / ⌘⌥→", "90°回転（左/右）"),
            ("⌘C", "クリップボードにコピー（アノテーション込み）"),
            ("⌘⌥C", "オリジナルをコピー（アノテーションなし）"),
            ("⌘⌥⇧C", "選択範囲を画像でコピー"),
            ("⌘⌥T", "選択範囲のテキストをOCR・コピー"),
            ("⌘S", "ファイルに保存"),
            ("⌘⇧S", "別名で保存"),
            ("⌘⇧E", "共有（AirDrop・メール等）"),
            ("履歴サムネイルホバー", "プレビュー・メモ編集"),
            ("顔自動モザイク", "消しゴムツールボタンで顔を一括ぼかし"),
            ("↔ トグル", "矢印ツール選択時：両方向矢印に切り替え"),
            ("変形メニュー", "余白自動トリミング・反転・リサイズ"),
            ("テンプレートアイコン", "アノテーションセットを名前付きで保存・適用"),
            ("右下ステータス", "選択アノテーションのpx座標 [幅×高さ @x,y]"),
            ("左下座標", "カーソルのキャンバス座標をリアルタイム表示"),
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
    @State private var filenameTemplate: String = ""
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ファイル名テンプレート")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("{date}, {time}, {width}, {height}, {title}", text: $filenameTemplate)
                            .font(.system(.caption, design: .monospaced))
                            .onSubmit { settings.filenameTemplate = filenameTemplate }
                            .onChange(of: filenameTemplate) { settings.filenameTemplate = filenameTemplate }
                        Text("例: SnapLocal-{date}-{time}  →  \(settings.filename(for: Date(), width: 1920, height: 1080, title: nil))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
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

                Section("キャプチャ") {
                    Toggle("カーソルを含める", isOn: Binding(
                        get: { settings.captureWithCursor },
                        set: { settings.captureWithCursor = $0 }
                    ))
                    Toggle("撮影後にクリップボードへ自動コピー", isOn: Binding(
                        get: { settings.autoCopyOnCapture },
                        set: { settings.autoCopyOnCapture = $0 }
                    ))
                    Toggle("撮影後すぐにエディタを開く（HUDをスキップ）", isOn: Binding(
                        get: { settings.openEditorOnCapture },
                        set: { settings.openEditorOnCapture = $0 }
                    ))
                }

                Section("書き出し形式") {
                    Picker("形式", selection: Binding(
                        get: { settings.exportFormat },
                        set: { settings.exportFormat = $0 }
                    )) {
                        ForEach(ExportFormat.allCases, id: \.self) { fmt in
                            Text(fmt.displayName).tag(fmt)
                        }
                    }
                    .pickerStyle(.segmented)
                    if settings.exportFormat == .jpeg {
                        HStack {
                            Text("JPEG品質")
                                .foregroundStyle(.secondary)
                            Slider(value: Binding(
                                get: { settings.jpegQuality },
                                set: { settings.jpegQuality = $0 }
                            ), in: 0.4...1.0, step: 0.05)
                            Text("\(Int(settings.jpegQuality * 100))%")
                                .font(.system(.caption, design: .monospaced))
                                .frame(width: 36)
                        }
                    }
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
        .onAppear {
            saveDirectoryPath = settings.saveDirectoryURL.path
            filenameTemplate = settings.filenameTemplate
        }
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
    @AppStorage("sidebarVisible") private var sidebarVisible = true

    var windowTitle: String {
        guard state.canvas.backgroundImage != nil else { return "SnapLocal" }
        if let id = state.selectedHistoryID,
           let item = state.history.first(where: { $0.id == id }),
           let title = item.title, !title.isEmpty {
            return title
        }
        if let img = state.canvas.backgroundImage {
            return "\(img.width) × \(img.height)"
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
                onPaste: state.pasteFromClipboard,
                onShare: state.shareCurrentImage,
                onAutoRedactFaces: {
                    guard let img = state.canvas.backgroundImage else { return }
                    state.autoRedactFaces(in: img, canvas: state.canvas)
                },
                sidebarVisible: $sidebarVisible,
                onCaptureToClipboard: state.captureNowToClipboard,
                onCaptureRegionToClipboard: state.captureRegionToClipboard
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
                    onOpenPermissions: state.hasScreenRecordingPermission ? nil : { state.openScreenRecordingSettings() },
                    onFocusSearch: { state.searchFocusTrigger.toggle() },
                    onNavigateHistory: { delta in state.navigateHistory(by: delta) },
                    onCopyOriginal: state.copyOriginalToClipboard,
                    onCopyRegion: state.copySelectedRegion,
                    onOcrRegion: state.ocrSelectedRegion
                )
                    .frame(minWidth: 600, minHeight: 400)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .onDrop(of: [UTType.image, UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                        state.handleDroppedProviders(providers)
                    }
                    .overlay {
                        if isDropTargeted {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.accentColor.opacity(0.08))
                                    .padding(4)
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [10, 5]))
                                    .padding(4)
                                VStack(spacing: 8) {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .font(.system(size: 36))
                                        .foregroundStyle(Color.accentColor)
                                    Text("画像をドロップして開く")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(Color.accentColor)
                                }
                                .padding(16)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                                .shadow(color: Color.accentColor.opacity(0.2), radius: 12, y: 4)
                            }
                            .transition(.opacity)
                            .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        StatusChip(message: state.statusMessage, visible: state.statusVisible)
                            .padding(.bottom, 14)
                            .animation(.easeInOut(duration: 0.2), value: state.statusVisible)
                    }
                    .overlay(alignment: .bottomLeading) {
                        if let qrURL = state.detectedQRURL {
                            Button(action: {
                                NSWorkspace.shared.open(qrURL)
                                state.detectedQRURL = nil
                            }) {
                                HStack(spacing: 5) {
                                    Image(systemName: "qrcode.viewfinder")
                                        .font(.system(size: 11))
                                    Text(qrURL.absoluteString.count > 40
                                         ? String(qrURL.absoluteString.prefix(40)) + "…"
                                         : qrURL.absoluteString)
                                        .font(.system(size: 10))
                                        .lineLimit(1)
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.secondary)
                                        .onTapGesture { state.detectedQRURL = nil }
                                }
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                                .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                            }
                            .buttonStyle(.plain)
                            .padding([.bottom, .leading], 14)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let img = state.canvas.backgroundImage {
                            let zoomPct = Int(state.canvas.currentZoom * 100)
                            let annCount = state.canvas.annotations.count
                            let selInfo: String = {
                                guard let selID = state.canvas.selectedAnnotationID,
                                      let ann = state.canvas.annotations.first(where: { $0.id == selID }),
                                      state.canvas.canvasSize.width > 0 else { return "" }
                                let b = ann.bounds(in: CGRect(origin: .zero, size: state.canvas.canvasSize))
                                let sx = CGFloat(img.width) / state.canvas.canvasSize.width
                                let sy = CGFloat(img.height) / state.canvas.canvasSize.height
                                let pw = Int(b.width * sx), ph = Int(b.height * sy)
                                let px = Int(b.minX * sx), py = Int(b.minY * sy)
                                return "  [\(pw)×\(ph) @\(px),\(py)]"
                            }()
                            let info = "\(img.width) × \(img.height)  \(zoomPct)%"
                                + (annCount > 0 ? "  ✎\(annCount)" : "")
                                + selInfo
                            Text(info)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                                .padding([.bottom, .trailing], 8)
                        }
                    }

                if sidebarVisible {
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
                        onExport: state.exportHistoryItem,
                        onRename: state.renameHistoryItem,
                        onDuplicate: state.duplicateHistoryItem,
                        onDeleteAll: state.deleteAllHistory,
                        onExportZip: state.exportHistoryAsZip,
                        onExportPDF: state.exportHistoryAsPDF,
                        onUpdateNotes: state.updateNotesForItem,
                        onToggleStar: state.toggleStar
                    )
                    .transition(.move(edge: .trailing))
                }
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
    var onCopyOriginal: (() -> Void)? = nil
    var onCopyRegion: (() -> Void)? = nil
    var onOcrRegion: (() -> Void)? = nil

    @FocusState private var textFieldFocused: Bool
    @FocusState private var canvasFocused: Bool
    @State private var textInputHeight: CGFloat = 36
    @State private var isHovering = false
    @State private var zoom: CGFloat = 1.0
    @State private var baseZoom: CGFloat = 1.0
    @State private var panOffset: CGSize = .zero
    @State private var basePan: CGSize = .zero
    @State private var isPanning = false
    @State private var hoverLocation: CGPoint? = nil
    @State private var hoverColorHex: String? = nil
    @State private var hoverCanvasPoint: CGPoint? = nil
    @State private var imageOpacity: Double = 1.0

    @State private var hoverHandleIndex: Int? = nil

    private func updateCursor() {
        guard isHovering else { return }
        if isPanning {
            NSCursor.openHand.set()
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
        case .redact, .highlight:
            NSCursor.crosshair.set()
        default:
            NSCursor.crosshair.set()
        }
    }

    private func toCanvas(_ point: CGPoint, size: CGSize) -> CGPoint {
        let cx = size.width / 2, cy = size.height / 2
        return CGPoint(x: (point.x - cx) / zoom + cx, y: (point.y - cy) / zoom + cy)
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
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: 16, height: 16)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.6), lineWidth: 1))
                Text("#" + hex.prefix(6).lowercased())
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7))
            .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
            .offset(x: x, y: y)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image = viewModel.backgroundImage {
                    Image(decorative: image, scale: 1.0, orientation: .up)
                        .resizable()
                        .interpolation(zoom >= 3.0 ? .none : .high)
                        .scaledToFit()
                        .brightness(viewModel.adjustBrightness)
                        .contrast(viewModel.adjustContrast)
                        .saturation(viewModel.adjustSaturation)
                        .opacity(imageOpacity)
                        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
                    annotationLayer(size: proxy.size)
                    // Animated crop overlay (TimelineView for marching ants)
                    if viewModel.isCropMode {
                        cropOverlayLayer(size: proxy.size)
                            .allowsHitTesting(false)
                    }
                    // Pixel grid overlay at zoom ≥ 4×
                    if zoom >= 4.0, let img = viewModel.backgroundImage {
                        let cellW = proxy.size.width / CGFloat(img.width)
                        let cellH = proxy.size.height / CGFloat(img.height)
                        Canvas { ctx, size in
                            let opacity = min(0.35, Double((zoom - 4) / 4) * 0.35)
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
                            HintRow(key: "⌘⇧3", label: "ウィンドウ撮影")
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
            .onAppear { viewModel.canvasSize = proxy.size; viewModel.currentZoom = zoom }
            .onChange(of: proxy.size) { _, newSize in viewModel.canvasSize = newSize }
            .onChange(of: zoom) { _, z in viewModel.currentZoom = z }
            .modifier(ZoomNotificationHandler(
                zoom: $zoom, baseZoom: $baseZoom,
                panOffset: $panOffset, basePan: $basePan,
                canvasSize: viewModel.canvasSize,
                imageSize: viewModel.backgroundImage.map { CGSize(width: $0.width, height: $0.height) }
            ))
            .overlay(textInputOverlay)
            .overlay(
                ScrollWheelHandler { dx, dy, isCmd, cursor in
                    if isCmd {
                        // ⌘+scroll → zoom toward cursor
                        let oldZoom = zoom
                        let newZoom = max(0.25, min(8.0, zoom * (1.0 + dy * 0.02)))
                        zoom = newZoom; baseZoom = newZoom
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
                if abs(zoom - 1.0) > 0.01 {
                    Text("\(Int(zoom * 100))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .padding(8)
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.2)) { zoom = 1.0; baseZoom = 1.0; panOffset = .zero; basePan = .zero }
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
                        let vx = cx + (lp.x - cx) * zoom + panOffset.width
                        let vy = cy + (lp.y - cy) * zoom + panOffset.height
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
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                        .padding(.bottom, 20)
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
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 3))
                            .padding(6)
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
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 3))
                            .padding(6)
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
                withAnimation(.easeOut(duration: 0.15)) { zoom = min(8.0, zoom * 1.25); baseZoom = zoom }
                return .handled
            }
            .onKeyPress("-", phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                withAnimation(.easeOut(duration: 0.15)) { zoom = max(0.25, zoom / 1.25); baseZoom = zoom }
                return .handled
            }
            .onKeyPress("0", phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                withAnimation(.easeOut(duration: 0.2)) { zoom = 1.0; baseZoom = 1.0; panOffset = .zero; basePan = .zero }
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
                guard press.modifiers.contains(.command) else { return .ignored }
                // ⌘F = Fit canvas to viewport
                let iw: CGFloat = viewModel.backgroundImage.map { CGFloat($0.width) } ?? viewModel.canvasSize.width
                let ih: CGFloat = viewModel.backgroundImage.map { CGFloat($0.height) } ?? viewModel.canvasSize.height
                guard iw > 0, ih > 0 else { return .ignored }
                let fitW = viewModel.canvasSize.width / iw
                let fitH = viewModel.canvasSize.height / ih
                let fitZoom: CGFloat = min(fitW, fitH)
                withAnimation(.easeOut(duration: 0.2)) {
                    zoom = max(0.25, min(8.0, fitZoom))
                    baseZoom = zoom
                    panOffset = .zero; basePan = .zero
                }
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
                    if viewModel.currentTool == .select, !viewModel.isDraggingAnnotation {
                        let canvasLoc = toCanvas(location, size: proxy.size)
                        let hit = viewModel.annotations.last(where: {
                            !$0.isLocked && $0.hitTest(canvasLoc, in: CGRect(origin: .zero, size: viewModel.canvasSize))
                        })
                        viewModel.hoveredAnnotationID = hit?.id
                        // Check if hovering over a resize/endpoint handle of the selected annotation
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
                // Auto-fit: zoom to fill the canvas view, capped at 4x (good for small region captures)
                if let img = viewModel.backgroundImage,
                   viewModel.canvasSize.width > 0, viewModel.canvasSize.height > 0 {
                    let iw = CGFloat(img.width), ih = CGFloat(img.height)
                    let fitW = viewModel.canvasSize.width / iw
                    let fitH = viewModel.canvasSize.height / ih
                    // Fit image to canvas with 10% margin, cap zoom at 4x to avoid excessive upscaling
                    let fitZoom = min(fitW, fitH) * 0.9
                    zoom = max(0.25, min(4.0, fitZoom)); baseZoom = zoom
                } else {
                    zoom = 1.0; baseZoom = 1.0
                }
                panOffset = .zero; basePan = .zero
                imageOpacity = 0
                withAnimation(.easeOut(duration: 0.25)) { imageOpacity = 1.0 }
            }
            .onChange(of: viewModel.cropAnimToken) { _, _ in
                imageOpacity = 0
                withAnimation(.easeOut(duration: 0.2)) { imageOpacity = 1.0 }
            }
        }
    }

    // Animated crop overlay using TimelineView for marching ants
    @ViewBuilder
    private func cropOverlayLayer(size: CGSize) -> some View {
        TimelineView(.animation(minimumInterval: 0.05)) { timeline in
            Canvas { context, _ in
                let phase = timeline.date.timeIntervalSinceReferenceDate * 20
                drawCropOverlay(context: context, size: size, dashPhase: CGFloat(phase))
            }
        }
    }

    private func drawCropOverlay(context: GraphicsContext, size: CGSize, dashPhase: CGFloat) {
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

    private func annotationLayer(size: CGSize) -> some View {
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

            // Hover glow: draw a faint accent outline behind the hovered annotation (select mode only)
            if viewModel.currentTool == .select,
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

            // Resize handles for selected resizable annotation (single select only)
            if viewModel.currentTool == .select,
               viewModel.selectedAnnotationIDs.count <= 1,
               let id = viewModel.selectedAnnotationID,
               let ann = viewModel.annotations.first(where: { $0.id == id }),
               CanvasViewModel.isResizable(ann.type) {
                let bounds = ann.bounds(in: canvasRect)
                let handles = viewModel.handleCorners(for: bounds)
                for (i, handle) in handles.enumerated() {
                    let hs: CGFloat = i < 4 ? 5.5 : 4.5  // corners slightly larger
                    let outer = CGRect(x: handle.x - hs - 1, y: handle.y - hs - 1, width: (hs+1)*2, height: (hs+1)*2)
                    let inner = CGRect(x: handle.x - hs, y: handle.y - hs, width: hs*2, height: hs*2)
                    if i < 4 {
                        // Corner handles: circles
                        context.fill(Path(ellipseIn: outer), with: .color(.black.opacity(0.2)))
                        context.fill(Path(ellipseIn: inner), with: .color(.white))
                        context.stroke(Path(ellipseIn: inner), with: .color(.accentColor), lineWidth: 1.5)
                    } else {
                        // Mid-edge handles: small rounded squares
                        context.fill(Path(roundedRect: outer, cornerRadius: 2), with: .color(.black.opacity(0.2)))
                        context.fill(Path(roundedRect: inner, cornerRadius: 2), with: .color(.white))
                        context.stroke(Path(roundedRect: inner, cornerRadius: 2), with: .color(.accentColor), lineWidth: 1.5)
                    }
                }
                // Callout tail handle (index 8 — distinct orange dot)
                if ann.type == .callout, let baseTail = ann.calloutTailPoint {
                    let tailCanvas = baseTail.applying(ann.transform)
                    let hs: CGFloat = 5.0
                    let outer = CGRect(x: tailCanvas.x - hs - 1, y: tailCanvas.y - hs - 1, width: (hs+1)*2, height: (hs+1)*2)
                    let inner = CGRect(x: tailCanvas.x - hs, y: tailCanvas.y - hs, width: hs*2, height: hs*2)
                    context.fill(Path(ellipseIn: outer), with: .color(.black.opacity(0.2)))
                    context.fill(Path(ellipseIn: inner), with: .color(.white))
                    context.stroke(Path(ellipseIn: inner), with: .color(Color.orange), lineWidth: 1.5)
                }
            }

            // Arrow / Line endpoint handles (single selection)
            if viewModel.currentTool == .select,
               viewModel.selectedAnnotationIDs.count <= 1,
               let id = viewModel.selectedAnnotationID,
               let ann = viewModel.annotations.first(where: { $0.id == id }),
               (ann.type == .arrow || ann.type == .line),
               let baseStart = ann.lineStartPoint, let baseEnd = ann.lineEndPoint {
                let t = ann.transform
                for (pt, isEnd) in [(baseStart.applying(t), false), (baseEnd.applying(t), true)] {
                    let hs: CGFloat = 5.5
                    let outer = CGRect(x: pt.x - hs - 1, y: pt.y - hs - 1, width: (hs+1)*2, height: (hs+1)*2)
                    let inner = CGRect(x: pt.x - hs, y: pt.y - hs, width: hs*2, height: hs*2)
                    context.fill(Path(ellipseIn: outer), with: .color(.black.opacity(0.2)))
                    context.fill(Path(ellipseIn: inner), with: .color(.white))
                    context.stroke(Path(ellipseIn: inner), with: .color(isEnd ? .accentColor : Color.secondary), lineWidth: 1.5)
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
               !viewModel.isCropMode {
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
                        let textColor: Color = viewModel.currentColor == .yellow || viewModel.currentColor == .white ? .black : .white
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
                HStack(spacing: 8) {
                    Text("⏎ 確定").font(.system(size: 9)).foregroundStyle(.secondary)
                    Text("⇧⏎ 改行").font(.system(size: 9)).foregroundStyle(.secondary)
                    Text("Esc キャンセル").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
            }
            .position(x: viewX, y: viewY)
            .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .center)))
            .onChange(of: viewModel.showTextInput) { _, show in
                if !show { textInputHeight = 36 }
            }
        }
    }
}

// MARK: - Diagonal resize cursor

private func makeDiagonalCursor(nwse: Bool) -> NSCursor {
    let size: CGFloat = 16
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    for (color, lineWidth) in [(NSColor.white.cgColor, CGFloat(3.0)), (NSColor.black.cgColor, CGFloat(1.5))] {
        ctx.setStrokeColor(color)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        if nwse {
            ctx.move(to: CGPoint(x: 3, y: 13)); ctx.addLine(to: CGPoint(x: 13, y: 3))
            ctx.move(to: CGPoint(x: 3, y: 13)); ctx.addLine(to: CGPoint(x: 3, y: 8))
            ctx.move(to: CGPoint(x: 3, y: 13)); ctx.addLine(to: CGPoint(x: 8, y: 13))
            ctx.move(to: CGPoint(x: 13, y: 3)); ctx.addLine(to: CGPoint(x: 13, y: 8))
            ctx.move(to: CGPoint(x: 13, y: 3)); ctx.addLine(to: CGPoint(x: 8, y: 3))
        } else {
            ctx.move(to: CGPoint(x: 13, y: 13)); ctx.addLine(to: CGPoint(x: 3, y: 3))
            ctx.move(to: CGPoint(x: 13, y: 13)); ctx.addLine(to: CGPoint(x: 8, y: 13))
            ctx.move(to: CGPoint(x: 13, y: 13)); ctx.addLine(to: CGPoint(x: 13, y: 8))
            ctx.move(to: CGPoint(x: 3, y: 3)); ctx.addLine(to: CGPoint(x: 3, y: 8))
            ctx.move(to: CGPoint(x: 3, y: 3)); ctx.addLine(to: CGPoint(x: 8, y: 3))
        }
        ctx.strokePath()
    }
    img.unlockFocus()
    return NSCursor(image: img, hotSpot: NSPoint(x: size / 2, y: size / 2))
}

@MainActor private let cursorNWSE = makeDiagonalCursor(nwse: true)
@MainActor private let cursorNESW = makeDiagonalCursor(nwse: false)
