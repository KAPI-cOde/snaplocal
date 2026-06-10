// AnnotationMosaicBlur.swift - Redact (Mosaic / Blur) Annotation
// SnapLocal - Core Image Filters

import SwiftUI
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Redact Annotation (mosaic / blur)

/// Unified struct for the two redaction annotation types (R4.1).
/// `type` is `.mosaic` or `.blur` — the AnnotationType raw values and the
/// encoded key set (id/type/color/lineWidth/transform/rect/intensity) are
/// identical to the former MosaicAnnotation/BlurAnnotation, so entries saved
/// by either old struct decode here unchanged (and vice versa).
struct RedactAnnotation: AnnotationElement {
    var id = UUID()
    var type: AnnotationType
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
        let filtered: CIImage?
        switch type {
        case .blur:
            let filter = CIFilter.gaussianBlur()
            filter.inputImage = image
            filter.radius = intensity
            filtered = filter.outputImage
        default: // .mosaic
            let filter = CIFilter.pixellate()
            filter.inputImage = image  // full image — prevents edge artifact from cropped input
            filter.scale = intensity
            filter.center = CGPoint(x: r.midX, y: r.midY)
            filtered = filter.outputImage
        }

        // White = show filtered, Black = show original
        let blackBackground = CIImage(color: .black).cropped(to: image.extent)
        let whiteRect = CIImage(color: .white).cropped(to: r)
        let maskImage = whiteRect.composited(over: blackBackground)

        guard let filtered else { return nil }
        return filtered.applyingFilter("CIBlendWithMask", parameters: [kCIInputMaskImageKey: maskImage])
            .composited(over: image)
    }
}
