import SwiftUI

/// A colour token the shared views draw with, named as its asset is. Each one
/// is the generated colour of `Colors.xcassets`, with a light and a dark value,
/// so the views never write a colour in Swift.
enum ColorToken: String, CaseIterable, Sendable {
    case ink
    case ink2 = "ink-2"
    case ink3 = "ink-3"
    case bg
    case surface
    case surface2 = "surface-2"
    case surfaceSunken = "surface-sunken"
    case line
    case line2 = "line-2"
    case stBacklog = "st-backlog"
    case stBacklogSoft = "st-backlog-soft"
    case stReady = "st-ready"
    case stReadySoft = "st-ready-soft"
    case stDoing = "st-doing"
    case stDoingSoft = "st-doing-soft"
    case stReview = "st-review"
    case stReviewSoft = "st-review-soft"
    case stDone = "st-done"
    case stDoneSoft = "st-done-soft"
    case stBlocked = "st-blocked"
    case stBlockedSoft = "st-blocked-soft"
    case priCritical = "pri-critical"
    case priHigh = "pri-high"
    case priMedium = "pri-medium"
    case priLow = "pri-low"
    case strideOrangeInk = "stride-orange-ink"
    case strideOrangeSoft = "stride-orange-soft"
    case strideVioletInk = "stride-violet-ink"
    case strideVioletSoft = "stride-violet-soft"
    case labelBlue = "label-blue"
    case labelBlueSoft = "label-blue-soft"
    case labelGreen = "label-green"
    case labelGreenSoft = "label-green-soft"
    case labelGray = "label-gray"
    case labelGraySoft = "label-gray-soft"
    case labelOrange = "label-orange"
    case labelTeal = "label-teal"

    /// The colour Xcode generates for the token's asset.
    var resource: ColorResource {
        switch self {
        case .ink: .ink
        case .ink2: .ink2
        case .ink3: .ink3
        case .bg: .bg
        case .surface: .surface
        case .surface2: .surface2
        case .surfaceSunken: .surfaceSunken
        case .line: .line
        case .line2: .line2
        case .stBacklog: .stBacklog
        case .stBacklogSoft: .stBacklogSoft
        case .stReady: .stReady
        case .stReadySoft: .stReadySoft
        case .stDoing: .stDoing
        case .stDoingSoft: .stDoingSoft
        case .stReview: .stReview
        case .stReviewSoft: .stReviewSoft
        case .stDone: .stDone
        case .stDoneSoft: .stDoneSoft
        case .stBlocked: .stBlocked
        case .stBlockedSoft: .stBlockedSoft
        case .priCritical: .priCritical
        case .priHigh: .priHigh
        case .priMedium: .priMedium
        case .priLow: .priLow
        case .strideOrangeInk: .strideOrangeInk
        case .strideOrangeSoft: .strideOrangeSoft
        case .strideVioletInk: .strideVioletInk
        case .strideVioletSoft: .strideVioletSoft
        case .labelBlue: .labelBlue
        case .labelBlueSoft: .labelBlueSoft
        case .labelGreen: .labelGreen
        case .labelGreenSoft: .labelGreenSoft
        case .labelGray: .labelGray
        case .labelGraySoft: .labelGraySoft
        case .labelOrange: .labelOrange
        case .labelTeal: .labelTeal
        }
    }

    var color: Color { Color(resource) }
}
