import SwiftUI

/// 选集弹层（设计稿 `.dj .sheet`）：30 集一组，看过的变淡，当前集明黄
struct DramaEpisodeSheet: View {
    let model: DramaModel
    @State private var group: Int
    @Namespace private var tabs

    private static let size = 30

    init(model: DramaModel) {
        self.model = model
        _group = State(initialValue: model.index / Self.size)
    }

    var body: some View {
        let count = model.count
        let groups = (count + Self.size - 1) / Self.size
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.session.book.name.withoutEmoji)
                    .font(.serif(16))
                    .tracking(1.5)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text("更新至 \(count) 集")
                    .font(.num(11.5, .medium))
                    .opacity(0.5)
            }
            if groups > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 18) {
                        ForEach(0..<groups, id: \.self) { tab($0, count: count) }
                    }
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .padding(.top, 14)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                let start = group * Self.size
                ForEach(start..<min(count, start + Self.size), id: \.self) { cell($0) }
            }
            .id(group)
            .transition(.opacity)
            .padding(.top, 14)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 31)
        .foregroundStyle(.white)
    }

    private func tab(_ index: Int, count: Int) -> some View {
        let on = index == group
        let start = index * Self.size + 1
        let end = min(count, start + Self.size - 1)
        return Button {
            withAnimation(.snappy) { group = index }
        } label: {
            Text(start == end ? "\(start)" : "\(start)–\(end)")
                .font(.num(13, .semibold))
                .opacity(on ? 1 : 0.45)
                .padding(.bottom, 6)
                .overlay(alignment: .bottom) {
                    if on {
                        Rectangle()
                            .fill(Tok.accent)
                            .frame(height: 2)
                            .matchedGeometryEffect(id: "underline", in: tabs)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private func cell(_ episode: Int) -> some View {
        let current = episode == model.index
        let seen = episode < model.index
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            model.picking = false
            model.jump(to: episode)
        } label: {
            Text("\(episode + 1)")
                .font(.num(13.5, .semibold))
                .foregroundStyle(current ? Tok.onAccent : .white.opacity(seen ? 0.4 : 1))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(current ? AnyShapeStyle(Tok.accent) : AnyShapeStyle(.white.opacity(0.08)),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.press)
    }
}
