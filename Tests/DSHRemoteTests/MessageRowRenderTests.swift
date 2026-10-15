import CoreGraphics
import DSHRemoteKit
import SwiftUI
import Testing
@testable import DSHRemote

/// #74: assistant prose lost the left edge of the first glyph of its first and last lines.
///
/// `MessageRow` clipped both roles to a `cardCornerRadius` rounded rectangle, but only the user
/// bubble is padded, so the invisible corner cut into whatever glyph sat in the corner of an
/// assistant reply: "The" read as "ſhe" and "no" as "ɿo". The clip is a view modifier, so these
/// tests render the real view: a kit-level test would still pass with the `.clipShape` back on.
///
/// Each corner test compares the row with the same text drawn by `MessageBody` alone, which has
/// the same origin and height as the row's content and is never clipped. Any ink the row has lost
/// in a corner square is ink the clip took.
@MainActor
@Suite("MessageRow rendering (#74)")
struct MessageRowRenderTests {
    /// Two paragraphs: a straight-edged "T" opens the first line in the top-left corner, and the
    /// stem of an "n" opens the last line in the bottom-left corner.
    ///
    /// Both lines are far wider than `2 × cardCornerRadius`, and they have to be. SwiftUI shrinks a
    /// rounded rectangle's corner radius to half its shorter side, and `MessageRow`'s content is
    /// only as wide as its text. The first sample planned, `"T\n\nn"`, made a box about 10pt wide
    /// and a 5pt corner that cut nothing: a probe measured zero pixels lost with the clip in
    /// place, so the test would have passed against the bug.
    static let sample = "The step ended.\n\nno more frames."
    static let width: CGFloat = 320
    static let scale: CGFloat = 3
    static let corner = DSHMetrics.cardCornerRadius

    @Test("AC1: assistant prose keeps its top-left corner")
    func assistantProseKeepsItsTopLeftCorner() throws {
        try expectAssistantRowKeepsInk(in: .topLeft)
    }

    @Test("AC2: assistant prose keeps its bottom-left corner")
    func assistantProseKeepsItsBottomLeftCorner() throws {
        try expectAssistantRowKeepsInk(in: .bottomLeft)
    }

    /// The scope guard: green before the fix and after it. A fix that dropped the rounding
    /// along with the clip would fill the corner pixel; one that dropped the fill would leave the
    /// top edge empty.
    @Test("AC3: a user bubble keeps its rounded, filled corners")
    func userBubbleKeepsItsRoundedCorners() throws {
        let row = MessageRow(message: Self.message(.user, "Why did the feed stop mid-turn?"))
        let image = try Bitmap(try render(row))
        let bubble = try #require(image.inkBounds, "the user row drew nothing at all")

        let cornerAlpha = image.alpha(x: bubble.minX, y: bubble.minY)
        #expect(
            cornerAlpha == 0,
            "the user bubble's top-left corner pixel is filled (alpha \(cornerAlpha)): the bubble lost its rounded corner"
        )

        let edgeX = bubble.minX + Int(Self.corner * Self.scale)
        let edgeY = bubble.minY + Int(Self.scale)
        let edgeAlpha = image.alpha(x: edgeX, y: edgeY)
        #expect(
            edgeAlpha > 0,
            "the user bubble is empty \(Int(Self.corner))pt along its top edge (alpha \(edgeAlpha)): the bubble lost its fill"
        )
    }

    // MARK: - Helpers

    enum Corner: String {
        case topLeft = "top-left"
        case bottomLeft = "bottom-left"
    }

    /// The assistant row has at least as much ink in `corner`'s square as the unclipped text.
    private func expectAssistantRowKeepsInk(in corner: Corner) throws {
        let reference = try Bitmap(try render(MessageBody(text: Self.sample)))
        let row = try Bitmap(try render(MessageRow(message: Self.message(.assistant, Self.sample))))

        let referenceInk = ink(in: corner, of: reference)
        try #require(
            referenceInk > 0,
            "the sample no longer puts a glyph in the \(corner.rawValue) corner, so this test checks nothing there"
        )
        let referenceWidth = CGFloat(reference.width) / Self.scale
        try #require(
            referenceWidth > 2 * Self.corner,
            "the sample is too narrow to be clipped: at \(referenceWidth)pt wide, SwiftUI shrinks a \(Int(Self.corner))pt corner to half the width, and a clip there cuts nothing"
        )
        // The row's content is the reference: same origin, same height. If that stops being
        // true, comparing the two corner squares means nothing.
        try #require(
            row.height == reference.height,
            "the assistant row is \(row.height) px tall but its text alone is \(reference.height) px: the corner squares no longer line up"
        )

        let rowInk = ink(in: corner, of: row)
        #expect(
            rowInk >= referenceInk,
            "the assistant row lost \(referenceInk - rowInk) px of ink in its \(corner.rawValue) \(Int(Self.corner))pt corner (row \(rowInk), unclipped \(referenceInk))"
        )
    }

    /// Draws `view` the way the transcript does: dark appearance, phone width, 3× pixels.
    private func render(_ view: some View, width: CGFloat = MessageRowRenderTests.width) throws -> CGImage {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        renderer.scale = Self.scale
        return try #require(renderer.cgImage, "ImageRenderer produced no image")
    }

    /// Pixels with any alpha in `corner`'s `cardCornerRadius` square.
    private func ink(in corner: Corner, of image: Bitmap) -> Int {
        let side = Self.corner
        let rect: CGRect
        switch corner {
        case .topLeft:
            rect = CGRect(x: 0, y: 0, width: side, height: side)
        case .bottomLeft:
            let height = CGFloat(image.height) / Self.scale
            rect = CGRect(x: 0, y: height - side, width: side, height: side)
        }
        return ink(in: rect, of: image)
    }

    /// Pixels with any alpha in `rect`, given in points from the image's top-left corner.
    private func ink(in rect: CGRect, of image: Bitmap) -> Int {
        let pixels = CGRect(
            x: rect.minX * Self.scale, y: rect.minY * Self.scale,
            width: rect.width * Self.scale, height: rect.height * Self.scale
        ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !pixels.isNull, !pixels.isEmpty else { return 0 }
        var count = 0
        for y in Int(pixels.minY)..<Int(pixels.maxY) {
            for x in Int(pixels.minX)..<Int(pixels.maxX) where image.alpha(x: x, y: y) > 0 {
                count += 1
            }
        }
        return count
    }

    private static func message(_ role: ConversationMessage.Role, _ text: String) -> ConversationMessage {
        ConversationMessage(id: "seq:1", role: role, text: text, isProvisional: false, reasoning: nil)
    }
}

/// A rendered image redrawn into a known RGBA layout, so its pixels can be read whatever format
/// the renderer chose. Row 0 is the top of the image.
private struct Bitmap {
    let width: Int
    let height: Int
    private let rgba: [UInt8]

    init(_ image: CGImage) throws {
        width = image.width
        height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        try #require(drawn, "could not redraw the rendered image into an RGBA bitmap")
        rgba = pixels
    }

    func alpha(x: Int, y: Int) -> UInt8 {
        guard (0..<width).contains(x), (0..<height).contains(y) else { return 0 }
        return rgba[(y * width + x) * 4 + 3]
    }

    /// The smallest pixel rectangle holding every pixel with any alpha; nil for a blank image.
    var inkBounds: (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where rgba[(y * width + x) * 4 + 3] > 0 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        return maxX < 0 ? nil : (minX, minY, maxX, maxY)
    }
}
