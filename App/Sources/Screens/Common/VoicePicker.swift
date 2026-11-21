import SwiftUI

/// 本地神经语音音色网格：女声、男声各一组编号格子，选中的填强调色
struct LocalVoiceGrid: View {
    let selected: Int?
    var loading: Int?
    var columns = 6
    let onPick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            group("女声", LocalVoice.female)
            group("男声", LocalVoice.male)
        }
    }

    private func group(_ title: String, _ speakers: [Int]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.ui(13)).foregroundStyle(Tok.fg3)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                ForEach(Array(speakers.enumerated()), id: \.element) { index, speaker in
                    cell(speaker, number: index + 1)
                }
            }
        }
    }

    private func cell(_ speaker: Int, number: Int) -> some View {
        let isSelected = selected == speaker
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            onPick(speaker)
        } label: {
            ZStack {
                if loading == speaker {
                    ProgressView().controlSize(.small).tint(Tok.onAccent)
                } else {
                    Text("\(number)").font(.num(14))
                }
            }
            .foregroundStyle(isSelected ? Tok.onAccent : Tok.fg2)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(isSelected ? Tok.accent : Tok.fill, in: shape)
            .contentShape(shape)
            .animation(.snappy, value: isSelected)
        }
        .buttonStyle(.press)
        .accessibilityLabel(LocalVoice.name(of: speaker))
    }
}

/// 本地神经语音包未下载：大小、下载进度、继续与重试
struct VoicePackCard: View {
    let store: LocalVoiceStore

    var body: some View {
        HStack(spacing: 14) {
            Image(icon: "waveform")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Tok.accentInk)
                .frame(width: 44, height: 44)
                .background(Tok.accentSoft, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text("自然人声").font(.ui(16, .medium)).foregroundStyle(Tok.fg)
                Text(subtitle)
                    .font(.num(12))
                    .foregroundStyle(failed ? Tok.accentInk : Tok.fg3)
                    .lineLimit(2)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 8)
            action
        }
        .padding(16)
        .cardSurface()
    }

    private var failed: Bool {
        if case .failed = store.phase { return true }
        return false
    }

    private var amount: String { "\(Formats.size(store.received)) / \(Formats.size(store.total))" }

    private var subtitle: String {
        switch store.phase {
        case .downloading: store.total > 0 ? amount : "准备下载"
        case .failed(let message): message
        default: store.isPartial ? amount : "离线可用 · 约 370 MB"
        }
    }

    @ViewBuilder
    private var action: some View {
        if store.phase == .downloading {
            Button {
                store.cancel()
            } label: {
                ZStack {
                    Circle().stroke(Tok.fill2, lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: store.progress)
                        .stroke(Tok.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.2), value: store.progress)
                    Image(icon: "pause.fill").font(.system(size: 10)).foregroundStyle(Tok.fg2)
                }
                .frame(width: 34, height: 34)
            }
            .buttonStyle(.press)
            .accessibilityLabel("暂停下载")
        } else {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                store.download()
            } label: {
                Text(failed ? "重试" : store.isPartial ? "继续" : "下载")
                    .font(.ui(14, .semibold))
                    .foregroundStyle(Tok.onAccent)
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .background(Tok.accent, in: Capsule())
            }
            .buttonStyle(.press)
        }
    }
}

/// 声音选项行：名称、可选说明，右侧勾选或加载中
struct VoiceOptionRow: View {
    let title: String
    var detail: String?
    let selected: Bool
    var loading = false
    let action: () -> Void

    var body: some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            action()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.ui(16)).foregroundStyle(Tok.fg).lineLimit(1)
                    if let detail {
                        Text(detail).font(.ui(12)).foregroundStyle(Tok.fg3).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                ZStack {
                    ProgressView()
                        .controlSize(.small)
                        .opacity(loading ? 1 : 0)
                    Image(icon: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Tok.accentInk)
                        .opacity(selected && !loading ? 1 : 0)
                        .scaleEffect(selected ? 1 : 0.3)
                }
                .animation(.bouncy, value: selected)
                .animation(.snappy, value: loading)
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.row)
    }
}
