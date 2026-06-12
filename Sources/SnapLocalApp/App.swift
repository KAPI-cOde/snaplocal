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
    static let snapLocalRegionHotkeyChanged = Notification.Name("snaplocal.hotkey.regionChanged")
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
        NSApp.bringToFront()
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
        Button("範囲選択撮影 (\(SettingsManager.shared.hijackRegionHotkey ? "⌘⇧4" : "⌥⌘4"))") { state.captureRegion() }
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
            NSApp.bringToFront()
        }
        Button("設定… (⌘,)") {
            NSApp.bringToFront()
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
        // ⌘⇧4乗っ取り設定の適用(CGS状態はセッション限りなので毎起動で再適用。
        // オフ設定なら明示的に有効へ戻す = 前回異常終了で無効のまま残った場合の回復も兼ねる)
        SystemScreenshotHotkey.setNativeSelectionEnabled(!SettingsManager.shared.hijackRegionHotkey)
        
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
                    } else if NSApp.windows.first(where: { $0.canBecomeMain }) == nil {
                        // 前回「閉じた状態」で復元されるとウィンドウなしで起動完了してしまう
                        // (mainWindow はアプリ非アクティブ時も nil のため、実在チェックは canBecomeMain で)
                        logger.warning("No main window after launch — recreating via reopen")
                        NSApp.reopenMainWindow()
                    }
                }
            }
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 乗っ取りはアプリ稼働中のみ — 終了後は mac 標準⌘⇧4 を必ず復元する
        SystemScreenshotHotkey.setNativeSelectionEnabled(true)
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
    @Published var selectedHistoryID: UUID? = nil
    @Published var searchFocusTrigger: Bool = false

    var canvas = CanvasViewModel()
    let vault: PersistentVault
    var captureEngine: CaptureEngine?
    var statusTask: Task<Void, Never>?
    private var autoSaveTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    var clipboardOnlyCapture = false   // set before a "capture to clipboard only" call
    var fullScreenCapturePending = false
    /// T9.9 撮影トリガ時の最前面アプリ。URL記録の対象判定用
    var pendingSourceBundleID: String? = nil
    // T8.2: クイック注釈パネル表示中はメインウィンドウ側のキャンバスをヒエラルキーから
    // 外す(canvasSize の単一書き込み者を保証 — CLAUDE.md 最重要項)
    @Published var quickPanelActive = false
    // ペースト/ドロップ等「エディタ内での画像取り込み」ではパネルを出さない
    // (clipboardOnlyCapture と同じ「呼び出し直前にセット→acceptCapture で消費」の作法)
    var suppressQuickPanel = false
    // ID of the VaultItem currently shown on canvas (for annotation save-back)
    var currentVaultID: UUID?

    init() {
        vault = PersistentVault(directory: SettingsManager.shared.saveDirectoryURL)
        let hotkey = SettingsManager.shared.hotkeyConfig
        captureEngine = CaptureEngine(hotkey: hotkey, regionHijack: SettingsManager.shared.hijackRegionHotkey) { [weak self] result in
            Task { @MainActor in
                self?.handleCaptureResult(result)
            }
        }
        captureEngine?.regionCaptureAction = { [weak self] in
            Task { @MainActor in self?.captureRegion() }
        }
        captureEngine?.fullScreenCaptureAction = { [weak self] in
            Task { @MainActor in self?.captureNow() }
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
        // 設定トグル(⌘⇧4乗っ取り⇄⌥⌘4共存)の即時反映
        NotificationCenter.default.addObserver(forName: .snapLocalRegionHotkeyChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.captureEngine?.updateRegionHotkey(hijack: SettingsManager.shared.hijackRegionHotkey)
            }
        }

        // Auto-save annotations 3 seconds after last change
        canvas.$annotations
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleAutoSave() }
            .store(in: &cancellables)

        // 背景編集(クロップ・回転等)も同じオートセーブに乗せる(T7.2)
        canvas.$backgroundDirty
            .dropFirst()
            .filter { $0 }
            .sink { [weak self] _ in self?.scheduleAutoSave() }
            .store(in: &cancellables)

        // Save annotations on quit (queue: .main なので assumeIsolated は安全)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let anns = self.canvas.annotations
                let basis = self.canvas.annotationsBasis
                let v = self.vault
                let sem = DispatchSemaphore(value: 0)
                if self.canvas.backgroundDirty, let bg = self.canvas.backgroundImage {
                    // 編集済み背景は新規アイテムとして保存(元画像は残す — T7.2)。
                    // フォーク済みなら上書き。タイトル類のコピーはここでは行わない(終了時の最小処理)
                    let targetID = self.currentVaultID.flatMap { self.forkedThisSession.contains($0) ? $0 : nil }
                    Task.detached {
                        if let id = targetID {
                            _ = await v.updateImage(id: id, image: bg)
                            await v.updateAnnotations(id: id, annotations: anns, basis: basis)
                        } else {
                            _ = await v.save(image: bg, annotations: anns, annotationsBasis: basis)
                        }
                        sem.signal()
                    }
                } else if let id = self.currentVaultID, !anns.isEmpty {
                    Task.detached {
                        await v.updateAnnotations(id: id, annotations: anns, basis: basis)
                        sem.signal()
                    }
                } else {
                    return
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
                if canvas.backgroundDirty {
                    await persistEditedBackground(selectResult: true)
                } else if let id = currentVaultID {
                    let anns = canvas.annotations
                    await vault.updateAnnotations(id: id, annotations: anns,
                                                  basis: canvas.annotationsBasis)
                }
            } catch {}
        }
    }

    // MARK: - 背景編集の永続化(T7.2)

    /// このセッション中に背景編集から生まれたアイテム。続けて編集した場合は
    /// 新規アイテムを乱造せず、これらを上書き更新する
    private var forkedThisSession: Set<UUID> = []

    /// 編集済み背景(クロップ・回転・結合等)をvaultへ保存する。
    /// 方針(ユーザー承認済み): 元アイテムは一切触らず「新しいアイテム」として保存する。
    /// 元画像・元注釈は履歴にそのまま残る
    /// - Parameter selectResult: trueなら保存後のアイテムを選択状態にする(その場のオートセーブ用)。
    ///   別アイテムへの切替直前のフラッシュでは false(ユーザーの移動先を奪わない)
    func persistEditedBackground(selectResult: Bool) async {
        guard canvas.backgroundDirty, let bg = canvas.backgroundImage else { return }
        canvas.backgroundDirty = false
        let anns = canvas.annotations
        let basis = canvas.annotationsBasis
        let sourceID = currentVaultID

        // フォーク済みアイテムの続き編集 → 同じアイテムを上書き
        if let id = sourceID, forkedThisSession.contains(id) {
            _ = await vault.updateImage(id: id, image: bg)
            await vault.updateAnnotations(id: id, annotations: anns, basis: basis)
            let text = await OCRService.recognizeText(in: bg)
            await vault.updateOCR(id: id, text: text)
            await loadHistory()
            return
        }

        // 新しいアイテムとして保存(元アイテムは無変更)
        guard let item = await vault.save(image: bg, annotations: anns, annotationsBasis: basis) else {
            showStatus("編集の保存に失敗しました")
            return
        }
        if let sid = sourceID, let src = history.first(where: { $0.id == sid }) {
            if let t = src.title { await vault.updateTitle(id: item.id, title: t) }
            if let n = src.notes { await vault.updateNotes(id: item.id, notes: n) }
        }
        forkedThisSession.insert(item.id)
        if selectResult {
            currentVaultID = item.id
            selectedHistoryID = item.id
            showStatus("編集を新しい項目として保存しました（元の画像も履歴に残っています）", success: true)
        }
        await loadHistory()
        // 切り抜きでテキストが減っている可能性があるため、検索用OCRを撮り直す
        let text = await OCRService.recognizeText(in: bg)
        await vault.updateOCR(id: item.id, text: text)
        await loadHistory()
    }

    /// アイテム切替・新規撮影の直前に未保存の編集を退避する。
    /// canvasはこの直後に上書きされるため、値を同期的に確保してから非同期で保存する
    func flushPendingBackgroundEdit() {
        guard canvas.backgroundDirty, let bg = canvas.backgroundImage else { return }
        canvas.backgroundDirty = false
        let anns = canvas.annotations
        let basis = canvas.annotationsBasis
        let sourceID = currentVaultID
        let targetID = sourceID.flatMap { forkedThisSession.contains($0) ? $0 : nil }
        let sourceTitle = sourceID.flatMap { sid in history.first(where: { $0.id == sid })?.title }
        let sourceNotes = sourceID.flatMap { sid in history.first(where: { $0.id == sid })?.notes }
        let v = vault
        Task { [weak self] in
            if let id = targetID {
                _ = await v.updateImage(id: id, image: bg)
                await v.updateAnnotations(id: id, annotations: anns, basis: basis)
                let text = await OCRService.recognizeText(in: bg)
                await v.updateOCR(id: id, text: text)
            } else if let item = await v.save(image: bg, annotations: anns, annotationsBasis: basis) {
                if let t = sourceTitle { await v.updateTitle(id: item.id, title: t) }
                if let n = sourceNotes { await v.updateNotes(id: item.id, notes: n) }
                await MainActor.run { self?.forkedThisSession.insert(item.id) }
                let text = await OCRService.recognizeText(in: bg)
                await v.updateOCR(id: item.id, text: text)
            }
            await MainActor.run { self?.refreshHistory() }
        }
    }

    var hasScreenRecordingPermission: Bool { CGPreflightScreenCaptureAccess() }

    @Published var detectedQRURL: URL? = nil

    // MARK: - Stored properties for Capture (moved methods in StateCapture.swift)
    var lastRegionRect: CGRect?
    var regionCapturePlayedSound = false   // prevents double-shutter in region capture fast path

    // MARK: - Stored properties for History (moved methods in StateHistory.swift)
    var loadHistoryTask: Task<Void, Never>? = nil
    var searchDebounceTask: Task<Void, Never>?
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
            .navigationTitle(windowTitle)
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    Group {
                        if state.quickPanelActive {
                            // クイック注釈パネルが canvasSize を所有している間はメイン側の
                            // キャンバスを外す(二重書き込み防止)。閉じれば onAppear が取り戻す
                            VStack(spacing: DS.Space.xs) {
                                Text("クイック注釈パネルで編集中")
                                    .font(.system(size: DS.FontSize.body))
                                    .foregroundStyle(.secondary)
                                Button("このウィンドウで編集する") {
                                    QuickAnnotatePanel.shared.closeKeepingAnnotations()
                                }
                            }
                        } else {
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
                        }
                    }
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

                    if !state.quickPanelActive,
                       let item = state.selectedHistoryID.flatMap({ id in state.history.first(where: { $0.id == id }) }) {
                        Divider()
                        DetailPane(
                            item: item,
                            onRename: state.renameHistoryItem,
                            onUpdateNotes: state.updateNotesForItem
                        )
                        .id(item.id)
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
