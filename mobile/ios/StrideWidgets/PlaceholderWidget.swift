import SwiftUI
import WidgetKit

/// A placeholder that shows only the system background. The string catalog does
/// not exist yet, so it gives the widget gallery no name or description.
struct PlaceholderWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PlaceholderWidget", provider: PlaceholderProvider()) { _ in
            Color.clear
                .containerBackground(.background, for: .widget)
        }
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
