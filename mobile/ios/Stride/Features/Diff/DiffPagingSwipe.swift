import SwiftUI

extension View {
    /// Pages between files on a sideways swipe without holding up a scroll.
    /// On iOS 18 and later a SwiftUI `DragGesture` inside a `ScrollView`, even
    /// a simultaneous one, keeps a fast vertical flick from scrolling at all,
    /// so there a UIKit pan pages instead: it begins only when the finger moves
    /// mostly sideways, so a flick goes to the scroll alone. It recognizes
    /// beside nothing else, or the swipe back that iOS 26 takes from anywhere
    /// on a pushed screen also leaves the screen on a page turn (W2797).
    func diffPagingSwipe(next: @escaping () -> Void, previous: @escaping () -> Void) -> some View {
        modifier(DiffPagingSwipe(next: next, previous: previous))
    }
}

private struct DiffPagingSwipe: ViewModifier {
    let next: () -> Void
    let previous: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.gesture(SidewaysPan(next: next, previous: previous))
        } else {
            content.simultaneousGesture(drag)
        }
    }

    /// iOS 17 has no `UIGestureRecognizerRepresentable`; a swipe that is
    /// mostly sideways pages, and a scroll stays a scroll.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 40)
            .onEnded { drag in
                let width = drag.translation.width
                guard DiffSwipe.pages(width: width, height: drag.translation.height) else { return }

                if width < 0 { next() } else { previous() }
            }
    }
}
