import Foundation

/// One section's verdict, as a pill shows it.
struct Verdict: Hashable, Sendable {
    let section: VerdictSection
    let state: VerdictState

    /// The verdict in words, such as "Patterns failed", for VoiceOver.
    func reading(in locale: Locale) -> String {
        let name = section.name.resolved(in: locale)
        let sentence: LocalizedStringResource =
            switch state {
            case .passed: .verdictPassed(section: name)
            case .failed: .verdictFailed(section: name)
            case .notAssessed: .verdictNotAssessed(section: name)
            }

        return sentence.resolved(in: locale)
    }
}
