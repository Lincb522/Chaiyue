import ReaderKit
import ReaderServices
import SwiftUI

/// 阅读设置：顶部是随设置即时变化的页面预览，下面是字号行距、字体、翻页方式与其他开关
struct ReadingSettingsScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme

    private static let preloadOptions = [0, 1, 2, 3, 5, 8, 10]

    var body: some View {
        @Bindable var settings = app.settings
        let theme = settings.theme(for: scheme)
        PageScaffold(title: "阅读设置") {
            VStack(spacing: 18) {
                PagePreview(theme: theme, font: settings.font, imported: settings.importedFont?.id,
                            size: settings.fontSize, spacing: settings.spacing)
                HStack(spacing: 10) {
                    FontSizeStepper(size: $settings.fontSize)
                    SpacingPicker(selection: $settings.spacing)
                }
                FontPicker()
                HStack(spacing: 0) {
                    ForEach(PageTurnStyle.ordered, id: \.self) { style in
                        ModeCard(style: style, selected: settings.pageStyle == style, theme: theme) {
                            guard settings.pageStyle != style else { return }
                            UISelectionFeedbackGenerator().selectionChanged()
                            settings.pageStyle = style
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 20)

            CardGroup {
                Button {
                    app.push(.fonts)
                } label: {
                    SettingRow(icon: "textformat", title: "字体") {
                        Text(settings.importedFont?.name ?? settings.font.name)
                    }
                }
                .buttonStyle(.row)
                ToggleRow(icon: "sun.max", title: "屏幕常亮", isOn: $settings.keepScreenOn)
                ToggleRow(icon: "hand.tap", title: "两侧都翻下一页", isOn: $settings.tapToTurnBothSides)
                ToggleRow(icon: "text.bubble", title: "段评", isOn: $settings.paragraphComments)
                ToggleRow(icon: "books.vertical", title: "自动加入书架", isOn: $settings.autoAddToShelf)
                Menu {
                    Picker("简繁转换", selection: $settings.conversion) {
                        ForEach(ChineseConversion.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } label: {
                    SettingRow(icon: "character.book.closed", title: "简繁转换") {
                        RollingText(text: settings.conversion.title)
                    }
                }
                Menu {
                    Picker("预加载", selection: $settings.preloadCount) {
                        ForEach(Self.preloadOptions, id: \.self) { Text($0 == 0 ? "关闭" : "\($0) 章").tag($0) }
                    }
                } label: {
                    SettingRow(icon: "arrow.down.doc", title: "预加载") {
                        RollingText(text: settings.preloadCount == 0 ? "关闭" : "\(settings.preloadCount) 章")
                    }
                }
                Button {
                    app.push(.tocRules)
                } label: {
                    SettingRow(icon: "list.number", title: "TXT 目录规则") {
                        Text("\(app.library.txtTocRules.enabledRules.count)")
                    }
                }
                .buttonStyle(.row)
            }
            .padding(.horizontal, 16)
            .padding(.top, 28)
        }
        .onChange(of: settings.conversion) { _, value in app.library.chineseConversion = value }
        .onChange(of: settings.preloadCount) { _, value in app.library.preloadCount = value }
        .onChange(of: settings.autoAddToShelf) { _, value in app.library.autoAddToShelf = value }
    }
}

/// 一小块阅读页：主题底色、字体、字号与行距都即时反映
private struct PagePreview: View {
    let theme: ReaderThemeSpec
    let font: ReaderFontChoice
    let imported: String?
    let size: Double
    let spacing: Int

    private static let sample = "　　雨是后半夜停的。巷子里的青石板还湿着，路灯把影子拉得很长。\n　　他把信折好放回口袋，抬头看了一眼对面那扇亮着的窗。"

    private func face(_ size: Double) -> Font {
        imported.map { .custom($0, fixedSize: size) } ?? font.preview(size)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
        VStack(alignment: .leading, spacing: size * 0.9) {
            Text("第一章　雨夜")
                .font(face(size * 1.3))
                .fontWeight(.semibold)
            Text(Self.sample)
                .font(face(size))
                .lineSpacing(size * ReaderSettings.lineSpacings[min(max(spacing, 0), 2)])
                .foregroundStyle(theme.fg.opacity(0.92))
        }
        .foregroundStyle(theme.fg)
        .padding(.horizontal, 24)
        .padding(.top, 26)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 220, alignment: .top)
        .background {
            if let skin = theme.skin {
                Image(skin.imageName).resizable().scaledToFill()
            } else {
                theme.bg
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(theme.isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06), lineWidth: 0.5))
        .coverShadow()
        .animation(.snappy, value: size)
        .animation(.snappy, value: spacing)
        .animation(.easeOut(duration: 0.25), value: font)
        .animation(.easeOut(duration: 0.25), value: imported)
    }
}
