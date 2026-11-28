import SwiftUI
import UIKit

/// The sideways swipe, as a UIKit pan that never stands in a scroll's way.
@available(iOS 18, *)
struct SidewaysPan: UIGestureRecognizerRepresentable {
    let next: () -> Void
    let previous: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        guard recognizer.state == .ended else { return }

        let translation = recognizer.translation(in: recognizer.view)
        guard DiffSwipe.pages(width: translation.x, height: translation.y) else { return }

        if translation.x < 0 { next() } else { previous() }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// Only a movement that sets out mostly sideways, so an up or down
        /// flick never waits on the pan.
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }

            return DiffSwipe.begins(velocity: pan.velocity(in: pan.view))
        }
    }
}
