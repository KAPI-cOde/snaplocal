// QuickAnnotatePanel.swift
// SnapLocal — 撮影直後に画面中央へ出る軽量注釈パネル (T8.2)
//
// mac標準⌘⇧4の感覚で「選択→離す→中央で注釈→⌘↩で完了」を実現する。
// 完了 = 注釈込みレンダをクリップボードへ + 注釈を即時永続化 + パネルを閉じる。
// Esc = 注釈を保持したまま閉じるだけ(クリップボードは撮影時の素画像のまま)。
//
// canvasSize 所有権(CLAUDE.md 最重要項): AnnotationCanvasView の GeometryReader が
// canvasSize を管理するため、キャンバスのホストは常に1つでなければならない。
// パネル表示中は ContentView 側が `state.quickPanelActive` でメインのキャンバスを
// ヒエラルキーから外し、パネルを閉じると再挿入された onAppear が canvasSize を取り戻す。

import SwiftUI

// Borderless panel that can still become key (text annotation needs keyboard focus).
final class QuickAnnotatePanelWindow: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
final class QuickAnnotatePanel {
    static let shared = QuickAnnotatePanel()
    private var panel: QuickAnnotatePanelWindow?
    private weak var state: SnapLocalState?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(for state: SnapLocalState) {
        self.state = state
        // Remove the main-window canvas BEFORE the panel's canvas appears so there is
        // never a second canvasSize writer (see header comment).
        state.quickPanelActive = true
        NSApp.windows.first(where: { $0.canBecomeMain })?.orderOut(nil)

        // Re-capture while a panel is already open: replace it
        panel?.orderOut(nil)
        panel = nil

        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        let canvasArea = Self.canvasArea(for: state.canvas.backgroundImage, on: screen)
        let hosting = NSHostingView(rootView: QuickAnnotateView(state: state, canvasArea: canvasArea))
        let size = hosting.fittingSize

        let p = QuickAnnotatePanelWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        // 注意: isMovableByWindowBackground は使わない — キャンバス上のドラッグ(注釈描画)が
        // ウィンドウ移動に吸われる(実機で発生)。パネルは中央固定のまま動かさない
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        p.contentView = hosting
        p.onEscape = { [weak self] in self?.closeKeepingAnnotations() }

        if let vf = screen?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2))
        }
        panel = p
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    /// ⌘↩ / 完了ボタン: 注釈込みの最終画像をクリップボードへ、注釈を即時永続化して閉じる
    func complete() {
        guard let state else { close(); return }
        state.copyToClipboard()
        state.sendNotification(title: "完了", body: "注釈込みの画像をクリップボードにコピーしました")
        persistAnnotations(state)
        close()
    }

    /// Esc: 注釈は保持したまま閉じるだけ(オートセーブに加えて即時永続化もしておく)
    func closeKeepingAnnotations() {
        if let state { persistAnnotations(state) }
        close()
    }

    func openInEditor() {
        if let state { persistAnnotations(state) }
        close()
        NSApp.bringToFront()
    }

    private func persistAnnotations(_ state: SnapLocalState) {
        guard let id = state.currentVaultID, !state.canvas.annotations.isEmpty else { return }
        let anns = state.canvas.annotations
        let basis = state.canvas.annotationsBasis
        let v = state.vault
        Task { await v.updateAnnotations(id: id, annotations: anns, basis: basis) }
    }

    private func close() {
        panel?.orderOut(nil)
        panel = nil
        // After the panel's canvas is gone, re-insert the main-window canvas so its
        // onAppear re-owns canvasSize (single-writer invariant).
        state?.quickPanelActive = false
    }

    /// 撮影画像の論理ptサイズを基準に、画面の約70%へクランプしたキャンバス領域
    private static func canvasArea(for image: CGImage?, on screen: NSScreen?) -> CGSize {
        let scale = screen?.backingScaleFactor ?? 2
        let imgW = max(CGFloat(image?.width ?? 1200) / scale, 1)
        let imgH = max(CGFloat(image?.height ?? 800) / scale, 1)
        let visible = screen?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let fit = min(1, min(visible.width * 0.7 / imgW, visible.height * 0.7 / imgH))
        // 幅はツールバーが収まる下限(メインウィンドウの minWidth と同値)、高さは操作可能な下限
        return CGSize(width: max(600, imgW * fit), height: max(280, imgH * fit))
    }
}

// MARK: - Panel content

struct QuickAnnotateView: View {
    @ObservedObject var state: SnapLocalState
    let canvasArea: CGSize

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
                sidebarVisible: .constant(false),
                showsSidebarToggle: false,
                onCaptureToClipboard: state.captureNowToClipboard,
                onCaptureRegionToClipboard: state.captureRegionToClipboard
            )
            Divider()
            AnnotationCanvasView(
                viewModel: state.canvas,
                onCapture: state.captureNow,
                onCopyOriginal: state.copyOriginalToClipboard,
                onCopyRegion: state.copySelectedRegion,
                onOcrRegion: state.ocrSelectedRegion
            )
            .frame(width: canvasArea.width, height: canvasArea.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .bottom) {
                StatusChip(message: state.statusMessage, visible: state.statusVisible, success: state.statusIsSuccess)
                    .padding(.bottom, DS.Space.m)
                    .animation(DS.Anim.smooth, value: state.statusVisible)
            }
            Divider()
            HStack(spacing: DS.Space.s) {
                Button("エディタで開く") { QuickAnnotatePanel.shared.openInEditor() }
                Spacer()
                Text("Esc で閉じる")
                    .font(.system(size: DS.FontSize.caption))
                    .foregroundStyle(.secondary)
                Button("完了") { QuickAnnotatePanel.shared.complete() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, DS.Space.s)
            .padding(.vertical, DS.Space.xs)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.large))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.large).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
    }
}
