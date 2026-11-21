import SwiftUI

/// 「柴阅」字标：轮廓来自 LogoArt，笔画随前景色走（深色下变浅），耳朵与书页保持品牌色
struct LogoMark: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height * LogoArt.aspect)
            let origin = CGPoint(x: (size.width - scale) / 2, y: (size.height - scale / LogoArt.aspect) / 2)
            for layer in LogoArt.layers {
                var path = Path()
                for contour in layer.contours {
                    let points = stride(from: 0, to: contour.count - 1, by: 2).map {
                        CGPoint(x: origin.x + CGFloat(contour[$0]) * scale, y: origin.y + CGFloat(contour[$0 + 1]) * scale)
                    }
                    path.addPath(ShibaArt.smoothPath(points))
                }
                context.fill(path, with: .color(color(layer.ink)), style: FillStyle(eoFill: true))
            }
        }
        .aspectRatio(LogoArt.aspect, contentMode: .fit)
        .accessibilityLabel("柴阅")
    }

    private func color(_ ink: LogoArt.Ink) -> Color {
        switch ink {
        case .navy: Tok.fg
        case .orange: Color(hex: 0xF2A25C)
        case .cream: Color(hex: 0xFCE4CE)
        case .yellow: Color(hex: 0xFFD508)
        }
    }
}
