import Foundation
import ReaderModels
import RuleEngine

// 用法：
// swift run SourceProbe --sources 书源.json --source 名称关键字 --store 状态文件.json
//   [--env 账号.env --login] [--search 关键词] [--explore] [--chapters N] [--eval 'js']
// 只输出数量、标题、长度等结构信息，不输出正文

struct Options {
    var sourcesPath = ""
    var sourceFilter = ""
    var storePath = ""
    var envPath: String?
    var login = false
    var search: String?
    var explore = false
    var chapters = 1
    var pick = 0
    var kind: String?
    var shape = false
    var media = false
    var eval: String?
    var fields = false
    var loginUi = false
    var actions: [String] = []
    var kinds: [String] = []

    init(_ args: [String]) {
        var i = 1
        func next() -> String {
            i += 1
            return i < args.count ? args[i] : ""
        }
        while i < args.count {
            switch args[i] {
            case "--sources": sourcesPath = next()
            case "--source": sourceFilter = next()
            case "--store": storePath = next()
            case "--env": envPath = next()
            case "--login": login = true
            case "--search": search = next()
            case "--explore": explore = true
            case "--chapters": chapters = Int(next()) ?? 1
            case "--pick": pick = Int(next()) ?? 0
            case "--kind": kind = next()
            case "--shape": shape = true
            case "--media": media = true
            case "--eval": eval = next()
            case "--fields": fields = true
            case "--login-ui": loginUi = true
            case "--action": actions.append(next())
            case "--kinds": kinds = next().components(separatedBy: ",")
            default: break
            }
            i += 1
        }
    }
}

func short(_ s: String?, _ n: Int = 60) -> String {
    guard let s else { return "nil" }
    let one = s.replacingOccurrences(of: "\n", with: "⏎")
    return one.count > n ? String(one.prefix(n)) + "…(\(one.count))" : one
}

func readEnv(_ path: String) -> [String: String] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
    var map: [String: String] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
        guard let eq = line.firstIndex(of: "="), !line.hasPrefix("#") else { continue }
        map[String(line[..<eq]).trimmingCharacters(in: .whitespaces)] =
            String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
    }
    return map
}

/// 结构视图：汉字替换为「字」，用于检查排版结构而不暴露正文
func shapeOf(_ text: String, limit: Int = 500) -> String {
    var out = ""
    for ch in text.prefix(limit) {
        if let scalar = ch.unicodeScalars.first, (0x4E00...0x9FFF).contains(scalar.value) {
            out.append("字")
        } else if ch == "\n" {
            out.append("⏎")
        } else {
            out.append(ch)
        }
    }
    return out.replacingOccurrences(of: "字字字字字字字字字字", with: "…")
}

func step<T>(_ name: String, _ body: () async throws -> T) async -> T? {
    let start = Date()
    do {
        let value = try await body()
        print("✅ \(name)（\(String(format: "%.1f", Date().timeIntervalSince(start)))s）")
        return value
    } catch {
        print("❌ \(name)：\(short("\(error)", 300))")
        return nil
    }
}

let options = Options(CommandLine.arguments)
guard let data = FileManager.default.contents(atPath: options.sourcesPath) else {
    print("无法读取书源文件")
    exit(1)
}
let sources = try SourceImport.bookSources(from: data)
guard let source = sources.first(where: { $0.bookSourceName.contains(options.sourceFilter) }) else {
    print("未找到书源：\(options.sourceFilter)；可选：\(sources.map(\.bookSourceName))")
    exit(1)
}
print("书源：\(source.bookSourceName)（key=\(source.bookSourceUrl)）")

let store = FileKeyValueStore(fileURL: URL(fileURLWithPath: options.storePath))
let env = SourceEnvironment(store: store)
env.setLogger { _, message in print("  [log] \(short(message, 160))") }
let ui = HeadlessSourceUI(onToast: { print("  [toast] \(short($0, 400))") })
env.setUIDelegate(ui)
env.setEventHandler { print("  [event] \($0)") }
print("设备 ID 末 6 位：\(env.deviceID.suffix(6))")
let webBook = WebBook(source: source, environment: env)

if options.login, let envPath = options.envPath {
    let account = readEnv(envPath)
    let email = account["YUNDUAN_EMAIL"] ?? ""
    let password = account["YUNDUAN_PASSWORD"] ?? ""
    let rows = webBook.loginRows
    print("登录表单：\(rows.filter { $0.type != .button }.map(\.name))，按钮 \(rows.filter { $0.type == .button }.count) 个")
    let action = rows.first { $0.type == .button && ($0.action ?? "").hasPrefix("login(") }?.action ?? "login(true)"
    _ = await step("登录 \(action)") {
        try await webBook.runLoginAction(action, formData: ["邮箱": email, "密码": password])
    }
    print("  登录头：\(webBook.loginHeader == nil ? "无" : "已保存（\(webBook.loginHeader!.count) 字符）")")
}

if options.loginUi {
    if let rows = await step("登录界面", { try await webBook.resolveLoginRows() }) {
        print("  共 \(rows.count) 个控件")
        for row in rows {
            let extra = [row.chars.map { "选项\($0.count)个" }, row.defaultValue.map { "默认=\(short($0, 20))" }]
                .compactMap { $0 }.joined(separator: " ")
            print("  - [\(row.type.rawValue)] \(short(row.name, 30)) \(row.action.map { "→ " + short($0, 50) } ?? "") \(extra)")
        }
    }
}
for action in options.actions {
    _ = await step("按钮 \(short(action, 40))") { try await webBook.runLoginAction(action, formData: [:]) }
}

func printFields(_ books: [SearchBook]) {
    guard options.fields else { return }
    for b in books.prefix(3) {
        print("    · 《\(b.name)》作者=\(short(b.author, 20)) 分类=\(short(b.kind, 40)) 字数=\(b.wordCount ?? "-")")
        print("      最新=\(short(b.latestChapterTitle, 40)) 封面=\(short(b.coverUrl, 70))")
        print("      简介=\(short(b.intro, 50)) 地址=\(short(b.bookUrl, 90))")
    }
}

if let js = options.eval {
    if let out = await step("执行脚本", { try await webBook.evalJS(js) }) {
        print("  结果：\(short(out, 400))")
    }
}

if options.explore {
    if let kinds = await step("发现页分类", { try await webBook.exploreKinds(refresh: true) }) {
        print("  共 \(kinds.count) 项：" + kinds.prefix(12).map { "\($0.title)[\($0.type ?? "url")]" }.joined(separator: "、"))
        let candidates = kinds.filter {
            !($0.url ?? "").isEmpty && !($0.url ?? "").contains("startBrowser") && ($0.type == nil || $0.type == "url")
        }
        var picked = options.kinds.compactMap { k in candidates.first { $0.title.contains(k) } }
        if picked.isEmpty, let first = options.kind.flatMap({ k in candidates.first { $0.title.contains(k) } }) ?? candidates.first {
            picked = [first]
        }
        for kind in picked {
            print("  分类 url：\(short(kind.url, 120))")
            if let books = await step("发现：\(kind.title)", { try await webBook.exploreBook(url: kind.url!) }) {
                print("  \(books.count) 本：" + books.prefix(3).map { "《\($0.name)》\($0.author)" }.joined(separator: "、"))
                printFields(books)
            }
        }
    }
}

if let keyword = options.search {
    let results = await step("搜索「\(keyword)」") { try await webBook.searchBook(keyword) } ?? []
    print("  \(results.count) 条：" + results.prefix(5).map { "《\($0.name)》\($0.author)" }.joined(separator: "、"))
    printFields(results)
    if results.indices.contains(options.pick) {
        let first = results[options.pick]
        print("  首条 bookUrl：\(short(first.bookUrl, 80))")
        if let book = await step("详情", { try await webBook.getBookInfo(first.toBook()) }) {
            print("  类型=\(book.type)")
            print("  《\(book.name)》\(book.author) 分类=\(short(book.kind, 30)) 字数=\(book.wordCount ?? "-") 最新=\(short(book.latestChapterTitle, 30))")
            print("  简介 \(book.intro?.count ?? 0) 字，封面=\(book.coverUrl == nil ? "无" : "有")，tocUrl=\(short(book.tocUrl, 80))")
            if let (tocBook, chapters) = await step("目录", { try await webBook.getChapterList(book) }) {
                print("  目录后类型=\(tocBook.type)")
                let vip = chapters.filter(\.isVip).count
                print("  共 \(chapters.count) 章（VIP \(vip)）：\(chapters.prefix(3).map(\.title))…\(chapters.last?.title ?? "")")
                for (i, chapter) in chapters.prefix(options.chapters).enumerated() {
                    let next = i + 1 < chapters.count ? chapters[i + 1].url : nil
                    if let (content, updated) = await step("正文：\(updated(chapter))", {
                        try await webBook.getContent(tocBook, chapter: chapter, nextChapterUrl: next)
                    }) {
                        let lines = content.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                        let images = content.components(separatedBy: "<img").count - 1
                        print("  正文 \(content.count) 字符，\(lines.count) 段，图片 \(images) 个，标题=\(updated.title)")
                        if options.shape { print("  结构：\(shapeOf(content))") }
                        if options.media { print("  媒体：\(mediaShape(content))") }
                    }
                }
            }
        }
    }
}

func updated(_ chapter: BookChapter) -> String { chapter.title }

/// 媒体正文的结构：链接只保留协议、域名、扩展名和参数名，不输出参数值（可能含令牌）
func mediaShape(_ content: String) -> String {
    let links = content.matches(of: /https?:\/\/[^\s"'<>,]+/).map { String($0.output) }
    let described = links.prefix(4).map { link -> String in
        guard let url = URLComponents(string: link) else { return "?" }
        let ext = (url.path as NSString).pathExtension
        let keys = url.queryItems?.map(\.name).joined(separator: ",") ?? ""
        return "\(url.scheme ?? "")://\(url.host ?? "")/…\(ext.isEmpty ? "" : "." + ext)\(keys.isEmpty ? "" : " ?[\(keys)]")"
    }
    let head = shapeOf(content.replacing(/https?:\/\/[^\s"'<>,]+/, with: "<URL>"), limit: 200)
    return "链接 \(links.count) 个 \(described)；开头：\(head)"
}

store.flush()
