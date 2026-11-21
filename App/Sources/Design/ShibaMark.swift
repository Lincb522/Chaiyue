import SwiftUI

/// App 图标里的柴犬：数据来自欢迎动画逐帧描出的轮廓（ShibaArt），帧与帧之间按时间平滑插值
struct ShibaMark: View {
    /// nil 时静止在第一帧；否则从这个时刻开始循环播放
    var start: Date?
    var speed: Double = 1

    var body: some View {
        Group {
            if let start {
                TimelineView(.animation) { context in
                    art(phase: context.date.timeIntervalSince(start) * speed / ShibaArt.frameDuration)
                }
            } else {
                art(phase: 0)
            }
        }
        .aspectRatio(ShibaArt.aspect, contentMode: .fit)
    }

    private func art(phase: Double) -> some View {
        Canvas { context, size in
            ShibaArt.draw(in: &context, size: size, phase: phase)
        }
    }
}

extension ShibaArt {
    static var frameDuration: Double { frameDurations.first ?? 0.18 }

    nonisolated static func color(_ ink: Ink) -> Color {
        switch ink {
        case .navy: rgb(0x14142B)
        case .white: rgb(0xF4F3F2)
        case .peach: rgb(0xFCCB94)
        case .yellow: rgb(0xFFD508)
        case .cream: rgb(0xFCEFE4)
        }
    }

    nonisolated private static func rgb(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }

    /// phase 以帧为单位，可以是任意实数；整数时正好落在原动画的某一帧
    nonisolated static func draw(in context: inout GraphicsContext, size: CGSize, phase: Double) {
        let scale = min(size.width, size.height * aspect)
        let origin = CGPoint(x: (size.width - scale) / 2, y: (size.height - scale / aspect) / 2)
        let frameCount = layers.first?.frames.count ?? 1
        let base = Int(floor(phase))
        let t = Float(phase - floor(phase))
        let index = (-1...2).map { ((base + $0) % frameCount + frameCount) % frameCount }
        for layer in layers {
            let f = index.map { layer.frames[$0] }
            var points = [CGPoint]()
            points.reserveCapacity(layer.count)
            for i in 0..<layer.count {
                let x = catmull(f[0][2 * i], f[1][2 * i], f[2][2 * i], f[3][2 * i], t)
                let y = catmull(f[0][2 * i + 1], f[1][2 * i + 1], f[2][2 * i + 1], f[3][2 * i + 1], t)
                points.append(CGPoint(x: origin.x + CGFloat(x) * scale, y: origin.y + CGFloat(y) * scale))
            }
            context.fill(smoothPath(points), with: .color(color(layer.ink)))
        }
    }

    nonisolated private static func catmull(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float, _ t: Float) -> Float {
        let t2 = t * t, t3 = t2 * t
        return 0.5 * (2 * p1 + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (3 * p1 - p0 - 3 * p2 + p3) * t3)
    }

    /// 闭合的 Catmull-Rom 曲线，转成三次贝塞尔
    nonisolated static func smoothPath(_ p: [CGPoint]) -> Path {
        var path = Path()
        let n = p.count
        guard n > 2 else { return path }
        path.move(to: p[0])
        for i in 0..<n {
            let p0 = p[(i - 1 + n) % n], p1 = p[i], p2 = p[(i + 1) % n], p3 = p[(i + 2) % n]
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        path.closeSubpath()
        return path
    }
}
