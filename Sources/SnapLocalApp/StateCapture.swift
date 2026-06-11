// StateCapture.swift
// SnapLocal — SnapLocalState extension: キャプチャ系メソッド (R1.6)

import AppKit
import ScreenCaptureKit
import UserNotifications

@MainActor
extension SnapLocalState {

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
        // T8.2修正: initialRect(前回範囲プリセレクション)を渡さない。渡すと2回目以降の
        // ⌘⇧4 が旧 adjusting+Enter モードで開いてしまう(ネイティブ化ピボットに反する)
        RegionCapture.start { [weak self] rect, preCaptured in
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
        showStatus("ウィンドウを撮影中…")
        captureEngine?.captureWindow(window)
    }

    func captureRegion() {
        isRegionCapturing = true
        showStatus("範囲を選択 — ドラッグして選択")
        // T8.2修正: initialRect を渡さず常に素の選択で開始(上記 captureRegionToClipboard と同じ)。
        // lastRegionRect は repeatLastRegionCapture(前回範囲で再撮影)では引き続き使用
        RegionCapture.start { [weak self] rect, preCaptured in
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
        // Persist current annotations / pending background edits before overwriting canvas
        if canvas.backgroundDirty {
            flushPendingBackgroundEdit()
        } else if let id = currentVaultID, !canvas.annotations.isEmpty {
            let anns = canvas.annotations
            let v = vault
            Task { await v.updateAnnotations(id: id, annotations: anns) }
        }
        canvas.backgroundImage = image
        canvas.backgroundDirty = false
        canvas.annotations.removeAll()
        canvas.loadToken = UUID()
        currentVaultID = nil
        selectedHistoryID = nil
        // Post-capture surface (T8.2): full editor if that setting is enabled;
        // quick annotate panel for captures; HUD for paste/drop (the user is already
        // working inside the editor, so a panel would hijack their context)
        let suppressPanel = suppressQuickPanel
        suppressQuickPanel = false
        // T8.4: パネルが画面に出るときは撮影完了通知を出さない(パネル自体が完了の合図。
        // 通知は⌘↩完了時の1回に寄せる)
        let willShowPanel = !SettingsManager.shared.openEditorOnCapture && !suppressPanel

        if SettingsManager.shared.autoCopyOnCapture {
            copyImageToClipboard(image)
            showStatus("撮影 → クリップボードにコピーしました", success: true)
            if !willShowPanel { sendNotification(title: "撮影完了", body: "クリップボードにコピーしました") }
        } else {
            showStatus("撮影しました", success: true)
            if !willShowPanel { sendNotification(title: "撮影完了", body: "HUDから操作できます") }
        }

        if SettingsManager.shared.openEditorOnCapture {
            NSApp.bringToFront()
        } else if !suppressPanel {
            QuickAnnotatePanel.shared.show(for: self)
        } else if !QuickAnnotatePanel.shared.isVisible {
            // パネル表示中のペースト/ドロップは画像がパネルに反映済みなのでHUDを重ねない
            let actions = CaptureNotificationActions(
                copy: { [weak self] in self?.copyToClipboard() },
                save: { [weak self] in self?.saveAnnotatedImage() },
                annotate: { [weak self] in
                    NSApp.bringToFront()
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

    // MARK: - Capture result

    func handleCaptureResult(_ result: Result<CGImage, Error>) {
        switch result {
        case .success(let image):
            acceptCapture(image)
        case .failure(let error):
            showStatus(Self.captureFailureMessage(for: error))
        }
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func sendNotification(title: String, body: String) {
        guard SettingsManager.shared.notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static func captureFailureMessage(for error: Error) -> String {
        if case CaptureError.permissionDenied = error {
            return "画面録画権限が必要です"
        }
        let nsError = error as NSError
        return "撮影失敗: \(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))"
    }
}
