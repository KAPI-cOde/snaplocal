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

    private func openItem(_ item: VaultItem) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
        state.loadHistoryItem(item)
    }

    var body: some View {
        // Recent captures — last 5 as clickable rows
        let recent = Array(state.history.prefix(5))
        if !recent.isEmpty {
            ForEach(recent) { item in
                Button {
                    openItem(item)
                } label: {
                    HStack(spacing: DS.Space.xs) {
                        if let nsImage = NSImage(data: item.thumbnailData) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 56, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.small))
                        } else {
                            RoundedRectangle(cornerRadius: DS.Radius.small)
                                .fill(Color.secondary.opacity(0.15))
                                .frame(width: 56, height: 36)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title ?? item.dimensionLabel)
                                .font(.system(size: DS.FontSize.body, weight: .medium))
                                .lineLimit(1)
                            Text(item.createdAt.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: DS.FontSize.caption))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
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
            NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
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
    @Published var statusIsSuccess = false
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

    func showStatus(_ message: String, success: Bool = false) {
        statusTask?.cancel()
        statusMessage = message
        statusIsSuccess = success
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
                        self.showStatus("キャンセルしました", success: true)
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
                self.showStatus("キャンセルしました", success: true)
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
            showStatus("クリップボードにコピーしました（履歴には保存しません）", success: true)
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
            showStatus("撮影 → クリップボードにコピーしました", success: true)
            sendNotification(title: "撮影完了", body: "クリップボードにコピーしました")
        } else {
            showStatus("撮影しました", success: true)
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
                showStatus("OCR完了 — 検索可能になりました", success: true)
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
                    showStatus("QRコード検出 — テキストをコピーしました: \(String(first.prefix(40)))", success: true)
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
        showStatus("画面にピン留めしました", success: true)
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
        showStatus("クリップボードにコピーしました", success: true)
    }

    func copyOriginalToClipboard() {
        guard let image = canvas.backgroundImage else {
            showStatus("コピーする画像がありません"); return
        }
        copyImageToClipboard(image)
        showStatus("オリジナル（アノテーションなし）をコピーしました", success: true)
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
        showStatus("選択範囲をコピーしました (\(Int(pixelRect.width))×\(Int(pixelRect.height)) px)", success: true)
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
                showStatus("テキストをコピーしました (\(text.count)文字)", success: true)
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
            showStatus("顔を\(normalizedFaces.count)箇所検出しました", success: true)
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
                    showStatus("ZIPを保存しました: \(url.lastPathComponent) (\(history.count)件)", success: true)
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
                await MainActor.run { self.showStatus("PDFを保存しました: \(url.lastPathComponent) (\(history.count)ページ)", success: true) }
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
            showStatus("すべての履歴を削除しました", success: true)
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
        showStatus(vertical ? "下に結合しました" : "右に結合しました", success: true)
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
            showStatus("複製しました", success: true)
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

    private var loadHistoryTask: Task<Void, Never>? = nil

    func loadHistoryItem(_ item: VaultItem) {
        // Save current annotations before switching
        if let id = currentVaultID, !canvas.annotations.isEmpty {
            let anns = canvas.annotations
            let v = vault
            Task { await v.updateAnnotations(id: id, annotations: anns) }
        }
        // Set selection immediately for responsive UI
        currentVaultID = item.id
        selectedHistoryID = item.id
        // Load image off the main thread to avoid blocking on large PNGs
        loadHistoryTask?.cancel()
        let url = item.imageURL
        let annotations = item.annotations
        loadHistoryTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let nsImage = NSImage(contentsOf: url),
                  let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.canvas.resetAndLoad(image: cgImage, annotations: annotations)
                self?.showStatus("履歴を読み込みました")
            }
        }
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
            showStatus("保存しました: \(url.lastPathComponent) (\(px))", success: true)
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
                            self.showStatus("保存しました: \(url.lastPathComponent)", success: true)
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
                    self.showStatus("保存しました: \(url.lastPathComponent) (\(px))", success: true)
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
                    self.showStatus("保存しました: \(url.lastPathComponent) (\(px))", success: true)
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
        HStack(spacing: DS.Space.xs) {
            Text(key)
                .monospacedDigit()
                .padding(.horizontal, DS.Space.xxs)
                .padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: DS.Radius.small))
            Text(label)
        }
    }
}

// MARK: - Status Chip

struct StatusChip: View {
    let message: String
    let visible: Bool
    var success: Bool = false

    var body: some View {
        if visible {
            HStack(spacing: DS.Space.xxs) {
                if success {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
                Text(message)
                    .font(.caption)
                    .lineLimit(1)
            }
            .padding(.horizontal, DS.Space.xs)
            .padding(.vertical, DS.Space.xxs)
            .background(.regularMaterial, in: Capsule())
            .shadow(DS.Shadow.overlay)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .animation(DS.Anim.base, value: success)
        }
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
                onCaptureRegionToClipboard: state.captureRegionToClipboard,
                currentOCRText: {
                    guard let id = state.selectedHistoryID else { return "" }
                    return state.history.first(where: { $0.id == id })?.ocrText ?? ""
                }()
            )
            .sheet(isPresented: $state.showWindowPicker) {
                WindowPickerSheet(
                    windows: state.windowPickerItems,
                    onSelect: { state.captureWindowNow($0) },
                    onCancel: {
                        state.showWindowPicker = false
                        state.showStatus("キャンセルしました", success: true)
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
                                RoundedRectangle(cornerRadius: DS.Radius.large)
                                    .fill(Color.accentColor.opacity(0.08))
                                    .padding(DS.Space.xxs)
                                RoundedRectangle(cornerRadius: DS.Radius.large)
                                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, dash: [10, 5]))
                                    .padding(DS.Space.xxs)
                                VStack(spacing: DS.Space.xs) {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .font(.system(size: 36))
                                        .foregroundStyle(Color.accentColor)
                                    Text("画像をドロップして開く")
                                        .font(.system(size: DS.FontSize.body, weight: .medium))
                                        .foregroundStyle(Color.accentColor)
                                }
                                .padding(DS.Space.m)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.large))
                                .shadow(color: Color.accentColor.opacity(0.2), radius: 12, y: 4)
                            }
                            .transition(.opacity)
                            .animation(DS.Anim.base, value: isDropTargeted)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        StatusChip(message: state.statusMessage, visible: state.statusVisible,
                                   success: state.statusIsSuccess)
                            .padding(.bottom, DS.Space.m)
                            .animation(DS.Anim.smooth, value: state.statusVisible)
                    }
                    .overlay(alignment: .bottomLeading) {
                        if let qrURL = state.detectedQRURL {
                            Button(action: {
                                NSWorkspace.shared.open(qrURL)
                                state.detectedQRURL = nil
                            }) {
                                HStack(spacing: DS.Space.xxs) {
                                    Image(systemName: "qrcode.viewfinder")
                                        .font(.system(size: 11))
                                    Text(qrURL.absoluteString.count > 40
                                         ? String(qrURL.absoluteString.prefix(40)) + "…"
                                         : qrURL.absoluteString)
                                        .font(.system(size: DS.FontSize.caption))
                                        .lineLimit(1)
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.secondary)
                                        .onTapGesture { state.detectedQRURL = nil }
                                }
                                .foregroundStyle(.primary)
                                .padding(.horizontal, DS.Space.xs)
                                .padding(.vertical, DS.Space.xxs)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.medium))
                                .overlay(RoundedRectangle(cornerRadius: DS.Radius.medium).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
                                .shadow(DS.Shadow.overlay)
                            }
                            .buttonStyle(.plain)
                            .padding([.bottom, .leading], DS.Space.m)
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
                                .font(.system(size: DS.FontSize.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, DS.Space.xs)
                                .padding(.vertical, 3)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.small))
                                .padding([.bottom, .trailing], DS.Space.xs)
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
    @State private var isPanDragging = false
    @State private var hoverLocation: CGPoint? = nil
    @State private var hoverColorHex: String? = nil
    @State private var hoverCanvasPoint: CGPoint? = nil
    @State private var imageOpacity: Double = 1.0

    @State private var hoverHandleIndex: Int? = nil

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
                    selectionHandlesOverlay(size: proxy.size)
                        .allowsHitTesting(false)
                        .animation(viewModel.isDraggingAnnotation || viewModel.resizingHandleIndex != nil
                                   ? nil : DS.Anim.fast,
                                   value: viewModel.selectedAnnotationID)
                        .animation(DS.Anim.fast, value: viewModel.currentTool)
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
                    VStack(spacing: DS.Space.s) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 48))
                            .foregroundStyle(.tertiary)
                        if let onCapture = onCapture {
                            Button("撮影する", action: onCapture)
                                .buttonStyle(.borderedProminent)
                        }
                        VStack(spacing: DS.Space.xxs) {
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
                        .font(.system(size: DS.FontSize.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, DS.Space.xs)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: DS.Radius.small))
                        .padding(DS.Space.xs)
                        .onTapGesture {
                            withAnimation(DS.Anim.smooth) { zoom = 1.0; baseZoom = 1.0; panOffset = .zero; basePan = .zero }
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
                    let grabSupportedTools: Set<DrawingTool> = [.arrow, .line, .rectangle,
                        .ellipse, .roundedRect, .callout, .highlight, .step, .redact, .spotlight]
                    if !viewModel.isDraggingAnnotation && !viewModel.isGrabMoving &&
                       (viewModel.currentTool == .select || grabSupportedTools.contains(viewModel.currentTool)) {
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

    /// 選択中アノテーションのリサイズ/端点/テールハンドル。
    /// Canvas(GraphicsContext)ではなくSwiftUIビューで描くことで出現/消滅をアニメーションさせる。
    /// ヒットテストはCanvasViewModel側の座標計算で行うため、ここは表示専用(allowsHitTesting(false))。
    @ViewBuilder
    private func selectionHandlesOverlay(size: CGSize) -> some View {
        let canvasRect = CGRect(origin: .zero, size: size)
        if viewModel.currentTool == .select,
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

    private func handleDot(circle: Bool, diameter: CGFloat, tint: Color) -> some View {
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

            // Hover glow: faint accent outline behind hovered annotation (select + grab-capable tools)
            let grabCapableTools: Set<DrawingTool> = [.select, .arrow, .line, .rectangle, .ellipse,
                .roundedRect, .callout, .highlight, .step, .redact, .spotlight]
            if grabCapableTools.contains(viewModel.currentTool),
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
