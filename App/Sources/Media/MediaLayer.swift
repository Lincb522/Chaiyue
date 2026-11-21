import ReaderModels
import SwiftUI

/// 听书、漫画、短剧的覆盖层：单独观察 `app.media`，各播放页自己负责展开与收起动画，收起结束时调用 `app.closeMedia()`。
/// 常驻透明底的原因同 `ReaderLayer`
struct MediaLayer: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            Color.clear
                .allowsHitTesting(false)
            if let launch = app.media {
                Group {
                    switch launch.kind {
                    case .audio: AudioPlayerScreen(launch: launch)
                    case .comic: ComicReaderScreen(launch: launch)
                    case .video: DramaPlayerScreen(launch: launch)
                    case .text: EmptyView()
                    }
                }
                .id(launch.id)
            }
        }
        .ignoresSafeArea()
    }
}
