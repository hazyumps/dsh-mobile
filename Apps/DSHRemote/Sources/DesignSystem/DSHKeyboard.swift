import SwiftUI
import UIKit

/// Putting the keyboard away, from anywhere.
///
/// SwiftUI has no equivalent of "resign whatever is focused": `@FocusState` is view-local, and
/// this app focuses text in several places that do not know about each other — the composer, the
/// conversation's, the drawer's filter, the new-session field. When a screen opens over one of
/// them the field keeps first responder, so the keyboard stays up and covers the thing that was
/// just opened.
///
/// This is the one place that gets to reach for UIKit, and it is deliberately the whole API: a
/// caller does not need to know which field is focused to put it away.
enum DSHKeyboard {
    static func dismiss() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}

extension View {
    /// Puts the keyboard away when the content is dragged downward.
    ///
    /// `scrollDismissesKeyboard` needs something to scroll, and the drawer holds three rows on a
    /// phone — there is no scroll to start, so there was no gesture that could push the keyboard
    /// off. This reacts to the drag itself, which is the motion a thumb already makes.
    func dismissesKeyboardOnDownwardDrag() -> some View {
        simultaneousGesture(
            DragGesture(minimumDistance: 8).onChanged { value in
                if value.translation.height > 24 {
                    DSHKeyboard.dismiss()
                }
            }
        )
    }
}
