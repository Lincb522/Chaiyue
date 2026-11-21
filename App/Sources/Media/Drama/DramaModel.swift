import AVFoundation
import Observation
import ReaderModels
import ReaderServices
import UIKit

/// 短剧播放状态：当前集与下一集各一个播放器，其余集不持有播放器
@MainActor
@Observable
final class DramaModel {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    struct Heart: Identifiable {
        let id = UUID()
        let point: CGPoint
        let tilt: Double
    }

    static let speeds: [Float] = [1, 1.25, 1.5, 2]
    private static let speedKey = "drama.speed"

    let session: MediaSession
    private(set) var index: Int
    private(set) var phases: [Int: Phase] = [:]
    /// 秒
    private(set) var time: Double = 0
    private(set) var duration: Double = 0
    private(set) var paused = false
    private(set) var buffering = true
    private(set) var boosting = false
    private(set) var speed: Float
    private(set) var onShelf: Bool
    private(set) var cover: UIImage?
    /// 上下切集跟手或收尾中
    var dragging = false
    /// 拖动进度条时的目标比例
    var scrub: Double?
    var hearts: [Heart] = []
    var picking = false

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var slots: [Int: Slot] = [:]
    @ObservationIgnored private var tasks: [Int: Task<Void, Never>] = [:]
    /// 直链在本次观看内短暂复用，回看上一集不再消耗书源额度
    @ObservationIgnored private var links: [Int: (playback: MediaPlayback, at: Date)] = [:]
    @ObservationIgnored private var clock: Any?
    @ObservationIgnored private weak var clockOwner: AVPlayer?
    @ObservationIgnored private var pendingStart: Double = 0
    @ObservationIgnored private var positionReady = false
    @ObservationIgnored private var seeking = false
    @ObservationIgnored private var prefetched = false
    @ObservationIgnored private var lastSave = Date()
    @ObservationIgnored private var closed = false

    @ObservationIgnored var onPlayersChanged: (() -> Void)?
    @ObservationIgnored var onAdvance: (() -> Void)?
    @ObservationIgnored var onJump: ((Int) -> Void)?
    @ObservationIgnored var onBackDrag: ((CGFloat, CGFloat, Bool) -> Void)?
    @ObservationIgnored var onClose: (() -> Void)?

    init(app: AppModel, book: Book) {
        self.app = app
        session = app.library.mediaSession(for: book)
        index = session.index
        onShelf = session.isOnShelf
        let stored = UserDefaults.standard.float(forKey: Self.speedKey)
        speed = Self.speeds.contains(stored) ? stored : 1
    }

    var count: Int { session.chapters.count }
    var phase: Phase { phases[index] ?? .loading }

    func player(for episode: Int?) -> AVPlayer? {
        episode.flatMap { slots[$0]?.player }
    }

    // MARK: - 生命周期

    func start() async {
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .moviePlayback)
        try? audio.setActive(true)
        Task { await loadCover() }
        await session.open()
        guard !closed, session.tocState == .ready, !session.chapters.isEmpty else { return }
        index = session.index
        pendingStart = Double(session.position) / 1000
        begin()
    }

    func reopen() async {
        await session.refreshToc()
        guard !closed, session.tocState == .ready, !session.chapters.isEmpty else { return }
        index = session.index
        pendingStart = Double(session.position) / 1000
        begin()
    }

    private func loadCover() async {
        guard let url = session.book.displayCover else { return }
        cover = await ImagePipeline.shared.image(for: url, book: session.book, app: app, maxPixel: 600)
    }

    func stop() {
        guard !closed else { return }
        save()
        closed = true
        detachClock()
        slots.values.forEach(release)
        slots = [:]
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        onPlayersChanged?()
    }

    /// 回到前台：系统在后台暂停了视频，按用户意图接着播
    func wake() {
        guard !closed, !paused, positionReady, let slot = slots[index], slot.player.rate == 0 else { return }
        play(slot)
    }

    // MARK: - 取链与播放器

    private func wanted(_ episode: Int) -> Bool {
        episode == index || episode == index + 1
    }

    private func load(_ episode: Int, fresh: Bool = false) {
        guard !closed, session.chapters.indices.contains(episode), slots[episode] == nil, tasks[episode] == nil else { return }
        if case .failed = phases[episode], !fresh { return }
        phases[episode] = .loading
        let cached = fresh ? nil : links[episode].flatMap { Date().timeIntervalSince($0.at) < 600 ? $0.playback : nil }
        tasks[episode] = Task { [weak self] in
            guard let self else { return }
            do {
                let playback: MediaPlayback
                if let cached {
                    playback = cached
                } else {
                    playback = try await session.playback(at: episode)
                }
                tasks[episode] = nil
                guard !closed, wanted(episode) else {
                    phases[episode] = nil
                    return
                }
                links[episode] = (playback, Date())
                makeSlot(episode, playback, cached: cached != nil)
            } catch {
                tasks[episode] = nil
                guard !closed else { return }
                phases[episode] = error is CancellationError ? nil : .failed(error.localizedDescription)
            }
        }
    }

    private func makeSlot(_ episode: Int, _ playback: MediaPlayback, cached: Bool) {
        let asset = AVURLAsset(url: playback.url, options: ["AVURLAssetHTTPHeaderFieldsKey": playback.headers])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = episode == index ? 0 : 4
        let player = AVPlayer(playerItem: item)
        player.defaultRate = speed
        player.actionAtItemEnd = .pause
        let slot = Slot(player: player, item: item, cached: cached)
        slot.observations = [
            dramaWatch(item, \.status) { [weak self] in self?.itemChanged(episode) },
            dramaWatch(player, \.timeControlStatus) { [weak self] in self?.statusChanged(episode) },
        ]
        slot.endToken = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                               object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ended(episode) }
        }
        slots[episode] = slot
        phases[episode] = .ready
        onPlayersChanged?()
        if episode == index { begin() }
    }

    private func release(_ slot: Slot) {
        if clockOwner === slot.player { detachClock() }
        slot.observations.forEach { $0.invalidate() }
        if let token = slot.endToken { NotificationCenter.default.removeObserver(token) }
        slot.player.pause()
        slot.player.replaceCurrentItem(with: nil)
    }

    private func trim() {
        for (episode, slot) in slots where !wanted(episode) {
            release(slot)
            slots[episode] = nil
            if phases[episode] == .ready { phases[episode] = nil }
        }
        for (episode, task) in tasks where !wanted(episode) {
            task.cancel()
            tasks[episode] = nil
            phases[episode] = nil
        }
        onPlayersChanged?()
    }

    private func itemChanged(_ episode: Int) {
        guard let slot = slots[episode] else { return }
        switch slot.item.status {
        case .readyToPlay:
            if episode == index { startPlayback(slot) }
            onPlayersChanged?()
        case .failed:
            let message = slot.item.error?.localizedDescription ?? "无法播放"
            release(slot)
            slots[episode] = nil
            links[episode] = nil
            onPlayersChanged?()
            // 复用的旧直链可能已过期：只换新链重来一次
            if slot.cached {
                phases[episode] = nil
                load(episode, fresh: true)
            } else {
                phases[episode] = .failed(message)
            }
        default:
            break
        }
        if episode == index { statusChanged(episode) }
    }

    private func statusChanged(_ episode: Int) {
        guard episode == index else { return }
        guard let slot = slots[episode] else {
            buffering = true
            return
        }
        buffering = slot.item.status != .readyToPlay || slot.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }

    // MARK: - 当前集

    private func begin() {
        guard !closed else { return }
        guard let slot = slots[index] else {
            load(index)
            return
        }
        attachClock(slot)
        slot.item.preferredForwardBufferDuration = 0
        if slot.item.status == .readyToPlay { startPlayback(slot) }
        statusChanged(index)
    }

    private func startPlayback(_ slot: Slot) {
        guard !slot.started else { return }
        slot.started = true
        let start = pendingStart
        pendingStart = 0
        let length = slot.item.duration.seconds
        if start > 1, !length.isFinite || start < length - 2 {
            time = start
            slot.item.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero,
                           toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600)) { [weak self] _ in
                Task { @MainActor in self?.resume(slot) }
            }
        } else {
            resume(slot)
        }
    }

    private func resume(_ slot: Slot) {
        guard slots[index] === slot else { return }
        positionReady = true
        lastSave = Date()
        if !paused { play(slot) }
    }

    private func play(_ slot: Slot) {
        app.audio.pause()
        slot.player.play()
        if boosting { slot.player.rate = 2 }
    }

    private func attachClock(_ slot: Slot) {
        detachClock()
        clockOwner = slot.player
        clock = slot.player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 15), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time) }
        }
    }

    private func detachClock() {
        if let clock, let clockOwner { clockOwner.removeTimeObserver(clock) }
        clock = nil
        clockOwner = nil
    }

    private func tick(_ now: CMTime) {
        guard let slot = slots[index], positionReady else { return }
        let length = slot.item.duration.seconds
        if length.isFinite, length > 0, length != duration { duration = length }
        if !seeking, now.seconds.isFinite { time = now.seconds }
        if !prefetched, slot.player.timeControlStatus == .playing {
            prefetched = true
            load(index + 1)
        }
        if Date().timeIntervalSince(lastSave) >= 5 { save() }
    }

    private func ended(_ episode: Int) {
        guard episode == index else { return }
        if duration > 0 { time = duration }
        save()
        if session.chapters.indices.contains(index + 1) {
            onAdvance?()
        } else {
            paused = true
        }
    }

    func save() {
        guard !closed, positionReady, session.chapters.indices.contains(index) else { return }
        lastSave = Date()
        session.update(index: index, position: Int(time * 1000), length: duration > 0 ? Int(duration * 1000) : nil)
    }

    /// 分页器落定到新的一集
    func settle(to episode: Int) {
        guard episode != index, session.chapters.indices.contains(episode) else { return }
        save()
        let old = index
        slots[old]?.player.pause()
        detachClock()
        index = episode
        time = 0
        duration = 0
        paused = false
        boosting = false
        buffering = true
        prefetched = false
        positionReady = false
        seeking = false
        pendingStart = 0
        session.update(index: episode, position: 0)
        trim()
        // 退回上一集时，留作「下一集」的播放器回到片头
        if let kept = slots[old] {
            kept.started = false
            kept.item.preferredForwardBufferDuration = 4
            if kept.item.status == .readyToPlay { kept.item.seek(to: .zero, completionHandler: nil) }
        }
        if phases[episode] == nil || phases[episode] == .ready {
            begin()
        } else {
            statusChanged(episode)
        }
    }

    // MARK: - 操作

    func jump(to episode: Int) {
        guard episode != index, session.chapters.indices.contains(episode) else { return }
        onJump?(episode)
    }

    func retry() {
        guard case .failed = phase else { return }
        phases[index] = nil
        load(index, fresh: true)
    }

    func togglePause() {
        guard let slot = slots[index], positionReady else { return }
        if paused {
            paused = false
            if duration > 0, time >= duration - 0.3 {
                time = 0
                slot.player.seek(to: .zero)
            }
            play(slot)
        } else {
            paused = true
            slot.player.pause()
            save()
        }
    }

    func boost(_ on: Bool) {
        guard let slot = slots[index], positionReady, !paused || !on else { return }
        guard boosting != on else { return }
        boosting = on
        if on {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            slot.player.rate = 2
        } else if !paused {
            slot.player.rate = speed
        }
    }

    func cycleSpeed() {
        let next = Self.speeds[((Self.speeds.firstIndex(of: speed) ?? 0) + 1) % Self.speeds.count]
        speed = next
        UserDefaults.standard.set(next, forKey: Self.speedKey)
        slots.values.forEach { $0.player.defaultRate = next }
        if let slot = slots[index], !paused, !boosting, slot.player.rate > 0 { slot.player.rate = next }
    }

    func seek(to fraction: Double) {
        guard let slot = slots[index], positionReady, duration > 0 else { return }
        let target = min(max(fraction, 0), 1) * duration
        time = target
        seeking = true
        slot.player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                self?.seeking = false
                self?.save()
            }
        }
    }

    func heart(at point: CGPoint) {
        hearts.append(Heart(point: point, tilt: .random(in: -16...16)))
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        addToShelf()
    }

    func addToShelf() {
        guard !onShelf else { return }
        app.confirmShelfAdd(session.book) { [self] replacing in
            session.addToShelf(replacing: replacing)
            onShelf = session.isOnShelf
            if onShelf { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        }
    }
}

private final class Slot {
    let player: AVPlayer
    let item: AVPlayerItem
    let cached: Bool
    var started = false
    var observations: [NSKeyValueObservation] = []
    var endToken: NSObjectProtocol?

    init(player: AVPlayer, item: AVPlayerItem, cached: Bool) {
        self.player = player
        self.item = item
        self.cached = cached
    }
}

/// KVO 回调可能来自任意线程，统一转回主线程
func dramaWatch<Object: NSObject, Value>(_ object: Object, _ keyPath: KeyPath<Object, Value>,
                                      _ handler: @escaping @Sendable @MainActor () -> Void) -> NSKeyValueObservation {
    object.observe(keyPath, options: [.new]) { @Sendable _, _ in
        Task { @MainActor in handler() }
    }
}
