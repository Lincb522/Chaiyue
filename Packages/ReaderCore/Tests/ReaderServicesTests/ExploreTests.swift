import Foundation
import ReaderModels
@testable import ReaderServices
import RuleEngine
import Testing

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

@Suite("发现页")
@MainActor
struct ExploreTests {
    func kind(_ json: String) throws -> ExploreKind {
        try JSONDecoder().decode(ExploreKind.self, from: Data(json.utf8))
    }

    @Test func 条目类型判定() throws {
        #expect(try kind(#"{"title":"分类"}"#).role == .title)
        #expect(try kind(#"{"title":"玄幻","url":"/list/{{page}}"}"#).role == .category(url: "/list/{{page}}"))
        #expect(try kind(#"{"title":"登录","url":"{{java.startBrowser('https://a.com','登录')}}"}"#).role
            == .script("java.startBrowser('https://a.com','登录')"))
        #expect(try kind(#"{"title":"翻页","url":"{{'/list/' + page}}"}"#).role == .category(url: "{{'/list/' + page}}"))
        #expect(try kind(#"{"title":"排序","type":"select","chars":["热门","最新"]}"#).role == .select(options: ["热门", "最新"]))
        #expect(try kind(#"{"title":"完结","type":"toggle","chars":["是","否"]}"#).role == .toggle(options: ["是", "否"]))
        #expect(try kind(#"{"title":"关键词","type":"text"}"#).role == .text)
        #expect(try kind(#"{"title":"刷新","type":"button","action":"x"}"#).role == .button)
    }

    @Test func 控件取值切换与持久化() async throws {
        let kinds = """
        [{"title":"排序","type":"select","chars":["热门","最新"],"action":"source.put('排序', infoMap.get('排序'))"},\
        {"title":"完结","type":"toggle","chars":["全部","完结","连载"],"default":"完结","action":"source.put('完结', infoMap.get('完结'))"},\
        {"title":"关键词","type":"text","action":"source.put('关键词', infoMap.get('关键词'))"},\
        {"title":"登录","url":"{{source.put('登录', '是')}}"}]
        """
        let escaped = String(decoding: try JSONSerialization.data(withJSONObject: [kinds], options: .fragmentsAllowed), as: UTF8.self)
        let src = try source("https://e.test", "E", extra: #","exploreUrl":\#(escaped.dropFirst().dropLast())"#)
        let env = SourceEnvironment(http: StubTransport(), store: MemoryKeyValueStore(), deviceID: "test")

        let session = ExploreSession(source: src, environment: env)
        await session.load()
        #expect(session.errorMessage == nil)
        let byTitle = Dictionary(uniqueKeysWithValues: session.kinds.map { ($0.title, $0) })
        let sort = try #require(byTitle["排序"])
        let done = try #require(byTitle["完结"])
        let keyword = try #require(byTitle["关键词"])
        let login = try #require(byTitle["登录"])

        #expect(session.value(for: sort) == "热门")
        #expect(session.value(for: done) == "完结")
        await session.select("最新", for: sort)
        await session.toggle(done)
        #expect(session.value(for: done) == "连载")
        await session.toggle(done)
        #expect(session.value(for: done) == "全部")
        session.setText("龙", for: keyword)
        await session.submit(keyword)
        await session.press(login)
        #expect(session.errorMessage == nil)

        let web = WebBook(source: src, environment: env)
        #expect(try await web.evalJS("source.get('排序')") == "最新")
        #expect(try await web.evalJS("source.get('完结')") == "全部")
        #expect(try await web.evalJS("source.get('关键词')") == "龙")
        #expect(try await web.evalJS("source.get('登录')") == "是")

        let reopened = ExploreSession(source: src, environment: env)
        #expect(reopened.value(for: sort) == "最新")
        #expect(reopened.infoMap["关键词"] == "龙")
    }

    @Test func 书单去重与到底判定() async throws {
        let transport = StubTransport()
        transport.on("https://e.test/list/1", json: #"[{"n":"甲","u":"/b/1"},{"n":"乙","u":"/b/2"}]"#)
        transport.on("https://e.test/list/2", json: #"[{"n":"乙","u":"/b/2"},{"n":"丙","u":"/b/3"}]"#)
        transport.on("https://e.test/list/3", json: #"[{"n":"丙","u":"/b/3"}]"#)
        let env = SourceEnvironment(http: transport, store: MemoryKeyValueStore(), deviceID: "test")
        let src = try source("https://e.test", "E", extra: #","ruleExplore":{"bookList":"$[*]","name":"$.n","bookUrl":"$.u"}"#)

        let list = ExploreBookList(source: src, url: "/list/{{page}}", environment: env)
        await list.loadMore()
        #expect(list.books.map(\.name) == ["甲", "乙"])
        await list.loadMore()
        #expect(list.books.map(\.name) == ["甲", "乙", "丙"])
        #expect(!list.isFinished)
        await list.loadMore()
        #expect(list.isFinished)
        await list.loadMore()
        #expect(list.books.count == 3)

        await list.reload()
        #expect(list.books.map(\.name) == ["甲", "乙"])
        #expect(!list.isFinished)
    }

    @Test func 其它入口登录后已打开的发现页刷新() async throws {
        let login = "function login(){ cookie.setCookie('https://srv.test', 'qttoken=' + source.getLoginInfoMap().get('密钥')); }"
        let explore = "@js:cookie.getCookie('https://srv.test') ? '个人中心::https://srv.test/get_book_shelf' : '登录::{{java.toast(1)}}'"
        let extra = try JSONSerialization.data(withJSONObject: ["loginUrl": login, "exploreUrl": explore])
        let services = LibraryServices(dataDirectory: tempDirectory(), cacheDirectory: tempDirectory(), http: StubTransport())
        let src = try source("大灰狼测试源", "测试", extra: "," + String(decoding: extra, as: UTF8.self).dropFirst().dropLast())
        services.sources.importSources([src])

        let session = services.exploreSession(for: src)
        await session.load()
        #expect(session.kinds.map(\.title) == ["登录"])
        let cached = services.exploreList(source: src, url: "https://srv.test/shelf")
        #expect(services.exploreList(source: src, url: "https://srv.test/shelf") === cached)

        let notified = LockedFlag()
        let observer = NotificationCenter.default.addObserver(forName: .sourceLoginChanged, object: nil, queue: nil) { note in
            if note.object as? String == "大灰狼测试源" { notified.set() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        // 书源管理的登录弹层用的是另一个 WebBook 实例
        try await services.webBook(for: src).login(formData: ["密钥": "fake-key"])
        for _ in 0..<100 where session.kinds.map(\.title) != ["个人中心"] || !notified.value {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(notified.value)
        #expect(session.kinds.map(\.title) == ["个人中心"])
        #expect(services.exploreList(source: src, url: "https://srv.test/shelf") !== cached)
    }
}
