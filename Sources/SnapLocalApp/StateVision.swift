// StateVision.swift
// SnapLocal — SnapLocalState extension: Vision・OCR・バーコード系メソッド (R1.6)

import AppKit
import Vision

@MainActor
extension SnapLocalState {

    // MARK: - OCR

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

    nonisolated func detectBarcodes(in image: CGImage) async -> [String] {
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
            // 安全網(T9.5): addAnnotation を通らない直接 append のため、ここでも基準を確定する
            if canvas.annotationsBasis == nil, canvas.canvasSize.width > 1, canvas.canvasSize.height > 1 {
                canvas.annotationsBasis = canvas.canvasSize
            }
            for normalized in normalizedFaces {
                let pixX = normalized.minX * iw
                let pixY = (1 - normalized.maxY) * ih   // flip Y
                let pixW = normalized.width * iw
                let pixH = normalized.height * ih
                let faceRect = CGRect(
                    x: pixX * scaleX - 8, y: pixY * scaleY - 8,
                    width: pixW * scaleX + 16, height: pixH * scaleY + 16
                )
                var a = RedactAnnotation(type: isBlur ? .blur : .mosaic, rect: faceRect)
                a.intensity = Float(isBlur ? canvas.currentBlurRadius : canvas.currentMosaicScale)
                canvas.annotations.append(AnyAnnotation(a))
            }
            canvas.recomputeAllFilterPreviews()
            canvas.objectWillChange.send()
            showStatus("顔を\(normalizedFaces.count)箇所検出しました", success: true)
        }
    }

    nonisolated func detectFaceRects(in image: CGImage) async -> [CGRect] {
        await withCheckedContinuation { continuation in
            let request = VNDetectFaceRectanglesRequest { req, _ in
                let obs = req.results as? [VNFaceObservation] ?? []
                continuation.resume(returning: obs.map { $0.boundingBox })
            }
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([request])
        }
    }

    // MARK: - OCR selected region

    func ocrSelectedRegion() {
        guard let id = canvas.selectedAnnotationID,
              let ann = canvas.annotations.first(where: { $0.id == id }),
              let bgImage = canvas.backgroundImage,
              canvas.canvasSize.width > 0, canvas.canvasSize.height > 0 else {
            showStatus("テキストを認識する領域を選択してください")
            return
        }
        let bounds = ann.bounds(in: CGRect(origin: .zero, size: canvas.canvasSize))
        guard let pixelRect = canvas.canvasRectToPixelRect(bounds, in: bgImage),
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
}
