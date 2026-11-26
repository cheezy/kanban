import Foundation

/// What a review decided about one section.
enum VerdictState: CaseIterable, Sendable {
    case passed
    case failed
    case notAssessed

    /// From the API's `status`: `passed` or `failed`, and anything else,
    /// `not_assessed` and null among them, is not assessed.
    init(apiValue: String?) {
        switch apiValue {
        case "passed": self = .passed
        case "failed": self = .failed
        default: self = .notAssessed
        }
    }

    var ink: ColorToken {
        switch self {
        case .passed: .stDone
        case .failed: .stBlocked
        case .notAssessed: .ink3
        }
    }

    var fill: ColorToken {
        switch self {
        case .passed: .stDoneSoft
        case .failed: .stBlockedSoft
        case .notAssessed: .surface2
        }
    }

    /// The symbol shown instead of the dot when the reader asks for shapes as
    /// well as colours.
    var symbol: String {
        switch self {
        case .passed: "checkmark"
        case .failed: "xmark"
        case .notAssessed: "minus"
        }
    }
}
