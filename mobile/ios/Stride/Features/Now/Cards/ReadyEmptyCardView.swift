import SwiftUI

/// A board whose Ready column is empty: a row that opens the board, where the
/// person picks work from the backlog. Offline the row waits, and says it
/// needs a connection, as the other cards' buttons do.
struct ReadyEmptyCardView: View {
    @Environment(\.locale) private var locale

    @ScaledMetric(relativeTo: .caption2) private var dotSide = 7

    let card: NowCard
    /// Nil when the server offers no way to open the board.
    let open: (() -> Void)?
    let isOffline: Bool

    var body: some View {
        if let open {
            Button(action: open) { row(showsChevron: true, needsConnection: isOffline) }
                .buttonStyle(.plain)
                .disabled(isOffline)
                .accessibilityHint(isOffline ? Text(.nowNeedsConnection) : Text(verbatim: ""))
        } else {
            row(showsChevron: false, needsConnection: false)
        }
    }

    private func row(showsChevron: Bool, needsConnection: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle()
                        .fill(card.kind.color.color)
                        .frame(width: dotSide, height: dotSide)
                        .accessibilityHidden(true)
                    Text(verbatim: card.readyHeading(in: locale) ?? "")
                        .textStyle(.label)
                        .foregroundStyle(ColorToken.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let body = card.body(in: locale) {
                    Text(verbatim: body)
                        .textStyle(.body)
                        .foregroundStyle(ColorToken.ink.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if needsConnection {
                    Text(.nowNeedsConnection)
                        .textStyle(.footnote)
                        .foregroundStyle(ColorToken.ink2.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .foregroundStyle(ColorToken.ink3.color)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .cardChrome()
        .accessibilityElement(children: .combine)
    }
}
