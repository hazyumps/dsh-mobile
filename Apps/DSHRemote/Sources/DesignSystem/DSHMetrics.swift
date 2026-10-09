import SwiftUI

/// Spacing, radii, and the type scale from UX spec "Visual system" → Type and
/// spacing.
///
/// The scale names the spec's *roles*, not point sizes. The spec gives
/// approximate sizes ("Card title approximately 16 pt") but also requires
/// Dynamic Type styles instead of fixed-size text boxes, and a fixed size would
/// stop growing at accessibility sizes — where the spec additionally requires
/// rows to stack and card buttons to become full-width. Each style below is the
/// Dynamic Type style whose default size is the spec's starting value.
enum DSHMetrics {
    /// Default page margin.
    static let pageMargin: CGFloat = 16
    /// The base rhythm; everything else is a multiple or one of the two
    /// in-card values the spec allows.
    static let space: CGFloat = 8
    static let spaceSmall: CGFloat = 4
    static let spaceCard: CGFloat = 12
    static let spaceGroup: CGFloat = 24
    /// Cards approximately 16 pt.
    static let cardCornerRadius: CGFloat = 16
    /// The composer approximately 20 pt.
    static let composerCornerRadius: CGFloat = 20
    /// Small chips: 8–12 pt. Status chips use a capsule instead.
    static let chipCornerRadius: CGFloat = 10
    /// The spec's floor for any control, whatever its symbol's visual size.
    static let minimumHitTarget: CGFloat = 44
}

extension Font {
    /// "Into the Unknown" heading: system title, approximately 26–28 pt, medium.
    static let dshHomeTitle: Font = .largeTitle.weight(.medium)
    /// Session title in the conversation toolbar: system headline, ~17 pt.
    static let dshConversationTitle: Font = .headline
    /// Message text: system body, ~17 pt.
    static let dshMessageBody: Font = .body
    /// Card title: ~16 pt, medium.
    static let dshCardTitle: Font = .callout.weight(.medium)
    /// Supporting copy: ~14 pt. `.subheadline` is the closest Dynamic Type
    /// style; 15 pt rather than 14 pt was preferred to dropping to `.footnote`
    /// (13 pt), because supporting lines carry real information.
    static let dshSupporting: Font = .subheadline
    /// Timestamps and status: ~12–13 pt.
    static let dshMetadata: Font = .footnote
    /// Code and paths. Horizontal scrolling stays with the container so a
    /// monospaced block can be wider than the screen.
    static let dshCode: Font = .system(.callout, design: .monospaced)
}

/// At these sizes the spec's requirements change shape: "allow selector rows to
/// stack, card buttons to become full-width vertical controls, and titles to
/// wrap". Components ask this instead of each inventing its own cut-off.
extension DynamicTypeSize {
    var dshNeedsStackedControls: Bool { self >= .accessibility3 }
}
