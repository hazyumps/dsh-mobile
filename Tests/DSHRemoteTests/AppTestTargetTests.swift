import CoreGraphics
import SwiftUI
import Testing
@testable import DSHRemote

/// Proves the app test target's plumbing (#74): the bundle is hosted in the app, `@testable
/// import DSHRemote` reaches an internal view, and `ImageRenderer` draws it in the test process.
/// It is green from the start, so a red app suite always means a real test failed, never that the
/// target could not render at all.
///
/// Not a planner test: written with the target, outside any `Tests:` commit. The render tests for
/// view-level bugs sit beside it (`MessageRowRenderTests`).
@MainActor
@Suite("App test target")
struct AppTestTargetTests {
    @Test("the hosted bundle renders an app view to pixels")
    func rendersAnAppView() throws {
        let renderer = ImageRenderer(content: MessageBody(text: "The step ended."))
        renderer.proposedSize = ProposedViewSize(width: 320, height: nil)
        renderer.scale = 3
        let image = try #require(renderer.cgImage, "ImageRenderer produced no image in the test host")

        #expect(image.width > 0 && image.height > 0)
        #expect(Self.inkedPixels(in: image) > 0, "the rendered text left no ink: the view drew nothing")
    }

    /// Pixels with any alpha. The image is redrawn into a known RGBA layout rather than read in
    /// whatever format the renderer chose.
    private static func inkedPixels(in image: CGImage) -> Int {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        return stride(from: 3, to: pixels.count, by: 4).reduce(0) { $0 + (pixels[$1] > 0 ? 1 : 0) }
    }
}
