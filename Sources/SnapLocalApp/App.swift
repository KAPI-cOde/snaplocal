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
    static let snapLocalOpenSettings = Notification.Name("snaplocal.settings.open")
}

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
            // T3.5-K: 設定はツールバーから外し、⌘,(アプリメニュー)とメニューバーで到達
            CommandGroup(replacing: .appSettings) {
                Button("設定…") {
                    NSApp.activate(ignoringOtherApps: true)
                    NotificationCenter.default.post(name: .snapLocalOpenSettings, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }

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
                    .keyboardShortcut("9", modifiers: .command)
                Divider()
                Button("履歴を検索") { appState.searchFocusTrigger.toggle() }
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
        Button("設定… (⌘,)") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: .snapLocalOpenSettings, object: nil)
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

        // 起動時クリーンアップ: index.json未登録の残留画像をゴミ箱へ(復元可能)
        let v = vault
        Task { [weak self] in
            let n = await v.cleanOrphans()
            if n > 0 {
                await MainActor.run { self?.showStatus("未登録の残留ファイル\(n)件をゴミ箱へ移動しました") }
            }
        }

        // AppIntents notifications (queue: .main なので assumeIsolated は安全)
        NotificationCenter.default.addObserver(forName: .intentCaptureScreen, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.captureNow() }
        }
        NotificationCenter.default.addObserver(forName: .intentCaptureRegion, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.captureRegion() }
        }

        // Auto-save annotations 3 seconds after last change
        canvas.$annotations
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleAutoSave() }
            .store(in: &cancellables)

        // Save annotations on quit (queue: .main なので assumeIsolated は安全)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
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

    /// 履歴アイテムの文字認識をやり直す(誤認識・失敗時用 — 通常は撮影後に自動実行される)
    func reRunOCR(for item: VaultItem) {
        showStatus("文字認識を再実行中…")
        let v = vault
        Task { [weak self] in
            guard let nsImage = NSImage(contentsOf: item.imageURL),
                  let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                await MainActor.run { self?.showStatus("画像を読み込めませんでした") }
                return
            }
            let text = await OCRService.recognizeText(in: cg)
            await v.updateOCR(id: item.id, text: text)
            await MainActor.run {
                self?.refreshHistory()
                self?.showStatus(text.isEmpty
                                 ? "テキストは見つかりませんでした"
                                 : "文字認識を再実行しました (\(text.count)文字)",
                                 success: !text.isEmpty)
            }
        }
    }

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
        loadHistoryItem(item, quiet: false)
    }

    /// quiet=true: 起動時の自動復元など、ユーザー操作によらないロードではチップを出さない
    func loadHistoryItem(_ item: VaultItem, quiet: Bool) {
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
                if !quiet { self?.showStatus("履歴を読み込みました") }
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
        // 入力が進んで古くなった結果は捨てる(タイプ中の結果順序の乱れ防止)
        guard q == searchQuery else { return }
        let wasEmpty = history.isEmpty && currentVaultID == nil
        history = items
        // Auto-load the most recent screenshot on first launch
        if wasEmpty, let first = items.first {
            loadHistoryItem(first, quiet: true)
        }
    }

    private var searchDebounceTask: Task<Void, Never>?

    /// 検索フィールドからの呼び出し。1文字ごとに全件スキャンしないよう200msデバウンス(T6.2)
    func applySearch() {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await self?.loadHistory()
        }
    }

    private func pngData(from image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
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

// 画像サイズ・ズーム・注釈数のチップ(キャンバス右下)。
// CanvasViewModel を直接観測して、ズーム変化に即時追従する
private struct CanvasInfoChip: View {
    @ObservedObject var canvas: CanvasViewModel

    var body: some View {
        if let img = canvas.backgroundImage {
            let zoomPct = Int(round(canvas.currentZoom * 100))
            let annCount = canvas.annotations.count
            let selInfo: String = {
                guard let selID = canvas.selectedAnnotationID,
                      let ann = canvas.annotations.first(where: { $0.id == selID }),
                      canvas.canvasSize.width > 0 else { return "" }
                let b = ann.bounds(in: CGRect(origin: .zero, size: canvas.canvasSize))
                let sx = CGFloat(img.width) / canvas.canvasSize.width
                let sy = CGFloat(img.height) / canvas.canvasSize.height
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
}

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
                        // canvas を直接観測する(ContentView は state しか観測しないため、
                        // ここに直書きするとズーム・注釈数の表示が更新されない)
                        CanvasInfoChip(canvas: state.canvas)
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
                        onToggleStar: state.toggleStar,
                        onReocr: state.reRunOCR
                    )
                    .transition(.move(edge: .trailing))
                }
            }
            .onChange(of: state.searchFocusTrigger) { _, _ in
                // ⌘F(履歴を検索): サイドバーが閉じていれば開いてから検索欄へフォーカス
                // (再トグルでHistoryRail側のonChangeを改めて発火させる)
                if !sidebarVisible {
                    withAnimation(DS.Anim.smooth) { sidebarVisible = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        state.searchFocusTrigger.toggle()
                    }
                }
            }
        }
    }
}

