import SwiftUI

/// A decision's verdict pills, wrapping onto more lines as they need.
struct VerdictFlow: View {
    let verdicts: [Verdict]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(verdicts, id: \.self) { VerdictPill(verdict: $0) }
        }
    }
}
