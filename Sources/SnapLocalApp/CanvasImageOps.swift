import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - CanvasViewModel: 画像変換・クロップ系

@MainActor
extension CanvasViewModel {

    // MARK: - Crop

    func enterCropMode() {
        dragState.cancel()
        isDraggingAnnotation = false
        isCropMode = true
        cropStart = nil
        cropEnd = nil
        selectedAnnotationID = nil
        showTextInput = false
    }

    func confirmCrop() {
        defer { cancelCrop() }
        guard let start = cropStart, let end = cropEnd,
              let bgImage = backgroundImage,
              canvasSize.width > 0, canvasSize.height > 0 else { return }
        let sel = CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        )
        guard sel.width > 4, sel.height > 4 else { return }
        let scaleX = CGFloat(bgImage.width) / canvasSize.width
        let scaleY = CGFloat(bgImage.height) / canvasSize.height
        let pixelRect = CGRect(
            x: sel.minX * scaleX, y: sel.minY * scaleY,
            width: sel.width * scaleX, height: sel.height * scaleY
        ).intersection(CGRect(x: 0, y: 0, width: CGFloat(bgImage.width), height: CGFloat(bgImage.height)))
        guard !pixelRect.isNull, pixelRect.width > 0, pixelRect.height > 0,
              let cropped = bgImage.cropping(to: pixelRect) else { return }
        let prevImage = bgImage
        let prevAnnotations = annotations
        backgroundImage = cropped
        annotations.removeAll()
        selectedAnnotationID = nil
        cropAnimToken = UUID()
        registerBackgroundUndo(previousImage: prevImage, previousAnnotations: prevAnnotations)
        recomputeAllFilterPreviews()
    }

    func cancelCrop() {
        isCropMode = false
        cropStart = nil; cropEnd = nil; cropAspectRatio = nil
        cropHandleActive = nil
    }

    // Crop directly to a canvas-space rect (from annotation bounds)
    func cropToRect(_ canvasRect: CGRect) {
        guard canvasRect.width > 4, canvasRect.height > 4,
              let bgImage = backgroundImage,
              canvasSize.width > 0, canvasSize.height > 0 else { return }
        let scaleX = CGFloat(bgImage.width) / canvasSize.width
        let scaleY = CGFloat(bgImage.height) / canvasSize.height
        let pixelRect = CGRect(
            x: canvasRect.minX * scaleX, y: canvasRect.minY * scaleY,
            width: canvasRect.width * scaleX, height: canvasRect.height * scaleY
        ).intersection(CGRect(x: 0, y: 0, width: CGFloat(bgImage.width), height: CGFloat(bgImage.height)))
        guard !pixelRect.isNull, pixelRect.width > 0, pixelRect.height > 0,
              let cropped = bgImage.cropping(to: pixelRect) else { return }
        let prevImage = bgImage
        let prevAnnotations = annotations
        backgroundImage = cropped
        annotations.removeAll()
        selectedAnnotationID = nil
        registerBackgroundUndo(previousImage: prevImage, previousAnnotations: prevAnnotations)
        recomputeAllFilterPreviews()
    }

    // Detect background color from corner pixels and trim uniform-color borders.
    func trimWhitespace(threshold: CGFloat = 8) {
        guard let img = backgroundImage, img.width > 2, img.height > 2 else { return }
        // Render to an ARGB8888 bitmap for pixel access
        let w = img.width, h = img.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Sample corner pixels to determine background color
        func pixel(_ x: Int, _ y: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
            let i = (y * w + x) * 4
            let a = CGFloat(pixels[i + 3]) / 255
            guard a > 0 else { return (1, 1, 1) }
            return (CGFloat(pixels[i]) / 255 / a,
                    CGFloat(pixels[i + 1]) / 255 / a,
                    CGFloat(pixels[i + 2]) / 255 / a)
        }
        let corners = [pixel(0, 0), pixel(w-1, 0), pixel(0, h-1), pixel(w-1, h-1)]
        let bgR = corners.map(\.r).reduce(0, +) / CGFloat(corners.count)
        let bgG = corners.map(\.g).reduce(0, +) / CGFloat(corners.count)
        let bgB = corners.map(\.b).reduce(0, +) / CGFloat(corners.count)

        func isBackground(_ x: Int, _ y: Int) -> Bool {
            let p = pixel(x, y)
            let dist = abs(p.r - bgR) + abs(p.g - bgG) + abs(p.b - bgB)
            return dist * 255 < threshold
        }

        // Find crop bounds
        var minX = 0, maxX = w - 1, minY = 0, maxY = h - 1
        outer: for x in 0..<w {
            for y in 0..<h { if !isBackground(x, y) { minX = x; break outer } }
        }
        outer: for x in stride(from: w-1, through: 0, by: -1) {
            for y in 0..<h { if !isBackground(x, y) { maxX = x; break outer } }
        }
        outer: for y in 0..<h {
            for x in 0..<w { if !isBackground(x, y) { minY = y; break outer } }
        }
        outer: for y in stride(from: h-1, through: 0, by: -1) {
            for x in 0..<w { if !isBackground(x, y) { maxY = y; break outer } }
        }

        let cropW = maxX - minX + 1, cropH = maxY - minY + 1
        guard cropW > 4, cropH > 4,
              (cropW < w || cropH < h),
              let cropped = img.cropping(to: CGRect(x: minX, y: minY, width: cropW, height: cropH)) else { return }

        let prevImage = img
        let prevAnnotations = annotations
        backgroundImage = cropped
        annotations.removeAll()
        selectedAnnotationID = nil
        registerBackgroundUndo(previousImage: prevImage, previousAnnotations: prevAnnotations)
        recomputeAllFilterPreviews()
    }

    // Register undo for a background image replacement (saves previous image + annotations)
    private func registerBackgroundUndo(previousImage: CGImage, previousAnnotations: [AnyAnnotation]) {
        backgroundDirty = true
        undoManager.registerMainActorUndo(withTarget: self) { [previousImage, previousAnnotations] vm in
            let currentImage = vm.backgroundImage
            let currentAnnotations = vm.annotations
            vm.backgroundImage = previousImage
            vm.annotations = previousAnnotations
            vm.backgroundDirty = true
            vm.selectedAnnotationID = nil
            vm.selectedAnnotationIDs = []
            vm.updateUndoRedoState()
            vm.recomputeAllFilterPreviews()
            vm.undoManager.registerMainActorUndo(withTarget: vm) { [currentImage, currentAnnotations] vm2 in
                vm2.backgroundImage = currentImage
                vm2.annotations = currentAnnotations
                vm2.backgroundDirty = true
                vm2.selectedAnnotationID = nil
                vm2.selectedAnnotationIDs = []
                vm2.updateUndoRedoState()
                vm2.recomputeAllFilterPreviews()
            }
        }
        updateUndoRedoState()
    }

    // MARK: - Canvas Extend

    /// Extend the canvas by adding padding on each side with a given background color.
    func extendCanvas(top: CGFloat, right: CGFloat, bottom: CGFloat, left: CGFloat, bgColor: CGColor) {
        guard let src = backgroundImage else { return }
        let newW = CGFloat(src.width) + left + right
        let newH = CGFloat(src.height) + top + bottom
        guard newW >= 1, newH >= 1, newW <= 16000, newH <= 16000 else { return }
        guard let ctx = CGContext(
            data: nil, width: Int(newW), height: Int(newH),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        ctx.setFillColor(bgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: newW, height: newH))
        // CGContext y-axis is bottom-up: original sits at (left, bottom)
        ctx.draw(src, in: CGRect(x: left, y: bottom, width: CGFloat(src.width), height: CGFloat(src.height)))
        guard let result = ctx.makeImage() else { return }
        let prevImage = src
        let prevAnnotations = annotations
        backgroundImage = result
        canvasSize = CGSize(width: newW, height: newH)
        registerBackgroundUndo(previousImage: prevImage, previousAnnotations: prevAnnotations)
        recomputeAllFilterPreviews()
        objectWillChange.send()
    }

    // MARK: - Image Stitch

    /// Stitch `other` below (vertical=true) or to the right (vertical=false) of the current background.
    func stitch(with other: CGImage, vertical: Bool) {
        guard let src = backgroundImage else { return }
        let outW = vertical ? max(src.width, other.width) : src.width + other.width
        let outH = vertical ? src.height + other.height : max(src.height, other.height)
        guard let ctx = CGContext(
            data: nil, width: outW, height: outH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))
        if vertical {
            // top = src, bottom = other (CGContext y is bottom-up)
            ctx.draw(src, in: CGRect(x: 0, y: outH - src.height, width: src.width, height: src.height))
            ctx.draw(other, in: CGRect(x: 0, y: 0, width: other.width, height: other.height))
        } else {
            // left = src, right = other
            ctx.draw(src, in: CGRect(x: 0, y: outH - src.height, width: src.width, height: src.height))
            ctx.draw(other, in: CGRect(x: src.width, y: outH - other.height, width: other.width, height: other.height))
        }
        guard let stitched = ctx.makeImage() else { return }
        let prevImage = src
        let prevAnnotations = annotations
        backgroundImage = stitched
        canvasSize = CGSize(width: CGFloat(outW), height: CGFloat(outH))
        registerBackgroundUndo(previousImage: prevImage, previousAnnotations: prevAnnotations)
        recomputeAllFilterPreviews()
    }

    // MARK: - Image Adjustments

    func bakeAdjustments() {
        guard adjustBrightness != 0 || adjustContrast != 1 || adjustSaturation != 1 || adjustSharpness != 0,
              let src = backgroundImage else { return }
        var ci = CIImage(cgImage: src)
        // Color controls
        if adjustBrightness != 0 || adjustContrast != 1 || adjustSaturation != 1 {
            let f = CIFilter.colorControls()
            f.inputImage = ci
            f.brightness = Float(adjustBrightness)
            f.contrast = Float(adjustContrast)
            f.saturation = Float(adjustSaturation)
            if let out = f.outputImage { ci = out }
        }
        // Sharpen
        if adjustSharpness > 0 {
            let sf = CIFilter.sharpenLuminance()
            sf.inputImage = ci
            sf.sharpness = Float(adjustSharpness)
            sf.radius = 1.69 + Float(adjustSharpness) * 0.5
            if let out = sf.outputImage { ci = out }
        }
        let ctx = CIContext()
        guard let baked = ctx.createCGImage(ci, from: ci.extent) else { return }
        let prevImage = src
        let prevAnnotations = annotations
        backgroundImage = baked
        adjustBrightness = 0; adjustContrast = 1; adjustSaturation = 1; adjustSharpness = 0
        registerBackgroundUndo(previousImage: prevImage, previousAnnotations: prevAnnotations)
    }

    func resetAdjustments() {
        adjustBrightness = 0; adjustContrast = 1; adjustSaturation = 1; adjustSharpness = 0
    }

    var hasActiveAdjustments: Bool {
        adjustBrightness != 0 || adjustContrast != 1 || adjustSaturation != 1 || adjustSharpness != 0
    }

    // MARK: - Image Rotation

    func rotateImage(clockwise: Bool) {
        guard let src = backgroundImage else { return }
        let w = src.width, h = src.height
        guard let ctx = CGContext(
            data: nil, width: h, height: w,
            bitsPerComponent: src.bitsPerComponent,
            bytesPerRow: 0,
            space: src.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: src.bitmapInfo.rawValue
        ) else { return }

        if clockwise {
            ctx.translateBy(x: CGFloat(h), y: 0)
            ctx.rotate(by: .pi / 2)
        } else {
            ctx.translateBy(x: 0, y: CGFloat(w))
            ctx.rotate(by: -.pi / 2)
        }
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        guard let rotated = ctx.makeImage() else { return }

        let oldW = canvasSize.width, oldH = canvasSize.height

        // Transform each annotation so it stays in place on the new (swapped) canvas
        // 90° CW: (x, y) → (oldH - y, x)  →  transform: translate(0, oldH) then rotate -π/2 (screen coords)
        // 90° CCW: (x, y) → (y, oldW - x)  →  transform: translate(oldW, 0) then rotate +π/2 (screen coords)
        let rotT: CGAffineTransform = clockwise
            ? CGAffineTransform(rotationAngle: .pi / 2).concatenating(CGAffineTransform(translationX: oldH, y: 0))
            : CGAffineTransform(rotationAngle: -.pi / 2).concatenating(CGAffineTransform(translationX: 0, y: oldW))

        for i in 0..<annotations.count {
            annotations[i].transform = annotations[i].transform.concatenating(rotT)
        }

        let prevImage = src
        let prevAnnotations = annotations
        backgroundImage = rotated
        canvasSize = CGSize(width: oldH, height: oldW)
        registerBackgroundUndo(previousImage: prevImage, previousAnnotations: prevAnnotations)
        recomputeAllFilterPreviews()
        objectWillChange.send()
    }

    // MARK: - Flip

    func flipImage(horizontal: Bool) {
        guard let src = backgroundImage else { return }
        let w = src.width, h = src.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        if horizontal {
            ctx.translateBy(x: CGFloat(w), y: 0)
            ctx.scaleBy(x: -1, y: 1)
        } else {
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        guard let flipped = ctx.makeImage() else { return }

        // Mirror each annotation's transform to match the flipped canvas
        let flipT: CGAffineTransform = horizontal
            ? CGAffineTransform(scaleX: -1, y: 1).concatenating(CGAffineTransform(translationX: canvasSize.width, y: 0))
            : CGAffineTransform(scaleX: 1, y: -1).concatenating(CGAffineTransform(translationX: 0, y: canvasSize.height))
        for i in 0..<annotations.count {
            annotations[i].transform = annotations[i].transform.concatenating(flipT)
        }
        let prevImage = src
        let prevAnnotations = annotations
        backgroundImage = flipped
        registerBackgroundUndo(previousImage: prevImage, previousAnnotations: prevAnnotations)
        recomputeAllFilterPreviews()
        objectWillChange.send()
    }

    // MARK: - Resize

    /// Resize to fit within the given target dimensions while preserving aspect ratio.
    func resizeToFit(width targetW: Int, height targetH: Int) {
        guard let src = backgroundImage, src.width > 0, src.height > 0 else { return }
        let scaleX = CGFloat(targetW) / CGFloat(src.width)
        let scaleY = CGFloat(targetH) / CGFloat(src.height)
        let scale = min(scaleX, scaleY)
        resizeCanvas(scale: scale)
    }

    func resizeCanvas(scale: CGFloat) {
        guard let src = backgroundImage, scale > 0, scale != 1.0 else { return }
        let newW = max(1, Int(CGFloat(src.width) * scale))
        let newH = max(1, Int(CGFloat(src.height) * scale))
        guard let ctx = CGContext(
            data: nil, width: newW, height: newH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        ctx.interpolationQuality = scale < 1.0 ? .high : .medium
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        guard let resized = ctx.makeImage() else { return }

        // Scale all annotation transforms
        let scaleT = CGAffineTransform(scaleX: scale, y: scale)
        for i in 0..<annotations.count {
            annotations[i].transform = annotations[i].transform.concatenating(scaleT)
        }

        let prevImage = src
        let prevAnnotations = annotations
        backgroundImage = resized
        canvasSize = CGSize(width: CGFloat(newW), height: CGFloat(newH))
        registerBackgroundUndo(previousImage: prevImage, previousAnnotations: prevAnnotations)
        recomputeAllFilterPreviews()
        loadToken = UUID()
        objectWillChange.send()
    }

}
