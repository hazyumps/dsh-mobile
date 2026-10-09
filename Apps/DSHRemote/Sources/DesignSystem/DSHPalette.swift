import SwiftUI

/// The semantic colors from UX spec "Visual system" → Identity and color.
///
/// Every value is a dynamic `UIColor`, so a view asks for "the card surface"
/// and gets whatever the current appearance means by that. Dark is the primary
/// reference (UX spec: "Dark mode is the primary visual reference"), and Light
/// keeps the same *hierarchy* — canvas furthest back, navigation and cards in
/// front of it, elevated above the card — rather than inverting the dark hex
/// values. That keeps System, Light, and Dark selectable, since the appearance
/// is still whatever the environment resolves to.
///
/// The spec calls its hex values "implementation starting values" and says to
/// validate the chosen colors rather than assume them. Every pair below was
/// checked against WCAG relative-luminance contrast (body text target 4.5:1,
/// essential boundaries 3:1, per UX spec "Accessibility and layout acceptance").
/// Adjustments from the starting values, with reasons:
///
/// * Dark `primaryAction` `#526B96` is kept as a *fill*, but at that value it
///   only reaches 3.4:1 against the canvas — too low for a link or a label.
///   `primaryActionText` (`#8AA6D4`, 7.4:1) is the same blue for text and
///   symbols, so blue can still identify actions without a low-contrast label.
/// * The light accents are the dark ones darkened. `#41C86A`, `#E8A23A`, and
///   `#F07878` all fall under 2:1 on white, which is unreadable in light mode;
///   the values here keep the same roles at 5.4:1 or better on every light
///   surface.
/// * Light `secondaryText` is `#4E4E58`, not the dark `#B0B2BB` inverted.
///   The dark value is 8.7:1 on the dark canvas; this holds 7.4:1 on the light
///   canvas, so supporting copy stays readable while still reading as
///   secondary. UX spec "Type and spacing": "Avoid low-contrast gray for
///   actionable information."
///
/// Not handled here: increased-contrast variants, and any accent the user
/// configures on the host. Both need a real appearance to compare against.
enum DSHPalette {
    /// Main page and conversation background. `#141416` / `#F2F2F5`.
    static let canvas = dynamic(light: 0xF2F2F5, dark: 0x141416)

    /// Drawer and secondary panels. `#1D1D1F` / `#FAFAFC`.
    static let navigationSurface = dynamic(light: 0xFAFAFC, dark: 0x1D1D1F)

    /// Session, tool, and decision cards, and text entry. `#2A2A2D` / `#FFFFFF`.
    static let card = dynamic(light: 0xFFFFFF, dark: 0x2A2A2D)

    /// A selected row or an expanded card area. `#323237` / `#E7E7ED`.
    static let elevatedSurface = dynamic(light: 0xE7E7ED, dark: 0x323237)

    /// Titles, messages, primary labels. `#F5F5F7` / `#16161A`.
    static let primaryText = dynamic(light: 0x16161A, dark: 0xF5F5F7)

    /// Workspace, timestamps, supporting copy. `#B0B2BB` / `#4E4E58`.
    static let secondaryText = dynamic(light: 0x4E4E58, dark: 0xB0B2BB)

    /// Subtle separation and card edges. `#3B3D43` / `#C6C6D0`.
    static let divider = dynamic(light: 0xC6C6D0, dark: 0x3B3D43)

    /// Send, selected choices, primary buttons. `#526B96` / `#4A638F`.
    ///
    /// Use with ``onPrimaryAction`` as the label color: white reaches 5.4:1 on
    /// the dark fill and 6.1:1 on the light one. The light fill is deeper than
    /// the dark one so the same button carries the same weight on white.
    static let primaryAction = dynamic(light: 0x4A638F, dark: 0x526B96)

    /// The only label color validated on ``primaryAction``.
    static let onPrimaryAction = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF)

    /// The action blue for text and symbols, where the fill is too dark to
    /// clear 4.5:1. See the note on the type.
    static let primaryActionText = dynamic(light: 0x33507D, dark: 0x8AA6D4)

    /// Confirmed connected or running, always with a text label.
    /// `#41C86A` / `#0B6B34`.
    static let success = dynamic(light: 0x0B6B34, dark: 0x41C86A)

    /// Waiting for input, or recovering. `#E8A23A` / `#7A500A`.
    static let attention = dynamic(light: 0x7A500A, dark: 0xE8A23A)

    /// Actionable failure, used sparingly. `#F07878` / `#A32219`.
    static let error = dynamic(light: 0xA32219, dark: 0xF07878)

    /// A hairline around a card. UX spec: "Use a thin edge to distinguish cards
    /// rather than large shadows, glowing borders, or gradients."
    static let cardEdge = divider

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
