import AVFoundation
import ReaderModels
import ReaderServices
import RuleEngine
import SwiftUI

/// 朗读设置：语速、在线朗读源与系统中文语音，点按即选中并试听
struct SpeechSettingsScreen: View {
    @Environment(AppModel.self) private var app
    @State private var player = VoicePreview()
    @State private var onlinePlayer = OnlinePreview()
    @State private var importing = false
    @State private var loggingIn: HttpTTS?

    var body: some View {
        @Bindable var settings = app.settings
        PageScaffold(title: "朗读") {
            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    Image(icon: "tortoise")
                        .font(.system(size: 15))
                        .foregroundStyle(Tok.fg2)
                    GlassSlider(value: $settings.speechRate, range: 0.25...0.75)
                        .frame(height: 30)
                    Image(icon: "hare")
                        .font(.system(size: 17))
                        .foregroundStyle(Tok.fg2)
                }
                HStack {
                    Text(String(format: "%.1f×", settings.speechRate / 0.5))
                        .font(.num(13))
                        .foregroundStyle(Tok.fg3)
                        .contentTransition(.numericText())
                        .animation(.snappy, value: settings.speechRate)
                    Spacer()
                    let playing = player.speaking || onlinePlayer.state != .idle
                    Button {
                        preview()
                    } label: {
                        Image(icon: playing ? "waveform" : "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Tok.fg)
                            .symbolEffect(.variableColor.iterative, isActive: playing)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 34, height: 34)
                            .background(Tok.fill, in: Circle())
                    }
                    .buttonStyle(.press)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .cardSurface()
            .padding(.horizontal, 16)

            GroupLabel("本地神经语音")
            if app.localVoiceReady {
                LocalVoiceGrid(selected: app.usesLocalVoice ? settings.localVoice : nil,
                               loading: app.usesLocalVoice && onlinePlayer.state == .loading ? settings.localVoice : nil) { speaker in
                    app.settings.speechEngine = nil
                    app.settings.localVoice = speaker
                    if app.speech.isActive {
                        app.applyVoiceChange()
                    } else {
                        player.stop()
                        onlinePlayer.play(.local(speaker, speechRate: app.settings.speechRate, voice: app.localVoice), island: app.island)
                    }
                }
                .padding(16)
                .cardSurface()
                .padding(.horizontal, 16)
                .contextMenu {
                    Button("删除语音包", icon: "trash", role: .destructive) {
                        app.localVoice.cancelAll()
                        app.voiceStore.remove()
                    }
                }
            } else {
                VoicePackCard(store: app.voiceStore)
                    .padding(.horizontal, 16)
            }

            GroupLabel("在线朗读")
            CardGroup(separatorInset: 20) {
                ForEach(app.library.httpTTS.engines) { tts in
                    engineRow(tts, selected: settings.speechEngine == tts.id)
                }
                Button {
                    importing = true
                } label: {
                    HStack(spacing: 10) {
                        Image(icon: "plus")
                            .font(.system(size: 14, weight: .semibold))
                        Text("导入朗读源").font(.ui(16))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Tok.accentInk)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.row)
            }
            .padding(.horizontal, 16)

            GroupLabel("系统语音")
            CardGroup(separatorInset: 20) {
                let system = app.selectedEngine == nil && !app.usesLocalVoice
                voiceRow(nil, name: "默认", detail: nil, selected: system && settings.speechVoice == nil)
                ForEach(app.voices.voices) { voice in
                    voiceRow(voice.id, name: voice.name, detail: voice.detail,
                             selected: system && settings.speechVoice == voice.id)
                }
            }
            .padding(.horizontal, 16)
        }
        .task { app.voices.load() }
        .onDisappear {
            player.stop()
            onlinePlayer.stop()
        }
        .sheet(isPresented: $importing) {
            ImportSheet(title: "导入朗读源")
        }
        .sheet(item: $loggingIn) { tts in
            LoginForm(target: app.library.ttsEngine(for: tts), title: tts.name.isEmpty ? "登录" : tts.name.withoutEmoji)
        }
    }

    /// 试听当前选中的语音或朗读源
    private func preview() {
        if let online = app.onlineSpeech {
            player.stop()
            onlinePlayer.play(online, island: app.island)
        } else {
            onlinePlayer.stop()
            player.play(voiceID: app.settings.speechVoice, rate: app.settings.speechRate)
        }
    }

    private func engineRow(_ tts: HttpTTS, selected: Bool) -> some View {
        let loading = selected && onlinePlayer.state == .loading
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            app.settings.speechEngine = tts.id
            if !tts.enabled { app.library.httpTTS.setEnabled(true, for: [tts.id]) }
            if app.speech.isActive { app.applyVoiceChange() } else { preview() }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tts.name.isEmpty ? "未命名" : tts.name.withoutEmoji)
                        .font(.ui(16))
                        .foregroundStyle(tts.enabled ? Tok.fg : Tok.fg3)
                        .lineLimit(1)
                    if let host = URL(string: tts.url.components(separatedBy: ",").first ?? "")?.host() {
                        Text(host)
                            .font(.ui(12))
                            .foregroundStyle(Tok.fg3)
                            .lineLimit(1)
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
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.row)
        .contextMenu {
            Button("试听", icon: "play") {
                player.stop()
                onlinePlayer.play(.http(tts, speechRate: app.settings.speechRate, loader: app.library.speech), island: app.island)
            }
            if tts.loginUi.nilIfEmpty != nil {
                Button("登录", icon: "key") { loggingIn = tts }
            }
            Button(tts.enabled ? "停用" : "启用", icon: tts.enabled ? "poweroff" : "power") {
                app.library.httpTTS.setEnabled(!tts.enabled, for: [tts.id])
            }
            Button("分享", icon: "square.and.arrow.up") {
                guard let data = try? app.library.httpTTS.export([tts.id]) else { return }
                Share.file(data, name: "朗读源-\(tts.name.isEmpty ? "\(tts.id)" : tts.name).json")
            }
            Divider()
            Button("删除", icon: "trash", role: .destructive) {
                if app.settings.speechEngine == tts.id { app.settings.speechEngine = nil }
                withAnimation(.snappy) { app.library.httpTTS.delete([tts.id]) }
            }
        }
    }

    private func voiceRow(_ id: String?, name: String, detail: String?, selected: Bool) -> some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            app.settings.speechVoice = id
            app.settings.speechEngine = nil
            app.settings.localVoice = -1
            if app.speech.isActive {
                app.applyVoiceChange()
            } else {
                onlinePlayer.stop()
                player.play(voiceID: id, rate: app.settings.speechRate)
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.ui(16))
                        .foregroundStyle(Tok.fg)
                    if let detail {
                        Text(detail)
                            .font(.ui(12))
                            .foregroundStyle(Tok.fg3)
                    }
                }
                Spacer(minLength: 8)
                Image(icon: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Tok.accentInk)
                    .opacity(selected ? 1 : 0)
                    .scaleEffect(selected ? 1 : 0.3)
                    .animation(.bouncy, value: selected)
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.row)
    }

}

/// 在线朗读源试听：合成同一句诗后播放
@Observable
final class OnlinePreview {
    enum State { case idle, loading, playing }

    private(set) var state: State = .idle
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private let proxy = AudioPlayerProxy()

    init() {
        proxy.onFinish = { [weak self] _ in Task { @MainActor in self?.state = .idle } }
        proxy.onError = { [weak self] _ in Task { @MainActor in self?.state = .idle } }
    }

    func play(_ online: SpeechController.Online, island: IslandCenter) {
        stop()
        state = .loading
        task = Task { [weak self] in
            do {
                let audio = try await online.audio(VoicePreview.sample)
                guard let self, !Task.isCancelled else { return }
                guard audio.format.isNativelyPlayable || audio.format == .unknown else {
                    throw SpeechPlaybackError.unsupported(audio.format.rawValue)
                }
                let player = try AVAudioPlayer(data: audio.data)
                player.delegate = proxy
                self.player = player
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try? AVAudioSession.sharedInstance().setActive(true)
                player.play()
                state = .playing
            } catch is CancellationError {
                guard let self, !Task.isCancelled else { return }
                state = .idle
            } catch {
                guard let self, !Task.isCancelled else { return }
                state = .idle
                island.show("exclamationmark.triangle", (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                            danger: true)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        player?.stop()
        player = nil
        state = .idle
    }
}

/// 试听：一句固定的诗，播放中显示声波
@Observable
final class VoicePreview: NSObject, AVSpeechSynthesizerDelegate {
    static let sample = "春风又绿江南岸，明月何时照我还。"

    private(set) var speaking = false
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func play(voiceID: String?, rate: Double) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: Self.sample)
        utterance.voice = voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = Float(min(max(rate, 0.1), 0.9))
        synthesizer.speak(utterance)
        speaking = true
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        speaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = self.synthesizer.isSpeaking }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = self.synthesizer.isSpeaking }
    }
}
