import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Why a picked image could not be turned into something the host accepts.
public enum ImagePreparationError: Error, Sendable, Hashable {
    /// The bytes are not an image this platform can decode.
    case notAnImage
    /// The image was re-encoded and still did not fit a limit.
    case stillTooLarge(ImageAttachmentRefusal)
    /// Encoding produced nothing.
    case encodingFailed
}

/// Turns a picked file into a prompt image, using the host's limits as the target.
///
/// SPEC §9: "Prepare phone formats into an allowed representation and report conversion errors
/// before Send." Two rules follow from that, and this type is where they live:
///
/// 1. **Re-encode only when needed.** An image the host already accepts, inside every limit,
///    is passed through byte-for-byte — re-encoding it would lose quality and could change the
///    very bytes a later `session/attachment` lookup resolves.
/// 2. **A phone format the host does not list becomes one it does.** HEIC is the ordinary case:
///    iOS shoots HEIC, this host accepts PNG/JPEG/WebP/GIF, so a shot is transcoded to JPEG
///    rather than refused.
///
/// Downscaling honours `maxImageDimension` and `maxImagePixels`, then the encoder walks its
/// quality down until the result fits `maxImageBytes`. When even that cannot fit, the refusal
/// names the limit that stopped it rather than saying "conversion failed".
public enum ImagePreparation {
    /// JPEG qualities tried, in order. Four steps is enough to span "visually identical" to
    /// "clearly lossy" without a long encode loop on a phone.
    static let qualities: [Double] = [0.9, 0.75, 0.6, 0.4]

    public static func prepare(
        data: Data,
        name: String?,
        limits: ImageLimits,
        declaredMediaType: String? = nil
    ) throws -> PromptImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let type = CGImageSourceGetType(source) as? String
        else { throw ImagePreparationError.notAnImage }

        let sourceMediaType = declaredMediaType
            ?? UTType(type)?.preferredMIMEType
            ?? "application/octet-stream"

        // 1. Already acceptable: hand back exactly these bytes.
        if limits.mediaTypes.contains(sourceMediaType) {
            let passthrough = PromptImage(
                mediaType: sourceMediaType,
                data: data,
                name: name,
                pixelWidth: width,
                pixelHeight: height
            )
            if (try? ImageAttachmentValidator.validate([passthrough], against: limits)) != nil {
                return passthrough
            }
        }

        // 2. Otherwise decode, shrink to the pixel limits, and encode as JPEG — a media type
        //    this host lists — at the best quality that fits.
        guard let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImagePreparationError.notAnImage
        }
        let target = targetSize(
            width: width,
            height: height,
            maxDimension: limits.maxImageDimension,
            maxPixels: limits.maxImagePixels
        )
        guard let scaled = resize(decoded, to: target) else {
            throw ImagePreparationError.encodingFailed
        }

        var lastRefusal: ImageAttachmentRefusal = .imageTooLarge(byteCount: data.count, limit: limits.maxImageBytes)
        for quality in qualities {
            guard let encoded = encodeJPEG(scaled, quality: quality) else { continue }
            let candidate = PromptImage(
                mediaType: "image/jpeg",
                data: encoded,
                name: jpegName(name),
                pixelWidth: scaled.width,
                pixelHeight: scaled.height
            )
            do {
                try ImageAttachmentValidator.validate([candidate], against: limits)
                return candidate
            } catch let refusal as ImageAttachmentRefusal {
                lastRefusal = refusal
            }
        }
        throw ImagePreparationError.stillTooLarge(lastRefusal)
    }

    // MARK: - Geometry

    /// The largest size inside both the longest-edge and total-pixel limits.
    ///
    /// Both are applied because they bound different shapes: a 8192×8192 square is inside the
    /// dimension limit and far outside a 64 MPix one.
    static func targetSize(
        width: Int,
        height: Int,
        maxDimension: Int,
        maxPixels: Int
    ) -> (width: Int, height: Int) {
        var scale = 1.0
        let longest = max(width, height)
        if longest > maxDimension { scale = Double(maxDimension) / Double(longest) }
        let pixels = Double(width) * Double(height) * scale * scale
        if pixels > Double(maxPixels) {
            scale *= (Double(maxPixels) / pixels).squareRoot()
        }
        return (
            width: max(1, Int((Double(width) * scale).rounded(.down))),
            height: max(1, Int((Double(height) * scale).rounded(.down)))
        )
    }

    private static func resize(_ image: CGImage, to size: (width: Int, height: Int)) -> CGImage? {
        if size.width == image.width, size.height == image.height { return image }
        guard let context = CGContext(
            data: nil,
            width: size.width,
            height: size.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return context.makeImage()
    }

    private static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// A transcoded image is no longer the file it came from, so it gets a matching name: a
    /// `.png` name on JPEG bytes is the kind of small lie that costs somebody an hour.
    static func jpegName(_ name: String?) -> String? {
        guard let name, !name.isEmpty else { return name }
        let base = (name as NSString).deletingPathExtension
        return base.isEmpty ? "image.jpg" : "\(base).jpg"
    }
}
