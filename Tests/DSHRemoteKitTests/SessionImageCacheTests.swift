import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import DSHRemoteKit

// SPEC §9 asks for three things of the attachment-image path: decode off the main actor,
// downsample for display, and bound the caches. The tests below are about the second and
// third, because those are the ones whose absence shows up as a crash rather than as a
// wrong pixel — a chat view that decodes camera images at full size runs out of memory.

@Suite("Session image cache")
struct SessionImageCacheTests {
    /// Builds a real PNG of the given size, so the decode path is exercised for real
    /// rather than against a stub that cannot fail the way ImageIO can.
    private func png(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
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

    private func fetcher(
        _ data: Data,
        counting counter: FetchCounter
    ) -> AttachmentFetcher {
        { sessionId, attachmentId in
            await counter.record(sessionId: sessionId, attachmentId: attachmentId)
            return data
        }
    }

    private actor FetchCounter {
        private(set) var calls: [(sessionId: String, attachmentId: String)] = []
        func record(sessionId: String, attachmentId: String) {
            calls.append((sessionId, attachmentId))
        }
        var count: Int { calls.count }
    }

    // MARK: - Downsampling

    @Test("a large image is decoded down to the maximum dimension")
    func largeImageIsDownsampled() throws {
        // 4000x3000 is an ordinary phone photo. At four bytes a pixel the full bitmap is
        // 48 MB; the point of the thumbnail path is that this is never allocated.
        let data = try png(width: 4000, height: 3000)
        let image = try SessionImageCache.downsample(data, maximumDimension: 2048)

        #expect(max(image.pixelWidth, image.pixelHeight) == 2048)
        // Aspect ratio is preserved: 4000x3000 is 4:3, so the short edge is 1536.
        #expect(image.pixelHeight == 1536)
        // The budget is charged for the decoded buffer, not the encoded file.
        #expect(image.byteCost == 2048 * 1536 * 4)
        #expect(image.byteCost > data.count)
    }

    @Test("an image already smaller than the limit is not enlarged")
    func smallImageIsNotUpscaled() throws {
        let data = try png(width: 64, height: 32)
        let image = try SessionImageCache.downsample(data, maximumDimension: 2048)

        #expect(image.pixelWidth == 64)
        #expect(image.pixelHeight == 32)
    }

    @Test("bytes that are not an image are refused rather than guessed at")
    func nonImageIsRefused() {
        #expect(throws: ImageLoadError.notAnImage) {
            try SessionImageCache.downsample(Data("not a png".utf8), maximumDimension: 512)
        }
        #expect(throws: ImageLoadError.notAnImage) {
            try SessionImageCache.downsample(Data(), maximumDimension: 512)
        }
    }

    // MARK: - Caching

    @Test("a second request for the same attachment does not fetch again")
    func repeatRequestUsesTheCache() async throws {
        let data = try png(width: 800, height: 600)
        let counter = FetchCounter()
        let cache = SessionImageCache()
        let fetch = fetcher(data, counting: counter)

        let first = try await cache.image(sessionId: "s1", attachmentId: "a1", fetch: fetch)
        let second = try await cache.image(sessionId: "s1", attachmentId: "a1", fetch: fetch)

        #expect(await counter.count == 1)
        #expect(first.pixelWidth == second.pixelWidth)
        #expect(await cache.cachedImageCount == 1)
    }

    @Test("the same attachment id under two sessions is two lookups")
    func attachmentsAreScopedToTheirSession() async throws {
        // The host validates that an attachment belongs to the session asking for it, so
        // the cache must not answer a cross-session request from a same-named entry.
        let data = try png(width: 100, height: 100)
        let counter = FetchCounter()
        let cache = SessionImageCache()
        let fetch = fetcher(data, counting: counter)

        _ = try await cache.image(sessionId: "s1", attachmentId: "a1", fetch: fetch)
        _ = try await cache.image(sessionId: "s2", attachmentId: "a1", fetch: fetch)

        #expect(await counter.count == 2)
        #expect(await cache.cachedImageCount == 2)
    }

    @Test("concurrent requests for one attachment decode it once")
    func concurrentRequestsShareOneDecode() async throws {
        let data = try png(width: 900, height: 900)
        let counter = FetchCounter()
        let cache = SessionImageCache()
        let fetch = fetcher(data, counting: counter)

        async let a = cache.image(sessionId: "s1", attachmentId: "a1", fetch: fetch)
        async let b = cache.image(sessionId: "s1", attachmentId: "a1", fetch: fetch)
        async let c = cache.image(sessionId: "s1", attachmentId: "a1", fetch: fetch)
        _ = try await (a, b, c)

        // Three views, one download and one decode.
        #expect(await counter.count == 1)
    }

    @Test("the cache evicts least-recently-used entries to stay under its budget")
    func evictionKeepsTheBudget() async throws {
        // Each 512x512 image costs 1 MiB decoded. A 2 MiB budget therefore holds two.
        let data = try png(width: 512, height: 512)
        let counter = FetchCounter()
        let cache = SessionImageCache(byteLimit: 2 * 1024 * 1024, maximumDimension: 512)
        let fetch = fetcher(data, counting: counter)

        _ = try await cache.image(sessionId: "s1", attachmentId: "a1", fetch: fetch)
        _ = try await cache.image(sessionId: "s1", attachmentId: "a2", fetch: fetch)
        _ = try await cache.image(sessionId: "s1", attachmentId: "a3", fetch: fetch)

        #expect(await cache.cachedImageCount == 2)
        #expect(await cache.cachedByteCount <= 2 * 1024 * 1024)
    }

    @Test("a recently used entry survives an eviction that would otherwise take it")
    func recencyProtectsAUsedEntry() async throws {
        let data = try png(width: 512, height: 512)
        let counter = FetchCounter()
        let cache = SessionImageCache(byteLimit: 2 * 1024 * 1024, maximumDimension: 512)
        let fetch = fetcher(data, counting: counter)

        _ = try await cache.image(sessionId: "s1", attachmentId: "a1", fetch: fetch)
        _ = try await cache.image(sessionId: "s1", attachmentId: "a2", fetch: fetch)
        // Touch a1 so a3's arrival evicts a2 rather than a1.
        _ = try await cache.image(sessionId: "s1", attachmentId: "a1", fetch: fetch)
        _ = try await cache.image(sessionId: "s1", attachmentId: "a3", fetch: fetch)

        // Fetch again to prove which survived, and that the fetch count stays put.
        let before = await counter.count
        _ = try await cache.image(sessionId: "s1", attachmentId: "a1", fetch: fetch)
        _ = try await cache.image(sessionId: "s1", attachmentId: "a3", fetch: fetch)
        #expect(await counter.count == before)

        // a2 was the least recently used, so asking for it fetches again.
        _ = try await cache.image(sessionId: "s1", attachmentId: "a2", fetch: fetch)
        #expect(await counter.count == before + 1)
    }

    @Test("an image larger than the whole budget is shown but not retained")
    func oversizedImageIsNotRetained() async throws {
        // Evicting everything to hold one image would be worse than re-decoding it.
        let data = try png(width: 512, height: 512)
        let counter = FetchCounter()
        let cache = SessionImageCache(byteLimit: 1024, maximumDimension: 512)
        let fetch = fetcher(data, counting: counter)

        let image = try await cache.image(sessionId: "s1", attachmentId: "a1", fetch: fetch)
        #expect(image.pixelWidth == 512)
        #expect(await cache.cachedImageCount == 0)

        _ = try await cache.image(sessionId: "s1", attachmentId: "a1", fetch: fetch)
        #expect(await counter.count == 2)
    }

    @Test("clearing drops everything, and removing one session leaves the others")
    func removalIsScoped() async throws {
        let data = try png(width: 100, height: 100)
        let counter = FetchCounter()
        let cache = SessionImageCache()
        let fetch = fetcher(data, counting: counter)

        _ = try await cache.image(sessionId: "s1", attachmentId: "a1", fetch: fetch)
        _ = try await cache.image(sessionId: "s2", attachmentId: "a1", fetch: fetch)
        // A different image per session, fetched once each.
        await cache.remove(sessionId: "s1")
        #expect(await cache.cachedImageCount == 1)
        #expect(await cache.cachedByteCount > 0)

        await cache.removeAll()
        #expect(await cache.cachedImageCount == 0)
        #expect(await cache.cachedByteCount == 0)
    }
}
