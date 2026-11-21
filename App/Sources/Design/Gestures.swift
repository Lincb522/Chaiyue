import SwiftUI
import UIKit

extension View {
    /// 横向拖动；iOS 17 用带方向锁的 DragGesture（17 上它不会抢纵向滚动）
    @ViewBuilder
    func horizontalPan(onChange: @escaping (CGFloat) -> Void, onEnd: @escaping (CGFloat, CGFloat) -> Void) -> some View {
        if #available(iOS 18, *) {
            gesture(HorizontalPan(onChange: onChange, onEnd: onEnd))
        } else {
            modifier(LegacyHorizontalPan(onChange: onChange, onEnd: onEnd))
        }
    }
}

private struct LegacyHorizontalPan: ViewModifier {
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat, CGFloat) -> Void
    /// 本次拖动是否判定为横向；nil 表示尚未判定
    @State private var horizontal: Bool?

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in
                    if horizontal == nil {
                        horizontal = abs(value.translation.width) > abs(value.translation.height)
                    }
                    if horizontal == true { onChange(value.translation.width) }
                }
                .onEnded { value in
                    if horizontal == true { onEnd(value.translation.width, value.velocity.width) }
                    horizontal = nil
                }
        )
    }
}

/// 只在横向拖动时开始的平移手势：放在纵向 ScrollView 里不影响上下滚动
@available(iOS 18, *)
struct HorizontalPan: UIGestureRecognizerRepresentable {
    var onChange: (CGFloat) -> Void
    /// 结束时的位移与速度（点/秒）
    var onEnd: (CGFloat, CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let dx = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed:
            onChange(dx)
        case .ended, .cancelled, .failed:
            onEnd(dx, recognizer.velocity(in: recognizer.view).x)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }
    }
}

/// 越界阻尼：拉得越远越难拉
func rubberBand(_ overshoot: CGFloat, limit: CGFloat = 0.6) -> CGFloat {
    let x = max(0, overshoot)
    return limit * (1 - 1 / (x / limit * 0.9 + 1))
}
