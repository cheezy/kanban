import Foundation

/// A sheet the shell's corner buttons open.
enum ShellSheet: String, Identifiable, Sendable {
    case newTask
    case settings

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .newTask: .shellNewTask
        case .settings: .shellSettings
        }
    }
}
