import PhotosUI
import SwiftUI

/// 大灰狼资料编辑：相册选图后拖动、双指缩放取景换头像，改昵称
struct WolfProfileEditor: View {
    let account: WolfAccount
    let profile: WolfProfile
    let currentAvatar: UIImage?
    var onSaved: (UIImage?) -> Void = { _ in }
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var nickname = ""
    @State private var item: PhotosPickerItem?
    @State private var picked: UIImage?
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var pinch: CGFloat = 1
    @State private var drag: CGSize = .zero
    @State private var saving = false
    @FocusState private var typing: Bool

    private let side: CGFloat = 200
    private static let nicknameLimit = 20

    var body: some View {
        VStack(spacing: 0) {
            Text("编辑资料")
                .font(.serif(20))
                .foregroundStyle(Tok.fg)
                .padding(.top, 26)
            stage
                .padding(.top, 26)
            PhotosPicker(selection: $item, matching: .images) {
                Label(picked == nil ? "更换头像" : "重新选择", icon: "photo.on.rectangle")
                    .font(.ui(14, .medium))
                    .foregroundStyle(Tok.accentInk)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(Tok.accentSoft, in: Capsule())
            }
            .buttonStyle(.press)
            .padding(.top, 16)

            HStack(spacing: 12) {
                Text("昵称").font(.ui(16)).foregroundStyle(Tok.fg2)
                TextField(profile.maskedEmail, text: $nickname)
                    .font(.ui(16))
                    .foregroundStyle(Tok.fg)
                    .multilineTextAlignment(.trailing)
                    .submitLabel(.done)
                    .focused($typing)
                    .onChange(of: nickname) { _, value in
                        if value.count > Self.nicknameLimit { nickname = String(value.prefix(Self.nicknameLimit)) }
                    }
            }
            .padding(.horizontal, 20)
            .frame(height: 56)
            .cardSurface()
            .padding(.horizontal, 16)
            .padding(.top, 28)

            Spacer(minLength: 20)

            Button(action: save) {
                ZStack {
                    if saving {
                        ProgressView().tint(Tok.onAccent)
                    } else {
                        Text("保存").font(.ui(16, .semibold))
                    }
                }
                .foregroundStyle(Tok.onAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(changed ? Tok.accent : Tok.fg3.opacity(0.4), in: Capsule())
            }
            .buttonStyle(.press)
            .disabled(!changed || saving)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .animation(.snappy, value: changed)
        }
        .contentShape(Rectangle())
        .onTapGesture { typing = false }
        .onAppear { nickname = profile.nickname }
        .onChange(of: item) { _, item in load(item) }
    }

    // MARK: - 头像取景

    private var stage: some View {
        let scale = zoom * pinch
        let shown = clamp(CGSize(width: offset.width + drag.width, height: offset.height + drag.height), zoom: scale)
        return ZStack {
            Circle().fill(Tok.fill)
            if let picked {
                let size = displaySize(picked, zoom: scale)
                Image(uiImage: picked)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .offset(shown)
            } else if let currentAvatar {
                Image(uiImage: currentAvatar).resizable().scaledToFill()
            } else {
                Text(String(profile.displayName.withoutEmoji.prefix(1)).uppercased())
                    .font(.serif(64))
                    .foregroundStyle(Tok.fg2)
            }
        }
        .frame(width: side, height: side)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Tok.fg.opacity(0.08), lineWidth: 1))
        .contentShape(Circle())
        .gesture(cropGesture, including: picked == nil ? .subviews : .all)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    private var cropGesture: some Gesture {
        DragGesture()
            .onChanged { drag = $0.translation }
            .onEnded { value in
                offset = clamp(CGSize(width: offset.width + value.translation.width, height: offset.height + value.translation.height),
                               zoom: zoom)
                drag = .zero
            }
            .simultaneously(with: MagnifyGesture()
                .onChanged { pinch = $0.magnification }
                .onEnded { value in
                    zoom = min(max(zoom * value.magnification, 1), 5)
                    pinch = 1
                    withAnimation(.snappy) { offset = clamp(offset, zoom: zoom) }
                })
    }

    /// 图片铺满取景圆时的显示尺寸
    private func displaySize(_ image: UIImage, zoom: CGFloat) -> CGSize {
        let k = side / max(1, min(image.size.width, image.size.height)) * zoom
        return CGSize(width: image.size.width * k, height: image.size.height * k)
    }

    /// 限制平移，图片始终盖满取景圆
    private func clamp(_ value: CGSize, zoom: CGFloat) -> CGSize {
        guard let picked else { return .zero }
        let size = displaySize(picked, zoom: max(1, zoom))
        let x = max(0, (size.width - side) / 2), y = max(0, (size.height - side) / 2)
        return CGSize(width: min(max(value.width, -x), x), height: min(max(value.height, -y), y))
    }

    /// 按取景裁成 500×500 的 JPEG（与网页用户中心一致）
    private func croppedImage() -> UIImage? {
        guard let image = picked else { return nil }
        let k = side / max(1, min(image.size.width, image.size.height)) * zoom
        let shift = clamp(offset, zoom: zoom)
        let originX = (image.size.width * k / 2 - side / 2 - shift.width) / k
        let originY = (image.size.height * k / 2 - side / 2 - shift.height) / k
        let output: CGFloat = 500
        let s = output / (side / k)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: output, height: output), format: format).image { _ in
            image.draw(in: CGRect(x: -originX * s, y: -originY * s, width: image.size.width * s, height: image.size.height * s))
        }
    }

    private func load(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                app.island.show("exclamationmark.triangle", "无法读取这张图片", danger: true)
                return
            }
            let longest = max(image.size.width, image.size.height)
            let fitted = longest > 1600
                ? image.preparingThumbnail(of: CGSize(width: image.size.width * 1600 / longest,
                                                      height: image.size.height * 1600 / longest)) ?? image
                : image
            withAnimation(.snappy) {
                picked = fitted
                zoom = 1
                offset = .zero
            }
        }
    }

    // MARK: - 保存

    private var trimmed: String { nickname.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var changed: Bool { picked != nil || (!trimmed.isEmpty && trimmed != profile.nickname) }

    private func save() {
        typing = false
        saving = true
        let image = croppedImage()
        let name = trimmed != profile.nickname ? trimmed : nil
        Task {
            do {
                let avatarError = try await account.updateProfile(nickname: name,
                                                                  avatarJPEG: image?.jpegData(compressionQuality: 0.9))
                if let avatarError {
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    app.island.show("exclamationmark.triangle", "昵称已保存，" + avatarError, danger: true)
                } else {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onSaved(image)
                    app.island.show("checkmark", "资料已更新")
                }
                dismiss()
            } catch {
                app.island.show("exclamationmark.triangle", error.localizedDescription, danger: true)
            }
            saving = false
        }
    }
}
