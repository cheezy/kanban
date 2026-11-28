import Foundation

/// One result in "Tests and checks": its words and its colour.
struct ReviewResult: Hashable, Sendable {
    let text: String
    let tone: ColorToken

    init(text: String, tone: ColorToken) {
        self.text = text
        self.tone = tone
    }

    init(_ resource: LocalizedStringResource, tone: ColorToken, in locale: Locale) {
        self.init(text: resource.resolved(in: locale), tone: tone)
    }
}
