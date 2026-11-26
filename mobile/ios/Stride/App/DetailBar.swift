import SwiftUI

extension EnvironmentValues {
    /// Whether a tab's first screen shows its navigation bar: only in the
    /// iPad's detail column while the sidebar is hidden, where the bar holds
    /// the button that brings the sidebar back.
    @Entry var showsDetailBar = false
}
