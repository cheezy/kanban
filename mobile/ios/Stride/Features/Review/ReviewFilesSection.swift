import SwiftUI

/// "Files · N", flagged first. A file with a stored diff opens it.
struct ReviewFilesSection: View {
    let content: ReviewContent

    var body: some View {
        ReviewSection(title: .reviewFiles(count: content.files.count), identifier: "review-files") {
            if content.hasFlaggedFiles {
                Text(.reviewFlaggedFirst)
                    .textStyle(.footnote)
                    .foregroundStyle(ColorToken.ink2.color)
                    .accessibilityIdentifier("review-flagged-first")
            }
        } content: {
            // Eager: one task's files, and a lazy stack lets go of rows the
            // Dynamic Type audit pushes off the screen.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(content.files) { file in
                    if let target = content.fileTarget(for: file) {
                        NavigationLink(value: AppRoute.reviewFile(target)) {
                            ReviewFileRowView(file: file)
                        }
                        .buttonStyle(.plain)
                    } else {
                        ReviewFileRowView(file: file)
                    }
                    if file.id != content.files.last?.id {
                        Divider().overlay(ColorToken.line.color)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("review-file-rows")
        }
    }
}
