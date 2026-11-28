import SwiftUI

/// What the last card action came to, above the cards, with a button that
/// closes it. VoiceOver reads it out when it appears.
struct NowNoticeView: View {
    let notice: NowNotice
    let close: () -> Void

    var body: some View {
        NoticeView(text: notice.text, isProblem: notice.isProblem, identifier: "now-notice", close: close)
    }
}
