import SwiftUI

/// The four places the tab bar, or the iPad's sidebar, opens.
enum AppTab: String, CaseIterable, Hashable, Identifiable, Sendable {
    case now
    case review
    case boards
    case agents

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .now: .tabNow
        case .review: .tabReview
        case .boards: .tabBoards
        case .agents: .tabAgents
        }
    }

    /// The symbols closest to the design's Heroicons: an inbox tray, a check
    /// badge, columns and a chip.
    var systemImage: String {
        switch self {
        case .now: "tray"
        case .review: "checkmark.seal"
        case .boards: "rectangle.split.3x1"
        case .agents: "cpu"
        }
    }
}
