import AVFoundation
import MediaPlayer
import Observation
import ReaderModels
import ReaderServices
import UIKit

/// 听书播放器：常驻于 AppModel，播放页关闭后继续播放。
/// 章内位置按毫秒存进 `MediaSession`；直链每章联网取一次，失败不自动重试（书源匿名额度有限）。本地有声书直接播放书籍目录里的文件
@MainActor
@Observable
final class AudioBookPlayer {
    enum Sleep: Equatable {
        case chapterEnd
        case minutes(Int)
    }

    nonisolated static let rates: [Float] = [0.75, 1, 1.25, 1.5, 2, 2.5, 3]
    nonisolated private static let rateKey = "audio.rate"

    private(set) var session: MediaSession?
    /// 用户意图：播放中（缓冲时也为 true）
    private(set) var isPlaying = false
    /// 正在取直链或缓冲
    private(set) var isLoading = false
    private(set) var error: String?
    /// 秒
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var rate: Float
    private(set) var sleep: Sleep?
    /// 定时剩余秒数（本章结束时按倍速折算）
    private(set) var sleepRemaining: Double?
    private(set) var artwork: UIImage?

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    @ObservationIgnored private var itemObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var controlObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var pendingSeek: Double = 0
    @ObservationIgnored private var seeking = false
    @ObservationIgnored private var lastSave = Date.distantPast
    @ObservationIgnored private var interrupted = false
    @ObservationIgnored private var commandsInstalled = false
    @ObservationIgnored private var artworkItem: MPMediaItemArtwork?
    /// 本章在文件中的区间（秒）：本地有声书按章节标记分章时只播这一段，`currentTime`、`duration` 都按章内计
    @ObservationIgnored private var clipStart: Double = 0
    @ObservationIgnored private var clipEnd: Double?

    init(app: AppModel) {
        self.app = app
        let saved = UserDefaults.standard.float(forKey: Self.rateKey)
        rate = Self.rates.contains(saved) ? saved : 1
        player.automaticallyWaitsToMinimizeStalling = true
        player.defaultRate = rate
        timeObserver = Self.periodic(player) { [weak self] seconds in
            MainActor.assumeIsolated { self?.tick(seconds) }
        }
        controlObservation = Self.observeControl(player) { [weak self] waiting in
            Task { @MainActor in self?.controlChanged(waiting: waiting) }
        }
        observeSystem()
    }

    var book: Book? { session?.book }
    var isActive: Bool { session != nil }
    var chapterTitle: String { session?.currentChapter?.title ?? session?.book.durChapterTitle ?? "" }
    var hasPrevious: Bool { (session?.index ?? 0) > 0 }
    var hasNext: Bool { session.map { $0.index + 1 < $0.chapters.count } ?? false }

    // MARK: - 打开

    /// 播放页打开时调用：同一本书保持现状，换书则切换并从上次位置续播
    func open(_ book: Book) {
        if let session, session.book.bookUrl == book.bookUrl { return }
        save()
        detach()
        let session = app.library.mediaSession(for: book)
        self.session = session
        error = nil
        duration = 0
        currentTime = Double(session.position) / 1000
        artwork = nil
        artworkItem = nil
        loadArtwork(for: session.book)
        start(session)
    }

    private func start(_ session: MediaSession) {
        isLoading = true
        isPlaying = true
        loadTask = Task { [weak self] in
            await session.open()
            guard let self, !Task.isCancelled, session === self.session else { return }
            self.loadTask = nil
            if case .failed(let message) = session.tocState {
                self.fail(message)
                return
            }
            self.load(index: session.index, from: session.position, autoplay: true)
        }
    }

    func refreshToc() {
        guard let session else { return }
        Task {
            await session.refreshToc()
            if case .failed(let message) = session.tocState {
                app.island.show("exclamationmark.triangle", message, danger: true)
            } else {
                app.island.show("arrow.clockwise", "目录已刷新")
            }
        }
    }

    func addToShelf() {
        guard let session, !session.isOnShelf else { return }
        app.confirmShelfAdd(session.book) { session.addToShelf(replacing: $0) }
    }

    // MARK: - 控制

    func play() {
        guard let session else { return }
        if app.speech.isActive { app.speech.stop() }
        activateSession()
        if loadTask != nil {
            isPlaying = true
            return
        }
        guard player.currentItem != nil, error == nil else {
            if session.chapters.isEmpty {
                start(session)
            } else {
                load(index: session.index, from: session.position, autoplay: true)
            }
            return
        }
        isPlaying = true
        player.play()
        updateNowPlaying()
    }

    /// 暂停（短剧、朗读开始播放时也会调用）
    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        player.pause()
        save()
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func retry() {
        guard let session else { return }
        error = nil
        if session.chapters.isEmpty { start(session) } else { load(index: session.index, from: session.position, autoplay: true) }
    }

    func skip(_ seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func seek(to seconds: Double) {
        let upper = duration > 0 ? max(0, duration - 0.5) : seconds
        let target = min(max(0, seconds), upper)
        currentTime = target
        guard let item = player.currentItem, item.status == .readyToPlay else {
            pendingSeek = target
            return
        }
        seeking = true
        Self.seek(player, to: clipStart + target) { [weak self] in
            Task { @MainActor in
                self?.seeking = false
                self?.updateNowPlaying()
            }
        }
        save()
    }

    func next() {
        guard let session, hasNext else { return }
        load(index: session.index + 1, from: 0, autoplay: true)
    }

    func previous() {
        guard let session, hasPrevious else { return }
        load(index: session.index - 1, from: 0, autoplay: true)
    }

    func select(chapter index: Int) {
        guard let session, session.chapters.indices.contains(index) else { return }
        if index == session.index, player.currentItem != nil, error == nil {
            if !isPlaying { play() }
            return
        }
        load(index: index, from: 0, autoplay: true)
    }

    func setRate(_ value: Float) {
        rate = value
        UserDefaults.standard.set(value, forKey: Self.rateKey)
        player.defaultRate = value
        if isPlaying, player.rate > 0 { player.rate = value }
        updateNowPlaying()
    }

    func setSleep(_ value: Sleep?) {
        sleepTask?.cancel()
        sleepTask = nil
        player.volume = 1
        sleep = value
        sleepRemaining = nil
        switch value {
        case .minutes(let minutes):
            let deadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
            sleepRemaining = deadline.timeIntervalSinceNow
            sleepTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let left = deadline.timeIntervalSinceNow
                    self.sleepRemaining = max(0, left)
                    if left <= 10 { self.player.volume = Float(max(0, left / 10)) }
                    if left <= 0 {
                        self.pause()
                        self.setSleep(nil)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(left <= 11 ? 100 : 500))
                }
            }
        case .chapterEnd:
            updateChapterEndFade()
        case nil:
            break
        }
    }

    /// 退出播放页、进入后台时调用
    func save() {
        guard let session, session.chapters.indices.contains(session.index) else { return }
        session.update(index: session.index, position: Int(currentTime * 1000),
                       length: duration > 0 ? Int(duration * 1000) : nil)
        lastSave = Date()
    }

    // MARK: - 载入章节

    private func load(index: Int, from position: Int, autoplay: Bool) {
        guard let session, session.chapters.indices.contains(index) else { return }
        if index != session.index { save() }
        loadTask?.cancel()
        detach()
        if app.speech.isActive, autoplay { app.speech.stop() }
        session.update(index: index, position: position)
        error = nil
        duration = 0
        currentTime = Double(position) / 1000
        pendingSeek = currentTime
        isPlaying = autoplay
        isLoading = true
        if autoplay { activateSession() }
        updateNowPlaying()
        loadTask = Task { [weak self] in
            do {
                let playback = try await session.playback(at: index)
                guard let self, !Task.isCancelled, session === self.session, session.index == index else { return }
                self.loadTask = nil
                self.attach(playback)
            } catch is CancellationError {
            } catch {
                guard let self, !Task.isCancelled, session === self.session else { return }
                self.loadTask = nil
                self.fail(error.localizedDescription)
            }
        }
    }

    private func attach(_ playback: MediaPlayback) {
        let options: [String: Any]? = playback.headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": playback.headers]
        let item = AVPlayerItem(asset: AVURLAsset(url: playback.url, options: options))
        item.audioTimePitchAlgorithm = .timeDomain
        clipStart = max(0, playback.start)
        clipEnd = playback.end.flatMap { $0 > clipStart ? $0 : nil }
        if let clipEnd {
            // 播到区间终点时发出 didPlayToEndTime，接下一章
            item.forwardPlaybackEndTime = CMTime(seconds: clipEnd, preferredTimescale: 600)
            duration = clipEnd - clipStart
        }
        let id = ObjectIdentifier(item)
        statusObservation = Self.observeStatus(item) { [weak self] status, message in
            Task { @MainActor in self?.statusChanged(status, message: message, item: id) }
        }
        let center = NotificationCenter.default
        itemObservers = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.chapterEnded() }
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] note in
                let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
                MainActor.assumeIsolated { self?.fail(message ?? "播放中断") }
            },
        ]
        player.replaceCurrentItem(with: item)
    }

    private func detach() {
        statusObservation = nil
        itemObservers.forEach(NotificationCenter.default.removeObserver)
        itemObservers = []
        player.pause()
        player.replaceCurrentItem(with: nil)
        seeking = false
        clipStart = 0
        clipEnd = nil
    }

    private func statusChanged(_ status: AVPlayerItem.Status, message: String?, item: ObjectIdentifier) {
        guard let current = player.currentItem, ObjectIdentifier(current) == item else { return }
        switch status {
        case .readyToPlay:
            readDuration(current)
            let resume = pendingSeek > 0.5 && (duration <= 0 || pendingSeek < duration - 1) ? pendingSeek : 0
            if clipStart + resume > 0.5 {
                seeking = true
                Self.seek(player, to: clipStart + resume) { [weak self] in
                    Task { @MainActor in self?.seeking = false }
                }
            }
            pendingSeek = 0
            isLoading = false
            if isPlaying { player.play() }
            updateNowPlaying()
        case .failed:
            fail(message ?? "无法播放本章")
        default:
            break
        }
    }

    private func fail(_ message: String) {
        detach()
        isLoading = false
        isPlaying = false
        error = message
        updateNowPlaying()
    }

    private func chapterEnded() {
        currentTime = duration
        save()
        guard let session else { return }
        let next = session.index + 1
        if sleep == .chapterEnd {
            setSleep(nil)
            isPlaying = false
            if session.chapters.indices.contains(next) {
                detach()
                session.update(index: next, position: 0)
                currentTime = 0
                duration = 0
            }
            updateNowPlaying()
            return
        }
        if session.chapters.indices.contains(next) {
            load(index: next, from: 0, autoplay: true)
        } else {
            isPlaying = false
            updateNowPlaying()
        }
    }

    // MARK: - 时钟

    private func tick(_ seconds: Double) {
        guard let item = player.currentItem, item.status == .readyToPlay else { return }
        if duration <= 0 { readDuration(item) }
        // 定位到区间起点之前的时钟回调不计入
        if !seeking, seconds.isFinite, seconds >= clipStart - 0.5 { currentTime = max(0, seconds - clipStart) }
        if sleep == .chapterEnd { updateChapterEndFade() }
        if isPlaying, Date().timeIntervalSince(lastSave) >= 5 {
            save()
            updateNowPlaying()
        }
    }

    private func readDuration(_ item: AVPlayerItem) {
        if let clipEnd {
            duration = clipEnd - clipStart
            return
        }
        let value = item.duration.seconds - clipStart
        if value.isFinite, value > 0 { duration = value }
    }

    private func updateChapterEndFade() {
        guard duration > 0 else {
            sleepRemaining = nil
            return
        }
        let left = max(0, duration - currentTime) / Double(max(rate, 0.1))
        sleepRemaining = left
        player.volume = Float(min(1, left / 10))
    }

    private func controlChanged(waiting: Bool) {
        guard player.currentItem?.status == .readyToPlay else { return }
        isLoading = waiting && isPlaying
    }

    // MARK: - 音频会话与系统事件

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
        installRemoteCommands()
    }

    private func observeSystem() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let raw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let resume = AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume)
            MainActor.assumeIsolated { self?.interruption(type, shouldResume: resume) }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            guard AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            MainActor.assumeIsolated { self?.pause() }
        }
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.save() }
            }
        }
    }

    private func interruption(_ type: AVAudioSession.InterruptionType?, shouldResume: Bool) {
        switch type {
        case .began:
            guard isPlaying else { return }
            interrupted = true
            pause()
        case .ended:
            guard interrupted else { return }
            interrupted = false
            if shouldResume { play() }
        default:
            break
        }
    }

    /// 朗读也注册了同一组远程命令：朗读进行中时这里不响应
    private func installRemoteCommands() {
        guard !commandsInstalled else { return }
        commandsInstalled = true
        let center = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor @Sendable (AudioBookPlayer) -> Void) {
            command.isEnabled = true
            command.addTarget { @Sendable [weak self] _ in
                Task { @MainActor in
                    guard let self, self.session != nil, !self.app.speech.isActive else { return }
                    action(self)
                }
                return .success
            }
        }
        on(center.playCommand) { $0.play() }
        on(center.pauseCommand) { $0.pause() }
        on(center.togglePlayPauseCommand) { $0.toggle() }
        on(center.nextTrackCommand) { $0.next() }
        on(center.previousTrackCommand) { $0.previous() }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
        on(center.skipForwardCommand) { $0.skip(15) }
        on(center.skipBackwardCommand) { $0.skip(-15) }
        center.changePlaybackRateCommand.supportedPlaybackRates = Self.rates.map { NSNumber(value: $0) }
        center.changePlaybackRateCommand.isEnabled = true
        center.changePlaybackRateCommand.addTarget { @Sendable [weak self] event in
            let value = (event as? MPChangePlaybackRateCommandEvent)?.playbackRate ?? 1
            Task { @MainActor in
                guard let self, self.session != nil, !self.app.speech.isActive else { return }
                self.setRate(Self.rates.min { abs($0 - value) < abs($1 - value) } ?? 1)
            }
            return .success
        }
        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { @Sendable [weak self] event in
            guard let time = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            Task { @MainActor in
                guard let self, self.session != nil, !self.app.speech.isActive else { return }
                self.seek(to: time)
            }
            return .success
        }
    }

    // MARK: - 正在播放

    private func updateNowPlaying() {
        guard let session else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: chapterTitle.isEmpty ? session.book.name : chapterTitle,
            MPMediaItemPropertyAlbumTitle: session.book.name,
            MPMediaItemPropertyArtist: session.book.author,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying && !isLoading ? Double(rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if !session.chapters.isEmpty {
            info[MPNowPlayingInfoPropertyChapterNumber] = session.index
            info[MPNowPlayingInfoPropertyChapterCount] = session.chapters.count
        }
        if let artworkItem { info[MPMediaItemPropertyArtwork] = artworkItem }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(for book: Book) {
        guard let url = book.displayCover else { return }
        let library = app.library
        Task { [weak self] in
            guard let data = try? await library.imageData(url, for: book) else { return }
            let image = await Task.detached(priority: .userInitiated) { ImagePipeline.downsample(data, maxPixel: 900) }.value
            guard let self, let image, self.session?.book.bookUrl == book.bookUrl else { return }
            self.artwork = image
            self.artworkItem = Self.artwork(image)
            self.updateNowPlaying()
        }
    }

    // MARK: - 非隔离的系统回调（回调线程不定）

    nonisolated private static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    nonisolated private static func periodic(_ player: AVPlayer, _ handler: @escaping @Sendable (Double) -> Void) -> Any {
        player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { time in
            handler(time.seconds)
        }
    }

    nonisolated private static func observeStatus(_ item: AVPlayerItem,
                                                  _ handler: @escaping @Sendable (AVPlayerItem.Status, String?) -> Void) -> NSKeyValueObservation {
        item.observe(\.status, options: [.initial, .new]) { item, _ in
            handler(item.status, item.error?.localizedDescription)
        }
    }

    nonisolated private static func observeControl(_ player: AVPlayer, _ handler: @escaping @Sendable (Bool) -> Void) -> NSKeyValueObservation {
        player.observe(\.timeControlStatus, options: [.new]) { player, _ in
            handler(player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
        }
    }

    nonisolated private static func seek(_ player: AVPlayer, to seconds: Double, done: @escaping @Sendable () -> Void) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            done()
        }
    }
}
