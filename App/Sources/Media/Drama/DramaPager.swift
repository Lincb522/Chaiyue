import AVFoundation
import SwiftUI
import UIKit

/// 竖向一集一屏：三屏复用（上一集、本集、下一集），上下拖动跟手，松手按速度投射决定翻过还是回弹
final class DramaPagerController: UIViewController, UIGestureRecognizerDelegate {
    private let model: DramaModel
    private var pages: [DramaPageView] = []
    private var count = 0
    private var index = 0
    private var offset: CGFloat = 0
    private var base: CGFloat = 0
    private var panning = false
    private var animator: UIViewPropertyAnimator?
    private let pan = UIPanGestureRecognizer()
    private let edge = UIScreenEdgePanGestureRecognizer()

    init(model: DramaModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.clipsToBounds = true
        pages = (0..<3).map { _ in DramaPageView() }
        pages.forEach(view.addSubview)

        pan.addTarget(self, action: #selector(handlePan))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        edge.edges = .left
        edge.addTarget(self, action: #selector(handleEdge))
        pan.require(toFail: edge)
        let double = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        double.numberOfTapsRequired = 2
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.require(toFail: double)
        let long = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        long.minimumPressDuration = 0.35
        [edge, pan, double, tap, long].forEach(view.addGestureRecognizer)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        for page in pages {
            page.bounds = CGRect(origin: .zero, size: view.bounds.size)
            page.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        }
        place()
    }

    // MARK: - 数据

    func sync(count: Int, index: Int, cover: UIImage?) {
        loadViewIfNeeded()
        pages.forEach { $0.setCover(cover) }
        let moved = index != self.index && !panning && animator == nil
        guard count != self.count || moved || pages[1].episode == nil else { return }
        self.count = count
        self.index = count > 0 ? min(max(index, 0), count - 1) : 0
        pages[1].configure(count > 0 ? self.index : nil, alwaysVisible: true)
        configureNeighbors()
        refreshPlayers()
        offset = 0
        place()
    }

    func refreshPlayers() {
        guard isViewLoaded else { return }
        pages.forEach { $0.attach(model.player(for: $0.episode)) }
    }

    private func configureNeighbors() {
        pages[0].configure(index > 0 ? index - 1 : nil)
        pages[2].configure(index + 1 < count ? index + 1 : nil)
    }

    private func hasPage(_ slot: Int) -> Bool { pages[slot].episode != nil }

    // MARK: - 布局

    private func place() {
        let height = view.bounds.height
        for (slot, page) in pages.enumerated() {
            page.transform = CGAffineTransform(translationX: 0, y: CGFloat(slot - 1) * height + offset)
        }
        let below = offset < 0
        pages[below ? 2 : 0].reveal(min(1, abs(offset) / 70), fromBelow: below)
        pages[below ? 0 : 2].reveal(0, fromBelow: !below)
    }

    /// 越界拖动的阻力：拖得越远越拉不动，最多走出屏高的两成
    private func rubberBand(_ dy: CGFloat) -> CGFloat {
        let limit = view.bounds.height * 0.2
        let pulled = (1 - 1 / (abs(dy) * 0.55 / limit + 1)) * limit
        return dy < 0 ? -pulled : pulled
    }

    // MARK: - 手势

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan else { return true }
        let velocity = pan.velocity(in: view)
        return count > 0 && abs(velocity.y) > abs(velocity.x)
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let height = view.bounds.height
        switch recognizer.state {
        case .began:
            catchAnimation()
            base = offset
            recognizer.setTranslation(.zero, in: view)
            panning = true
            model.dragging = true
        case .changed:
            let raw = base + recognizer.translation(in: view).y
            offset = hasPage(raw < 0 ? 2 : 0) ? min(max(raw, -height), height) : rubberBand(raw)
            place()
        case .ended, .cancelled, .failed:
            panning = false
            let velocity = recognizer.velocity(in: view).y
            let forward = offset != 0 ? offset < 0 : velocity < 0
            guard hasPage(forward ? 2 : 0) else {
                animate(to: 0, velocity: velocity, rubber: true)
                return
            }
            let toward = forward ? -velocity : velocity
            let progress = abs(offset) / height
            // 按松手速度推算会停在哪：过半才翻，或者是明确的快扫
            let complete = recognizer.state == .ended && toward >= -120
                && (toward > 520 || progress + toward * 0.16 / height > 0.5)
            animate(to: complete ? (forward ? -height : height) : 0, velocity: velocity, rubber: false)
        default:
            break
        }
    }

    @objc private func handleEdge(_ recognizer: UIScreenEdgePanGestureRecognizer) {
        let dx = recognizer.translation(in: view).x
        switch recognizer.state {
        case .began, .changed:
            model.onBackDrag?(dx, 0, false)
        case .ended, .cancelled, .failed:
            model.onBackDrag?(recognizer.state == .ended ? dx : 0, recognizer.velocity(in: view).x, true)
        default:
            break
        }
    }

    @objc private func handleTap() {
        guard !panning, animator == nil else { return }
        model.togglePause()
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard count > 0 else { return }
        model.heart(at: recognizer.location(in: view))
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began: model.boost(true)
        case .ended, .cancelled, .failed: model.boost(false)
        default: break
        }
    }

    // MARK: - 翻集

    /// 播完自动翻到下一集
    func turn(forward: Bool) {
        guard !panning, animator == nil, hasPage(forward ? 2 : 0) else { return }
        model.dragging = true
        animate(to: forward ? -view.bounds.height : view.bounds.height, velocity: 0, rubber: false)
    }

    /// 选集：把目标集放到相邻一屏再翻过去
    func jump(to episode: Int) {
        guard !panning, animator == nil, episode != index, episode >= 0, episode < count else { return }
        let forward = episode > index
        let page = pages[forward ? 2 : 0]
        page.configure(episode)
        page.attach(model.player(for: episode))
        turn(forward: forward)
    }

    /// 在收尾的动画被手指按住：停在当前位置接着拖
    private func catchAnimation() {
        guard let animator, animator.state == .active else { return }
        let current = pages[1].layer.presentation()?.affineTransform().ty ?? pages[1].transform.ty
        animator.stopAnimation(true)
        self.animator = nil
        offset = current
        place()
    }

    private func animate(to target: CGFloat, velocity: CGFloat, rubber: Bool) {
        let distance = target - offset
        guard abs(distance) > 0.5 else {
            offset = target
            place()
            finish(target)
            return
        }
        let animator: UIViewPropertyAnimator
        if rubber {
            animator = UIViewPropertyAnimator(duration: 0.5, dampingRatio: 0.78)
        } else {
            // 松手时的速度接进弹簧：甩得快就滑得快，慢慢放手就缓缓落定
            let relative = min(max(velocity / distance, -3), 10)
            animator = UIViewPropertyAnimator(duration: velocity == 0 ? 0.42 : 0.48, timingParameters: UISpringTimingParameters(
                dampingRatio: 1, initialVelocity: CGVector(dx: relative, dy: 0)))
        }
        offset = target
        animator.addAnimations { self.place() }
        animator.addCompletion { [weak self] position in
            guard let self, position == .end else { return }
            self.animator = nil
            finish(target)
        }
        self.animator = animator
        animator.startAnimation()
    }

    private func finish(_ target: CGFloat) {
        defer { if !panning { model.dragging = false } }
        guard target != 0 else { return }
        if target < 0 {
            pages = [pages[1], pages[2], pages[0]]
        } else {
            pages = [pages[2], pages[0], pages[1]]
        }
        guard let episode = pages[1].episode else { return }
        index = episode
        offset = 0
        configureNeighbors()
        refreshPlayers()
        place()
        let landed = pages[1]
        landed.reveal(1, fromBelow: target < 0)
        UIView.animate(withDuration: 0.3, delay: 0.1, options: [.allowUserInteraction, .beginFromCurrentState]) {
            landed.reveal(0, fromBelow: target < 0)
        }
        model.settle(to: episode)
    }
}

// MARK: - 单集一屏

final class DramaPageView: UIView {
    private(set) var episode: Int?
    private let backdrop = UIImageView()
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let video = DramaVideoView()
    private let shade = DramaShadeView()
    private let badge = DramaEpisodeTag()
    private var readyWatch: NSKeyValueObservation?
    private var fromBelow = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        backdrop.contentMode = .scaleAspectFill
        backdrop.clipsToBounds = true
        video.alpha = 0
        video.isUserInteractionEnabled = false
        shade.alpha = 0
        badge.alpha = 0
        [backdrop, blur, video, shade, badge].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        backdrop.frame = bounds
        blur.frame = bounds
        video.frame = bounds
        shade.frame = bounds
        layoutTag()
    }

    /// 设计稿：即将进入的那集，小标距离露出的边缘 22pt
    private func layoutTag() {
        let size = badge.intrinsicContentSize
        let y = fromBelow ? 22 + size.height / 2 : bounds.height - 22 - size.height / 2
        badge.bounds = CGRect(origin: .zero, size: size)
        badge.center = CGPoint(x: bounds.midX, y: y)
    }

    func setCover(_ image: UIImage?) {
        guard backdrop.image !== image else { return }
        backdrop.image = image
    }

    func configure(_ episode: Int?, alwaysVisible: Bool = false) {
        isHidden = episode == nil && !alwaysVisible
        guard episode != self.episode else { return }
        self.episode = episode
        if let episode { badge.text = "第 \(episode + 1) 集" }
        attach(nil)
    }

    func attach(_ player: AVPlayer?) {
        let layer = video.playerLayer
        guard layer.player !== player else {
            updateGravity()
            return
        }
        readyWatch?.invalidate()
        layer.player = player
        video.alpha = 0
        readyWatch = player == nil ? nil : dramaWatch(layer, \.isReadyForDisplay) { [weak self] in self?.readyChanged() }
        readyChanged()
    }

    private func readyChanged() {
        updateGravity()
        let ready = video.playerLayer.player != nil && video.playerLayer.isReadyForDisplay
        guard ready != (video.alpha > 0) else { return }
        UIView.animate(withDuration: ready ? 0.22 : 0, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.video.alpha = ready ? 1 : 0
        }
    }

    /// 竖屏视频铺满，横屏或方形完整显示
    private func updateGravity() {
        guard let size = video.playerLayer.player?.currentItem?.presentationSize, size.width > 0, size.height > 0 else { return }
        let gravity: AVLayerVideoGravity = size.height > size.width ? .resizeAspectFill : .resizeAspect
        guard video.playerLayer.videoGravity != gravity else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        video.playerLayer.videoGravity = gravity
        CATransaction.commit()
    }

    /// 滑动中露出的程度：显示「第 N 集」小标与边缘压暗
    func reveal(_ amount: CGFloat, fromBelow: Bool) {
        if fromBelow != self.fromBelow {
            self.fromBelow = fromBelow
            shade.flipped = !fromBelow
            layoutTag()
        }
        badge.alpha = amount
        shade.alpha = amount
    }
}

final class DramaVideoView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    // swiftlint:disable:next force_cast
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// 进入中那集露出的一侧压暗（设计稿 `.swipeB::before`）
final class DramaShadeView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    var flipped = false {
        didSet { update() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        let gradient = layer as? CAGradientLayer
        gradient?.colors = [UIColor(white: 0, alpha: 0.4).cgColor, UIColor.clear.cgColor]
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func update() {
        let gradient = layer as? CAGradientLayer
        gradient?.locations = flipped ? [0.6, 1] : [0, 0.4]
        gradient?.colors = (flipped
            ? [UIColor.clear, UIColor(white: 0, alpha: 0.4)]
            : [UIColor(white: 0, alpha: 0.4), UIColor.clear]).map(\.cgColor)
    }
}

/// 「第 N 集」毛玻璃小标（设计稿 `.epTag`）
final class DramaEpisodeTag: UIView {
    private let glass: UIVisualEffectView
    private let label = UILabel()

    var text: String = "" {
        didSet {
            label.attributedText = NSAttributedString(string: text, attributes: [
                .font: UIFont.systemFont(ofSize: 13, weight: .bold),
                .kern: 2,
                .foregroundColor: UIColor.white,
            ])
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    init() {
        let glass: UIVisualEffectView
        if #available(iOS 26, *) {
            glass = UIVisualEffectView(effect: UIGlassEffect())
        } else {
            glass = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
            glass.contentView.backgroundColor = UIColor(white: 1, alpha: 0.12)
            glass.layer.borderColor = UIColor(white: 1, alpha: 0.18).cgColor
            glass.layer.borderWidth = 0.5
        }
        self.glass = glass
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        glass.clipsToBounds = true
        glass.layer.cornerCurve = .continuous
        addSubview(glass)
        glass.contentView.addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        let size = label.intrinsicContentSize
        return CGSize(width: ceil(size.width) + 28, height: ceil(size.height) + 12)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        glass.layer.cornerRadius = bounds.height / 2
        label.frame = bounds.insetBy(dx: 14, dy: 6)
    }
}

// MARK: - SwiftUI 包装

struct DramaPager: UIViewControllerRepresentable {
    let model: DramaModel

    func makeUIViewController(context: Context) -> DramaPagerController {
        let controller = DramaPagerController(model: model)
        model.onPlayersChanged = { [weak controller] in controller?.refreshPlayers() }
        model.onAdvance = { [weak controller] in controller?.turn(forward: true) }
        model.onJump = { [weak controller] episode in controller?.jump(to: episode) }
        return controller
    }

    func updateUIViewController(_ controller: DramaPagerController, context: Context) {
        controller.sync(count: model.count, index: model.index, cover: model.cover)
    }
}
