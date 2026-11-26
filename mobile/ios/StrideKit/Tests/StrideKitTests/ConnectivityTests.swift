import Foundation
import os
import Testing

@testable import StrideKit

@Suite(.timeLimit(.minutes(1)))
struct ConnectivityTests {
    @Test("reports the state now, then each change once")
    func changes() async throws {
        let reporter = OSAllocatedUnfairLock<(@Sendable (Bool) -> Void)?>(initialState: nil)
        let connectivity = Connectivity { report in
            reporter.withLock { $0 = report }
            report(true)
            return {}
        }
        let report = { @Sendable (isOnline: Bool) in reporter.withLock { $0 }?(isOnline) }
        var states: [ConnectivityState] = []

        for await state in connectivity.states() {
            states.append(state)
            switch states.count {
            case 1:
                // The same state again is not a change. The stream keeps only
                // the newest state, so the change comes later: were the
                // repeat kept, it would be read before the change arrives.
                report(true)
                Task {
                    try? await Task.sleep(for: .milliseconds(200))
                    report(false)
                }
            case 2:
                report(false)
                report(true)
            default:
                break
            }
            if states.count == 3 { break }
        }

        #expect(states == [.online, .offline, .online])
    }

    @Test("stops the path source when nobody listens")
    func stops() async {
        let stopped = Gate()
        let connectivity = Connectivity { report in
            report(false)
            return { Task { await stopped.open() } }
        }

        for await state in connectivity.states() {
            #expect(state == .offline)
            break
        }

        await stopped.wait()
        #expect(await stopped.isOpen)
    }

    @Test("the system monitor reports a state")
    func system() async {
        var first: ConnectivityState?

        for await state in Connectivity.system.states() {
            first = state
            break
        }

        #expect(first != nil)
    }
}
