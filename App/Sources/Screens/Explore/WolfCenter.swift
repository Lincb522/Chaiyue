import ReaderModels
import ReaderServices
import RuleEngine
import SwiftUI

/// 大灰狼书源的账号资料（POST /user_api），字段与其网页用户中心一致
struct WolfProfile: Decodable, Sendable {
    var id = 0
    var email = ""
    var nickname = ""
    var avatar = ""
    var isVip = 0
    var vipEndTime = 0
    var userKey = ""
    var inviteCode = ""
    var registerTime = 0
    var dayReadCount = 0
    var allReadCount = 0
    var lastReadTime = 0
    var device = ""
    var userIP = ""
    var isBanned = false
    var unbanTime = 0

    enum CodingKeys: String, CodingKey {
        case id, email, nickname, avatar, device
        case isVip = "is_vip", vipEndTime = "vip_end_time", userKey = "user_key", inviteCode = "invite_code"
        case registerTime = "register_time", dayReadCount = "day_read_count", allReadCount = "all_read_count"
        case lastReadTime = "last_read_time", userIP = "user_ip", isBanned = "is_banned", unbanTime = "unban_time"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func int(_ key: CodingKeys) -> Int {
            (try? c.decode(Int.self, forKey: key)) ?? Int((try? c.decode(String.self, forKey: key)) ?? "") ?? 0
        }
        func string(_ key: CodingKeys) -> String { (try? c.decode(String.self, forKey: key)) ?? "" }
        id = int(.id)
        email = string(.email)
        nickname = string(.nickname)
        avatar = string(.avatar)
        isVip = int(.isVip)
        vipEndTime = int(.vipEndTime)
        userKey = string(.userKey)
        inviteCode = string(.inviteCode)
        registerTime = int(.registerTime)
        dayReadCount = int(.dayReadCount)
        allReadCount = int(.allReadCount)
        lastReadTime = int(.lastReadTime)
        device = string(.device)
        userIP = string(.userIP)
        isBanned = (try? c.decode(Bool.self, forKey: .isBanned)) ?? (int(.isBanned) != 0)
        unbanTime = int(.unbanTime)
    }

    var displayName: String { nickname.isEmpty ? maskedEmail : nickname }

    var maskedEmail: String {
        guard let at = email.firstIndex(of: "@") else { return email }
        return String(email[..<at].prefix(3)) + "***" + email[at...]
    }

    var tier: String { isVip >= 2 ? "SVIP" : isVip == 1 ? "VIP" : "普通用户" }

    /// 网页端的规则：SVIP 可关联 5 个 IP，其余 1 个
    var maxDevices: Int { isVip >= 2 ? 5 : 1 }

    /// 网页端把不早于 1912946812 的到期时间视为永久
    var expiry: String {
        guard vipEndTime > 0 else { return "未开通" }
        if vipEndTime >= 1_912_946_812 { return "永久" }
        let end = Date(timeIntervalSince1970: TimeInterval(vipEndTime))
        return end < Date() ? "已过期" : Self.day.string(from: end) + " 到期"
    }

    var todayReads: Int {
        Calendar.current.isDateInToday(Date(timeIntervalSince1970: TimeInterval(lastReadTime))) ? dayReadCount : 0
    }

    /// device 是 JSON 字符串 {ip: 最近活跃时间}，时间可能是秒或毫秒
    var devices: [WolfDevice] {
        guard let data = device.data(using: .utf8),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return map.compactMap { ip, value -> WolfDevice? in
            let raw = (value as? NSNumber)?.doubleValue ?? Double(value as? String ?? "") ?? 0
            return WolfDevice(ip: ip, lastActive: Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw))
        }
        .sorted { $0.lastActive > $1.lastActive }
    }

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(_ seconds: Int) -> String? {
        seconds > 0 ? day.string(from: Date(timeIntervalSince1970: TimeInterval(seconds))) : nil
    }
}

struct WolfDevice: Identifiable, Hashable {
    let ip: String
    let lastActive: Date
    var id: String { ip }
}

/// 大灰狼账号：用书源保存的登录 Cookie 直接请求其用户中心接口
@Observable
final class WolfAccount {
    let base: String
    private(set) var profile: WolfProfile?
    private(set) var notice: (title: String, content: String)?
    private(set) var error: String?
    private(set) var loading = false
    @ObservationIgnored private let environment: SourceEnvironment

    init(base: String, environment: SourceEnvironment) {
        self.base = base
        self.environment = environment
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            let profile = try JSONDecoder().decode(WolfProfile.self, from: try await request("/user_api", method: "POST"))
            guard profile.id != 0 else { throw RuleError.message("登录已失效，请重新登录") }
            self.profile = profile
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        if let data = try? await request("/user_center/notice?_=\(Int(Date().timeIntervalSince1970))"),
           let response = try? JSONDecoder().decode(NoticeResponse.self, from: data),
           response.code == 0, let item = response.data, item.enabled == true,
           let title = item.title.nilIfEmpty, let content = item.content.nilIfEmpty {
            notice = (title, content)
        }
    }

    func removeDevice(_ ip: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["device_id": ip])
        let data = try await request("/clear_device", method: "POST", body: body)
        if let response = try? JSONDecoder().decode(CodeResponse.self, from: data), response.code != 0 {
            throw RuleError.message(response.msg.nilIfEmpty ?? "移除失败")
        }
        await load()
    }

    /// 同书源的「清除设备」：清空全部已关联 IP，服务器可能随之要求重新登录
    func clearDevices() async throws {
        let data = try await request("/clear", method: "POST")
        if let response = try? JSONDecoder().decode(CodeResponse.self, from: data), response.code != 0 {
            throw RuleError.message(response.msg.nilIfEmpty ?? "清除失败")
        }
        await load()
    }

    /// 改头像与昵称（同网页用户中心）：头像先传到 /upload_avatar 换得地址，再与昵称一起提交。
    /// 头像上传失败时昵称照常保存，返回头像的失败原因；什么都没保存成功才抛出
    func updateProfile(nickname: String?, avatarJPEG: Data?) async throws -> String? {
        var payload: [String: String] = [:]
        var avatarError: String?
        if let avatarJPEG {
            do {
                payload["avatar"] = try await uploadAvatar(avatarJPEG)
            } catch {
                avatarError = error.localizedDescription
            }
        }
        if let nickname = (nickname?.trimmingCharacters(in: .whitespacesAndNewlines)).nilIfEmpty {
            payload["nickname"] = nickname
        }
        guard !payload.isEmpty else {
            if let avatarError { throw RuleError.message(avatarError) }
            return nil
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await request("/modify_the_avatar_and_nickname", method: "POST", body: body)
        let response = try? JSONDecoder().decode(CodeResponse.self, from: data)
        guard response?.code == 0 else { throw RuleError.message((response?.msg).nilIfEmpty ?? "保存失败，请重试") }
        await load()
        return avatarError
    }

    private func uploadAvatar(_ jpeg: Data) async throws -> String {
        let boundary = "Chaiyue-\(UUID().uuidString)"
        var body = Data("--\(boundary)\r\n".utf8)
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"avatar.jpg\"\r\n".utf8))
        body.append(Data("Content-Type: image/jpeg\r\n\r\n".utf8))
        body.append(jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let data = try await request("/upload_avatar", method: "POST", body: body,
                                     contentType: "multipart/form-data; boundary=\(boundary)")
        let response = try? JSONDecoder().decode(UploadResponse.self, from: data)
        guard response?.code == 0, let url = (response?.url).nilIfEmpty else {
            let reason = (response?.msg).nilIfEmpty ?? "请稍后再试"
            throw RuleError.message("头像未更新：大灰狼服务器\(reason.hasPrefix("上传图片失败") ? "暂时无法保存图片" : "返回「\(reason)」")")
        }
        return url
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil,
                         contentType: String = "application/json") async throws -> Data {
        var headers = [
            "Cookie": environment.cookies.getCookie(url: base),
            "Cache-Control": "no-cache",
            "User-Agent": environment.userAgent,
        ]
        if body != nil { headers["Content-Type"] = contentType }
        let request = HTTPRequest(url: base + path, method: method, headers: headers, body: body, timeout: 20)
        let http = environment.http
        let response = try await Task.detached { try http.send(request) }.value
        guard (200..<300).contains(response.statusCode) else { throw RuleError.network("HTTP \(response.statusCode)") }
        return response.body
    }

    private struct NoticeResponse: Decodable {
        struct Item: Decodable {
            var enabled: Bool?
            var title: String?
            var content: String?
        }
        var code: Int?
        var data: Item?
    }

    private struct CodeResponse: Decodable {
        var code: Int?
        var msg: String?
    }

    private struct UploadResponse: Decodable {
        var code: Int?
        var url: String?
        var msg: String?
    }
}

enum WolfCenter {
    /// 大灰狼书源发现页里的「大灰狼个人中心」指向 /get_book_shelf
    static func isCenter(_ url: String) -> Bool { url.contains("/get_book_shelf") }

    /// 分类地址（可带 `,{选项}`）所在的服务器根地址
    static func base(of url: String) -> String? {
        let raw = url.components(separatedBy: ",").first ?? url
        guard let parsed = URL(string: raw), let scheme = parsed.scheme, let host = parsed.host() else { return nil }
        return parsed.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }

    /// 书源变量里保存的当前线路（登录页的「用户后台」用）
    static func base(for source: BookSource, environment: SourceEnvironment) -> String? {
        guard let raw = environment.cache.get("sourceVariable_" + source.bookSourceUrl),
              let data = raw.data(using: .utf8),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let server = (map["server"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")),
              !server.isEmpty else { return nil }
        return server
    }

    /// 与书源一致：书架请求带上该服务器的 Cookie
    static func shelfURL(base: String, environment: SourceEnvironment) -> String {
        let option: [String: Any] = ["method": "GET", "headers": ["cookie": environment.cookies.getCookie(url: base)]]
        let json = (try? JSONSerialization.data(withJSONObject: option)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return base + "/get_book_shelf," + json
    }
}

/// 大灰狼个人中心（原生版网页用户中心）：资料、会员、阅读统计、公告、书架、账号与设备
struct WolfCenterView: View {
    let source: BookSource
    let base: String
    var onLogout: () -> Void = {}
    @Environment(AppModel.self) private var app
    @State private var account: WolfAccount?
    @State private var shelf: ExploreBookList?
    @State private var removing: WolfDevice?
    @State private var clearingAll = false
    @State private var clearing = false
    @State private var loggingOut = false
    @State private var noticeExpanded = false
    @State private var avatar: UIImage?
    @State private var editing = false
    /// 上次加载时该服务器的 Cookie，其它入口登录或退出后据此判断是否需要重新加载
    @State private var loadedCookie: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let account, let profile = account.profile {
                header(profile)
                if profile.isBanned { banner(profile) }
                stats(profile)
                if let notice = account.notice { noticeCard(notice) }
                shelfSection
                accountSection(profile)
                deviceSection(profile, account: account)
                logoutRow
            } else if let message = account?.error, account?.loading == false {
                failure(message)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 120)
            }
        }
        .padding(.bottom, 12)
        .task {
            guard account == nil else { return }
            await load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .sourceLoginChanged)) { note in
            guard note.object as? String == source.bookSourceUrl, account != nil,
                  app.library.environment.cookies.getCookie(url: base) != loadedCookie else { return }
            Task { await load() }
        }
        .confirmationDialog("移除这个 IP？", isPresented: Binding { removing != nil } set: { if !$0 { removing = nil } },
                            titleVisibility: .visible, presenting: removing) { device in
            Button("移除 \(Self.maskIP(device.ip))", role: .destructive) { remove(device) }
        }
        .confirmationDialog("清除全部已关联的 IP？", isPresented: $clearingAll, titleVisibility: .visible) {
            Button("清除全部", role: .destructive) { clearAll() }
        } message: {
            Text("清除后可能需要重新登录")
        }
        .confirmationDialog("退出大灰狼账号？", isPresented: $loggingOut, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { logout() }
        }
        .sheet(isPresented: $editing) {
            if let account, let profile = account.profile {
                WolfProfileEditor(account: account, profile: profile, currentAvatar: avatar) { image in
                    if let image { avatar = image }
                }
                .qSheet([.large])
                .environment(app)
            }
        }
    }

    // MARK: - 资料

    private func header(_ profile: WolfProfile) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(profile.isVip > 0 ? Tok.accentSoft : Tok.fill)
                if let avatar {
                    Image(uiImage: avatar).resizable().scaledToFill()
                } else {
                    Text(String(profile.displayName.withoutEmoji.prefix(1)).uppercased())
                        .font(.serif(28))
                        .foregroundStyle(profile.isVip > 0 ? Tok.accentInk : Tok.fg2)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(Circle())
            .overlay(alignment: .bottomTrailing) {
                Image(icon: "pencil")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Tok.fg2)
                    .frame(width: 22, height: 22)
                    .background(Tok.bg, in: Circle())
                    .overlay(Circle().strokeBorder(Tok.fill2, lineWidth: 1))
                    .offset(x: 2, y: 2)
            }
            .contentShape(Circle())
            .onTapGesture { editing = true }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("编辑资料")
            .task(id: profile.avatar) {
                guard !profile.avatar.isEmpty else { return }
                let url = profile.avatar
                if let image = await ImagePipeline.shared.image(for: url, book: nil, app: app, maxPixel: 200) { avatar = image }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(profile.displayName.withoutEmoji)
                    .font(.serif(24))
                    .foregroundStyle(Tok.fg)
                    .lineLimit(1)
                    .onTapGesture { editing = true }
                HStack(spacing: 8) {
                    Text(profile.tier)
                        .font(.ui(12, .semibold))
                        .foregroundStyle(profile.isVip > 0 ? Tok.onAccent : Tok.fg2)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(profile.isVip > 0 ? Tok.accent : Tok.fill2, in: Capsule())
                    Text(profile.expiry)
                        .font(.ui(13))
                        .foregroundStyle(Tok.fg2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
    }

    private func banner(_ profile: WolfProfile) -> some View {
        let until = profile.unbanTime > 0
            ? Formats.relative(Date(timeIntervalSince1970: TimeInterval(profile.unbanTime))) : nil
        return HStack(spacing: 10) {
            Image(icon: "exclamationmark.triangle.fill")
            Text(BookText.join("访问受限", until.map { "\($0)解封" }))
                .lineLimit(1)
        }
        .font(.ui(14, .medium))
        .foregroundStyle(Tok.accentInk)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .background(Tok.accentSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 18)
    }

    private func stats(_ profile: WolfProfile) -> some View {
        HStack(alignment: .top, spacing: 0) {
            stat("\(profile.todayReads)", unit: "章", label: "今日阅读")
            stat("\(profile.allReadCount)", unit: "章", label: "累计阅读")
            stat("\(profile.devices.count)/\(profile.maxDevices)", unit: nil, label: "在线 IP")
        }
        .padding(.horizontal, 20)
        .padding(.top, 26)
    }

    private func stat(_ value: String, unit: String?, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 34, weight: .light))
                    .monospacedDigit()
                    .tracking(-1)
                    .foregroundStyle(Tok.fg)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                if let unit { Text(unit).font(.ui(12)).foregroundStyle(Tok.fg2) }
            }
            Text(label).font(.ui(12)).foregroundStyle(Tok.fg3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func noticeCard(_ notice: (title: String, content: String)) -> some View {
        let content = notice.content
            .replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .withoutEmoji
        return Button {
            withAnimation(.snappy) { noticeExpanded.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(icon: "megaphone").font(.system(size: 14, weight: .medium)).foregroundStyle(Tok.accentInk)
                    Text(notice.title.withoutEmoji).font(.ui(15, .semibold)).foregroundStyle(Tok.fg).lineLimit(1)
                }
                Text(content)
                    .font(.ui(13))
                    .foregroundStyle(Tok.fg2)
                    .lineSpacing(3)
                    .lineLimit(noticeExpanded ? nil : 3)
                    .multilineTextAlignment(.leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
        .buttonStyle(.press)
        .padding(.horizontal, 16)
        .padding(.top, 22)
    }

    // MARK: - 书架

    private var shelfSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupLabel("书架")
            if let shelf, !shelf.books.isEmpty {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(shelf.books) { book in shelfItem(book) }
                    }
                    .padding(.vertical, 6)
                }
                .contentMargins(.horizontal, 20, for: .scrollContent)
                .scrollIndicators(.hidden)
            } else if shelf?.isFinished == true || shelf?.errorMessage != nil {
                Text("书架是空的")
                    .font(.ui(14))
                    .foregroundStyle(Tok.fg3)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .cardSurface()
                    .padding(.horizontal, 16)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 64)
            }
        }
    }

    private func shelfItem(_ book: SearchBook) -> some View {
        let id = "wolf-\(book.id)"
        return Button {
            app.openDetail(book.toBook(), sourceID: id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                BookCover(search: book)
                    .frame(width: 84)
                    .coverShadow()
                    .zoomSource(id)
                Text(book.name.withoutEmoji)
                    .font(.ui(12))
                    .foregroundStyle(Tok.fg2)
                    .lineLimit(1)
                    .frame(width: 84, alignment: .leading)
            }
        }
        .buttonStyle(.pressSoft)
    }

    // MARK: - 账号与设备

    private func accountSection(_ profile: WolfProfile) -> some View {
        VStack(spacing: 0) {
            GroupLabel("账号")
            CardGroup(separatorInset: 20) {
                infoRow("邮箱", profile.maskedEmail)
                if !profile.userKey.isEmpty {
                    copyRow("密钥", masked: Self.mask(profile.userKey, keep: 4), full: profile.userKey)
                }
                if !profile.inviteCode.isEmpty {
                    copyRow("邀请码", masked: Self.mask(profile.inviteCode, keep: 2), full: profile.inviteCode)
                }
                if let registered = WolfProfile.date(profile.registerTime) { infoRow("注册时间", registered) }
                infoRow("最近阅读", WolfProfile.date(profile.lastReadTime) ?? "未阅读")
            }
            .padding(.horizontal, 16)
        }
    }

    /// 与网页一致：IP 最近 10 分钟内访问过才算在线，过期由服务器自动移除
    private func deviceSection(_ profile: WolfProfile, account: WolfAccount) -> some View {
        let devices = profile.devices
        return VStack(spacing: 0) {
            GroupLabel("在线 IP")
            CardGroup(separatorInset: 58) {
                if devices.isEmpty {
                    Text("暂无在线 IP")
                        .font(.ui(14))
                        .foregroundStyle(Tok.fg3)
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                    let current = device.ip == profile.userIP
                    SettingRow(icon: current ? "iphone" : "iphone.gen1", title: current ? "当前 IP" : "IP \(index + 1)", chevron: false) {
                        HStack(spacing: 12) {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(Self.maskIP(device.ip))
                                Text(current ? Formats.relative(device.lastActive) : Self.offline(device.lastActive))
                                    .font(.ui(11))
                                    .foregroundStyle(current ? Tok.accentInk : Tok.fg3)
                            }
                            Button {
                                removing = device
                            } label: {
                                Image(icon: "minus.circle")
                                    .font(.system(size: 17))
                                    .foregroundStyle(Tok.fg3)
                                    .frame(width: 32, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.press)
                            .accessibilityLabel("移除")
                        }
                    }
                }
                if !devices.isEmpty {
                    Button {
                        clearingAll = true
                    } label: {
                        SettingRow(icon: "trash", title: "清除全部", chevron: false, tint: Tok.accentInk)
                    }
                    .buttonStyle(.row)
                    .disabled(clearing)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private static func maskIP(_ ip: String) -> String {
        let v4 = ip.split(separator: ".")
        if v4.count == 4 { return v4.prefix(3).joined(separator: ".") + ".*" }
        let v6 = ip.split(separator: ":", omittingEmptySubsequences: false)
        if v6.count >= 2 { return "\(v6[0]):\(v6[1]):****" }
        return ip
    }

    private static func offline(_ lastActive: Date) -> String {
        let minutes = Int(ceil(lastActive.addingTimeInterval(600).timeIntervalSinceNow / 60))
        return minutes > 0 ? "\(minutes) 分钟后下线" : "即将下线"
    }

    private var logoutRow: some View {
        CardGroup {
            Button {
                loggingOut = true
            } label: {
                SettingRow(icon: "rectangle.portrait.and.arrow.right", title: "退出登录", chevron: false, tint: Tok.accentInk)
            }
            .buttonStyle(.row)
        }
        .padding(.horizontal, 16)
        .padding(.top, 22)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        SettingRow(title: title, chevron: false) { Text(value) }
    }

    private func copyRow(_ title: String, masked: String, full: String) -> some View {
        Button {
            UIPasteboard.general.string = full
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            app.island.show("doc.on.doc", "已复制\(title)")
        } label: {
            SettingRow(title: title, chevron: false) {
                HStack(spacing: 6) {
                    Text(masked)
                    Image(icon: "doc.on.doc").font(.system(size: 12))
                }
            }
        }
        .buttonStyle(.row)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(icon: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 34, weight: .light))
            Text(message).font(.ui(14)).multilineTextAlignment(.center)
            Button {
                Task { await account?.load() }
            } label: {
                Label("重试", icon: "arrow.clockwise")
                    .font(.ui(14, .medium))
                    .foregroundStyle(Tok.fg)
                    .chip(.raised)
            }
            .buttonStyle(.press)
        }
        .foregroundStyle(Tok.fg3)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
        .padding(.top, 100)
    }

    // MARK: - 操作

    private func load() async {
        let environment = app.library.environment
        loadedCookie = environment.cookies.getCookie(url: base)
        let account = WolfAccount(base: base, environment: environment)
        self.account = account
        let list = app.library.exploreList(source: source, url: WolfCenter.shelfURL(base: base, environment: environment))
        shelf = list
        async let books: Void = list.loadMore()
        await account.load()
        await books
    }

    private func remove(_ device: WolfDevice) {
        guard let account else { return }
        Task {
            do {
                try await account.removeDevice(device.ip)
                app.island.show("checkmark", "已移除 \(Self.maskIP(device.ip))")
            } catch {
                app.island.show("exclamationmark.triangle", error.localizedDescription, danger: true)
            }
        }
    }

    private func clearAll() {
        guard let account else { return }
        clearing = true
        Task {
            do {
                try await account.clearDevices()
                app.island.show("checkmark", "已清除全部 IP")
            } catch {
                app.island.show("exclamationmark.triangle", error.localizedDescription, danger: true)
            }
            clearing = false
        }
    }

    /// 走书源自己的 logout()，与登录页的「退出登录」一致
    private func logout() {
        let webBook = app.library.webBook(for: source)
        let action = webBook.loginRows.first { $0.type == .button && ($0.action ?? "").contains("logout") }?.action
        Task {
            do {
                if let action {
                    try await webBook.runLoginAction(action, formData: webBook.savedLoginInfo)
                } else {
                    app.library.environment.cookies.removeCookie(url: base)
                    app.library.environment.sourceLoginDidChange(source.bookSourceUrl)
                }
                app.island.show("rectangle.portrait.and.arrow.right", "已退出登录")
                onLogout()
            } catch {
                app.island.show("exclamationmark.triangle", error.localizedDescription, danger: true)
            }
        }
    }

    private static func mask(_ text: String, keep: Int) -> String {
        guard text.count > keep * 2 else { return text }
        return text.prefix(keep) + "…" + text.suffix(keep)
    }
}
