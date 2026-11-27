import Foundation
import StrideKit

/// A goal's last after_goal attempt as the phone shows it: the exit code and
/// how long the hook ran, and nothing else. The hook's output can hold secrets
/// or internal paths, and no web page shows it, so the phone never does
/// (decision 9 of the design).
struct HookAttempt: Hashable, Sendable {
    let exitCode: Int?
    let duration: Duration?

    init(exitCode: Int?, duration: Duration?) {
        self.exitCode = exitCode
        self.duration = duration
    }

    init(_ attempt: Components.Schemas.MeAfterGoalAttempt) {
        self.init(exitCode: attempt.exitCode, duration: attempt.durationMs.map { .milliseconds(max(0, $0)) })
    }

    func exitCodeText(in locale: Locale) -> String {
        exitCode.map { String($0) } ?? LocalizedStringResource.nowAttemptNotReported.resolved(in: locale)
    }

    func durationText(in locale: Locale) -> String {
        duration?.hookText(in: locale) ?? LocalizedStringResource.nowAttemptNotReported.resolved(in: locale)
    }
}
