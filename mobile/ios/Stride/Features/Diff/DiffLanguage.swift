import Foundation

/// The language the server highlighted a file as.
enum DiffLanguage: Hashable, Sendable {
    case elixir
    case heex
    case erlang
    /// A language with no highlighter, shown as plain text.
    case plain
    /// A language this build does not know, shown as the server names it.
    case other(String)

    init(apiValue: String?) {
        switch apiValue {
        case "elixir": self = .elixir
        case "heex": self = .heex
        case "erlang": self = .erlang
        case "plain", nil, "": self = .plain
        case let other?: self = .other(other)
        }
    }

    /// The language's name, as the header shows it.
    func name(in locale: Locale) -> String {
        switch self {
        case .elixir: LocalizedStringResource.diffLanguageElixir.resolved(in: locale)
        case .heex: LocalizedStringResource.diffLanguageHeex.resolved(in: locale)
        case .erlang: LocalizedStringResource.diffLanguageErlang.resolved(in: locale)
        case .plain: LocalizedStringResource.diffLanguagePlain.resolved(in: locale)
        case .other(let name): name
        }
    }
}
