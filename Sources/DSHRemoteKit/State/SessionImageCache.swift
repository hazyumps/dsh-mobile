import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A decoded image, sized for display rather than for the file it came from.
///
/// `@unchecked Sendable` is a deliberate, narrow claim: a `CGImage` is immutable once
/// created, so handing the same one to several views is safe, but CoreGraphics does not
/// declare that. This records the reasoning instead of leaving the compiler to guess, and
/// it is the only unchecked conformance in the type.
public struct DisplayImage: @unchecked Sendable {
    public let image: CGImage
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// What this image costs against the cache's budget, in bytes.
    ///
    /// An estimate from the pixel count and not the encoded file's size, because the
    /// decoded buffer is what the memory warning is about: a 200 KiB JPEG can decode to
    /// tens of megabytes.
    public let byteCost: Int

    public init(image: CGImage, byteCost: Int? = nil) {
        self.image = image
        self.pixelWidth = image.width
        self.pixelHeight = image.height
        self.byteCost = byteCost ?? (image.width * image.height * 4)
    }
}

/// Fetches one attachment's bytes. Injected so this type never knows about the RPC layer.
///
/// `session/attachment` returns base64 image data for an attachment the session already
/// references (SPEC §6.8/§9); the caller owns that call, its redaction, and its retry
/// policy.
public typealias AttachmentFetcher = @Sendable (_ sessionId: String, _ attachmentId: String) async throws -> Data

/// Why an attachment could not be turned into something displayable.
public enum ImageLoadError: Error, Sendable, Hashable {
    /// The bytes are not an image this device can decode.
    case notAnImage
    /// The image decoded but produced no thumbnail, which should not happen for a
    /// decodable image and is reported rather than silently substituted.
    case thumbnailFailed
}

/// Decodes attachment images once, at display size, under a memory budget.
///
/// SPEC §9 requires three things of this path, and each is a real failure mode rather
/// than a nicety:
///
/// - **"Decode off the main actor."** Decoding a photograph on the main actor is a visible
///   hitch, so this is an `actor` and the work happens where the caller awaits it.
/// - **"Downsample for display."** A phone camera image is far larger than the screen
///   area that will show it. Full-size decoding is the usual cause of an out-of-memory
///   crash in a chat view, so the thumbnail path is used — which decodes at the target
///   size instead of decoding then shrinking, and is the only version of this that
///   actually saves the memory.
/// - **"Bound memory/disk caches."** ``byteLimit`` is enforced by evicting least-recently
///   used entries. There is no disk cache here on purpose: the phone's disk is not the
///   scarce resource and the host is the source of truth.
///
/// Nothing here caches by URL. Attachments are named by `(sessionId, attachmentId)`
/// because the host validates that an attachment belongs to the session asking for it,
/// and the same attachment ID under two sessions is two different lookups.
public actor SessionImageCache {
    private struct Key: Hashable {
        var sessionId: String
        var attachmentId: String
    }

    public let byteLimit: Int
    /// The longest edge of a decoded image. Larger images are downsampled to this.
    public let maximumDimension: Int

    private var images: [Key: DisplayImage] = [:]
    /// Least-recently used first. An array rather than a linked list because a chat view
    /// holds tens of images, not thousands, and the constant factor is smaller.
    private var recency: [Key] = []
    private var byteTotal = 0
    /// In-flight decodes, so two views asking for the same image decode it once.
    private var inFlight: [Key: Task<DisplayImage, any Error>] = [:]

    public init(byteLimit: Int = 64 * 1024 * 1024, maximumDimension: Int = 2048) {
        self.byteLimit = max(1, byteLimit)
        self.maximumDimension = max(1, maximumDimension)
    }

    public var cachedByteCount: Int { byteTotal }
    public var cachedImageCount: Int { images.count }

    /// The image for one attachment, decoding it if it is not already held.
    ///
    /// - Parameter fetch: called at most once per attachment while a decode is in flight
    ///   or cached.
    /// - Throws: whatever `fetch` throws, or ``ImageLoadError`` if the bytes are not a
    ///   decodable image.
    public func image(
        sessionId: String,
        attachmentId: String,
        fetch: @escaping AttachmentFetcher
    ) async throws -> DisplayImage {
        let key = Key(sessionId: sessionId, attachmentId: attachmentId)
        if let cached = images[key] {
            touch(key, image: cached)
            return cached
        }

        // Two views showing the same image should produce one decode, not two. Sharing the
        // task rather than a lock means both callers get the same failure too.
        if let existing = inFlight[key] {
            return try await existing.value
        }

        let maximumDimension = maximumDimension
        let task = Task.detached(priority: .userInitiated) { () throws -> DisplayImage in
            let data = try await fetch(sessionId, attachmentId)
            return try Self.downsample(data, maximumDimension: maximumDimension)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }

        do {
            let image = try await task.value
            store(key, image: image)
            return image
        } catch {
            throw error
        }
    }

    /// Drops everything. For a memory warning, or on leaving a conversation.
    public func removeAll() {
        images.removeAll()
        recency.removeAll()
        byteTotal = 0
    }

    /// Drops one attachment, for a session, or for every session of one host.
    public func remove(sessionId: String, attachmentId: String? = nil) {
        let doomed = images.keys.filter {
            $0.sessionId == sessionId && (attachmentId == nil || $0.attachmentId == attachmentId)
        }
        for key in doomed {
            if let image = images.removeValue(forKey: key) { byteTotal -= image.byteCost }
        }
        recency.removeAll { key in
            key.sessionId == sessionId && (attachmentId == nil || key.attachmentId == attachmentId)
        }
    }

    private func store(_ key: Key, image: DisplayImage) {
        // An image bigger than the whole budget is still worth showing once; holding it
        // while evicting everything else would be worse than not caching it at all.
        guard image.byteCost <= byteLimit else { return }
        if let previous = images[key] { byteTotal -= previous.byteCost }
        images[key] = image
        byteTotal += image.byteCost
        touch(key, image: image)
        evictIfNeeded()
    }

    private func touch(_ key: Key, image: DisplayImage) {
        recency.removeAll { $0 == key }
        recency.append(key)
        _ = image
    }

    private func evictIfNeeded() {
        while byteTotal > byteLimit, let oldest = recency.first {
            recency.removeFirst()
            if let image = images.removeValue(forKey: oldest) { byteTotal -= image.byteCost }
        }
    }

    // MARK: - Decoding

    /// Decodes `data` straight to a bounded thumbnail.
    ///
    /// `CGImageSourceCreateThumbnailAtIndex` with a maximum pixel size is the whole point:
    /// the alternative — `CGImageSourceCreateImageAtIndex` followed by a resize — decodes
    /// the full-size bitmap first, which is the allocation this type exists to avoid.
    static func downsample(_ data: Data, maximumDimension: Int) throws -> DisplayImage {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary),
              CGImageSourceGetCount(source) > 0
        else {
            throw ImageLoadError.notAnImage
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Without this the thumbnail honours the file's EXIF rotation, and a portrait
            // photo renders sideways.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageLoadError.thumbnailFailed
        }
        return DisplayImage(image: thumbnail)
    }
}
