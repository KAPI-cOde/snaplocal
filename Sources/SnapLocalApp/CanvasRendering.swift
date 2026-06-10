// CanvasRendering.swift
// SnapLocal - CoreImage / Export レンダリング系メソッド
//
// Copyright © 2024 SnapLocal. All rights reserved.

import SwiftUI
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

// MARK: - CanvasViewModel Rendering Extension

@MainActor
extension CanvasViewModel {

    // MARK: - Filter Previews

    func updateFilterPreview(for annotation: AnyAnnotation) {
        guard !annotation.hasStrokeRepresentation,
              let bgImage = backgroundImage,
              canvasSize.width > 0, canvasSize.height > 0 else { return }
        let vr = annotation.bounds(in: CGRect(origin: .zero, size: canvasSize))
        guard let ciRect = canvasRectToCIRect(vr, in: bgImage) else { return }
        let ciSource = CIImage(cgImage: bgImage)
        var filtered: CIImage?
        switch annotation.type {
        case .blur:
            let f = CIFilter.gaussianBlur()
            f.inputImage = ciSource.cropped(to: ciRect)
            f.radius = 20
            filtered = f.outputImage?.cropped(to: ciRect)
        case .mosaic:
            let f = CIFilter.pixellate()
            f.inputImage = ciSource.cropped(to: ciRect)
            f.scale = 12
            filtered = f.outputImage?.cropped(to: ciRect)
        default: return
        }
        if let out = filtered, let cg = ciPreviewCtx.createCGImage(out, from: ciRect) {
            filterPreviews[annotation.id] = cg
        }
    }

    // Generate a live mosaic/blur preview image during redact drag (view-space coords)
    func updateRedactDragPreview(start: CGPoint, end: CGPoint) {
        guard let bgImage = backgroundImage, canvasSize.width > 0, canvasSize.height > 0 else {
            redactDragPreview = nil; return
        }
        let vr = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                        width: abs(end.x - start.x), height: abs(end.y - start.y))
        guard vr.width > 4, vr.height > 4 else { redactDragPreview = nil; return }
        guard let ciRect = canvasRectToCIRect(vr, in: bgImage) else { redactDragPreview = nil; return }
        let ciSource = CIImage(cgImage: bgImage)
        var filtered: CIImage?
        switch currentRedactMode {
        case .mosaic:
            let f = CIFilter.pixellate()
            f.inputImage = ciSource.cropped(to: ciRect)
            f.scale = Float(currentMosaicScale)
            filtered = f.outputImage?.cropped(to: ciRect)
        case .blur:
            let f = CIFilter.gaussianBlur()
            f.inputImage = ciSource.cropped(to: ciRect)
            f.radius = Float(currentBlurRadius)
            filtered = f.outputImage?.cropped(to: ciRect)
        }
        if let out = filtered, let cg = ciPreviewCtx.createCGImage(out, from: ciRect) {
            redactDragPreview = cg
            redactDragPreviewBounds = vr
        } else {
            redactDragPreview = nil
        }
    }

    // MARK: - Color Sampling

    func sampleColor(at canvasPoint: CGPoint) -> String? {
        guard let image = backgroundImage, canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let imgW = CGFloat(image.width), imgH = CGFloat(image.height)
        let px = Int(canvasPoint.x / canvasSize.width * imgW)
        let py = Int(canvasPoint.y / canvasSize.height * imgH)
        guard px >= 0, py >= 0, px < image.width, py < image.height else { return nil }
        guard let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        // CGContext origin is bottom-left; shift so pixel (px,py) [top-origin] lands at (0,0)
        ctx.translateBy(x: -CGFloat(px), y: -(imgH - 1.0 - CGFloat(py)))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: imgW, height: imgH))
        guard let data = ctx.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: 4)
        return String(format: "%02X%02X%02XFF", bytes[0], bytes[1], bytes[2])
    }

    // MARK: - Decoration (beautify / export wrapper)

    func applyDecoration(to image: CGImage) -> CGImage {
        guard decorationEnabled else { return image }
        let pad = decorationPadding
        let outW = CGFloat(image.width) + pad * 2
        let outH = CGFloat(image.height) + pad * 2
        guard let ctx = CGContext(
            data: nil,
            width: Int(outW), height: Int(outH),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        // Background
        switch decorationBackgroundStyle {
        case 1: // dark
            ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))
        case 2: // gradient
            let presets = CanvasViewModel.gradientPresets
            let idx = max(0, min(presets.count - 1, decorationGradientIndex))
            let (c1, c2) = presets[idx]
            let colors = [c1, c2] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: colors, locations: [0.0, 1.0]) {
                ctx.drawLinearGradient(grad,
                    start: CGPoint(x: 0, y: outH),
                    end: CGPoint(x: outW, y: 0),
                    options: [])
            }
        case 3: // transparent — nothing
            break
        case 4: // desktop wallpaper, tiled/scaled to fill
            let wallpaperURL = NSWorkspace.shared.desktopImageURL(for: NSScreen.main ?? NSScreen.screens[0])
            if let wpURL = wallpaperURL,
               let wpImg = NSImage(contentsOf: wpURL),
               let cgWp = wpImg.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let destRect = CGRect(x: 0, y: 0, width: outW, height: outH)
                let srcW = CGFloat(cgWp.width), srcH = CGFloat(cgWp.height)
                let scale = max(outW / srcW, outH / srcH)
                let drawW = srcW * scale, drawH = srcH * scale
                let drawRect = CGRect(x: (outW - drawW) / 2, y: (outH - drawH) / 2, width: drawW, height: drawH)
                ctx.saveGState()
                ctx.clip(to: destRect)
                ctx.draw(cgWp, in: drawRect)
                ctx.restoreGState()
            } else {
                ctx.setFillColor(CGColor(gray: 0.18, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))
            }
        default: // white
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))
        }

        let imageRect = CGRect(x: pad, y: pad, width: CGFloat(image.width), height: CGFloat(image.height))
        let radius = decorationCornerRadius

        // Shadow
        if decorationShadow {
            ctx.saveGState()
            let shadowPath = CGPath(roundedRect: imageRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 28, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.addPath(shadowPath)
            ctx.fillPath()
            ctx.restoreGState()
        }

        // Clip to rounded rect and draw screenshot
        ctx.saveGState()
        let clipPath = CGPath(roundedRect: imageRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(clipPath)
        ctx.clip()
        ctx.draw(image, in: imageRect)
        ctx.restoreGState()

        return ctx.makeImage() ?? image
    }

    // MARK: - Export

    func renderAnnotations() -> CGImage? {
        guard let bgImage = backgroundImage else { return nil }

        let imageW = CGFloat(bgImage.width)
        let imageH = CGFloat(bgImage.height)
        // アノテーションはview座標 → 物理ピクセルへのスケール係数
        let scaleX = canvasSize.width  > 0 ? imageW / canvasSize.width  : 1
        let scaleY = canvasSize.height > 0 ? imageH / canvasSize.height : 1

        // STEP 1: CI フィルタ（モザイク・ぼかし）をフル解像度で適用
        let ciImage = CIImage(cgImage: bgImage)
        var resultCI = ciImage
        let ciCtx = CIContext(options: [.useSoftwareRenderer: false])

        for annotation in annotations where !annotation.hasStrokeRepresentation {
            // view空間 → CI空間変換（スケール + Y軸反転）
            let vr = annotation.bounds(in: CGRect(origin: .zero, size: canvasSize))
            let ciRect = CGRect(
                x: vr.minX * scaleX,
                y: imageH - vr.maxY * scaleY,
                width: vr.width  * scaleX,
                height: vr.height * scaleY
            )
            if let filtered = applyFilter(type: annotation.type, to: resultCI, in: ciRect) {
                resultCI = filtered
            }
        }

        let filteredCGImage = resultCI !== ciImage
            ? ciCtx.createCGImage(resultCI, from: resultCI.extent)
            : nil

        // STEP 2: 物理ピクセルサイズのコンテキストにストローク系アノテーションを描画
        guard let cgCtx = CGContext(
            data: nil,
            width: bgImage.width,
            height: bgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return filteredCGImage ?? bgImage }

        let fullRect = CGRect(x: 0, y: 0, width: imageW, height: imageH)
        cgCtx.draw(filteredCGImage ?? bgImage, in: fullRect)

        let viewRect = CGRect(origin: .zero, size: canvasSize)
        let toImage = CGAffineTransform(scaleX: scaleX, y: scaleY)
        let strokeScale = min(scaleX, scaleY)

        // Ordinal step numbers: position in annotation list, so deletion keeps 1,2,3 sequence
        var exportStepOrdinal = 0
        let stepOrdinals: [UUID: Int] = Dictionary(uniqueKeysWithValues: annotations.filter { $0.type == .step }.map { ann in
            exportStepOrdinal += 1; return (ann.id, exportStepOrdinal)
        })

        for annotation in annotations {
            guard annotation.hasStrokeRepresentation else { continue }
            cgCtx.saveGState()
            cgCtx.setAlpha(annotation.opacity)
            if annotation.type == .step, let n = stepOrdinals[annotation.id] {
                let rect = annotation.bounds(in: viewRect).applying(toImage)
                let cgPath = annotation.path(in: viewRect).applying(toImage).cgPath
                cgCtx.addPath(cgPath)
                cgCtx.setFillColor(annotation.resolvedCGColor)
                cgCtx.fillPath()
                let textColor: NSColor = annotation.color.isLight ? .black : .white
                let fs = min(rect.width, rect.height) * 0.5
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.boldSystemFont(ofSize: max(fs, 10)),
                    .foregroundColor: textColor
                ]
                let str = NSAttributedString(string: "\(n)", attributes: attrs)
                let strSize = str.size()
                let strRect = CGRect(
                    x: rect.midX - strSize.width / 2,
                    y: rect.midY - strSize.height / 2,
                    width: strSize.width,
                    height: strSize.height
                )
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: cgCtx, flipped: false)
                str.draw(in: strRect)
                NSGraphicsContext.restoreGraphicsState()
            } else if annotation.type == .text, let text = annotation.textContent {
                let rect = annotation.bounds(in: viewRect).applying(toImage)
                let fs = annotation.textFontSize ?? max(rect.height * 0.6, 14)
                if annotation.textHasBackground {
                    let bgNS: NSColor = annotation.color == .white ? NSColor.black.withAlphaComponent(0.82) : NSColor.white.withAlphaComponent(0.82)
                    cgCtx.setFillColor(bgNS.cgColor)
                    let bgRect = rect.insetBy(dx: -4, dy: -2)
                    let radius = min(bgRect.width, bgRect.height) * 0.15
                    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
                    cgCtx.addPath(bgPath)
                    cgCtx.fillPath()
                }
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: fs * strokeScale, weight: .semibold),
                    .foregroundColor: NSColor(cgColor: annotation.resolvedCGColor) ?? .labelColor
                ]
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: cgCtx, flipped: false)
                NSAttributedString(string: text, attributes: attrs).draw(in: rect)
                NSGraphicsContext.restoreGraphicsState()
            } else if annotation.type == .spotlight {
                // Spotlight: dark overlay with spotlight area showing the original image
                let cgPath = annotation.path(in: viewRect).applying(toImage).cgPath
                cgCtx.setFillColor(CGColor(gray: 0, alpha: 0.6 * annotation.opacity))
                cgCtx.fill(fullRect)
                // Redraw original image clipped to the spotlight ellipse (punch-through)
                cgCtx.saveGState()
                cgCtx.addPath(cgPath)
                cgCtx.clip()
                cgCtx.draw(filteredCGImage ?? bgImage, in: fullRect)
                cgCtx.restoreGState()
                // Bright ring around spotlight
                cgCtx.setStrokeColor(CGColor(gray: 1, alpha: 0.6 * annotation.opacity))
                cgCtx.setLineWidth(2 * strokeScale)
                cgCtx.addPath(cgPath)
                cgCtx.strokePath()
            } else if annotation.type == .highlight {
                let cgPath = annotation.path(in: viewRect).applying(toImage).cgPath
                cgCtx.addPath(cgPath)
                cgCtx.setFillColor(annotation.resolvedCGColor.copy(alpha: 0.38) ?? annotation.resolvedCGColor)
                cgCtx.fillPath()
            } else {
                let cgPath = annotation.path(in: viewRect).applying(toImage).cgPath
                if annotation.type == .arrow {
                    // Solid polygon arrow — fill only
                    cgCtx.addPath(cgPath)
                    cgCtx.setFillColor(annotation.resolvedCGColor)
                    cgCtx.fillPath()
                } else if annotation.isFilled {
                    cgCtx.addPath(cgPath)
                    cgCtx.setFillColor(annotation.resolvedCGColor.copy(alpha: 0.35) ?? annotation.resolvedCGColor)
                    cgCtx.fillPath()
                    cgCtx.addPath(cgPath)
                    cgCtx.setStrokeColor(annotation.resolvedCGColor)
                    let lw = annotation.lineWidth.rawValue * strokeScale
                    cgCtx.setLineWidth(lw)
                    cgCtx.setLineCap(.round)
                    cgCtx.setLineJoin(.round)
                    cgCtx.strokePath()
                } else {
                    cgCtx.addPath(cgPath)
                    cgCtx.setStrokeColor(annotation.resolvedCGColor)
                    let lw = annotation.lineWidth.rawValue * strokeScale
                    cgCtx.setLineWidth(lw)
                    cgCtx.setLineCap(.round)
                    cgCtx.setLineJoin(.round)
                    switch annotation.lineStyle {
                    case .dashed: cgCtx.setLineDash(phase: 0, lengths: [lw * 3, lw * 2])
                    case .dotted: cgCtx.setLineDash(phase: 0, lengths: [0.01, lw * 2])
                    case .solid:  break
                    }
                    cgCtx.strokePath()
                }
            }
            cgCtx.restoreGState()
        }

        return cgCtx.makeImage() ?? filteredCGImage ?? bgImage
    }

    func applyFilter(type: AnnotationType, to image: CIImage, in ciRect: CGRect) -> CIImage? {
        let black = CIImage(color: .black).cropped(to: image.extent)
        let white = CIImage(color: .white).cropped(to: ciRect)
        let mask  = white.composited(over: black)

        switch type {
        case .mosaic:
            let f = CIFilter.pixellate()
            f.inputImage = image
            f.scale = 12.0
            guard let out = f.outputImage else { return nil }
            return out.applyingFilter("CIBlendWithMask", parameters: [kCIInputMaskImageKey: mask])
                .composited(over: image)
        case .blur:
            let f = CIFilter.gaussianBlur()
            f.inputImage = image
            f.radius = 20.0
            guard let out = f.outputImage else { return nil }
            return out.applyingFilter("CIBlendWithMask", parameters: [kCIInputMaskImageKey: mask])
                .composited(over: image)
        default:
            return nil
        }
    }
}
