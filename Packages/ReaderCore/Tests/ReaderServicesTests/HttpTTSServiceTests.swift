import Foundation
import ReaderModels
@testable import ReaderServices
import RuleEngine
import Testing

private final class RequestCount: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func add(_ url: String) -> Int { lock.withLock { counts[url, default: 0] += 1; return counts[url]! } }
    func count(_ url: String) -> Int { lock.withLock { counts[url] ?? 0 } }
}

/// 连接后依次推送固定帧，推送完即正常关闭
private final class FixedWebSocket: WebSocketTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let frames: [WebSocketFrame]
    private var connects = 0

    init(_ frames: [WebSocketFrame]) { self.frames = frames }

    var connectCount: Int { lock.withLock { connects } }

    func connect(_ request: WebSocketRequest) async throws -> any WebSocketConnection {
        lock.withLock { connects += 1 }
        return Connection(frames)
    }

    private final class Connection: WebSocketConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [WebSocketFrame]

        init(_ frames: [WebSocketFrame]) { queue = frames }

        func send(_ frame: WebSocketFrame) async throws {}

        func receive() async throws -> WebSocketFrame? {
            lock.withLock { queue.isEmpty ? nil : queue.removeFirst() }
        }

        func close() {}
    }
}

@Suite("朗读源仓库与合成缓存")
@MainActor
struct HttpTTSServiceTests {
    @Test func 导入合并删除导出并持久化() throws {
        let file = tempDirectory().appendingPathComponent("httpTTS.json")
        let repo = HttpTTSRepository(fileURL: file)
        let a = HttpTTS(id: 1, name: "甲", url: "https://a.test/{{speakText}}")
        var b = HttpTTS(id: 2, name: "乙", url: "https://b.test/{{speakText}}")
        #expect(repo.importEngines([a, b]) == ImportSummary(added: 2))
        b.name = "乙二"
        #expect(repo.importEngines([a, b, HttpTTS(id: 3, name: "丙", url: "https://c.test")])
            == ImportSummary(added: 1, updated: 1, unchanged: 1))
        #expect(repo.engines.map(\.name) == ["甲", "乙二", "丙"])

        repo.setEnabled(false, for: [3])
        #expect(repo.enabledEngines.map(\.id) == [1, 2])
        repo.delete([1])
        #expect(repo.engine(id: 1) == nil && repo.engine(id: 2)?.name == "乙二")

        let exported = try SourceImport.httpTTS(from: repo.export([2]))
        #expect(exported.map(\.id) == [2])
        #expect(try ImportService.classify(repo.export()).count == 2)

        repo.save(HttpTTS(id: 4, name: "丁", url: "https://d.test"))
        #expect(try #require(repo.engine(id: 4)).lastUpdateTime > 0)
        repo.flush()
        #expect(HttpTTSRepository(fileURL: file).engines == repo.engines)
    }

    @Test func 统一入口导入朗读源() async throws {
        let services = LibraryServices(dataDirectory: tempDirectory(), cacheDirectory: tempDirectory(), http: StubTransport())
        let summary = try await services.importHttpTTS(text: #"{"id":5,"name":"单个","url":"https://t.test/?t={{speakText}}"}"#)
        #expect(summary == ImportSummary(added: 1))
        #expect(services.httpTTS.engines.map(\.name) == ["单个"])
        await #expect(throws: ImportError.unsupported("书源（这里只能导入朗读源）")) {
            try await services.importHttpTTS(text: #"[{"bookSourceUrl":"https://a.com","bookSourceName":"A"}]"#)
        }
        #expect(services.apply(try ImportService.classify(Data(#"[{"id":6,"name":"数组","url":"https://t.test"}]"#.utf8)))
            == ImportSummary(added: 1))
        #expect(services.httpTTS.engines.count == 2)
    }

    @Test func 预取与正式请求共用一次合成_失败不缓存() async throws {
        let transport = StubTransport()
        let counts = RequestCount()
        transport.on("https://t.test/ok") { req in
            _ = counts.add(req.url)
            return HTTPResponse(url: req.url, headers: ["Content-Type": "audio/mpeg"], body: Data("ID3\(req.url.suffix(1))".utf8))
        }
        transport.on("https://t.test/fail") { req in
            let n = counts.add(req.url)
            return n == 1
                ? HTTPResponse(url: req.url, headers: ["Content-Type": "application/json"], body: Data(#"{"msg":"忙"}"#.utf8))
                : HTTPResponse(url: req.url, headers: ["Content-Type": "audio/mpeg"], body: Data("ID3".utf8))
        }
        let services = LibraryServices(dataDirectory: tempDirectory(), cacheDirectory: tempDirectory(), http: transport)
        let tts = HttpTTS(id: 201, name: "缓存", url: "https://t.test/ok?t={{speakText}}")

        services.speech.prefetch(tts, text: "a")
        let first = try await services.synthesize(engine: tts, text: "a")
        #expect(first.data == Data("ID3a".utf8))
        #expect(services.speech.isReady(tts, text: "a"))
        _ = try await services.synthesize(engine: tts, text: "a")
        #expect(counts.count("https://t.test/ok?t=a") == 1)
        // 语速不同视为不同的句子
        _ = try await services.synthesize(engine: tts, text: "a", rate: 15)
        #expect(counts.count("https://t.test/ok?t=a") == 2)

        let failing = HttpTTS(id: 202, name: "失败", url: "https://t.test/fail")
        await #expect(throws: TTSError.server(#"{"msg":"忙"}"#)) { try await services.synthesize(engine: failing, text: "b") }
        #expect(try await services.synthesize(engine: failing, text: "b").data == Data("ID3".utf8))

        services.speech.cancelAll()
        #expect(!services.speech.isReady(tts, text: "a"))
        _ = try await services.synthesize(engine: tts, text: "a")
        #expect(counts.count("https://t.test/ok?t=a") == 3)
    }

    @Test func 超出容量淘汰最早的句子() async throws {
        let transport = StubTransport()
        transport.on("https://t.test/") { req in
            HTTPResponse(url: req.url, headers: ["Content-Type": "audio/mpeg"], body: Data("ID3".utf8))
        }
        let loader = SpeechAudioLoader(environment: SourceEnvironment(http: transport, store: MemoryKeyValueStore(), deviceID: "t"))
        loader.capacity = 2
        let tts = HttpTTS(id: 203, url: "https://t.test/?t={{speakText}}")
        for text in ["一", "二", "三"] { _ = try await loader.audio(tts, text: text) }
        #expect(!loader.isReady(tts, text: "一"))
        #expect(loader.isReady(tts, text: "二") && loader.isReady(tts, text: "三"))
    }

    @Test func WebSocket合成同样预取与缓存() async throws {
        let ws = FixedWebSocket([.text("SUQz"), .binary(Data([0xFF, 0xFB]))])
        let transport = StubTransport()
        let env = SourceEnvironment(http: transport, webSocket: ws, store: MemoryKeyValueStore(), deviceID: "t")
        let loader = SpeechAudioLoader(environment: env)
        var tts = HttpTTS(id: 204, url: "@js:java.webSocket(open(speakText))")
        tts.jsLib = """
        function open(text) { return {url: "wss://ws.test/tts", send: [text], onMessage: frame}; }
        function frame(message) { return {audio: message.type === "text" ? message.text : message.base64(0, -1)}; }
        """
        loader.prefetch(tts, text: "一")
        let audio = try await loader.audio(tts, text: "一")
        #expect(audio.data == Data("ID3".utf8) + Data([0xFF, 0xFB]) && audio.format == .mp3)
        _ = try await loader.audio(tts, text: "一")
        #expect(ws.connectCount == 1 && loader.isReady(tts, text: "一"))
    }
}
