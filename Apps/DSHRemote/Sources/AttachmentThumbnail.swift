import DSHRemoteKit
import SwiftUI

/// An image attachment, drawn in the transcript.
///
/// The pixels come from the host — `session/attachment` — rather than from anything this
/// device kept, because the device may have been reinstalled since the message was sent and
/// the host is the only copy that is certain to exist.
struct AttachmentThumbnail: View {
    let attachment: MessageAttachment
    let load: () async -> DisplayImage?

    @State private var image: DisplayImage?

    var body: some View {
        VStack(alignment: .leading, spacing: DSHMetrics.spaceSmall) {
            Group {
                if let image {
                    Image(decorative: image.image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 240, maxHeight: 240)
                        .clipShape(RoundedRectangle(cornerRadius: DSHMetrics.spaceCard, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DSHMetrics.spaceCard, style: .continuous)
                                .strokeBorder(DSHPalette.cardEdge, lineWidth: 1)
                        )
                } else {
                    // A placeholder of the attachment's own aspect ratio, so the transcript does
                    // not jump when the image arrives.
                    RoundedRectangle(cornerRadius: DSHMetrics.spaceCard, style: .continuous)
                        .fill(DSHPalette.elevatedSurface)
                        .overlay(ProgressView().controlSize(.small))
                        .frame(width: placeholderWidth, height: placeholderHeight)
                        .accessibilityLabel("Loading \(attachment.name)")
                }
            }
            Label(attachment.name, systemImage: "photo")
                .font(.dshMetadata)
                .foregroundStyle(DSHPalette.secondaryText)
                .lineLimit(1)
        }
        .task(id: attachment.id) {
            // A failure leaves the placeholder rather than a broken image: the name below says
            // what it was, and a retry costs another request for something already wrong.
            image = await load()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(attachment.name)
    }

    /// The host's own dimensions, bounded, so the placeholder matches the picture.
    private var placeholderWidth: CGFloat {
        guard let width = attachment.pixelWidth, let height = attachment.pixelHeight, width > 0, height > 0 else {
            return 160
        }
        let longest = CGFloat(max(width, height))
        return max(80, 160 * CGFloat(width) / longest)
    }

    private var placeholderHeight: CGFloat {
        guard let width = attachment.pixelWidth, let height = attachment.pixelHeight, width > 0, height > 0 else {
            return 120
        }
        let longest = CGFloat(max(width, height))
        return max(60, 160 * CGFloat(height) / longest)
    }
}
