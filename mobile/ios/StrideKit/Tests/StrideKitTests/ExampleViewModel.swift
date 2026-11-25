import Observation

@testable import StrideKit

/// Built the way the app builds its view models, to show one runs on fixtures.
@MainActor
@Observable
final class ExampleViewModel {
    private(set) var titles: [String] = []
    private let api: any StrideAPI

    init(api: any StrideAPI) {
        self.api = api
    }

    func load() async throws {
        titles = try await api.listMyDecisions().ok.body.json.data.items.compactMap(\.summary.title)
    }
}
