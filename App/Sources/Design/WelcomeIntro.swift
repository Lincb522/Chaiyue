import SwiftUI

/// 欢迎过场：立体方块图标倾斜 → 黄色光环绕上来 → 旋成「柴阅」字标 → 星芒闪两下化成放射短线。
/// 逐帧对照原 GIF（12 帧 × 0.18 秒）取关键帧，帧与帧之间平滑插值；画布坐标沿用原图的 356 × 358
struct WelcomeIntro: View {
    /// 过场从这一刻开始；之前停在第 0 帧
    var start: Date
    /// 字标笔画色（深色模式下变浅），方块、光环、星芒保持品牌色
    var ink: Color
    var dark = false

    var body: some View {
        TimelineView(.animation) { context in
            Canvas { canvas, size in
                WelcomeScene.draw(in: &canvas, size: size,
                                  frame: context.date.timeIntervalSince(start) / WelcomeScene.frameDuration,
                                  ink: ink, dark: dark)
            }
        }
        .aspectRatio(WelcomeScene.stage.width / WelcomeScene.stage.height, contentMode: .fit)
    }
}

nonisolated enum WelcomeScene {
    static let stage = CGSize(width: 356, height: 358)
    static let frameDuration = 0.18
    static let frameCount = 12
    /// 整段过场时长（最后一帧停住）
    static var duration: Double { Double(frameCount - 1) * frameDuration }

    // MARK: 关键帧（每帧一个值，单位为原图像素 / 度）

    // 方块
    static let tileX = Track([179.5, 185, 185, 181, 182, 180, 183, 183, 183, 183, 183, 183])
    static let tileY = Track([180, 176, 177, 173, 170, 166, 168, 170, 170, 170, 170, 170])
    static let tileRot = Track([-3, -8, -13, -11, -8, -14, -20, -24, -24, -24, -24, -24])
    static let tileSX = Track([1, 1, 1, 1, 1.02, 1.05, 1.1, 1.14, 1.14, 1.14, 1.14, 1.14])
    static let tileSY = Track([1, 0.99, 0.98, 0.93, 0.9, 0.78, 0.66, 0.6, 0.6, 0.6, 0.6, 0.6])
    static let tileAlpha = Track([1, 1, 1, 1, 1, 0.92, 0.3, 0, 0, 0, 0, 0])
    static let tileBlur = Track([0, 0, 0.4, 0.8, 1.2, 2.8, 7, 10, 10, 10, 10, 10])
    static let shibaAlpha = Track([1, 1, 1, 1, 1, 0.85, 0.2, 0, 0, 0, 0, 0])
    /// 投影和侧面厚度先于正面散掉，方块化开时只剩一团亮白
    static let solid = Track([1, 1, 1, 1, 1, 0.7, 0.1, 0, 0, 0, 0, 0])
    /// 方块散成的白色旋涡云，压在刚成形的字标上
    static let cloud = Track([0, 0, 0, 0, 0, 0, 0.35, 0, 0, 0, 0, 0])
    /// 旋转拖影（方块左右各一份淡影）
    static let smear = Track([0, 0, 0.15, 0.3, 0.4, 0.6, 0.4, 0, 0, 0, 0, 0])
    /// 侧面厚度随翻转变大
    static let depth = Track([1, 1.2, 1.5, 1.8, 2, 2.2, 2.2, 2.2, 2.2, 2.2, 2.2, 2.2])

    // 光环：透视下的圆环，后半圈在方块 / 字标后面
    static let ringAlpha = Track([0, 0, 0.35, 0.85, 1, 1, 1, 0.95, 0.7, 0, 0, 0])
    static let ringX = Track([175, 175, 175, 171, 180, 175, 179, 185, 212, 215, 215, 215])
    static let ringY = Track([228, 228, 228, 224, 205, 198, 200, 210, 220, 222, 222, 222])
    static let ringR = Track([130, 130, 130, 139, 140, 150, 148, 138, 114, 105, 105, 105])
    static let ringSquash = Track([0.3, 0.3, 0.3, 0.3, 0.38, 0.32, 0.34, 0.3, 0.3, 0.3, 0.3, 0.3])
    static let ringRoll = Track([-6, -6, -6, -6, -5, -7, -5, -6, -9, -10, -10, -10])
    /// 可见弧段（度，0 为右端，90 为正前方）
    static let arcFrom = Track([60, 60, 60, -20, -70, -180, -180, -40, -30, -30, -30, -30])
    static let arcTo = Track([100, 100, 100, 140, 230, 180, 180, 200, 110, 110, 110, 110])
    static let ringWidth = Track([4, 4, 4, 7, 9, 9, 8.5, 6, 4.5, 4, 4, 4])
    /// 高光在环上的横向位置（0 左端，1 右端）；leftFade 让左半边逐渐变淡
    static let highlight = Track([0.3, 0.3, 0.3, 0.3, 0.3, 0.3, 0.3, 0.2, 0.1, 0.1, 0.1, 0.1])
    static let leftFade = Track([0, 0, 0, 0, 0, 0, 0, 0.6, 0.9, 1, 1, 1])
    /// 第二圈（旋转残影）和环下的白色拖尾
    static let ghostRing = Track([0, 0, 0, 0, 0.2, 0.7, 0.35, 0, 0, 0, 0, 0])
    static let whiteTrail = Track([0, 0, 0.3, 0.5, 0.8, 0.8, 0.35, 0.15, 0, 0, 0, 0])

    // 字标：LogoArt 等比缩放，终态宽 238、左上角 (60, 115.5)
    static let logoAlpha = Track([0, 0, 0, 0, 0, 0.1, 0.9, 1, 1, 1, 1, 1])
    static let logoX = Track([192, 192, 192, 192, 192, 192, 192, 183.5, 181, 179, 179, 179])
    static let logoY = Track([168, 168, 168, 168, 168, 168, 168, 172, 174, 174.6, 174.6, 174.6])
    static let logoScale = Track([0.78, 0.78, 0.78, 0.78, 0.78, 0.78, 0.78, 0.96, 0.99, 1, 1, 1])
    static let logoBlur = Track([6, 6, 6, 6, 6, 5, 2.8, 1.8, 1, 0.3, 0, 0])
    static let logoWidth: CGFloat = 238

    // 星芒：四角星亮起 → 变淡 → 换成三道放射短线
    static let starAlpha = Track([0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0.55, 0])
    static let starScale = Track([0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 1, 1, 0.6])
    static let rays = Track([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
    static let starCenter = CGPoint(x: 307, y: 104)

    // MARK: 配色

    static let navy = rgb(0x0E1A30)
    static let ear = rgb(0xF79675)
    static let headTop = rgb(0xFBB47C)
    static let headBottom = rgb(0xFDDCBE)
    static let pageDeep = rgb(0xFDCB22)
    static let pageLight = rgb(0xFEE6A2)
    static let ringDeep = rgb(0xFFC21A)
    static let ringPale = rgb(0xFFF1C4)
    static let sparkle = rgb(0xFFC81E)

    static func rgb(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }

    static func blend(_ a: UInt32, _ b: UInt32, _ t: Double) -> Color {
        func c(_ v: UInt32, _ s: UInt32) -> Double { Double((v >> s) & 0xFF) / 255 }
        return Color(.sRGB, red: c(a, 16) + (c(b, 16) - c(a, 16)) * t, green: c(a, 8) + (c(b, 8) - c(a, 8)) * t,
                     blue: c(a, 0) + (c(b, 0) - c(a, 0)) * t)
    }

    // MARK: 预先算好的路径

    /// 柴犬各层，坐标单位为方块宽
    static let shibaPaths: [(part: WelcomeArt.Part, path: Path)] = WelcomeArt.shiba.map { layer in
        let pts = stride(from: 0, to: layer.points.count - 1, by: 2).map {
            CGPoint(x: CGFloat(layer.points[$0]), y: CGFloat(layer.points[$0 + 1]))
        }
        return (layer.part, ShibaArt.smoothPath(pts))
    }

    /// 字标各层，坐标单位为字标宽，原点在中心
    static let logoPaths: [(ink: LogoArt.Ink, path: Path)] = LogoArt.layers.map { layer in
        var path = Path()
        let cy = 0.5 / LogoArt.aspect
        for contour in layer.contours {
            let pts = stride(from: 0, to: contour.count - 1, by: 2).map {
                CGPoint(x: CGFloat(contour[$0]) - 0.5, y: CGFloat(contour[$0 + 1]) - cy)
            }
            path.addPath(ShibaArt.smoothPath(pts))
        }
        return (layer.ink, path)
    }

    /// 方块正面（宽 1），尺寸比例与圆角按原图第 0 帧量出
    static let tileAspect: CGFloat = 188.0 / 207.0
    static let tileShape = Path(roundedRect: CGRect(x: -0.5, y: -tileAspect / 2, width: 1, height: tileAspect),
                                cornerRadius: 0.25, style: .continuous)
    static let tileWidth: CGFloat = 207

    static let starPath: Path = {
        // 四条弧边向内凹的四角星，半径 1
        var p = Path()
        let tips = [CGPoint(x: 0, y: -1), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: -1, y: 0)]
        let pinch: CGFloat = 0.16
        p.move(to: tips[0])
        for i in 0..<4 {
            let a = tips[i], b = tips[(i + 1) % 4]
            let mid = CGPoint(x: (a.x + b.x) * pinch, y: (a.y + b.y) * pinch)
            p.addQuadCurve(to: b, control: mid)
        }
        p.closeSubpath()
        return p
    }()

    /// 三道放射短线：外端粗、内端细（原图第 11 帧量出）
    static let rayEnds: [(outer: CGPoint, inner: CGPoint)] = [
        (CGPoint(x: 294, y: 80), CGPoint(x: 296.5, y: 101)),
        (CGPoint(x: 322, y: 87), CGPoint(x: 308.5, y: 104)),
        (CGPoint(x: 333, y: 112.5), CGPoint(x: 315, y: 117.5)),
    ]

    // MARK: 绘制

    static func draw(in context: inout GraphicsContext, size: CGSize, frame rawFrame: Double, ink: Color, dark: Bool) {
        let f = min(max(rawFrame, 0), Double(frameCount - 1))
        let scale = min(size.width / stage.width, size.height / stage.height)
        context.translateBy(x: (size.width - stage.width * scale) / 2, y: (size.height - stage.height * scale) / 2)
        context.scaleBy(x: scale, y: scale)

        let ring = RingPose(f)
        if ring.alpha > 0.005 { drawRing(in: context, ring, half: .back, dark: dark) }
        if tileAlpha(f) > 0.005 { drawTile(in: context, f: f, dark: dark) }
        if logoAlpha(f) > 0.005 { drawLogo(in: context, f: f, ink: ink) }
        if cloud(f) > 0.005 { drawCloud(in: context, f: f, dark: dark) }
        if ring.alpha > 0.005 { drawRing(in: context, ring, half: .front, dark: dark) }
        drawSparkle(in: context, f: f)
    }

    // 方块 + 柴犬
    private static func drawTile(in base: GraphicsContext, f: Double, dark: Bool) {
        let alpha = clamp01(tileAlpha(f))
        let blur = max(0, tileBlur(f))
        let smearAlpha = clamp01(smear(f))
        if smearAlpha > 0.01 {
            for (dRot, dx) in [(-9.0, -6.0), (9.0, 6.0)] {
                var ghost = base
                ghost.addFilter(.blur(radius: blur + 4))
                drawTileBody(in: ghost, alpha: alpha * smearAlpha * 0.45, f: f, extraRotation: dRot, dx: dx,
                             shiba: false, dark: dark)
            }
        }
        var ctx = base
        if blur > 0.05 { ctx.addFilter(.blur(radius: blur)) }
        drawTileBody(in: ctx, alpha: alpha, f: f, extraRotation: 0, dx: 0, shiba: true, dark: dark)
    }

    /// base 上不要带 opacity：再次赋值 opacity 会覆盖而不是相乘，这里各层自己乘好再设
    private static func drawTileBody(in base: GraphicsContext, alpha: Double, f: Double, extraRotation: Double, dx: Double,
                                     shiba: Bool, dark: Bool) {
        let m = CGAffineTransform(translationX: tileX(f) + dx, y: tileY(f))
            .rotated(by: (tileRot(f) + extraRotation) * .pi / 180)
            .scaledBy(x: tileSX(f) * tileWidth, y: tileSY(f) * tileWidth)
        // 滤镜要在变换之前加，模糊半径才按画布像素算
        func layer(blur: CGFloat, opacity: Double) -> GraphicsContext {
            var c = base
            c.opacity = opacity
            if blur > 0 { c.addFilter(.blur(radius: blur)) }
            c.concatenate(m)
            return c
        }
        let d = depth(f)
        // 投影：偏左下的一团柔影
        let solidity = clamp01(solid(f))
        let shadow = layer(blur: 22, opacity: alpha * (dark ? 0.5 : 0.22) * solidity)
        shadow.fill(tileShape.applying(CGAffineTransform(translationX: -0.05, y: 0.1)), with: .color(.black))
        // 侧面厚度
        let sideCtx = layer(blur: 1.2, opacity: alpha * solidity)
        let side = tileShape.applying(CGAffineTransform(translationX: -0.012 * d, y: 0.022 * d))
        sideCtx.fill(side, with: .linearGradient(Gradient(colors: [rgb(0xF2F0EE), rgb(0xE5E2DE)]),
                                                 startPoint: CGPoint(x: 0, y: -0.2), endPoint: CGPoint(x: 0, y: 0.55)))
        // 正面
        let ctx = layer(blur: 0, opacity: alpha)
        ctx.fill(tileShape, with: .linearGradient(Gradient(colors: [.white, rgb(0xF6F5F3)]),
                                                  startPoint: CGPoint(x: 0, y: -0.2), endPoint: CGPoint(x: 0, y: 0.46)))

        guard shiba else { return }
        let art = layer(blur: 0, opacity: alpha * clamp01(shibaAlpha(f)))
        for (part, path) in shibaPaths {
            switch part {
            case .head:
                art.fill(path, with: .linearGradient(Gradient(colors: [headTop, headBottom]),
                                                     startPoint: CGPoint(x: 0, y: WelcomeArt.headSpan.lowerBound),
                                                     endPoint: CGPoint(x: 0, y: WelcomeArt.headSpan.upperBound)))
            case .ear:
                art.fill(path, with: .color(ear))
            case .stroke, .eye, .nose:
                art.fill(path, with: .color(navy))
            case .page:
                art.fill(path, with: .linearGradient(Gradient(stops: [
                    .init(color: pageLight, location: 0), .init(color: pageDeep, location: 0.45),
                    .init(color: rgb(0xFED65E), location: 1),
                ]), startPoint: CGPoint(x: 0.02, y: WelcomeArt.pageSpan.upperBound),
                    endPoint: CGPoint(x: 0.34, y: WelcomeArt.pageSpan.lowerBound)))
            }
        }
    }

    private static func drawCloud(in base: GraphicsContext, f: Double, dark: Bool) {
        let amount = clamp01(cloud(f)) * (dark ? 0.3 : 1)
        var ctx = base
        ctx.addFilter(.blur(radius: 9))
        ctx.translateBy(x: tileX(f), y: tileY(f) - 4)
        ctx.rotate(by: .degrees(tileRot(f) * 0.5))
        for (sx, sy, dx, a) in [(1.25, 0.55, -10.0, 0.9), (0.9, 0.38, 22.0, 0.7)] {
            var c = ctx
            c.opacity = amount * a
            c.translateBy(x: dx, y: 0)
            c.scaleBy(x: sx * tileWidth, y: sy * tileWidth)
            c.fill(Path(ellipseIn: CGRect(x: -0.5, y: -0.5, width: 1, height: 1)), with: .color(.white))
        }
    }

    // 字标
    private static func drawLogo(in base: GraphicsContext, f: Double, ink: Color) {
        var ctx = base
        ctx.opacity = clamp01(logoAlpha(f))
        let blur = max(0, logoBlur(f))
        if blur > 0.05 { ctx.addFilter(.blur(radius: blur)) }
        ctx.translateBy(x: logoX(f), y: logoY(f))
        let s = logoScale(f) * logoWidth
        ctx.scaleBy(x: s, y: s)
        for (kind, path) in logoPaths {
            let color: Color = switch kind {
            case .navy: ink
            case .orange: rgb(0xF2A25C)
            case .cream: rgb(0xFCE4CE)
            case .yellow: rgb(0xFFD508)
            }
            ctx.fill(path, with: .color(color), style: FillStyle(eoFill: true))
        }
    }

    // 星芒
    private static func drawSparkle(in base: GraphicsContext, f: Double) {
        let a = clamp01(starAlpha(f))
        if a > 0.005 {
            var ctx = base
            ctx.opacity = a
            ctx.translateBy(x: starCenter.x, y: starCenter.y)
            let s = 21 * max(0, starScale(f))
            ctx.scaleBy(x: s, y: s)
            // 变淡时中心先亮起来
            let pale = clamp01((1 - a) * 2)
            ctx.fill(starPath, with: .radialGradient(Gradient(colors: [blend(0xFFC81E, 0xFFFFFF, pale * 0.7), sparkle]),
                                                     center: .zero, startRadius: 0, endRadius: 0.8))
        }
        let r = clamp01(rays(f))
        if r > 0.005 {
            var ctx = base
            ctx.opacity = min(1, r * 1.6)
            for (outer, inner) in rayEnds {
                // 从内端向外射出
                let tip = CGPoint(x: inner.x + (outer.x - inner.x) * r, y: inner.y + (outer.y - inner.y) * r)
                ctx.fill(teardrop(from: inner, to: tip, r0: 2.6, r1: 4.6 * max(0.4, r)), with: .color(sparkle))
            }
        }
    }

    /// 两端圆头、一端粗一端细的短线
    private static func teardrop(from a: CGPoint, to b: CGPoint, r0: CGFloat, r1: CGFloat) -> Path {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(0.001, hypot(dx, dy))
        let nx = -dy / len, ny = dx / len
        let angle = atan2(dy, dx)
        var p = Path()
        p.move(to: CGPoint(x: a.x + nx * r0, y: a.y + ny * r0))
        p.addLine(to: CGPoint(x: b.x + nx * r1, y: b.y + ny * r1))
        p.addArc(center: b, radius: r1, startAngle: .radians(angle + .pi / 2), endAngle: .radians(angle - .pi / 2),
                 clockwise: true)
        p.addLine(to: CGPoint(x: a.x - nx * r0, y: a.y - ny * r0))
        p.addArc(center: a, radius: r0, startAngle: .radians(angle - .pi / 2), endAngle: .radians(angle + .pi / 2),
                 clockwise: true)
        p.closeSubpath()
        return p
    }

    // MARK: 光环

    private enum Half { case back, front }

    private struct RingPose {
        var alpha, cx, cy, r, squash, roll, from, to, width, highlight, leftFade, ghost, trail: Double
        init(_ f: Double) {
            alpha = WelcomeScene.clamp01(WelcomeScene.ringAlpha(f))
            cx = WelcomeScene.ringX(f)
            cy = WelcomeScene.ringY(f)
            r = WelcomeScene.ringR(f)
            squash = WelcomeScene.ringSquash(f)
            roll = WelcomeScene.ringRoll(f)
            from = WelcomeScene.arcFrom(f)
            to = WelcomeScene.arcTo(f)
            width = WelcomeScene.ringWidth(f)
            highlight = WelcomeScene.highlight(f)
            leftFade = WelcomeScene.clamp01(WelcomeScene.leftFade(f))
            ghost = WelcomeScene.clamp01(WelcomeScene.ghostRing(f))
            trail = WelcomeScene.clamp01(WelcomeScene.whiteTrail(f))
        }

        /// 第二圈：比主环略小、略低、更斜
        var shifted: Self {
            var p = self
            p.cy += 12
            p.r *= 0.9
            p.roll -= 6
            return p
        }
    }

    /// 环上一点（phi 为度）：透视下前侧（下方）更大更粗
    private static func ringPoint(_ p: RingPose, _ phi: Double, radius: Double, dy: Double = 0) -> (CGPoint, Double) {
        let a = phi * .pi / 180
        let s = 1 + 0.12 * sin(a)
        let x = radius * cos(a) * s, y = radius * sin(a) * p.squash * s
        let t = p.roll * .pi / 180
        return (CGPoint(x: p.cx + x * cos(t) - y * sin(t), y: p.cy + dy + x * sin(t) + y * cos(t)), s)
    }

    /// 一段环带（内外两条边围成的填充形）
    private static func ribbon(_ p: RingPose, from: Double, to: Double, radius: Double, width: Double, dy: Double = 0) -> Path {
        guard to > from else { return Path() }
        let steps = max(2, Int((to - from) / 4))
        var outer = [CGPoint](), inner = [CGPoint]()
        for i in 0...steps {
            let phi = from + (to - from) * Double(i) / Double(steps)
            // 两端收细
            let edge = min(1, min(phi - p.from, p.to - phi) / 18 + 0.15)
            let (c, s) = ringPoint(p, phi, radius: radius, dy: dy)
            let (c2, _) = ringPoint(p, phi + 0.5, radius: radius, dy: dy)
            let tx = c2.x - c.x, ty = c2.y - c.y
            let l = max(0.0001, hypot(tx, ty))
            let w = width * s * edge / 2
            outer.append(CGPoint(x: c.x - ty / l * w, y: c.y + tx / l * w))
            inner.append(CGPoint(x: c.x + ty / l * w, y: c.y - tx / l * w))
        }
        var path = Path()
        path.move(to: outer[0])
        for q in outer.dropFirst() { path.addLine(to: q) }
        for q in inner.reversed() { path.addLine(to: q) }
        path.closeSubpath()
        return path
    }

    private static func drawRing(in base: GraphicsContext, _ p: RingPose, half: Half, dark: Bool) {
        // 后半圈 phi ∈ (180, 360)，前半圈 phi ∈ (0, 180)；把可见弧段按半圈切开
        var segments: [(Double, Double)] = []
        for k in -1...1 {
            let lo = Double(k) * 360 + (half == .front ? 0 : 180)
            let a = max(p.from, lo), b = min(p.to, lo + 180)
            if b > a { segments.append((a, b)) }
        }
        guard !segments.isEmpty else { return }
        let backDim = half == .back ? 0.75 : 1.0
        let left = p.cx - p.r * 1.12, right = p.cx + p.r * 1.12
        let hl = p.highlight
        let fade = 1 - p.leftFade
        let shading = GraphicsContext.Shading.linearGradient(Gradient(stops: [
            .init(color: ringPale.opacity(fade * 0.7), location: 0),
            .init(color: ringDeep.opacity(max(fade, 0.15)), location: max(0.01, hl - 0.2)),
            .init(color: ringPale, location: hl),
            .init(color: ringDeep, location: min(0.99, hl + 0.22)),
            .init(color: ringDeep, location: 1),
        ]), startPoint: CGPoint(x: left, y: 0), endPoint: CGPoint(x: right, y: 0))

        // 环下的白色拖尾（深色底上收敛一些）
        if p.trail > 0.01 {
            var trail = base
            trail.opacity = p.alpha * p.trail * (dark ? 0.35 : 0.9) * backDim
            trail.addFilter(.blur(radius: 4))
            for (a, b) in segments {
                trail.fill(ribbon(p, from: a, to: b, radius: p.r * 0.96, width: p.width * 2.2, dy: 9), with: .color(.white))
            }
        }
        // 第二圈残影
        if p.ghost > 0.01 {
            var ghost = base
            ghost.opacity = p.alpha * p.ghost * 0.8 * backDim
            ghost.addFilter(.blur(radius: 1.2))
            let g = p.shifted
            for (a, b) in segments {
                ghost.fill(ribbon(g, from: a, to: b, radius: g.r, width: p.width * 0.8), with: shading)
            }
        }
        // 光晕 + 本体
        var glow = base
        glow.opacity = p.alpha * 0.55 * backDim
        glow.addFilter(.blur(radius: 3))
        var body = base
        body.opacity = p.alpha * backDim
        for (a, b) in segments {
            let path = ribbon(p, from: a, to: b, radius: p.r, width: p.width)
            glow.fill(ribbon(p, from: a, to: b, radius: p.r, width: p.width * 1.8), with: shading)
            body.fill(path, with: shading)
        }
    }

    fileprivate static func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }
}

/// 按帧取值的关键帧轨道：整数帧正好落在原图那一帧，中间用 Catmull-Rom 平滑过渡
nonisolated struct Track: Sendable {
    let keys: [Double]
    init(_ keys: [Double]) { self.keys = keys }

    func callAsFunction(_ f: Double) -> Double {
        let n = keys.count
        let i = Int(floor(f))
        let t = f - Double(i)
        func k(_ j: Int) -> Double { keys[min(max(j, 0), n - 1)] }
        let p0 = k(i - 1), p1 = k(i), p2 = k(i + 1), p3 = k(i + 2)
        let t2 = t * t, t3 = t2 * t
        return 0.5 * (2 * p1 + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (3 * p1 - p0 - 3 * p2 + p3) * t3)
    }
}
