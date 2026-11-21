import SwiftUI

extension View {
    /// 毛玻璃表面：iOS 26 起用系统 Liquid Glass，更早的系统用材质叠加原型色调
    @ViewBuilder
    func glassSurface<S: Shape>(_ shape: S, strong: Bool = false, interactive: Bool = false) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self.background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(strong ? Tok.gBgStrong : Tok.gBg)
                }
            }
            .overlay { shape.stroke(Tok.gLine, lineWidth: 0.5) }
            .shadow(color: Tok.shadowWarm.opacity(0.2), radius: 24, y: 14)
        }
    }

    /// 浮在内容上的小圆按钮底（原型 `.circle-btn`）
    @ViewBuilder
    func glassCircle(_ size: CGFloat = 40) -> some View {
        if #available(iOS 26, *) {
            self.frame(width: size, height: size)
                .glassEffect(.regular.interactive(), in: Circle())
        } else {
            self.frame(width: size, height: size)
                .background(.ultraThinMaterial, in: Circle())
                .background(Tok.btnGlass, in: Circle())
                .overlay(Circle().stroke(Tok.edge, lineWidth: 0.5))
        }
    }
}

/// iOS 26 的玻璃形变容器；更早的系统直接平铺内容
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
