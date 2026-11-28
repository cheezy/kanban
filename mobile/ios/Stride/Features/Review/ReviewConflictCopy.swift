import Foundation

/// What a conflict says, kept apart from the view so tests read it.
enum ReviewConflictCopy {
    static func message(for conflict: ReviewConflictState) -> LocalizedStringResource {
        switch conflict {
        case .resubmitted: .reviewResubmittedHint
        case .alreadyDecided(by: nil, _, _): .reviewDecidedSomeone
        case .alreadyDecided(by: let name?, decision: .approved, _): .reviewDecidedApproved(name: name)
        case .alreadyDecided(by: let name?, decision: .changesRequested, _): .reviewDecidedChanges(name: name)
        case .alreadyDecided(by: let name?, decision: .other, _): .reviewDecidedOther(name: name)
        }
    }

    /// When it was decided, such as "2 minutes ago", as the locale says it.
    static func when(_ date: Date, relativeTo now: Date, in locale: Locale) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
