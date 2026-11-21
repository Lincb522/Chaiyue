import SwiftUI
import UIKit

// iOS 17 兼容层：iOS 18 起直接用系统 API，17 上用等价降级实现

extension Color {
    /// `Color.mix(with:by:)` 的兼容版；iOS 17 在 sRGB 下线性插值，并保持深浅色动态
    func blend(with other: Color, by fraction: Double) -> Color {
        if #available(iOS 18, *) {
            return mix(with: other, by: fraction)
        }
        let t = CGFloat(min(max(fraction, 0), 1))
        let a = UIColor(self), b = UIColor(other)
        return Color(uiColor: UIColor { traits in
            var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
            a.resolvedColor(with: traits).getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
            b.resolvedColor(with: traits).getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
            return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t,
                           blue: b1 + (b2 - b1) * t, alpha: a1 + (a2 - a1) * t)
        })
    }
}

/// 逐个子视图变换的兼容版 `Group(subviews:transform:)`；iOS 17 走 `_VariadicView`
struct ForEachSubview<Content: View, Row: View>: View {
    let content: Content
    let row: (_ index: Int, _ subview: AnyView) -> Row

    init(_ content: Content, @ViewBuilder row: @escaping (_ index: Int, _ subview: AnyView) -> Row) {
        self.content = content
        self.row = row
    }

    var body: some View {
        if #available(iOS 18, *) {
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.offset) { index, subview in
                    row(index, AnyView(subview))
                }
            }
        } else {
            _VariadicView.Tree(VariadicRows(row: row)) { content }
        }
    }
}

private struct VariadicRows<Row: View>: _VariadicView_MultiViewRoot {
    let row: (Int, AnyView) -> Row

    func body(children: _VariadicView.Children) -> some View {
        ForEach(Array(children.enumerated()), id: \.offset) { index, child in
            row(index, AnyView(child))
        }
    }
}

// MARK: - 滚动观察（iOS 17 代替 onScrollGeometryChange / onScrollPhaseChange）

extension View {
    /// 滚动偏移变化：值为 contentOffset.y + 顶部 inset（与 iOS 18 的 `ScrollGeometry` 口径一致）
    @ViewBuilder
    func onScrollOffset(_ action: @escaping (CGFloat) -> Void) -> some View {
        if #available(iOS 18, *) {
            onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top
            } action: { _, value in
                action(value)
            }
        } else {
            background(ScrollViewProbe(onOffset: action, onRelease: nil))
        }
    }

    /// 手指离开滚动视图（交互结束）
    @ViewBuilder
    func onScrollRelease(_ action: @escaping () -> Void) -> some View {
        if #available(iOS 18, *) {
            onScrollPhaseChange { old, new in
                if old == .interacting, new != .interacting { action() }
            }
        } else {
            background(ScrollViewProbe(onOffset: nil, onRelease: action))
        }
    }
}

/// 挂在 ScrollView 背景上，找到同尺寸的 UIScrollView 并监听偏移与拖拽结束
private struct ScrollViewProbe: UIViewRepresentable {
    let onOffset: ((CGFloat) -> Void)?
    let onRelease: (() -> Void)?

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.onOffset = onOffset
        view.onRelease = onRelease
    }

    final class ProbeView: UIView {
        var onOffset: ((CGFloat) -> Void)?
        var onRelease: (() -> Void)?
        private weak var scrollView: UIScrollView?
        private var observation: NSKeyValueObservation?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { detach() } else { attachIfNeeded() }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            attachIfNeeded()
        }

        private func attachIfNeeded() {
            guard window != nil, scrollView?.window == nil else { return }
            guard let target = findScrollView() else {
                // SwiftUI 可能晚一拍才把 UIScrollView 放进层级
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.window != nil, self.scrollView == nil, let target = self.findScrollView() else { return }
                    self.attach(target)
                }
                return
            }
            attach(target)
        }

        private func attach(_ target: UIScrollView) {
            detach()
            scrollView = target
            observation = target.observe(\.contentOffset, options: [.initial, .new]) { [weak self] sv, _ in
                MainActor.assumeIsolated {
                    self?.onOffset?(sv.contentOffset.y + sv.adjustedContentInset.top)
                }
            }
            target.panGestureRecognizer.addTarget(self, action: #selector(handlePan(_:)))
        }

        private func detach() {
            observation?.invalidate()
            observation = nil
            scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(handlePan(_:)))
            scrollView = nil
        }

        @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
            if pan.state == .ended || pan.state == .cancelled || pan.state == .failed { onRelease?() }
        }

        /// 由近及远在祖先子树里找与自身尺寸最接近、且覆盖自身中心的 UIScrollView
        private func findScrollView() -> UIScrollView? {
            guard let window, bounds.width > 0, bounds.height > 0 else { return nil }
            let mine = convert(bounds, to: window)
            let center = CGPoint(x: mine.midX, y: mine.midY)
            var ancestor = superview
            while let node = ancestor {
                var best: (UIScrollView, CGFloat)?
                collect(in: node) { sv in
                    let frame = sv.convert(sv.bounds, to: window)
                    guard frame.contains(center) else { return }
                    let diff = abs(frame.width - mine.width) + abs(frame.height - mine.height)
                    if diff < (best?.1 ?? .infinity) { best = (sv, diff) }
                }
                if let best { return best.0 }
                ancestor = node.superview
            }
            return nil
        }

        private func collect(in view: UIView, _ visit: (UIScrollView) -> Void) {
            if view === self { return }
            if let sv = view as? UIScrollView, !(sv is UITextView) { visit(sv) }
            for sub in view.subviews { collect(in: sub, visit) }
        }
    }
}
