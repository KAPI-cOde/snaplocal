// AnnotationCanvas.swift - Part 3: Mosaic & Blur Annotations
// SnapLocal - Core Image Filters

import SwiftUI
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Mosaic Annotation

struct MosaicAnnotation: AnnotationElement {
    var id = UUID()
    let type: AnnotationType = .mosaic
    var color: AnnotationColor = .red
    var lineWidth: LineWidth = .thin
    var transform: CGAffineTransform = .identity
    var rect: CGRect
    var intensity: Float = 10.0
    
    var hasStrokeRepresentation: Bool { false }
    
    func path(in rect: CGRect) -> Path {
        let r = self.rect.applying(transform)
        return Path(r)
    }
    
    func hitTest(_ point: CGPoint, in rect: CGRect) -> Bool {
        let r = self.rect.applying(transform)
        return r.contains(point)
    }
    
    func bounds(in rect: CGRect) -> CGRect {
        let r = self.rect.applying(transform)
        return r
    }
    
    func applyFilter(to image: CIImage) -> CIImage? {
        let r = self.rect.applying(transform)
        let filter = CIFilter.pixellate()
        filter.inputImage = image  // full image — prevents edge artifact from cropped input
        filter.scale = intensity
        filter.center = CGPoint(x: r.midX, y: r.midY)

        let blackBackground = CIImage(color: .black).cropped(to: image.extent)
        let whiteRect = CIImage(color: .white).cropped(to: r)
        let maskImage = whiteRect.composited(over: blackBackground)

        guard let filtered = filter.outputImage else { return nil }
        return filtered.applyingFilter("CIBlendWithMask", parameters: [kCIInputMaskImageKey: maskImage])
            .composited(over: image)
    }
}

// MARK: - Blur Annotation

struct BlurAnnotation: AnnotationElement {
    var id = UUID()
    let type: AnnotationType = .blur
    var color: AnnotationColor = .red
    var lineWidth: LineWidth = .thin
    var transform: CGAffineTransform = .identity
    var rect: CGRect
    var intensity: Float = 20.0
    
    var hasStrokeRepresentation: Bool { false }
    
    func path(in rect: CGRect) -> Path {
        let r = self.rect.applying(transform)
        return Path(r)
    }

    func hitTest(_ point: CGPoint, in rect: CGRect) -> Bool {
        let r = self.rect.applying(transform)
        return r.contains(point)
    }

    func bounds(in rect: CGRect) -> CGRect {
        let r = self.rect.applying(transform)
        return r
    }

    func applyFilter(to image: CIImage) -> CIImage? {
        let r = self.rect.applying(transform)
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = image
        filter.radius = intensity

        // White = show filtered, Black = show original
        let blackBackground = CIImage(color: .black).cropped(to: image.extent)
        let whiteRect = CIImage(color: .white).cropped(to: r)
        let maskImage = whiteRect.composited(over: blackBackground)

        guard let filtered = filter.outputImage else { return nil }
        return filtered.applyingFilter("CIBlendWithMask", parameters: [kCIInputMaskImageKey: maskImage])
            .composited(over: image)
    }
}