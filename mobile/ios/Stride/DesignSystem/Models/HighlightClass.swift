/// The kind of token a server-highlighted span is, by the class the server
/// sends. The tokens have no syntax colours, so each kind takes a status or
/// label colour that keeps 4.5:1 on a diff line's background in both themes.
enum HighlightClass: String, CaseIterable, Sendable {
    case keyword
    case function
    case string
    case atom
    case comment
    case module
    case number
    case `operator`
    case plain

    /// From the server's class name; anything unknown is plain text.
    init(apiValue: String?) {
        self = apiValue.flatMap(Self.init(rawValue:)) ?? .plain
    }

    /// The span's colour, or nil to take the line's own.
    var ink: ColorToken? {
        switch self {
        case .keyword: .stReview
        case .function: .stReady
        case .string: .stDone
        case .atom: .strideOrangeInk
        case .comment: .ink3
        case .module: .labelTeal
        case .number: .labelOrange
        case .operator: .ink2
        case .plain: nil
        }
    }
}
