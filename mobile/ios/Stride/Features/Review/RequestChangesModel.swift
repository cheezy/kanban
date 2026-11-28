import Foundation
import Observation

/// The Request changes sheet (design section 6.7): the notes for the agent,
/// typed or dictated, with a chip for each failed verdict that adds its note,
/// sent once. Offline it waits, and says it needs a connection.
@MainActor
@Observable
final class RequestChangesModel: Identifiable {
    /// The most the notes may hold, counted in Unicode scalars, as the server
    /// counts codepoints.
    static let limit = 10_000

    let id = UUID()
    /// The task's identifier and title, for the sheet's heading.
    let identifier: String
    let title: String
    /// Who gets the notes, for the footnote; nil when the review names no agent.
    let agentName: String?
    let findings: [ReviewFinding]
    var text = ""
    private(set) var isSending = false
    /// Why the last send did not go through, shown in the sheet.
    private(set) var problem: RequestChangesProblem?

    @ObservationIgnored private let offline: @MainActor () -> Bool
    @ObservationIgnored private let submit: @MainActor (String) async -> RequestChangesProblem?

    init(
        identifier: String,
        title: String,
        agentName: String?,
        findings: [ReviewFinding],
        isOffline: @escaping @MainActor () -> Bool,
        send: @escaping @MainActor (String) async -> RequestChangesProblem?
    ) {
        self.identifier = identifier
        self.title = title
        self.agentName = agentName
        self.findings = findings
        offline = isOffline
        submit = send
    }

    /// The sheet for the review shown.
    convenience init(
        content: ReviewContent,
        isOffline: @escaping @MainActor () -> Bool,
        send: @escaping @MainActor (String) async -> RequestChangesProblem?
    ) {
        self.init(
            identifier: content.identifier,
            title: content.title,
            agentName: content.agent?.name,
            findings: content.findings,
            isOffline: isOffline,
            send: send
        )
    }

    var isOffline: Bool { offline() }

    /// The notes hold something visible: the server refuses notes that are
    /// only spaces, line breaks, control, format or combining characters.
    var hasText: Bool { notes.unicodeScalars.contains { !Self.isInvisible($0) } }

    var isTooLong: Bool { notes.unicodeScalars.count > Self.limit }

    /// Send needs some visible text, no more than the limit, and a connection,
    /// and waits while the notes are on their way.
    var canSend: Bool { hasText && !isTooLong && !isSending && !isOffline }

    /// A finding's chip adds its note once.
    func canAdd(_ finding: ReviewFinding) -> Bool {
        !isSending && !text.contains(finding.note)
    }

    /// Adds a finding's note to the end of the text, after a blank line when
    /// there is text already.
    func add(_ finding: ReviewFinding) {
        guard canAdd(finding) else { return }

        let written = text.replacing(/\s+$/, with: "")
        text = written.isEmpty ? finding.note : written + "\n\n" + finding.note
    }

    /// "Claude gets this note. The task stays in Review until the changes are
    /// picked up." (decision 10).
    var footnote: LocalizedStringResource {
        agentName.map { .reviewChangesFootnote(agent: $0) } ?? .reviewChangesFootnoteNoAgent
    }

    /// Sends the notes. The review screen closes the sheet when they went
    /// through, or when the review was decided or left the person's queue.
    func send() async {
        guard canSend else { return }

        isSending = true
        defer { isSending = false }
        problem = nil
        problem = await submit(notes)
    }

    /// The text without the blank space around it, which is what is sent.
    var notes: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The server's blank set: `[\s\p{Z}\p{Cc}\p{Cf}\p{M}]`.
    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isWhitespace { return true }

        switch scalar.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator,
             .control, .format,
             .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }
}
