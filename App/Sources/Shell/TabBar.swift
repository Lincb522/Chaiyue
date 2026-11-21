import SwiftUI

/// 液态玻璃标签栏：胶囊内透镜指示当前标签，按住拖动时透镜放大跟手、松手吸附；
/// 点搜索后胶囊收成圆（显示上一个标签，点它退出搜索），搜索框展开（原型 `.tabbar`）
struct TabBar: View {
    @Environment(AppModel.self) private var app
    @FocusState private var focused: Bool
    @State private var dragX: CGFloat?
    @State private var hover: MainTab?
    @State private var taps: [MainTab: Int] = [:]

    private let height: CGFloat = 62
    private let lens: CGFloat = 54
    private let gap: CGFloat = 19

    var body: some View {
        @Bindable var app = app
        GeometryReader { proxy in
            let wide = max(height, proxy.size.width - height - gap)
            GlassGroup(spacing: 14) {
                HStack(spacing: 0) {
                    capsule(full: wide)
                    Spacer(minLength: 0)
                    searchField(full: wide, text: $app.searchText)
                }
            }
        }
        .frame(height: height)
        .padding(.horizontal, 16)
        .padding(.bottom, focused ? 10 : 12)
        .ignoresSafeArea(.container, edges: .bottom)
        .animation(.soft, value: app.searching)
        .animation(.soft, value: focused)
        .onChange(of: app.searching) { _, searching in
            if searching {
                Task {
                    try? await Task.sleep(for: .milliseconds(320))
                    if app.searching, app.library.search.keyword.isEmpty { focused = true }
                }
            } else {
                focused = false
            }
        }
    }

    // MARK: - 标签胶囊

    private func capsule(full: CGFloat) -> some View {
        let searching = app.searching
        let width = searching ? height : full
        let itemWidth = (full - 8) / CGFloat(MainTab.allCases.count)
        let dragging = dragX != nil
        let index = CGFloat(app.tab.rawValue)
        let lensX = dragX.map { min(max($0 - itemWidth / 2, 4), full - itemWidth - 4) } ?? (4 + index * itemWidth)

        return ZStack(alignment: .leading) {
            Capsule()
                .fill(dragging ? Tok.gFill2 : Tok.gFill)
                .overlay(Capsule().strokeBorder(Tok.gLine, lineWidth: 0.5))
                .overlay(alignment: .top) {
                    Capsule().fill(Tok.gHi).frame(height: 1).padding(.horizontal, 16).opacity(0.6)
                }
                .frame(width: itemWidth, height: lens)
                .scaleEffect(x: dragging ? 1.12 : 1, y: dragging ? 1.08 : 1)
                .offset(x: lensX)
                .animation(dragging ? .interactiveSpring(response: 0.22, dampingFraction: 0.86) : .snappy, value: lensX)
                .animation(.bouncy, value: dragging)

            HStack(spacing: 0) {
                ForEach(MainTab.allCases) { tab in
                    item(tab, width: itemWidth, dragging: dragging)
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(width: full, height: height, alignment: .leading)
        .opacity(searching ? 0 : 1)
        .overlay {
            Image(icon: app.tab.icon)
                .font(.system(size: 21, weight: .medium))
                .symbolVariant(.fill)
                .foregroundStyle(Tok.gFg)
                .frame(width: height, height: height)
                .opacity(searching ? 1 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: width, alignment: .leading)
        .clipShape(Capsule())
        .contentShape(Capsule())
        .glassSurface(Capsule(), interactive: true)
        .gesture(lensGesture(itemWidth: itemWidth, full: full))
        .accessibilityElement(children: .contain)
    }

    private func item(_ tab: MainTab, width: CGFloat, dragging: Bool) -> some View {
        let selected = tab == app.tab
        let tint: Color = dragging ? (tab == hover ? Tok.gAccent : Tok.gFg) : (selected ? Tok.gAccent : Tok.gFg)
        return VStack(spacing: 3) {
            Image(icon: tab.icon)
                .font(.system(size: 21, weight: .medium))
                .symbolVariant(selected ? .fill : .none)
                .symbolEffect(.bounce.down, value: taps[tab, default: 0])
                .frame(height: 26)
            Text(tab.title)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(tint)
        .frame(width: width, height: lens)
        .animation(.easeOut(duration: 0.2), value: tint)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(tab.title)
    }

    private func lensGesture(itemWidth: CGFloat, full: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard !app.searching else { return }
                if dragX == nil, abs(value.translation.width) < 6 { return }
                dragX = value.location.x
                let raw = (min(max(value.location.x - itemWidth / 2, 4), full - itemWidth - 4) - 4) / itemWidth
                hover = MainTab(rawValue: Int(raw.rounded())) ?? app.tab
            }
            .onEnded { value in
                if app.searching {
                    exitSearch()
                    return
                }
                let target: MainTab
                if dragX != nil {
                    target = hover ?? app.tab
                } else {
                    let raw = Int((value.location.x - 4) / itemWidth)
                    target = MainTab(rawValue: min(max(raw, 0), MainTab.allCases.count - 1)) ?? app.tab
                    taps[target, default: 0] += 1
                }
                dragX = nil
                hover = nil
                select(target)
            }
    }

    private func select(_ tab: MainTab) {
        if tab == app.tab {
            NotificationCenter.default.post(name: .scrollToTop, object: tab)
            return
        }
        UISelectionFeedbackGenerator().selectionChanged()
        app.tab = tab
    }

    // MARK: - 搜索

    private func searchField(full: CGFloat, text: Binding<String>) -> some View {
        let searching = app.searching
        return HStack(spacing: 0) {
            Button {
                if searching {
                    focused = true
                } else {
                    app.searching = true
                }
            } label: {
                Image(icon: "magnifyingglass")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(searching ? Tok.gFg2 : Tok.gFg)
                    .frame(width: searching ? 50 : height, height: height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("搜索")

            TextField("", text: text, prompt: Text("书名或作者").foregroundStyle(Tok.gFg3))
                .font(.ui(17))
                .foregroundStyle(Tok.gFg)
                .tint(Tok.accentInk)
                .submitLabel(.search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .onSubmit { app.startSearch(app.searchText) }
                .opacity(searching ? 1 : 0)
                .allowsHitTesting(searching)

            Button {
                text.wrappedValue = ""
                app.library.search.clear()
                focused = true
            } label: {
                Image(icon: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Tok.gFg)
                    .frame(width: 22, height: 22)
                    .background(Tok.gFill2, in: Circle())
                    .padding(.trailing, 18)
                    .padding(.leading, 8)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(searching && !text.wrappedValue.isEmpty ? 1 : 0)
            .scaleEffect(searching && !text.wrappedValue.isEmpty ? 1 : 0.4)
            .animation(.bouncy, value: text.wrappedValue.isEmpty)
            .allowsHitTesting(searching && !text.wrappedValue.isEmpty)
            .accessibilityLabel("清除")
        }
        .frame(width: searching ? full : height, height: height, alignment: .leading)
        .clipShape(Capsule())
        .glassSurface(Capsule(), interactive: !searching)
    }

    private func exitSearch() {
        focused = false
        app.searching = false
    }
}

extension Notification.Name {
    /// 再次点击当前标签时滚回顶部
    static let scrollToTop = Notification.Name("chaiyue.scrollToTop")
}
