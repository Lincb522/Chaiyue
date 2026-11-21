import ReaderModels
import SwiftUI

/// 灵动岛提示：玻璃胶囊从灵动岛里滴落到岛的正下方，消失时缩回岛里，岛本身不变形；
/// 朗读时（阅读器关闭后）岛向两侧伸出封面与律动条。没有灵动岛的机型提示从顶部落下
struct IslandOverlay: View {
    @Environment(AppModel.self) private var app

    private static var safeTop: CGFloat { AppearanceStore.keyWindow?.safeAreaInsets.top ?? 0 }
    static var hasIsland: Bool { safeTop >= 51 }
    private var safeTop: CGFloat { Self.safeTop }
    private var hasIsland: Bool { Self.hasIsland }
    /// 灵动岛顶端（各机型略有差异，取常见值）
    private var islandTop: CGFloat { safeTop >= 62 ? 14 : 11 }
    private let islandHeight: CGFloat = 37
    private let gap: CGFloat = 8

    var body: some View {
        ZStack(alignment: .top) {
            if hasIsland { live }
            toastLayer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }

    // MARK: - 朗读

    private var live: some View {
        let speaking = app.speech.isActive && app.reader == nil
        let listening = app.audio.isActive && app.media == nil
        let on = speaking || listening
        return HStack {
            LiveCover(book: speaking ? app.speechBook : app.audio.book)
            Spacer()
            Equalizer(active: speaking ? app.speech.state == .speaking : app.audio.isPlaying)
        }
        .padding(.leading, 7)
        .padding(.trailing, 14)
        .opacity(on ? 1 : 0)
        .animation(.easeOut(duration: 0.2).delay(on ? 0.15 : 0), value: on)
        .frame(width: on ? 236 : 126, height: islandHeight)
        .background(.black, in: Capsule())
        .animation(.bouncy, value: on)
        // 收起时等岛缩回原尺寸再隐藏，避免挖孔周围露出黑边
        .opacity(on ? 1 : 0)
        .animation(on ? nil : .easeOut(duration: 0.15).delay(0.45), value: on)
        .padding(.top, islandTop)
        .onTapGesture {
            if speaking {
                app.reopenSpeechBook()
            } else if let book = app.audio.book {
                app.openReader(book)
            }
        }
        .allowsHitTesting(on)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            IslandHitArea.shared.live = on ? frame : nil
        }
        .onChange(of: on) { _, on in
            if !on { IslandHitArea.shared.live = nil }
        }
    }

    // MARK: - 提示

    private var toastLayer: some View {
        ZStack {
            if let toast = app.island.current {
                ToastCapsule(toast: toast)
                    .id(toast.id)
                    .transition(hasIsland ? .islandDrop(rise: islandHeight + gap) : .move(edge: .top).combined(with: .opacity))
                    .onTapGesture { app.island.dismiss() }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        IslandHitArea.shared.toasts[toast.id] = frame
                    }
                    .onDisappear { IslandHitArea.shared.toasts[toast.id] = nil }
            }
        }
        .padding(.top, hasIsland ? islandTop + islandHeight + gap : safeTop + 6)
        .animation(.spring(duration: 0.5, bounce: 0.32), value: app.island.current)
        .onChange(of: app.island.current?.id) { _, _ in IslandWindow.raise() }
    }
}

private struct ToastCapsule: View {
    let toast: IslandCenter.Toast

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(icon: toast.icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(toast.danger ? Tok.gFg2 : Color.white)
                .frame(width: 24, height: 24)
                .background(toast.danger ? Tok.gFill2 : Tok.accent, in: Circle())
            Text(toast.text)
                .font(.ui(14, .medium))
                .foregroundStyle(Tok.gFg)
                .lineLimit(4)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
        }
        .padding(.leading, 10)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        .frame(width: width, alignment: .leading)
        .frame(minHeight: 44)
        .glassSurface(RoundedRectangle(cornerRadius: 22, style: .continuous), strong: true)
        .accessibilityElement(children: .combine)
    }

    /// 一行放得下时按文字收紧；放不下时撑到屏宽减边距，再折行
    private var width: CGFloat {
        let font = UIFont.systemFont(ofSize: 14, weight: .medium)
        let text = (toast.text as NSString).size(withAttributes: [.font: font]).width
        let screen = AppearanceStore.keyWindow?.bounds.width ?? 390
        return min(screen - 40, ceil(10 + 24 + 10 + text + 16))
    }
}

/// 从灵动岛里滴落：起点缩小并上移到岛的位置（被挖孔遮住），弹性落到岛下方；移除时原路缩回
private struct IslandDrop: ViewModifier {
    let progress: CGFloat
    let rise: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: 0.4 + 0.6 * progress, y: 0.3 + 0.7 * progress, anchor: .top)
            .offset(y: -rise * (1 - progress))
            .blur(radius: 8 * (1 - progress))
            .opacity(Double(progress))
    }
}

private extension AnyTransition {
    static func islandDrop(rise: CGFloat) -> AnyTransition {
        .modifier(active: IslandDrop(progress: 0, rise: rise), identity: IslandDrop(progress: 1, rise: rise))
    }
}

private struct LiveCover: View {
    let book: Book?

    var body: some View {
        Group {
            if let book {
                BookCover(book: book, maxPixel: 80)
                    .frame(width: 24)
                    .frame(width: 24, height: 24, alignment: .center)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 7).fill(Tok.accent).frame(width: 24, height: 24)
            }
        }
    }
}

/// 朗读律动条
struct Equalizer: View {
    var active: Bool
    var color: Color = Tok.accent

    var body: some View {
        TimelineView(.animation(paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<4, id: \.self) { i in
                    let phase = [0, 0.35, 0.7, 0.15][i]
                    let value = active ? 0.3 + 0.7 * abs(sin((t + phase) * .pi)) : 0.3
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: 14 * value)
                }
            }
            .frame(height: 14)
        }
    }
}
