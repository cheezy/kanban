import Foundation
import StrideKit

extension AppUpdateState {
    /// Starts a debug build on the Update required screen, so the screen can be
    /// seen and tested without a server that refuses this version.
    static let updateRequiredArgument = "-StrideUpdateRequired"

    static func atLaunch(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> AppUpdateState {
        #if DEBUG
        if arguments.contains(updateRequiredArgument) {
            return AppUpdateState(storeURL: URL(string: "https://apps.apple.com/app/stride"))
        }
        #endif

        return AppUpdateState()
    }
}
