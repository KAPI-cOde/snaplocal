// AnnotationCanvas.swift - Part 3: Mosaic & Blur Annotations
// SnapLocal - Core Image Filters

import SwiftUI
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Mosaic Annotation

struct MosaicAnnotation: AnnotationElement {
    let id = UUID()
    let type: AnnotationType = .mosaic
    var color: AnnotationColor = .red
    var lineWidth: LineWidth = .thin
    var transform: CGAffineTransform = .identity
    var rect: CGRect
    var intensity: Float = 10.0

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

    mutating func applyTransform(_ transform: CGAffineTransform) {
        self.transform = transform.concatenating(self.transform)
    }

    func applyFilter(to image: CIImage) -> CIImage? {
        let r = self.rect.applying(transform)
        let filter = CIFilter.pixellate()
        filter.inputImage = image
        filter.scale = intensity
        
        // Create a mask for the region
        let mask = CIImage(color: .black)
            .cropped(to: image.extent)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
            ])
        
        let whiteRect = CIImage(color: .white).cropped(to: r)
        let maskImage = mask.composited(over: whiteRect)
        
        guard let filtered = filter.outputImage else { return nil }
        return filtered.applyingFilter("CIBlendWithMask", parameters: [kCIInputMaskImageKey: maskImage])
            .composited(over: image)
    }
}

// MARK: - Blur Annotation

struct BlurAnnotation: AnnotationElement {
    let id = UUID()
    let type: AnnotationType = .blur
    var color: AnnotationColor = .red
    var lineWidth: LineWidth = .thin
    var transform: CGAffineTransform = .identity
    var rect: CGRect
    var intensity: Float = 20.0

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

    mutating func applyTransform(_ transform: CGAffineTransform) {
        self.transform = transform.concatenating(self.transform)
    }

    func applyFilter(to image: CIImage) -> CIImage? {
        let r = self.rect.applying(transform)
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = image
        filter.radius = intensity
        
        let mask = CIImage(color: .black)
            .cropped(to: image.extent)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
            ])
        
        let whiteRect = CIImage(color: .white).cropped(to: r)
        let maskImage = mask.composited(over: whiteRect)
        
        guard let filtered = filter.outputImage else { return nil }
        return filtered.applyingFilter("CIBlendWithMask", parameters: [kCIInputMaskImageKey: maskImage])
            .composited(over: image)
    }
}