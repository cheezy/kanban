import CoreGraphics
import Testing
@testable import Stride

@Suite("When a swipe on the diff pages")
struct DiffSwipeTests {
    @Test(
        "a movement far enough across, and mostly across, pages",
        arguments: [CGSize(width: -81, height: 0), CGSize(width: 120, height: 59), CGSize(width: -200, height: -99)]
    )
    func pages(movement: CGSize) {
        #expect(DiffSwipe.pages(width: movement.width, height: movement.height))
    }

    @Test(
        "a short or a mostly vertical movement does not page",
        arguments: [CGSize(width: -80, height: 0), CGSize(width: 40, height: 0), CGSize(width: 120, height: 60), CGSize(width: 0, height: -400)]
    )
    func doesNotPage(movement: CGSize) {
        #expect(DiffSwipe.pages(width: movement.width, height: movement.height) == false)
    }

    @Test("a pan begins only when it sets out mostly sideways")
    func begins() {
        #expect(DiffSwipe.begins(velocity: CGPoint(x: -900, y: 100)))
        #expect(DiffSwipe.begins(velocity: CGPoint(x: 500, y: -249)))
        #expect(DiffSwipe.begins(velocity: CGPoint(x: 500, y: 250)) == false)
        #expect(DiffSwipe.begins(velocity: CGPoint(x: 100, y: -3000)) == false)
        #expect(DiffSwipe.begins(velocity: .zero) == false)
    }
}
