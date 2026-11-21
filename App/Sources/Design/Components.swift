import SwiftUI

/// 按下缩小、松手回弹（原型 `.press`）
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.12) : .bouncy, value: configuration.isPressed)
    }
}

/// 列表行按压高亮（原型 `.row.is-pressed`）
struct RowPressStyle: ButtonStyle {
    var color: Color = Tok.press

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(configuration.isPressed ? color : .clear)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressStyle {
    static var press: PressStyle { PressStyle() }
    static var pressSoft: PressStyle { PressStyle(scale: 0.97) }
}

extension ButtonStyle where Self == RowPressStyle {
    static var row: RowPressStyle { RowPressStyle() }
    static var glassRow: RowPressStyle { RowPressStyle(color: Tok.gFill) }
}

struct CircleButton: View {
    let systemName: String
    var size: CGFloat = 40
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(icon: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Tok.fg)
                .glassCircle(size)
                // 视觉仍是小圆，点按区铺满顶栏高度，偏一点也能点到
                .frame(width: max(size, 44), height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.press)
    }
}

/// 明黄主按钮（原型 `.btn-accent`）
struct AccentButton: View {
    let title: String
    var icon: String? = "book"
    var detail: String?
    var wide = false
    /// 半透明磨砂：浅色下白、深色下黑，用在有底色的卡片上
    var frosted = false
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if frosted { frostedBody } else { accentBody }
    }

    private var frostedBody: some View {
        let light = scheme == .light
        return Button(action: action) {
            label
                .foregroundStyle(light ? Tok.fg : .white)
                .background {
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(Capsule().fill(light ? Color.white.opacity(0.5) : Color.black.opacity(0.32)))
                }
                .overlay(Capsule().strokeBorder(light ? Color.white.opacity(0.7) : Color.white.opacity(0.14), lineWidth: 0.5))
                .shadow(color: .black.opacity(light ? 0.08 : 0.25), radius: 12, y: 6)
        }
        .buttonStyle(AccentPressStyle())
    }

    private var label: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(icon: icon).font(.system(size: wide ? 17 : 15, weight: .semibold))
            }
            Text(title).font(.ui(wide ? 17 : 16, .semibold))
            if let detail {
                Text(detail).font(.num(13, .medium)).opacity(0.72).padding(.leading, 2)
            }
        }
        .padding(.leading, wide ? 0 : 18)
        .padding(.trailing, wide ? 0 : 22)
        .frame(maxWidth: wide ? .infinity : nil)
        .frame(height: wide ? 56 : 46)
        .contentShape(Capsule())
    }

    private var accentBody: some View {
        Button(action: action) {
            label
            .foregroundStyle(Tok.onAccent)
            .background(Tok.accent, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5).blendMode(.overlay))
            .shadow(color: Tok.accent.opacity(0.5), radius: 14, y: 9)
        }
        .buttonStyle(AccentPressStyle())
    }
}

private struct AccentPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.06 : 0)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(configuration.isPressed ? .easeOut(duration: 0.12) : .bouncy, value: configuration.isPressed)
    }
}

/// 滑动胶囊分段（原型 `.chips` + `.seg`）
struct SegmentedChips: View {
    let items: [String]
    @Binding var selection: Int
    var height: CGFloat = 34
    var font: Font = .ui(14)
    var itemWidth: CGFloat?
    var inset: CGFloat = 4
    var glass = false
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                let on = index == selection
                Button {
                    guard index != selection else { return }
                    withAnimation(.snappy) { selection = index }
                } label: {
                    Text(item)
                        .font(font)
                        .fontWeight(on ? .semibold : .regular)
                        .foregroundStyle(on ? (glass ? Tok.gFg : Tok.fg) : (glass ? Tok.gFg2 : Tok.fg2))
                        .lineLimit(1)
                        .padding(.horizontal, itemWidth == nil ? 16 : 0)
                        .frame(width: itemWidth, height: height)
                        .background {
                            if on {
                                Capsule()
                                    .fill(Tok.segBg)
                                    .shadow(color: .black.opacity(0.14), radius: 4, y: 2)
                                    .matchedGeometryEffect(id: "pill", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(inset)
        .background(glass ? Tok.gFill : Tok.fill, in: Capsule())
        .overlay(Capsule().strokeBorder(glass ? .clear : Tok.edge, lineWidth: 0.5))
    }
}

extension EnvironmentValues {
    /// 内容位于玻璃弹层上：卡片、行与图标改用玻璃色调
    @Entry var onGlass = false
}

/// 卡片分组：圆角卡片 + 行间分隔线（原型 `.group`）；玻璃弹层里为半透明底
struct CardGroup<Content: View>: View {
    var separatorInset: CGFloat = 58
    @ViewBuilder var content: Content
    @Environment(\.onGlass) private var onGlass

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
        VStack(spacing: 0) {
            ForEachSubview(content) { index, subview in
                subview
                    .overlay(alignment: .top) {
                        if index > 0 {
                            Rectangle().fill(onGlass ? Tok.gLine : Tok.line).frame(height: 0.5).padding(.leading, separatorInset)
                        }
                    }
            }
        }
        .clipShape(shape)
        .modifier(GroupSurface(onGlass: onGlass, shape: shape))
    }
}

private struct GroupSurface: ViewModifier {
    let onGlass: Bool
    let shape: RoundedRectangle

    func body(content: Content) -> some View {
        if onGlass {
            content.background(Tok.gFill, in: shape)
        } else {
            content.cardSurface()
        }
    }
}

/// 两团模糊色块组成的环境光（原型 `.ambient`）
struct AmbientGlow: View {
    var first: Color
    var second: Color
    var opacity: Double = 1
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let light = scheme == .light
        GeometryReader { proxy in
            let w = proxy.size.width * 1.5
            ZStack {
                RadialGradient(colors: [tone(first, light ? 0.46 : 1).opacity(light ? 0.85 : 0.58), .clear],
                               center: UnitPoint(x: 0.3, y: 0.42), startRadius: 0, endRadius: w * 0.42)
                RadialGradient(colors: [tone(second, light ? 0.34 : 1).opacity(light ? 0.8 : 0.66), .clear],
                               center: UnitPoint(x: 0.76, y: 0.3), startRadius: 0, endRadius: w * 0.44)
            }
            .frame(width: w, height: 660)
            .offset(x: -proxy.size.width * 0.25, y: -180)
            .blur(radius: 26)
            .opacity(opacity)
        }
        .allowsHitTesting(false)
    }

    /// 浅色下先与白色混合，避免色块发灰
    private func tone(_ color: Color, _ amount: Double) -> Color {
        amount >= 1 ? color : color.blend(with: .white, by: 1 - amount)
    }
}

/// 细进度条
struct Hairline: View {
    var value: Double
    var track: Color = Tok.fill2
    var tint: Color = Tok.fg2
    var height: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(tint).frame(width: proxy.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: height)
    }
}

/// 大标题行（原型 `.lt-row`）
struct LargeTitle<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title).font(.serif(34)).tracking(0.5).foregroundStyle(Tok.fg)
            Spacer()
            trailing
        }
        .frame(minHeight: 62)
        .padding(.horizontal, 20)
        .padding(.top, 2)
    }
}

extension LargeTitle where Trailing == EmptyView {
    init(title: String) {
        self.title = title
        trailing = EmptyView()
    }
}

/// 滚动后出现的顶部渐隐与紧凑标题
struct CompactHeader: View {
    let title: String
    let visible: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                LinearGradient(stops: [.init(color: Tok.bg, location: 0.46),
                                       .init(color: Tok.bg.opacity(0.7), location: 0.7),
                                       .init(color: Tok.bg.opacity(0), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                Text(title)
                    .font(.ui(17, .semibold))
                    .foregroundStyle(Tok.fg)
                    .padding(.bottom, 26)
                    .offset(y: visible ? 0 : 8)
            }
            .frame(height: 108)
            Spacer()
        }
        .ignoresSafeArea(edges: .top)
        .opacity(visible ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: visible)
        .allowsHitTesting(false)
    }
}

/// 读取滚动偏移，超过阈值时切换紧凑标题
struct ScrollOffsetReader: ViewModifier {
    @Binding var scrolled: Bool
    var threshold: CGFloat = 44

    func body(content: Content) -> some View {
        content.onScrollOffset { value in
            let over = value > threshold
            if scrolled != over { scrolled = over }
        }
    }
}

extension View {
    func trackScroll(_ scrolled: Binding<Bool>, threshold: CGFloat = 44) -> some View {
        modifier(ScrollOffsetReader(scrolled: scrolled, threshold: threshold))
    }
}

/// 页面统一背景
struct ScreenBackground: View {
    var body: some View {
        Tok.bg.ignoresSafeArea()
    }
}

/// 分节标题行（原型 `.sec-h`）
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title).font(.ui(13)).tracking(0.5).foregroundStyle(Tok.fg3)
            Spacer()
            trailing
        }
        .frame(minHeight: 32)
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.title = title
        trailing = EmptyView()
    }
}

/// 自动换行的流式布局（标签、词条）
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
