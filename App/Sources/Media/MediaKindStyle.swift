import ReaderModels
import SwiftUI

/// 封面左下角的毛玻璃小标（设计稿「入口 · 书架小标」）
struct MediaBadge: View {
    let symbol: String
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            Image(icon: symbol)
                .font(.system(size: 8, weight: .bold))
            Text(label)
                .font(.ui(9.5, .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(.ultraThinMaterial.opacity(0.6), in: Capsule())
        .background(.black.opacity(0.3), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
    }
}

/// 各内容形态在入口处的文案与图标
extension BookMediaKind {
    var symbol: String {
        switch self {
        case .text: "book"
        case .audio: "headphones"
        case .comic: "photo"
        case .video: "play.fill"
        }
    }

    /// 书架封面小标；文字书不加标
    var badge: String? {
        switch self {
        case .text: nil
        case .audio: "听书"
        case .comic: "漫画"
        case .video: "短剧"
        }
    }

    func actionTitle(for book: Book) -> String {
        let started = book.hasStarted
        switch self {
        case .text: return started ? "继续阅读" : "开始阅读"
        case .audio: return started ? "继续收听" : "开始收听"
        case .comic: return started ? "继续看漫画" : "开始看漫画"
        case .video: return "播放第 \(max(0, book.durChapterIndex) + 1) 集"
        }
    }
}
