import Foundation

/// The image limits the host advertises for a session.
///
/// From the `imageLimits` session projection — the **host's** numbers, never this app's:
/// the installed host on 2026-10-09 reports 20 MiB per image, 20 per message, 200 MiB per
/// message, 64 MPix, an 8192-pixel longest edge, and PNG/JPEG/WebP/GIF.
///
/// There is deliberately no `default` case. A client that fell back to its own numbers would
/// send an image the host refuses, or refuse one it would have accepted, and either way the
/// user would be told something the host never said.
public struct ImageLimits: Sendable, Hashable {
    public var maxImageBytes: Int
    public var maxImagesPerMessage: Int
    public var maxMessageImageBytes: Int
    public var maxImagePixels: Int
    public var maxImageDimension: Int
    /// The media types the host accepts, as wire strings.
    public var mediaTypes: [String]

    public init(
        maxImageBytes: Int,
        maxImagesPerMessage: Int,
        maxMessageImageBytes: Int,
        maxImagePixels: Int,
        maxImageDimension: Int,
        mediaTypes: [String]
    ) {
        self.maxImageBytes = maxImageBytes
        self.maxImagesPerMessage = maxImagesPerMessage
        self.maxMessageImageBytes = maxMessageImageBytes
        self.maxImagePixels = maxImagePixels
        self.maxImageDimension = maxImageDimension
        self.mediaTypes = mediaTypes
    }

    /// Reads the projection's value.
    ///
    /// Every field is required, because a limit that is missing is not a limit the client may
    /// invent: a host that omits one gets an app that offers no image sending at all rather
    /// than one that guesses.
    public init?(json: JSONValue) {
        guard let maxImageBytes = json["maxImageBytes"]?.intValue,
              let maxImagesPerMessage = json["maxImagesPerMessage"]?.intValue,
              let maxMessageImageBytes = json["maxMessageImageBytes"]?.intValue,
              let maxImagePixels = json["maxImagePixels"]?.intValue,
              let maxImageDimension = json["maxImageDimension"]?.intValue,
              let mediaTypes = json["mediaTypes"]?.arrayValue?.compactMap(\.stringValue)
        else { return nil }
        self.init(
            maxImageBytes: Int(maxImageBytes),
            maxImagesPerMessage: Int(maxImagesPerMessage),
            maxMessageImageBytes: Int(maxMessageImageBytes),
            maxImagePixels: Int(maxImagePixels),
            maxImageDimension: Int(maxImageDimension),
            mediaTypes: mediaTypes
        )
    }

    /// The generated shape, so a decoded projection and a JSONValue one agree.
    public init(_ value: SessionProjectionsValueValuesImageLimits) {
        self.init(
            maxImageBytes: Int(value.maxImageBytes),
            maxImagesPerMessage: Int(value.maxImagesPerMessage),
            maxMessageImageBytes: Int(value.maxMessageImageBytes),
            maxImagePixels: Int(value.maxImagePixels),
            maxImageDimension: Int(value.maxImageDimension),
            mediaTypes: value.mediaTypes.map(\.rawValue)
        )
    }
}

/// One image prepared for a prompt.
///
/// The pixels travel base64-encoded in the prompt itself — SPEC §9 keeps generic files on the
/// upload route and images inline — so this carries the bytes and the metadata the limits are
/// checked against.
public struct PromptImage: Sendable, Hashable {
    public var mediaType: String
    public var data: Data
    public var name: String?
    public var pixelWidth: Int
    public var pixelHeight: Int

    public var byteCount: Int { data.count }
    public var pixelCount: Int { pixelWidth * pixelHeight }
    /// The longest edge, which is what `maxImageDimension` bounds.
    public var longestEdge: Int { max(pixelWidth, pixelHeight) }

    public init(
        mediaType: String,
        data: Data,
        name: String? = nil,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.mediaType = mediaType
        self.data = data
        self.name = name
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// Why an image cannot be sent, in the host's own terms.
///
/// Each case names the limit that refused it, because SPEC §9 asks for the conversion error
/// **before** Send: "this image is too large" is not actionable, and "over the host's 20 MiB
/// per image" is.
public enum ImageAttachmentRefusal: Error, Sendable, Hashable {
    case unsupportedMediaType(mediaType: String, supported: [String])
    case imageTooLarge(byteCount: Int, limit: Int)
    case tooManyImages(count: Int, limit: Int)
    case messageTooLarge(totalBytes: Int, limit: Int)
    case tooManyPixels(pixels: Int, limit: Int)
    case dimensionTooLarge(longestEdge: Int, limit: Int)
}

/// Checks prepared images against the host's limits, before anything is sent.
public enum ImageAttachmentValidator {
    /// - Throws: ``ImageAttachmentRefusal`` naming the first limit that refused the batch.
    public static func validate(_ images: [PromptImage], against limits: ImageLimits) throws {
        guard images.count <= limits.maxImagesPerMessage else {
            throw ImageAttachmentRefusal.tooManyImages(
                count: images.count,
                limit: limits.maxImagesPerMessage
            )
        }
        var total = 0
        for image in images {
            guard limits.mediaTypes.contains(image.mediaType) else {
                throw ImageAttachmentRefusal.unsupportedMediaType(
                    mediaType: image.mediaType,
                    supported: limits.mediaTypes
                )
            }
            guard image.byteCount <= limits.maxImageBytes else {
                throw ImageAttachmentRefusal.imageTooLarge(
                    byteCount: image.byteCount,
                    limit: limits.maxImageBytes
                )
            }
            guard image.pixelCount <= limits.maxImagePixels else {
                throw ImageAttachmentRefusal.tooManyPixels(
                    pixels: image.pixelCount,
                    limit: limits.maxImagePixels
                )
            }
            guard image.longestEdge <= limits.maxImageDimension else {
                throw ImageAttachmentRefusal.dimensionTooLarge(
                    longestEdge: image.longestEdge,
                    limit: limits.maxImageDimension
                )
            }
            total += image.byteCount
        }
        // The message total is checked last, because it is the only limit that depends on the
        // whole batch: an image that fits on its own can still push a message over.
        guard total <= limits.maxMessageImageBytes else {
            throw ImageAttachmentRefusal.messageTooLarge(
                totalBytes: total,
                limit: limits.maxMessageImageBytes
            )
        }
    }

    /// What a refusal should say to the user.
    public static func describe(_ refusal: ImageAttachmentRefusal) -> String {
        switch refusal {
        case .unsupportedMediaType(let mediaType, let supported):
            "The harness does not accept \(mediaType). It accepts \(supported.joined(separator: ", "))."
        case .imageTooLarge(let byteCount, let limit):
            "That image is \(byteCount) bytes; the harness allows \(limit) per image."
        case .tooManyImages(let count, let limit):
            "\(count) images is over the harness's limit of \(limit) per message."
        case .messageTooLarge(let totalBytes, let limit):
            "Those images total \(totalBytes) bytes; the harness allows \(limit) per message."
        case .tooManyPixels(let pixels, let limit):
            "That image is \(pixels) pixels; the harness allows \(limit)."
        case .dimensionTooLarge(let longestEdge, let limit):
            "That image is \(longestEdge) pixels on its longest edge; the harness allows \(limit)."
        }
    }
}
