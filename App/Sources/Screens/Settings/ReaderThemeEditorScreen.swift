import ReaderKit
import SwiftUI
import UniformTypeIdentifiers

/// 主题编辑：上方是与阅读页同一套排版绘制的实时预览，下方分样式表、脚本、HTML 装饰层（网页模式）、素材
struct ReaderThemeEditorScreen: View {
    let id: String
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss

    private enum Tab: String, CaseIterable {
        case css = "样式表", js = "脚本", html = "HTML", assets = "素材"
    }

    @State private var name = ""
    @State private var css = ""
    @State private var js = ""
    @State private var html = ""
    @State private var mode: ReaderThemeMode = .native
    @State private var loaded = false
    @State private var tab: Tab = .css
    @State private var dark = false
    @State private var page = 0
    @State private var preview: UIImage?
    @State private var issues: [String] = []
    @State private var webIssues: [String] = []
    @State private var expanded = false
    @State private var pickingAsset = false
    /// 网页预览防抖后的内容
    @State private var webSource = (css: "", js: "", html: "")

    private var store: ReaderThemeStore { ReaderThemeStore.shared }
    private var tabs: [Tab] { mode == .web ? Tab.allCases : [.css, .js, .assets] }
    private var shownIssues: [String] { mode == .web ? webIssues : issues }

    var body: some View {
        ZStack(alignment: .top) {
            ScreenBackground()
            VStack(spacing: 12) {
                previewCard
                controls
                Group {
                    switch tab {
                    case .css: CodeEditor(text: $css)
                    case .js: CodeEditor(text: $js)
                    case .html: CodeEditor(text: $html)
                    case .assets: assetsPane
                    }
                }
                .background(Tok.fill.opacity(0.5), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 12)
                if !shownIssues.isEmpty, tab != .assets { issueList }
            }
            .padding(.top, 50)
            .ignoresSafeArea(.container, edges: .bottom)
            PageBar(title: name, scrolled: true) {
                CircleButton(systemName: "checkmark") { save() }
            }
        }
        .onAppear(perform: load)
        .onAppear { dark = scheme == .dark }
        .task(id: renderKey) {
            try? await Task.sleep(for: .milliseconds(loaded && (preview != nil || mode == .web) ? 300 : 0))
            guard !Task.isCancelled else { return }
            render()
        }
        .onChange(of: mode) { _, new in
            if new != .web, tab == .html { tab = .css }
        }
        .onChange(of: pickingAsset) { _, on in
            guard on else { return }
            pickingAsset = false
            FilePicker.present([.image, .font, .data], multiple: true) { urls in addAssets(urls) }
        }
        .fullScreenCover(isPresented: $expanded) { expandedPreview }
    }

    private var renderKey: String {
        "\(css.hashValue)|\(js.hashValue)|\(html.hashValue)|\(mode)|\(dark)|\(page)|\(store.revision)|\(app.settings.fontSize)|\(loaded)"
    }

    // MARK: - 预览

    private var previewHeight: CGFloat { 250 }

    private var previewCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if mode == .web {
                    webPreview(interactive: false)
                        .frame(width: screenSize.width, height: screenSize.height)
                        .scaleEffect(previewHeight / screenSize.height, anchor: .topLeading)
                        .frame(width: screenSize.width * previewHeight / screenSize.height, height: previewHeight, alignment: .topLeading)
                } else if let preview {
                    Image(uiImage: preview).resizable().scaledToFit()
                } else {
                    Color.clear
                }
            }
            .frame(height: previewHeight)
            .aspectRatio(screenSize.width / screenSize.height, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Tok.line, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .contentShape(Rectangle())
            .onTapGesture { expanded = true }

            VStack(alignment: .leading, spacing: 10) {
                TextField("主题名称", text: $name)
                    .font(.ui(17, .semibold))
                    .foregroundStyle(Tok.fg)
                    .submitLabel(.done)
                previewToggle(title: mode == .web ? "网页渲染" : "原生排版", icon: mode == .web ? "globe" : "textformat") {
                    mode = mode == .web ? .native : .web
                    if mode == .web, html.isEmpty { html = ReaderThemeStore.webTemplateHTML }
                }
                previewToggle(title: dark ? "深色" : "浅色", icon: dark ? "moon" : "sun.max") { dark.toggle() }
                previewToggle(title: page == 0 ? "章首页" : "正文页", icon: "doc.text") { page = page == 0 ? 1 : 0 }
                previewToggle(title: "使用", icon: "checkmark.circle") { save(apply: true) }
                Spacer(minLength: 0)
                Text(mode == .web ? "点预览图全屏试读" : "点预览图放大").font(.ui(11)).foregroundStyle(Tok.fg3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: previewHeight)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var expandedPreview: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if mode == .web {
                webPreview(interactive: true).ignoresSafeArea()
            } else if let preview {
                Image(uiImage: preview).resizable().scaledToFit().ignoresSafeArea()
                    .onTapGesture { expanded = false }
            }
            Button { expanded = false } label: {
                Image(icon: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.press)
            .padding(.trailing, 18)
            .padding(.top, 6)
        }
        .statusBarHidden()
    }

    private func webPreview(interactive: Bool) -> some View {
        let raw = AppearanceStore.keyWindow?.safeAreaInsets ?? UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        let style = ReaderStyleSheet(css: webSource.css).resolve(dark: dark)
        var spec = ReaderThemeStore.spec(id: id, name: name, style: style, dark: dark)
        spec.web = true
        return WebThemePreview(themeID: id, css: webSource.css, js: webSource.js, html: webSource.html, dark: dark, page: page,
                               size: screenSize, insets: EdgeInsets(top: raw.top, leading: 0, bottom: raw.bottom, trailing: 0),
                               typography: app.settings.typography, theme: spec, title: Self.sampleTitle,
                               paragraphs: Self.sample, interactive: interactive) { issue in
            if !webIssues.contains(issue) { webIssues.append(issue) }
        }
    }

    private func previewToggle(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            action()
        } label: {
            Label(title, icon: icon)
                .font(.ui(14, .medium))
                .foregroundStyle(Tok.fg)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Tok.fill, in: Capsule())
        }
        .buttonStyle(.press)
    }

    private var controls: some View {
        Picker("", selection: $tab) {
            ForEach(tabs, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
    }

    private var issueList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(shownIssues.enumerated()), id: \.offset) { _, issue in
                    Text(issue).font(.system(size: 12, design: .monospaced)).foregroundStyle(Tok.fg2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
        }
        .frame(maxHeight: 96)
        .background(Tok.fill.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 24)
    }

    // MARK: - 素材

    private var assetsPane: some View {
        let names = store.imageNames(id)
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(mode == .web
                     ? "图片、字体等素材在样式表里用 url(文件名) 引用，HTML 里写 src=\"文件名\"；字体配合 @font-face 使用。点素材复制引用写法。"
                     : "在样式表里写 background-image: url(文件名) 引用；点图片复制引用写法。")
                    .font(.ui(13)).foregroundStyle(Tok.fg3)
                ForEach(names, id: \.self) { file in
                    HStack(spacing: 12) {
                        Group {
                            if let image = store.image(id, named: file) {
                                Image(uiImage: image).resizable().scaledToFill()
                            } else {
                                Image(icon: Self.isFont(file) ? "textformat" : "doc")
                                    .font(.system(size: 20)).foregroundStyle(Tok.fg2)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(Tok.fill)
                            }
                        }
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Text(file).font(.system(size: 14, design: .monospaced)).foregroundStyle(Tok.fg).lineLimit(1)
                        Spacer()
                        Button(role: .destructive) {
                            store.removeImage(file, from: id)
                        } label: {
                            Image(icon: "trash").foregroundStyle(Tok.fg3).frame(width: 36, height: 36)
                        }
                        .buttonStyle(.press)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { copyReference(file) }
                }
                Button {
                    pickingAsset = true
                } label: {
                    Label("添加素材", icon: "plus")
                        .font(.ui(15, .medium))
                        .foregroundStyle(Tok.fg)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Tok.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.press)
            }
            .padding(14)
        }
    }

    private static func isFont(_ file: String) -> Bool {
        ["ttf", "otf", "woff", "woff2", "ttc"].contains((file as NSString).pathExtension.lowercased())
    }

    private func copyReference(_ file: String) {
        let text: String
        if Self.isFont(file) {
            let family = (file as NSString).deletingPathExtension
            text = "@font-face { font-family: \"\(family)\"; src: url(\"\(file)\"); }"
        } else {
            text = "url(\"\(file)\")"
        }
        UIPasteboard.general.string = text
        app.island.show("doc.on.doc", "已复制引用写法")
    }

    private func addAssets(_ urls: [URL]) {
        for url in urls {
            do {
                _ = try store.addImage(url, to: id)
            } catch {
                app.island.show("exclamationmark.triangle", "素材导入失败", danger: true)
            }
        }
    }

    // MARK: - 读写

    private func load() {
        guard !loaded, let theme = store.theme(id) else { return }
        name = theme.name
        css = theme.css
        js = theme.js
        html = theme.html
        mode = theme.mode
        webSource = (css, js, html)
        loaded = true
    }

    private func save(apply: Bool = false) {
        guard var theme = store.theme(id) else { return }
        theme.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? theme.name : name
        theme.css = css
        theme.js = js
        theme.html = html
        theme.mode = mode
        store.save(theme)
        if apply || app.settings.customTheme == id, let saved = store.theme(id) { app.settings.use(saved) }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        app.island.show("checkmark", apply ? "已保存并使用" : "已保存")
        if !apply { dismiss() }
    }

    // MARK: - 渲染

    private var screenSize: CGSize {
        AppearanceStore.keyWindow?.bounds.size ?? CGSize(width: 402, height: 874)
    }

    private static let sampleTitle = "第十二章 雨夜来客"

    private static let sample = [
        "雨是后半夜停的。巷子里的青石板还湿着，路灯把影子拉得很长，他把伞收拢，站在屋檐下听了很久。",
        "“你来晚了。”门里的人没有回头，声音低得像是从很远的地方传过来。",
        "他没有答话，只是把信从怀里取出来，放在桌角。灯芯跳了一下，墙上的影子跟着晃了晃。",
        "“信我看过了。”那人终于转过身，“可你要的东西，不在这里。”",
        "窗外又起了风，檐角的铜铃一声接一声地响。他忽然想起很多年前的那个夜晚，也是这样的风，也是这样的铃声，只是那时候屋里点着两盏灯。",
        "他在桌边坐下，替自己倒了一杯冷茶。茶早就凉透了，入口带着一点涩，像是放了一整个下午。",
        "“那就告诉我，它在哪里。”",
        "那人沉默了很久，久到他以为不会再有回答。直到灯花爆开，屋里亮了一瞬，才听见一句极轻的话。",
        "“城南，旧书铺。”",
        "他点了点头，把杯子放回原处，起身推门出去。雨后的空气很凉，巷子尽头有人挑着担子走过，扁担吱呀吱呀地响，一直响到听不见为止。",
        "旧书铺的门板只卸了一半，掌柜坐在柜台后面打盹，听见脚步声才抬起眼皮。架上的书堆得很高，有的已经发黄卷边，空气里有一股淡淡的霉味和墨香。",
        "“找什么？”掌柜问。",
        "“一本没有名字的书。”他说。",
    ]

    private func render() {
        if mode == .web {
            webIssues = []
            webSource = (css, js, html)
            return
        }
        let size = screenSize
        let raw = AppearanceStore.keyWindow?.safeAreaInsets ?? UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        let sheet = ReaderStyleSheet(css: css)
        let style = sheet.resolve(dark: dark)
        let spec = ReaderThemeStore.spec(id: id, name: name, style: style, dark: dark)
        let metrics = ReaderStage.metrics(size: size, insets: EdgeInsets(top: raw.top, leading: 0, bottom: raw.bottom, trailing: 0),
                                          fontSize: app.settings.fontSize, page: style.page)
        let script = ReaderThemeScript(source: js)
        var problems = sheet.diagnostics.map { "第 \($0.line) 行：\($0.message)" }
        if let error = script.error { problems.insert("脚本：\(error)", at: 0) }
        let typography = app.settings.typography(for: spec)
        let content = ReaderModel.compose(title: Self.sampleTitle, paragraphs: Self.sample, typography: typography, theme: spec,
                                          maxImageSize: metrics.textFrame.size,
                                          classes: script.hasParagraphClass && !style.classes.isEmpty ? script.paragraphClasses(Self.sample) : [:])
        let layout = ChapterPaginator.layout(chapterIndex: 11, title: Self.sampleTitle, content: content,
                                             pageSize: metrics.textFrame.size, justify: true)
        let index = min(page, layout.pageCount - 1)
        let ctx = ReaderScriptContext(book: "雨夜来客", author: "柴阅", chapter: Self.sampleTitle, chapterIndex: 11, chapterCount: 120,
                                      page: index + 1, pages: layout.pageCount, percent: 9.6,
                                      time: Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)), battery: 80)
        let header = script.header(ctx) ?? ReaderChromeText(left: index == 0 ? "雨夜来客" : Self.sampleTitle)
        let footer = script.footer(ctx) ?? ReaderChromeText(left: "\(index + 1) / \(layout.pageCount)", right: "9.6%")
        problems += script.log.map { "脚本：\($0)" }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        preview = UIGraphicsImageRenderer(size: size, format: format).image { context in
            PagePainter.draw(in: context.cgContext, bounds: CGRect(origin: .zero, size: size), theme: spec, metrics: metrics,
                             header: header, footer: footer, page: (layout, index))
        }
        issues = problems
    }
}
