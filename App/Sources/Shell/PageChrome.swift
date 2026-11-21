import SwiftUI
import UIKit

/// 推入页面的顶栏：玻璃返回按钮、滚动后出现的紧凑标题与顶部渐隐（原型 `.page-bar`）
struct PageBar<Trailing: View>: View {
    var title: String
    var scrolled: Bool
    var fade = true
    @ViewBuilder var trailing: Trailing
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .top) {
            if fade {
                CompactHeader(title: "", visible: scrolled)
            }
            HStack(spacing: 10) {
                CircleButton(systemName: "chevron.backward") { dismiss() }
                Text(title)
                    .font(.ui(17, .semibold))
                    .foregroundStyle(Tok.fg)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .opacity(scrolled ? 1 : 0)
                    .offset(y: scrolled ? 0 : 8)
                    .animation(.out, value: scrolled)
                    .allowsHitTesting(false)
                HStack(spacing: 10) { trailing }
                    .frame(minWidth: 40, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .padding(.top, -6)
        }
    }
}

extension PageBar where Trailing == EmptyView {
    init(title: String, scrolled: Bool, fade: Bool = true) {
        self.title = title
        self.scrolled = scrolled
        self.fade = fade
        trailing = EmptyView()
    }
}

/// 推入页面的通用骨架：背景、滚动内容、顶栏
struct PageScaffold<Content: View, Trailing: View>: View {
    let title: String
    var largeTitle = true
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content
    @State private var scrolled = false

    var body: some View {
        ZStack(alignment: .top) {
            ScreenBackground()
            ScrollView {
                VStack(spacing: 0) {
                    if largeTitle {
                        HStack {
                            Text(title).font(.serif(34)).tracking(0.5).foregroundStyle(Tok.fg)
                            Spacer()
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 50)
                        .padding(.bottom, 14)
                    }
                    content
                }
                .padding(.bottom, 56)
            }
            .scrollIndicators(.hidden)
            .trackScroll($scrolled, threshold: largeTitle ? 60 : 8)
            PageBar(title: title, scrolled: scrolled) { trailing }
        }
    }
}

extension PageScaffold where Trailing == EmptyView {
    init(title: String, largeTitle: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.largeTitle = largeTitle
        trailing = EmptyView()
        self.content = content()
    }
}

/// 隐藏系统导航栏后保留边缘右滑返回
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }
}
