// StateExport.swift
// SnapLocal — SnapLocalState extension: 書き出し・クリップボード系メソッド (R1.6)

import AppKit
import PDFKit
import UniformTypeIdentifiers

@MainActor
extension SnapLocalState {

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

    func copyImageToClipboard(_ image: CGImage) {
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

    // MARK: - Save

    func saveAnnotatedImage() {
        guard let raw = canvas.renderAnnotations() ?? canvas.backgroundImage else {
            showStatus("保存できる画像がありません")
            return
        }
        let image = canvas.applyDecoration(to: raw)

        if currentVaultID != nil || canvas.backgroundDirty {
            Task {
                // 編集済み背景があれば先に永続化(新規アイテム化)してから、その対象に注釈を保存
                if canvas.backgroundDirty {
                    await persistEditedBackground(selectResult: true)
                }
                if let id = currentVaultID {
                    await vault.updateAnnotations(id: id, annotations: canvas.annotations)
                    if !canvas.annotations.isEmpty, let annotatedRaw = canvas.renderAnnotations() {
                        await vault.updateThumbnail(id: id, annotatedImage: annotatedRaw)
                    }
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

    private func pngData(from image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
