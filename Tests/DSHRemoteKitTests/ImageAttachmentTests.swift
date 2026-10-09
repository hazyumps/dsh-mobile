import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import DSHRemoteKit

/// The image limits the host advertises, and the refusals that name them.
///
/// The numbers are the ones the installed host reported on 2026-10-09, through its
/// `imageLimits` session projection.
@Suite("Image attachments")
struct ImageAttachmentTests {

    /// The live projection, verbatim.
    private var liveLimitsJSON: JSONValue {
        .object([
            "maxImageBytes": .int(20_971_520),
            "maxImagesPerMessage": .int(20),
            "maxMessageImageBytes": .int(209_715_200),
            "maxImagePixels": .int(64_000_000),
            "maxImageDimension": .int(8192),
            "mediaTypes": .array([
                .string("image/png"), .string("image/jpeg"),
                .string("image/webp"), .string("image/gif"),
            ]),
        ])
    }

    private var limits: ImageLimits {
        // swiftlint:disable:next force_unwrapping
        ImageLimits(json: liveLimitsJSON)!
    }

    private func image(
        mediaType: String = "image/png",
        bytes: Int = 1000,
        width: Int = 100,
        height: Int = 100
    ) -> PromptImage {
        PromptImage(
            mediaType: mediaType,
            data: Data(repeating: 0x41, count: bytes),
            name: "shot.png",
            pixelWidth: width,
            pixelHeight: height
        )
    }

    @Test("the live projection parses, and a projection missing a limit does not")
    func limitsComeFromTheHost() {
        let parsed = try? #require(ImageLimits(json: liveLimitsJSON))
        #expect(parsed?.maxImageBytes == 20_971_520)
        #expect(parsed?.maxImagesPerMessage == 20)
        #expect(parsed?.maxImageDimension == 8192)
        #expect(parsed?.mediaTypes == ["image/png", "image/jpeg", "image/webp", "image/gif"])

        // No default: a host that omits a limit gets no image sending, not a guessed number.
        var partial = liveLimitsJSON.objectValue ?? [:]
        partial["maxImageDimension"] = nil
        #expect(ImageLimits(json: .object(partial)) == nil)
    }

    @Test("an image inside every limit is accepted, including exactly on the boundary")
    func acceptsWithinLimits() throws {
        try ImageAttachmentValidator.validate([image()], against: limits)
        // A limit is inclusive: an image exactly at the dimension and byte limits passes.
        try ImageAttachmentValidator.validate(
            [image(bytes: 20_971_520, width: 8192, height: 1)],
            against: limits
        )
    }

    @Test("each limit refuses with its own name, rather than one vague error")
    func refusalsNameTheirLimit() {
        func refusal(_ images: [PromptImage]) -> ImageAttachmentRefusal? {
            do {
                try ImageAttachmentValidator.validate(images, against: limits)
                return nil
            } catch let refusal as ImageAttachmentRefusal {
                return refusal
            } catch {
                return nil
            }
        }

        #expect(refusal([image(mediaType: "image/tiff")])
            == .unsupportedMediaType(mediaType: "image/tiff", supported: limits.mediaTypes))
        #expect(refusal([image(bytes: 20_971_521)])
            == .imageTooLarge(byteCount: 20_971_521, limit: 20_971_520))
        #expect(refusal(Array(repeating: image(), count: 21))
            == .tooManyImages(count: 21, limit: 20))
        #expect(refusal([image(width: 8001, height: 8000)])
            == .tooManyPixels(pixels: 64_008_000, limit: 64_000_000))
        #expect(refusal([image(width: 8193, height: 1)])
            == .dimensionTooLarge(longestEdge: 8193, limit: 8192))
        // The message total is the only batch-level limit, so it is checked last: images that
        // each fit can still add up past it.
        #expect(refusal(Array(repeating: image(bytes: 10_000_000), count: 21)) != nil)
    }

    @Test("a message over the total is refused for the total, not for one image")
    func batchTotalIsItsOwnRefusal() {
        // Nine 19 MiB images: each fits `maxImageBytes`, and together they are 171 MiB — under
        // the 200 MiB total, so this passes and proves the check is a real sum.
        let fits = Array(repeating: image(bytes: 19 * 1_024 * 1_024), count: 9)
        try? ImageAttachmentValidator.validate(fits, against: limits)
        #expect((try? ImageAttachmentValidator.validate(fits, against: limits)) != nil)

        // Eleven of them is 209 MiB, past the total.
        let over = Array(repeating: image(bytes: 19 * 1_024 * 1_024), count: 11)
        #expect(throws: ImageAttachmentRefusal.self) {
            try ImageAttachmentValidator.validate(over, against: limits)
        }
    }

    // MARK: - Preparation

    /// A solid-colour PNG of a given size, built here so the test needs no fixture file.
    private func png(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @Test("an image the host already accepts is passed through byte-for-byte")
    func fittingImageIsNotReEncoded() throws {
        let source = try png(width: 64, height: 64)
        let prepared = try ImagePreparation.prepare(data: source, name: "shot.png", limits: limits)

        // Re-encoding would lose quality and could change the bytes a later lookup resolves.
        #expect(prepared.mediaType == "image/png")
        #expect(prepared.data == source)
        #expect(prepared.pixelWidth == 64)
        #expect(prepared.name == "shot.png")
    }

    @Test("an oversized image is shrunk to the host's limits and becomes a type it accepts")
    func oversizedImageIsPrepared() throws {
        // A square is the case the two limits disagree about, so the pixel cap has to bite too.
        let source = try png(width: 900, height: 900)
        let small = ImageLimits(
            maxImageBytes: 20_971_520,
            maxImagesPerMessage: 20,
            maxMessageImageBytes: 209_715_200,
            maxImagePixels: 64_000_000,
            maxImageDimension: 128,
            mediaTypes: ["image/jpeg"]
        )

        let prepared = try ImagePreparation.prepare(data: source, name: "IMG_0001.png", limits: small)

        #expect(prepared.longestEdge <= 128)
        #expect(prepared.pixelCount <= 64_000_000)
        // The host does not list PNG here, so it was transcoded — and the name follows the
        // bytes rather than still claiming `.png`.
        #expect(prepared.mediaType == "image/jpeg")
        #expect(prepared.name == "IMG_0001.jpg")
        try ImageAttachmentValidator.validate([prepared], against: small)
    }

    @Test("the geometry helper honours both the edge and the pixel cap")
    func targetSizeHonoursBothLimits() {
        // Inside both.
        #expect(ImagePreparation.targetSize(width: 100, height: 50, maxDimension: 200, maxPixels: 100_000)
            == (100, 50))
        // The longest edge binds.
        #expect(ImagePreparation.targetSize(width: 400, height: 200, maxDimension: 100, maxPixels: 1_000_000)
            == (100, 50))
        // The pixel cap binds: 1000×1000 is inside a 2000 edge limit and over a 100k cap.
        let capped = ImagePreparation.targetSize(width: 1000, height: 1000, maxDimension: 2000, maxPixels: 100_000)
        #expect(capped.width * capped.height <= 100_000)
    }

    @Test("an image that cannot be made to fit refuses with the limit that stopped it")
    func impossibleLimitsRefuse() throws {
        let source = try png(width: 64, height: 64)
        let impossible = ImageLimits(
            maxImageBytes: 10,
            maxImagesPerMessage: 20,
            maxMessageImageBytes: 200,
            maxImagePixels: 64_000_000,
            maxImageDimension: 8192,
            mediaTypes: ["image/jpeg"]
        )
        #expect(throws: ImagePreparationError.self) {
            try ImagePreparation.prepare(data: source, name: "shot.png", limits: impossible)
        }
    }

    @Test("every refusal says which limit it hit")
    func refusalsRead() {
        for refusal: ImageAttachmentRefusal in [
            .unsupportedMediaType(mediaType: "image/tiff", supported: ["image/png"]),
            .imageTooLarge(byteCount: 30_000_000, limit: 20_971_520),
            .tooManyImages(count: 25, limit: 20),
            .messageTooLarge(totalBytes: 300_000_000, limit: 209_715_200),
            .tooManyPixels(pixels: 70_000_000, limit: 64_000_000),
            .dimensionTooLarge(longestEdge: 10_000, limit: 8192),
        ] {
            let text = ImageAttachmentValidator.describe(refusal)
            #expect(!text.isEmpty)
            #expect(text.contains("harness"), "a refusal should name whose limit it is: \(text)")
        }
    }
}
