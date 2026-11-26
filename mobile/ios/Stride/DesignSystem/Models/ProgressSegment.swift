import CoreGraphics

/// A run of tasks in one state on a progress bar.
struct ProgressSegment: Hashable, Sendable {
    enum Kind: CaseIterable, Sendable {
        case done
        case review
        case doing
        case blocked
        case toDo

        /// The fill. Tasks not started are empty, drawn with a border instead.
        var fill: ColorToken {
            switch self {
            case .done: .stDone
            case .review: .stReview
            case .doing: .stDoing
            case .blocked: .stBlocked
            case .toDo: .surfaceSunken
            }
        }

        var hasBorder: Bool { self == .toDo }
    }

    let kind: Kind
    let count: Int

    /// The width of each segment across `width`, `gap` apart, in proportion to
    /// its count. A segment never gets less than `gap`, so a single task stays
    /// visible beside a large one; the others share what is left, so the
    /// segments and gaps fill `width` exactly unless every segment is that small.
    static func widths(of segments: [ProgressSegment], in width: CGFloat, gap: CGFloat) -> [CGFloat] {
        guard segments.contains(where: { $0.count > 0 }) else { return [] }

        let room = max(0, width - gap * CGFloat(segments.count - 1))
        var floored = Set<Int>()

        while true {
            let shared = segments.indices.filter { !floored.contains($0) }
            let count = CGFloat(shared.reduce(0) { $0 + segments[$1].count })
            let left = max(0, room - gap * CGFloat(floored.count))
            let share = { (index: Int) in count > 0 ? left * CGFloat(segments[index].count) / count : 0 }
            let small = shared.filter { share($0) < gap }

            if small.isEmpty || small.count == shared.count {
                return segments.indices.map { floored.contains($0) || small.contains($0) ? gap : share($0) }
            }
            floored.formUnion(small)
        }
    }
}
