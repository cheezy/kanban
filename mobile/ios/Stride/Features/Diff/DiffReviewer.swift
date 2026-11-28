import Foundation

/// The review step that raised a note, which names the note's reviewer.
enum DiffReviewer: Hashable, Sendable {
    case testing
    case patterns
    case pitfalls
    case security
    /// A step this build does not name, or none.
    case other

    /// From the issue's category, which the reviewer writes in the singular.
    init(category: String?) {
        switch category?.lowercased() {
        case "testing": self = .testing
        case "pattern", "patterns": self = .patterns
        case "pitfall", "pitfalls": self = .pitfalls
        case "security": self = .security
        default: self = .other
        }
    }

    /// "Testing reviewer", before the note.
    var name: LocalizedStringResource {
        switch self {
        case .testing: .diffNoteTesting
        case .patterns: .diffNotePatterns
        case .pitfalls: .diffNotePitfalls
        case .security: .diffNoteSecurity
        case .other: .diffNoteReviewer
        }
    }
}
