import SwiftUI

/// 行首图标块（原型 `.row-ic`）。`Aa` 用文字绘制：`textformat` 在中文环境会显示成「格式」
struct RowIcon: View {
    let symbol: String
    var tint: Color?
    @Environment(\.onGlass) private var onGlass

    var body: some View {
        Group {
            if symbol == "Aa" {
                Text("Aa").font(.system(size: 14, weight: .medium, design: .serif))
            } else {
                Image(icon: symbol).font(.system(size: 15, weight: .medium))
            }
        }
        .foregroundStyle(tint ?? (onGlass ? Tok.gFg : Tok.fg))
        .frame(width: 30, height: 30)
        .background(onGlass ? Tok.gFill2 : Tok.tile, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// 卡片里的设置行（原型 `.row`）：图标、名称、右侧值与箭头
struct SettingRow<Value: View>: View {
    var icon: String?
    let title: String
    var chevron = true
    var tint: Color?
    @ViewBuilder var value: Value
    @Environment(\.onGlass) private var onGlass

    var body: some View {
        HStack(spacing: 14) {
            if let icon { RowIcon(symbol: icon, tint: tint) }
            Text(title)
                .font(.ui(16))
                .foregroundStyle(tint ?? (onGlass ? Tok.gFg : Tok.fg))
                .lineLimit(1)
            Spacer(minLength: 8)
            value
                .font(.num(15))
                .foregroundStyle(onGlass ? Tok.gFg3 : Tok.fg3)
                .lineLimit(1)
            if chevron {
                Image(icon: "chevron.forward")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(onGlass ? Tok.gFg3 : Tok.fg3)
                    .padding(.leading, -6)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }
}

extension SettingRow where Value == EmptyView {
    init(icon: String? = nil, title: String, chevron: Bool = true, tint: Color? = nil) {
        self.icon = icon
        self.title = title
        self.chevron = chevron
        self.tint = tint
        value = EmptyView()
    }
}

/// 开关行
struct ToggleRow: View {
    var icon: String?
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(icon: icon, title: title, chevron: false) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(Tok.accent)
        }
    }
}

/// 卡片分组上方的小标题
struct GroupLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.ui(13))
            .tracking(0.5)
            .foregroundStyle(Tok.fg3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.top, 26)
            .padding(.bottom, 8)
    }
}

enum Formats {
    static func size(_ bytes: Int64) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 { return "\(Int(kb.rounded())) KB" }
        let mb = kb / 1024
        if mb < 1024 { return mb < 10 ? String(format: "%.1f MB", mb) : "\(Int(mb.rounded())) MB" }
        return String(format: "%.1f GB", mb / 1024)
    }

    /// 刚刚 / x 分钟前 / 今天 HH:mm / 昨天 / M月d日
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = calendar.isDate(date, equalTo: now, toGranularity: .year) ? "M月d日" : "yyyy年M月d日"
        return formatter.string(from: date)
    }

    /// 导出文件名里的日期：20261107-0815
    static func stamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: date)
    }
}

/// 系统分享面板：导出的文件先写到临时目录再分享
enum Share {
    static func file(_ data: Data, name: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
        present([url])
    }

    static func present(_ items: [Any]) {
        guard let top = SourcePresenter.topController() else { return }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = top.view
        top.present(controller, animated: true)
    }
}
